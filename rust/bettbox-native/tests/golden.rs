//! 配置管道与合并入口的 golden 测试。
//!
//! golden 期望输出由 Dart 镜像（`applyConfigPatch` + qjs）生成并入库，见
//! `fixtures/golden/README.txt` 与生成器 `test/rust/golden_generate_test.dart`。
//! 这里只读 golden、驱动 C ABI、逐字段比对——`cargo test` 一条命令即可覆盖整条管道，
//! 不再需要 flutter 与参考 dll（路线稿 §1.5 第 2 步）。
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

#[test]
fn patch_config_matches_golden() {
    let cases = load_cases("patch_config");
    assert!(
        cases.len() >= 10,
        "golden 用例只有 {} 个，覆盖不足（是不是生成器没跑全？）",
        cases.len()
    );

    for (name, case) in &cases {
        let input = case["input"].to_string();
        let input = cstring(&input);
        let output = call_ffi(|| unsafe { bettbox_native::ffi::bb_patch_config(input.as_ptr()) })
            .unwrap_or_else(|| panic!("{name}: bb_patch_config 返回 NULL"));
        let actual: Value = serde_json::from_str(&output)
            .unwrap_or_else(|error| panic!("{name}: 输出不是合法 JSON：{error}"));
        assert_matches_golden(name, &case["output"], &actual);
    }
    println!("patch_config golden：{} 个用例通过", cases.len());
}

#[test]
fn process_profile_matches_golden() {
    let cases = load_cases("process_profile");
    assert!(cases.len() >= 4, "golden 用例只有 {} 个", cases.len());

    for (name, case) in &cases {
        let input = case["input"].to_string();
        let script = case["script"]
            .as_str()
            .unwrap_or_else(|| panic!("{name}: 缺 script"));
        let options = case
            .get("customOptions")
            .filter(|value| !value.is_null())
            .map(Value::to_string);

        let input = cstring(&input);
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
        let envelope: Value = serde_json::from_str(&envelope)
            .unwrap_or_else(|error| panic!("{name}: 信封不是合法 JSON：{error}"));
        assert_eq!(
            envelope["ok"],
            Value::Bool(true),
            "{name}: 信封 ok 不为 true"
        );

        assert_matches_golden(name, &case["output"], &envelope["config"]);

        // 脚本报错的用例：错误串也要与 Dart 镜像逐字一致（沿用已有的跨引擎错误串断言）。
        let expected_error = case["scriptError"].as_str();
        let actual_error = envelope.get("scriptError").and_then(Value::as_str);
        assert_eq!(expected_error, actual_error, "{name}: scriptError 不一致");
    }
    println!("process_profile golden：{} 个用例通过", cases.len());
}
