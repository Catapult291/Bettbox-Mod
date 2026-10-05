//! Dart ↔ Rust 的窄 C ABI（覆写脚本引擎那半）。
//!
//! 声明在 `include/bettbox_script.h`，Dart 绑定由 ffigen 生成。约定与同 crate 的
//! 配置管道那半（`ffi.rs`）一致：字符串一律 UTF-8、Rust 分配、调用方用
//! [`bb_string_free`] 释放；ABI 级失败（NULL 入参、非法 JSON）返回 NULL
//! ——NULL 的含义是「回退 Dart 侧 qjs 路径」，而不是「脚本出错」。
//! [`bb_string_free`] 只在 `crate::ffi` 里定义一份。

use std::os::raw::c_char;
use std::ptr;

use crate::eval::{self, EvalOutcome, ExtractOutcome};
use crate::ffi_support::{borrow_str, catch_panic, into_c_string, MAX_JSON_INPUT_BYTES};

/// 执行覆写脚本，返回 JSON 信封（见头文件）。
///
/// # Safety
///
/// 三个入参都必须是 NUL 结尾的 UTF-8 C 字符串或 NULL（`options_json` 允许 NULL）。
/// 返回的指针所有权归调用方，用完必须传给 [`bb_string_free`]。
#[no_mangle]
pub unsafe extern "C" fn bb_eval_script(
    script: *const c_char,
    config_json: *const c_char,
    options_json: *const c_char,
) -> *mut c_char {
    catch_panic(ptr::null_mut(), || -> *mut c_char {
        let Some(script) = (unsafe { borrow_str(script) }) else {
            return ptr::null_mut();
        };
        let Some(config_json) = (unsafe { borrow_str(config_json) }) else {
            return ptr::null_mut();
        };
        if config_json.len() > MAX_JSON_INPUT_BYTES || !eval::is_json_object(config_json) {
            return ptr::null_mut();
        }
        let options_json = match unsafe { borrow_str(options_json) } {
            Some(text) if text.len() <= MAX_JSON_INPUT_BYTES && eval::is_json_object(text) => {
                Some(text)
            }
            Some(_) => return ptr::null_mut(),
            None => None,
        };

        let envelope = match eval::evaluate(script, config_json, options_json) {
            EvalOutcome::Config(result) => format!("{{\"ok\":true,\"config\":{result}}}"),
            // 脚本没返回对象：原样带回输入配置，与 Dart 侧「保留原配置」一致。
            EvalOutcome::NotAMap => format!("{{\"ok\":true,\"config\":{config_json}}}"),
            EvalOutcome::Error(message) => {
                let escaped =
                    serde_json::to_string(&message).unwrap_or_else(|_| "\"\"".to_string());
                format!("{{\"ok\":false,\"error\":{escaped}}}")
            }
        };
        into_c_string(&envelope)
    })
}

/// 抽取脚本声明的选项与图标（脚本页的 options/icons），返回 JSON 信封。
///
/// 信封形状见头文件：`{"ok":true,"result":{"options":…,"icons":…}}` /
/// `{"ok":false,"error":"…"}`；NULL 仍表示 ABI 级失败（入参 NULL / 非 UTF-8）。
///
/// # Safety
///
/// `script` 必须是 NUL 结尾的 UTF-8 C 字符串。返回的指针所有权归调用方，
/// 用完必须传给 [`bb_string_free`]。
#[no_mangle]
pub unsafe extern "C" fn bb_extract_script_options(script: *const c_char) -> *mut c_char {
    catch_panic(ptr::null_mut(), || -> *mut c_char {
        let Some(script) = (unsafe { borrow_str(script) }) else {
            return ptr::null_mut();
        };

        let envelope = match eval::extract_options(script) {
            ExtractOutcome::Options(result) => format!("{{\"ok\":true,\"result\":{result}}}"),
            ExtractOutcome::Error(message) => {
                let escaped =
                    serde_json::to_string(&message).unwrap_or_else(|_| "\"\"".to_string());
                format!("{{\"ok\":false,\"error\":{escaped}}}")
            }
        };
        into_c_string(&envelope)
    })
}

// `bb_string_free` 只在本 crate 的 `ffi` 模块定义一份：两个头文件都声明它，
// 合并成一个动态库后不能重复定义。

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{CStr, CString};

    fn eval_via_ffi(script: &str, config: &str) -> String {
        let script = CString::new(script).unwrap();
        let config = CString::new(config).unwrap();
        let out = unsafe { bb_eval_script(script.as_ptr(), config.as_ptr(), ptr::null()) };
        assert!(!out.is_null(), "bb_eval_script 返回 NULL");
        let text = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_string();
        unsafe { crate::ffi::bb_string_free(out) };
        text
    }

    #[test]
    fn null_inputs_return_null() {
        assert!(unsafe { bb_eval_script(ptr::null(), ptr::null(), ptr::null()) }.is_null());
        let script = CString::new("function main(c){ return c; }").unwrap();
        let not_object = CString::new("[1,2,3]").unwrap();
        assert!(
            unsafe { bb_eval_script(script.as_ptr(), not_object.as_ptr(), ptr::null()) }.is_null()
        );
    }

    #[test]
    fn free_accepts_null() {
        unsafe { crate::ffi::bb_string_free(ptr::null_mut()) };
    }

    #[test]
    fn non_object_return_keeps_original_config() {
        let text = eval_via_ffi("function main(c){ return 42; }", "{\"a\":1}");
        assert_eq!(text, "{\"ok\":true,\"config\":{\"a\":1}}");
    }

    #[test]
    fn error_envelope_carries_dart_style_prefix() {
        let text = eval_via_ffi("function main(c){ throw new Error('boom'); }", "{}");
        let value: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(value["ok"], false);
        let error = value["error"].as_str().unwrap();
        assert!(error.starts_with("JS Script Error: "), "{error}");
        assert!(error.contains("boom"), "{error}");
    }

    #[test]
    fn catch_panic_returns_fallback() {
        assert_eq!(catch_panic(-1, || panic!("boom")), -1);
    }

    #[test]
    fn oversized_config_input_returns_null() {
        let script = CString::new("function main(c){ return c; }").unwrap();
        let config = CString::new("x".repeat(MAX_JSON_INPUT_BYTES + 1)).unwrap();
        let out = unsafe { bb_eval_script(script.as_ptr(), config.as_ptr(), ptr::null()) };
        assert!(out.is_null());
    }
}
