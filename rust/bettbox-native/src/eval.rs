//! 覆写脚本求值：契约与 Dart 侧 `lib/common/js_runtime_manager.dart` 的
//! `JavaScriptRuntimeManager.evaluateScript` 逐项对齐。
//!
//! 对齐清单（改动这里必须同步改 Dart 侧，反之亦然）：
//!   * `console` 垫片：五个方法都转发到 `print`（未定义时为空操作），正文照抄 Dart 侧；
//!   * 脚本正文与 `return main(<config>)` 同处一个 IIFE 作用域（脚本里的顶层
//!     `const` / `function` 因此不会泄漏到全局）；
//!   * `customOptions` 非空时按 Dart 侧原样合并：`Object.assign(ruleOptionsEnable, …)`，
//!     且只在 `ruleOptionsEnable` 已定义时合并；
//!   * 返回值不是对象（数组、原始值、undefined/null）时保留原配置；
//!   * 失败重试一次（Dart 侧 `maxRetries = 1`）；
//!   * 超时 30 s、内存上限 256 MB（Dart 侧 `scriptTimeoutMs` / `scriptMemoryLimitBytes`）。

use serde_json::Value;

/// 与 `js_runtime_manager.dart` 的 `scriptTimeoutMs` 一致。
pub const SCRIPT_TIMEOUT_MS: i64 = 30_000;
/// 与 `js_runtime_manager.dart` 的 `scriptMemoryLimitBytes` 一致。
pub const SCRIPT_MEMORY_LIMIT_BYTES: usize = 256 * 1024 * 1024;
/// 与 `js_runtime_manager.dart` 的 `maxRetries = 1` 一致（失败后再试一次）。
const MAX_RETRIES: u32 = 1;

pub struct Limits {
    pub timeout_ms: i64,
    pub memory_limit_bytes: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            timeout_ms: SCRIPT_TIMEOUT_MS,
            memory_limit_bytes: SCRIPT_MEMORY_LIMIT_BYTES,
        }
    }
}

/// 求值结果，对应 Dart 侧 `evaluateScript` 的三种去向。
#[derive(Debug)]
pub enum EvalOutcome {
    /// 脚本返回对象：`config` 是结果对象的 JSON 文本。
    Config(String),
    /// 脚本返回值不是对象，调用方保留原配置。
    NotAMap,
    /// 脚本抛错/超时/内存超限；错误串已按 Dart 侧格式加前缀。
    Error(String),
}

pub fn evaluate(script: &str, config_json: &str, options_json: Option<&str>) -> EvalOutcome {
    evaluate_with_limits(script, config_json, options_json, &Limits::default())
}

pub fn evaluate_with_limits(
    script: &str,
    config_json: &str,
    options_json: Option<&str>,
    limits: &Limits,
) -> EvalOutcome {
    let program = build_program(script, config_json, options_json);
    let mut attempt = 0;
    loop {
        match eval_once(&program, limits) {
            Ok(outcome) => return outcome,
            Err(message) => {
                if attempt >= MAX_RETRIES {
                    return EvalOutcome::Error(format!("JS Script Error: {message}"));
                }
                attempt += 1;
            }
        }
    }
}

/// 拼装被求值的程序。正文与 Dart 侧 `_evaluateWithRetry` 的模板保持一致。
///
/// **行结构必须与 Dart 侧逐行对齐**：QuickJS 的异常栈里带 `<eval>:<行号>`，两侧
/// 程序差了行数就会让同一个脚本报出不同的行号，而脚本正文由用户编写，行号是定位
/// 出错位置的唯一线索。Dart 侧的模板以换行开头，但 Dart 的多行字符串会丢掉 `'''`
/// 之后的第一个换行，所以正文第 1 行就是 `var console = {`；而 `customOptions`
/// 为空时那一行**仍然占位**（模板里的固定一行），所以这里也不能省。缩进不进入
/// 行号，不跟随 Dart 侧的 10/12 空格缩进。
fn build_program(script: &str, config_json: &str, options_json: Option<&str>) -> String {
    const CONSOLE_SHIM: &str = "\
var console = {
  log: function(...args) { if (typeof print !== 'undefined') print(...args); },
  warn: function(...args) { if (typeof print !== 'undefined') print('WARN:', ...args); },
  error: function(...args) { if (typeof print !== 'undefined') print('ERROR:', ...args); },
  info: function(...args) { if (typeof print !== 'undefined') print('INFO:', ...args); },
  debug: function(...args) { if (typeof print !== 'undefined') print('DEBUG:', ...args); }
};
";

    let mut program = String::with_capacity(script.len() + config_json.len() + 1024);
    program.push_str(CONSOLE_SHIM);
    program.push_str("(function() {\n");
    program.push_str(script);
    program.push('\n');
    if let Some(options) = options_json {
        program.push_str(
            "if (typeof ruleOptionsEnable !== \"undefined\") { Object.assign(ruleOptionsEnable, ",
        );
        program.push_str(options);
        program.push_str("); }");
    }
    program.push('\n');
    program.push_str("return main(");
    program.push_str(config_json);
    program.push_str(");\n})();\n");
    program
}

/// `extractScriptOptions` 的求值结果（脚本页读 `ruleOptionsEnable` / `serviceConfigs`）。
#[derive(Debug)]
pub enum ExtractOutcome {
    /// 成功：`{"options":…,"icons":…}` 的 JSON 文本。
    Options(String),
    /// 脚本抛错/超时/内存超限。错误串与 qjs 侧同形（含异常栈），
    /// 但**不带** `JS Script Error: ` 前缀——那个前缀只有 `_evaluateWithRetry` 才加。
    Error(String),
}

/// 抽取脚本声明的选项与图标。
///
/// 与 [`evaluate`] 的两处关键差别，都对齐 Dart 侧 `extractScriptOptions`：
///   * **不重试**：Dart 侧这条路径没有重试循环，出错就交给调用方记日志并返回空表；
///   * 错误串不加 `JS Script Error: ` 前缀（Dart 侧只记 `extractScriptOptions error: $e`）。
pub fn extract_options(script: &str) -> ExtractOutcome {
    extract_options_with_limits(script, &Limits::default())
}

pub fn extract_options_with_limits(script: &str, limits: &Limits) -> ExtractOutcome {
    let program = build_extract_program(script);
    match eval_once(&program, limits) {
        Ok(EvalOutcome::Config(json)) => ExtractOutcome::Options(json),
        Ok(EvalOutcome::NotAMap) => ExtractOutcome::Error("脚本未返回选项对象".to_string()),
        Ok(EvalOutcome::Error(message)) => ExtractOutcome::Error(message),
        Err(message) => ExtractOutcome::Error(message),
    }
}

/// `extractScriptOptions` 用的程序，形状照 Dart 侧 `_extractOptionsViaQjs` 的模板：
/// 跑脚本正文，再读全局 `ruleOptionsEnable` 与 `serviceConfigs`。
///
/// 行结构同样必须与 Dart 侧逐行对齐（理由见 [`build_program`]）：这条路径的错误串
/// 也会带上 `<eval>:<行号>`。
///
/// 与 Dart 模板的唯一差别在末行：这里 `return { options: options, icons: icons };`
/// 直接返回对象，由 C 侧的 `JS_JSONStringify` 序列化（`JSON.stringify` 内部用的就是它），
/// 省掉「JSON 文本再套一层 JSON 字符串」的二次转义。行数不变，行号因此一致。
fn build_extract_program(script: &str) -> String {
    const CONSOLE_SHIM: &str = "\
var console = {
  log: function() {},
  warn: function() {},
  error: function() {},
  info: function() {},
  debug: function() {}
};
";

    let mut program = String::with_capacity(script.len() + 1024);
    program.push_str(CONSOLE_SHIM);
    program.push_str("(function() {\n");
    program.push_str(script);
    program.push('\n');
    program.push_str(EXTRACT_BODY);
    program.push_str("})();\n");
    program
}

/// `_extractOptionsViaQjs` 模板里 `$scriptContent` 之后的那一段，照抄（含注释里的缩进层级）。
const EXTRACT_BODY: &str = "\
var options = typeof ruleOptionsEnable !== 'undefined' && ruleOptionsEnable && typeof ruleOptionsEnable === 'object' ? ruleOptionsEnable : {};
var icons = {};
if (typeof serviceConfigs !== 'undefined' && Array.isArray(serviceConfigs)) {
  for (var i = 0; i < serviceConfigs.length; i++) {
    var svc = serviceConfigs[i];
    if (svc && svc.name && typeof svc.icon === 'string') {
      icons[svc.name] = svc.icon;
    }
  }
}
return { options: options, icons: icons };
";

fn eval_once(program: &str, limits: &Limits) -> Result<EvalOutcome, String> {
    // 必须交给引擎一个 NUL 结尾的缓冲区：见 c/quickjs_shim.c 的入参契约（漏了会被 C 侧
    // 的哨兵校验挡下并报内部错误，不会退化成「偶发解析失败」）。
    let program = match std::ffi::CString::new(program) {
        Ok(value) => value,
        Err(_) => return Err("脚本程序含 NUL 字节".to_string()),
    };
    let mut out_json: *mut std::os::raw::c_char = std::ptr::null_mut();
    let mut out_error: *mut std::os::raw::c_char = std::ptr::null_mut();
    let status = unsafe {
        ffi::bbq_eval_program(
            program.as_ptr(),
            program.as_bytes().len(),
            limits.timeout_ms,
            limits.memory_limit_bytes,
            &mut out_json,
            &mut out_error,
        )
    };
    let json = unsafe { take_c_string(out_json) };
    let error = unsafe { take_c_string(out_error) };

    match status {
        0 => json
            .map(EvalOutcome::Config)
            .ok_or_else(|| "脚本求值成功但没有结果".to_string()),
        2 => Ok(EvalOutcome::NotAMap),
        1 => Err(error.unwrap_or_else(|| "unknown script error".to_string())),
        _ => Err(error.unwrap_or_else(|| "脚本引擎内部错误".to_string())),
    }
}

/// 取走 C 侧 malloc 出来的字符串并释放。
unsafe fn take_c_string(ptr: *mut std::os::raw::c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    let text = unsafe { std::ffi::CStr::from_ptr(ptr) }
        .to_str()
        .ok()
        .map(str::to_string);
    unsafe { ffi::bbq_string_free(ptr) };
    text
}

/// 校验一段 JSON 文本是对象（配置必须是对象）。
pub fn is_json_object(text: &str) -> bool {
    matches!(serde_json::from_str::<Value>(text), Ok(Value::Object(_)))
}

mod ffi {
    use std::os::raw::{c_char, c_int};

    extern "C" {
        pub fn bbq_eval_program(
            program: *const c_char,
            program_len: usize,
            timeout_ms: i64,
            memory_limit: usize,
            out_json: *mut *mut c_char,
            out_error: *mut *mut c_char,
        ) -> c_int;
        pub fn bbq_string_free(ptr: *mut c_char);
    }
}
