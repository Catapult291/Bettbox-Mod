//! Dart ↔ Rust 的窄 C ABI。
//!
//! 声明在 `include/bettbox_script.h`，Dart 绑定由 ffigen 生成。约定与
//! `rust/bettbox-config` 一致：字符串一律 UTF-8、Rust 分配、调用方用
//! [`bb_string_free`] 释放；ABI 级失败（NULL 入参、非法 JSON）返回 NULL
//! ——NULL 的含义是「回退 Dart 侧 qjs 路径」，而不是「脚本出错」。

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use crate::eval::{self, EvalOutcome, ExtractOutcome};

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
    let Some(script) = (unsafe { borrow_str(script) }) else {
        return ptr::null_mut();
    };
    let Some(config_json) = (unsafe { borrow_str(config_json) }) else {
        return ptr::null_mut();
    };
    if !eval::is_json_object(config_json) {
        return ptr::null_mut();
    }
    let options_json = match unsafe { borrow_str(options_json) } {
        Some(text) if eval::is_json_object(text) => Some(text),
        Some(_) => return ptr::null_mut(),
        None => None,
    };

    let envelope = match eval::evaluate(script, config_json, options_json) {
        EvalOutcome::Config(result) => format!("{{\"ok\":true,\"config\":{result}}}"),
        // 脚本没返回对象：原样带回输入配置，与 Dart 侧「保留原配置」一致。
        EvalOutcome::NotAMap => format!("{{\"ok\":true,\"config\":{config_json}}}"),
        EvalOutcome::Error(message) => {
            let escaped = serde_json::to_string(&message).unwrap_or_else(|_| "\"\"".to_string());
            format!("{{\"ok\":false,\"error\":{escaped}}}")
        }
    };
    into_c_string(&envelope)
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
    let Some(script) = (unsafe { borrow_str(script) }) else {
        return ptr::null_mut();
    };

    let envelope = match eval::extract_options(script) {
        ExtractOutcome::Options(result) => format!("{{\"ok\":true,\"result\":{result}}}"),
        ExtractOutcome::Error(message) => {
            let escaped = serde_json::to_string(&message).unwrap_or_else(|_| "\"\"".to_string());
            format!("{{\"ok\":false,\"error\":{escaped}}}")
        }
    };
    into_c_string(&envelope)
}

/// 释放本库返回的字符串。
///
/// # Safety
///
/// `value` 必须是本库返回、且尚未释放的指针，或为 NULL。
#[no_mangle]
pub unsafe extern "C" fn bb_string_free(value: *mut c_char) {
    if value.is_null() {
        return;
    }
    drop(unsafe { CString::from_raw(value) });
}

unsafe fn borrow_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

fn into_c_string(value: &str) -> *mut c_char {
    match CString::new(value) {
        Ok(value) => value.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn eval_via_ffi(script: &str, config: &str) -> String {
        let script = CString::new(script).unwrap();
        let config = CString::new(config).unwrap();
        let out = unsafe { bb_eval_script(script.as_ptr(), config.as_ptr(), ptr::null()) };
        assert!(!out.is_null(), "bb_eval_script 返回 NULL");
        let text = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_string();
        unsafe { bb_string_free(out) };
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
        unsafe { bb_string_free(ptr::null_mut()) };
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
}
