//! 两个 FFI 模块（[`crate::ffi`] / [`crate::script_ffi`]）共用的边界工具。
//!
//! 合并 crate 之前，这些函数在两份 `ffi.rs` 里各存一份；现在只保留这一处。

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use serde_json::Value;

/// 单个 JSON 输入串的字节上限（64 MiB）。超过即视为 ABI 级失败返回 NULL，
/// 由 Dart 侧回退，避免异常订阅把内存撑爆。
pub(crate) const MAX_JSON_INPUT_BYTES: usize = 64 * 1024 * 1024;

/// 在 `extern "C"` 边界上捕获 panic。
///
/// Rust 1.81 起 `extern "C"` 内 unwind 会直接 abort（整个应用闪退），所以每个导出
/// 入口都包一层：panic 时返回兜底值，交给调用方的回退/报错逻辑处理。
/// `AssertUnwindSafe`：导出入口只使用本次调用传入的指针，panic 后不复用被污染的状态。
pub(crate) fn catch_panic<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(body)).unwrap_or(fallback)
}

/// 受上限保护的 JSON 解析；超限或语法错误都返回 `None`。
pub(crate) fn parse_json_limited(raw: &str) -> Option<Value> {
    if raw.len() > MAX_JSON_INPUT_BYTES {
        return None;
    }
    serde_json::from_str::<Value>(raw).ok()
}

/// 借出 C 字符串。指针为空返回 `None`；非 UTF-8 也返回 `None`。
pub(crate) unsafe fn borrow_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

/// 把 Rust 字符串交给调用方；含 NUL 字节时返回 NULL。
pub(crate) fn into_c_string(value: &str) -> *mut c_char {
    match CString::new(value) {
        Ok(value) => value.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}
