//! 配置管道与合并入口的 golden 测试。
//!
//! golden 期望输出是阶段 5 第 1 步用当时的 Dart 镜像（`applyConfigPatch` + qjs）跑出来的
//! 快照，随后 Dart 镜像与 qjs 路径已在第 3 步删除，它现在是配置管道唯一的跨版本回归网：
//! 这里只读 golden、驱动 C ABI、逐字段比对，`cargo test` 一条命令即可覆盖整条管道，
//! 不需要 flutter、也不依赖已删除的参照实现（路线稿 §1.5 第 1、2 步）。
//!
//! golden 需要更新时的做法见 `fixtures/golden/README.txt` 与 [`regenerate_golden`]。
//!
//! 覆盖范围：`bb_patch_config`（无脚本时的配置改写）与 `bb_process_profile`
//! （脚本 + 改写的合并入口）。脚本引擎的其余入口（`bb_eval_script`、
//! `bb_extract_script_options`）由 `tests/script_engine.rs` 覆盖。

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::PathBuf;
use std::ptr;

use serde_json::Value;

fn golden_dir(entry: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures/golden")
        .join(entry)
}

/// 读一整组 golden 用例，按文件名排序保证输出稳定。
fn load_cases(entry: &str) -> Vec<(String, Value)> {
    golden_paths(entry)
        .into_iter()
        .map(|path| {
            let text = std::fs::read_to_string(&path)
                .unwrap_or_else(|error| panic!("读取 {} 失败：{error}", path.display()));
            let value: Value = serde_json::from_str(&text)
                .unwrap_or_else(|error| panic!("解析 {} 失败：{error}", path.display()));
            let name = path
                .file_stem()
                .map(|stem| stem.to_string_lossy().into_owned())
                .unwrap_or_default();
            (name, value)
        })
        .collect()
}

/// 一组 golden 文件的路径，按文件名排序保证输出稳定。
fn golden_paths(entry: &str) -> Vec<PathBuf> {
    let dir = golden_dir(entry);
    let mut paths: Vec<PathBuf> = std::fs::read_dir(&dir)
        .unwrap_or_else(|error| panic!("读取 {} 失败：{error}", dir.display()))
        .map(|item| item.expect("读取目录项失败").path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "json")
        })
        .collect();
    paths.sort();
    assert!(
        !paths.is_empty(),
        "{} 下没有任何 golden 用例",
        dir.display()
    );
    paths
}

/// 调用 FFI 并取回字符串；返回 NULL 记作 None（本库的 ABI 级失败约定）。
fn call_ffi(call: impl FnOnce() -> *mut c_char) -> Option<String> {
    let out = call();
    if out.is_null() {
        return None;
    }
    let text = unsafe { CStr::from_ptr(out) }
        .to_str()
        .expect("FFI 返回的不是 UTF-8")
        .to_owned();
    unsafe { bettbox_native::ffi::bb_string_free(out) };
    Some(text)
}

fn cstring(value: &str) -> CString {
    CString::new(value).expect("输入里含 NUL，无法转成 C 字符串")
}

/// 只报第一处差异（带路径），语义与 Dart 侧 `firstJsonDifference` 一致：
/// 对象/数组逐层下钻；数值额外要求「整数/浮点」表示相同——`300` 与 `300.0`
/// 数值相等但序列化不一致，那属于两端行为分歧，要能看出来。
fn first_difference(expected: &Value, actual: &Value, path: &str) -> Option<String> {
    match (expected, actual) {
        (Value::Object(expected), Value::Object(actual)) => {
            for (key, value) in expected {
                match actual.get(key) {
                    Some(other) => {
                        if let Some(difference) =
                            first_difference(value, other, &format!("{path}.{key}"))
                        {
                            return Some(difference);
                        }
                    }
                    None => return Some(format!("{path}.{key}：实际侧缺失")),
                }
            }
            for key in actual.keys() {
                if !expected.contains_key(key) {
                    return Some(format!("{path}.{key}：期望侧缺失"));
                }
            }
            None
        }
        (Value::Array(expected), Value::Array(actual)) => {
            if expected.len() != actual.len() {
                return Some(format!(
                    "{path}：长度 期望={} 实际={}",
                    expected.len(),
                    actual.len()
                ));
            }
            for (index, (expected, actual)) in expected.iter().zip(actual).enumerate() {
                if let Some(difference) =
                    first_difference(expected, actual, &format!("{path}[{index}]"))
                {
                    return Some(difference);
                }
            }
            None
        }
        (Value::Number(expected), Value::Number(actual)) => {
            let same_kind = expected.is_f64() == actual.is_f64();
            let same_value = expected.as_f64() == actual.as_f64();
            if same_kind && same_value {
                None
            } else {
                Some(format!(
                    "{path}：数值 期望={expected} 实际={actual}（类型或取值不一致）"
                ))
            }
        }
        _ => {
            if expected == actual {
                None
            } else {
                Some(format!(
                    "{path}：期望={} 实际={}",
                    short(expected),
                    short(actual)
                ))
            }
        }
    }
}

fn short(value: &Value) -> String {
    let text = value.to_string();
    if text.chars().count() > 160 {
        format!("{}…", text.chars().take(160).collect::<String>())
    } else {
        text
    }
}

fn assert_matches_golden(case: &str, expected: &Value, actual: &Value) {
    if let Some(difference) = first_difference(expected, actual, "") {
        panic!("{case}: 与 golden 不一致\n{difference}");
    }
}

/// 跑 `bb_patch_config`，返回解析后的输出；NULL 即 panic。
fn actual_patch_config(name: &str, case: &Value) -> Value {
    let input = cstring(&case["input"].to_string());
    let output = call_ffi(|| unsafe { bettbox_native::ffi::bb_patch_config(input.as_ptr()) })
        .unwrap_or_else(|| panic!("{name}: bb_patch_config 返回 NULL"));
    serde_json::from_str(&output)
        .unwrap_or_else(|error| panic!("{name}: 输出不是合法 JSON：{error}"))
}

/// 跑 `bb_process_profile`，返回信封；NULL 即 panic。
fn actual_process_profile(name: &str, case: &Value) -> Value {
    let script = case["script"]
        .as_str()
        .unwrap_or_else(|| panic!("{name}: 缺 script"));
    let options = case
        .get("customOptions")
        .filter(|value| !value.is_null())
        .map(Value::to_string);

    let input = cstring(&case["input"].to_string());
    let script = cstring(script);
    let options = options.as_deref().map(cstring);
    let envelope = call_ffi(|| unsafe {
        bettbox_native::ffi::bb_process_profile(
            input.as_ptr(),
            script.as_ptr(),
            options.as_ref().map_or(ptr::null(), |value| value.as_ptr()),
        )
    })
    .unwrap_or_else(|| panic!("{name}: bb_process_profile 返回 NULL"));
    serde_json::from_str(&envelope)
        .unwrap_or_else(|error| panic!("{name}: 信封不是合法 JSON：{error}"))
}

#[test]
fn patch_config_matches_golden() {
    let cases = load_cases("patch_config");
    assert!(
        cases.len() >= 10,
        "golden 用例只有 {} 个，覆盖不足",
        cases.len()
    );

    for (name, case) in &cases {
        assert_matches_golden(name, &case["output"], &actual_patch_config(name, case));
    }
    println!("patch_config golden：{} 个用例通过", cases.len());
}

#[test]
fn process_profile_matches_golden() {
    let cases = load_cases("process_profile");
    assert!(cases.len() >= 4, "golden 用例只有 {} 个", cases.len());

    for (name, case) in &cases {
        let envelope = actual_process_profile(name, case);
        assert_eq!(
            envelope["ok"],
            Value::Bool(true),
            "{name}: 信封 ok 不为 true"
        );

        assert_matches_golden(name, &case["output"], &envelope["config"]);

        // 脚本报错的用例：错误串也要逐字一致（沿用已有的跨引擎错误串断言）。
        let expected_error = case["scriptError"].as_str();
        let actual_error = envelope.get("scriptError").and_then(Value::as_str);
        assert_eq!(expected_error, actual_error, "{name}: scriptError 不一致");
    }
    println!("process_profile golden：{} 个用例通过", cases.len());
}

/// 重新冻结 golden：用当前 Rust 管道跑 golden 里存的输入，把产出定点写回 `output`
/// （`process_profile` 连 `scriptError` 一起刷新），其余字节保持原样。
///
/// **只在有意改变管道行为时运行，且必须人工复查 diff。** Dart 镜像已删除，重新生成
/// 只是把「当前行为」记下来，不再是独立参照；无意变更就是回归，要查根因而不是重生成糊过去。
///
/// 运行：`cargo test --test golden -- --ignored regenerate_golden`
/// 输入没有变、管道行为也没变时，重生成是幂等的（文件逐字节不变）。
#[test]
#[ignore = "手动重新冻结 golden 时运行"]
fn regenerate_golden() {
    for entry in ["patch_config", "process_profile"] {
        for path in golden_paths(entry) {
            let text = std::fs::read_to_string(&path)
                .unwrap_or_else(|error| panic!("读取 {} 失败：{error}", path.display()));
            let case: Value = serde_json::from_str(&text)
                .unwrap_or_else(|error| panic!("解析 {} 失败：{error}", path.display()));
            let name = path
                .file_stem()
                .map(|stem| stem.to_string_lossy().into_owned())
                .unwrap_or_default();

            let (output, script_error) = if entry == "patch_config" {
                (actual_patch_config(&name, &case), None)
            } else {
                let envelope = actual_process_profile(&name, &case);
                assert_eq!(
                    envelope["ok"],
                    Value::Bool(true),
                    "{name}: 信封 ok 不为 true"
                );
                let error = envelope.get("scriptError").cloned().unwrap_or(Value::Null);
                (envelope["config"].clone(), Some(error))
            };

            let new_text = rewrite_case(&name, &text, &output, script_error.as_ref());
            if new_text == text {
                println!("无需改动 {}", path.display());
            } else {
                std::fs::write(&path, new_text)
                    .unwrap_or_else(|error| panic!("写入 {} 失败：{error}", path.display()));
                println!("已重新冻结 {}", path.display());
            }
        }
    }
}

/// 把新算出的结果写回 golden 文本：只替换顶层 `output`（与 `scriptError`）的**值**，
/// 其余部分（行尾风格、逗号、其它键）原样保留。
///
/// 不用「整份 `serde_json` 重写」的原因：serde_json 按字典序写键，整文件重排会让
/// 「golden 变了 = 行为变了」这条纪律失效——真正的行为变更会被格式噪音淹没。
/// 这里依赖 golden 的固定版面：`output` 是最后一个顶层键（其值独占一块，其后只剩
/// 收尾的 `}`），`scriptError` 是单行。
fn rewrite_case(name: &str, text: &str, output: &Value, script_error: Option<&Value>) -> String {
    // 工作区文件是 CRLF（`core.autocrlf=true`），写回时保持原样，别把文件改成混合行尾。
    let eol = if text.contains("\r\n") { "\r\n" } else { "\n" };

    let mut body = match script_error {
        Some(error) => {
            let value = serde_json::to_string(error).expect("序列化 scriptError 失败");
            replace_top_level_value(text, "  \"scriptError\": ", &value)
                .unwrap_or_else(|| panic!("{name}: 找不到顶层 \"scriptError\" 键"))
        }
        None => text.to_string(),
    };

    let marker = format!("{eol}  \"output\": ");
    let index = body
        .rfind(&marker)
        .unwrap_or_else(|| panic!("{name}: 找不到顶层 \"output\" 键"));
    let output_json = serde_json::to_string_pretty(output).expect("序列化 output 失败");
    body.truncate(index);
    body.push_str(&marker);
    body.push_str(&indent_after_first_line(&output_json, 2, eol));
    body.push_str(&format!("{eol}}}{eol}"));
    body
}

/// 替换以 `prefix` 开头的顶层键的值，保留原有逗号与行尾；`prefix` 不是行首则返回 None。
fn replace_top_level_value(text: &str, prefix: &str, value: &str) -> Option<String> {
    let start = text.find(prefix)?;
    if start != 0 && text.as_bytes()[start - 1] != b'\n' {
        return None;
    }
    let line_end = text[start..]
        .find('\n')
        .map(|offset| start + offset + 1)
        .unwrap_or(text.len());
    let line = &text[start..line_end];
    let eol = if line.ends_with("\r\n") {
        "\r\n"
    } else if line.ends_with('\n') {
        "\n"
    } else {
        ""
    };
    let has_comma = line[..line.len() - eol.len()].ends_with(',');

    let mut result = String::with_capacity(text.len() + value.len());
    result.push_str(&text[..start]);
    result.push_str(prefix);
    result.push_str(value);
    if has_comma {
        result.push(',');
    }
    result.push_str(eol);
    result.push_str(&text[line_end..]);
    Some(result)
}

/// 除首行外每行加 `spaces` 个空格（把 pretty 值嵌进顶层键下面），行尾统一成 `eol`。
fn indent_after_first_line(text: &str, spaces: usize, eol: &str) -> String {
    let pad = " ".repeat(spaces);
    let mut out = String::with_capacity(text.len() + text.len() / 8);
    for (index, line) in text.split('\n').enumerate() {
        if index > 0 {
            out.push_str(eol);
            out.push_str(&pad);
        }
        out.push_str(line);
    }
    out
}
