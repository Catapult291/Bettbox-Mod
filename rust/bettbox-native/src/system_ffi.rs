//! 系统代理（Windows）的窄 C ABI。声明在 `include/bettbox_system_proxy.h`。
//!
//! 与配置/脚本两个 FFI 模块的差别：这里返回的**总是**一个 JSON 信封
//! （`{"ok":true,...}` / `{"ok":false,"message":"..."}`），只有 ABI 级失败
//! （入参非法、内存分配失败）才返回 NULL。Win32 层的失败（例如设置被策略拒绝）
//! 需要把原因交回 Dart 侧，不能和「指针为空」混为一谈。

use std::os::raw::c_char;
use std::ptr;

use serde_json::{json, Value};

use crate::ffi_support::{borrow_str, catch_panic, into_c_string};
use crate::system_proxy::{self, ProxySnapshot};

fn envelope(value: Value) -> *mut c_char {
    into_c_string(&value.to_string())
}

/// 读取当前系统代理设置（LAN 连接 + 所有 RAS 拨号项）。
///
/// # Safety
///
/// 返回的指针所有权归调用方，用完必须传给 `bb_string_free`。
#[no_mangle]
pub unsafe extern "C" fn bb_system_proxy_query() -> *mut c_char {
    catch_panic(ptr::null_mut(), || match system_proxy::query() {
        Ok(snapshot) => envelope(json!({ "ok": true, "snapshot": snapshot })),
        Err(message) => envelope(json!({ "ok": false, "message": message })),
    })
}

/// 启用指向 `127.0.0.1:<port>` 的系统代理，信封里带回启用前的快照。
///
/// `bypass` 是分号分隔的绕过域名（可为 NULL 或空串）。
///
/// # Safety
///
/// 同 [`bb_system_proxy_query`]；`bypass` 必须是 NUL 结尾的 UTF-8 C 字符串或 NULL。
#[no_mangle]
pub unsafe extern "C" fn bb_system_proxy_enable(port: i32, bypass: *const c_char) -> *mut c_char {
    catch_panic(ptr::null_mut(), || {
        if !(1..=65535).contains(&port) {
            return envelope(json!({ "ok": false, "message": format!("端口非法：{port}") }));
        }
        let domains: Vec<String> = match unsafe { borrow_str(bypass) } {
            Some(text) => text
                .split(';')
                .filter(|domain| !domain.is_empty())
                .map(str::to_string)
                .collect(),
            None => Vec::new(),
        };
        match system_proxy::enable(port as u16, &domains) {
            Ok((snapshot, warnings)) => envelope(json!({
                "ok": true,
                "snapshot": snapshot,
                "warnings": warnings,
            })),
            Err(message) => envelope(json!({ "ok": false, "message": message })),
        }
    })
}

/// 按快照还原系统代理：只还原仍归本应用管的连接。
///
/// # Safety
///
/// 同 [`bb_system_proxy_query`]；`snapshot_json` 必须是 NUL 结尾的 UTF-8 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn bb_system_proxy_restore(snapshot_json: *const c_char) -> *mut c_char {
    catch_panic(ptr::null_mut(), || {
        let Some(raw) = (unsafe { borrow_str(snapshot_json) }) else {
            return envelope(json!({ "ok": false, "message": "快照为空" }));
        };
        let snapshot = match ProxySnapshot::from_json(raw) {
            Ok(snapshot) => snapshot,
            Err(message) => return envelope(json!({ "ok": false, "message": message })),
        };
        match system_proxy::restore(&snapshot) {
            Ok(report) => envelope(json!({
                "ok": true,
                "restored": report.restored,
                "skipped": report.skipped,
                "warnings": report.warnings,
            })),
            Err(message) => envelope(json!({ "ok": false, "message": message })),
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi_support::borrow_str;
    use std::ffi::CString;

    fn call_query() -> Value {
        let ptr = unsafe { bb_system_proxy_query() };
        assert!(!ptr.is_null());
        let text = unsafe { borrow_str(ptr) }.expect("utf-8").to_string();
        unsafe { crate::ffi::bb_string_free(ptr) };
        serde_json::from_str(&text).expect("json")
    }

    #[test]
    fn query_returns_an_envelope() {
        let value = call_query();
        assert!(value.get("ok").is_some());
        if value["ok"] == json!(true) {
            assert!(value["snapshot"]["connections"].is_array());
        } else {
            assert!(value["message"].is_string());
        }
    }

    #[test]
    fn enable_rejects_out_of_range_port() {
        let bypass = CString::new("<local>").unwrap();
        let ptr = unsafe { bb_system_proxy_enable(0, bypass.as_ptr()) };
        assert!(!ptr.is_null());
        let text = unsafe { borrow_str(ptr) }.expect("utf-8").to_string();
        unsafe { crate::ffi::bb_string_free(ptr) };
        let value: Value = serde_json::from_str(&text).expect("json");
        assert_eq!(value["ok"], json!(false));
    }

    #[test]
    fn restore_rejects_bad_snapshot() {
        for raw in ["", "not json", "{\"version\":7,\"connections\":[]}"] {
            let input = CString::new(raw).unwrap();
            let ptr = unsafe { bb_system_proxy_restore(input.as_ptr()) };
            assert!(!ptr.is_null());
            let text = unsafe { borrow_str(ptr) }.expect("utf-8").to_string();
            unsafe { crate::ffi::bb_string_free(ptr) };
            let value: Value = serde_json::from_str(&text).expect("json");
            assert_eq!(value["ok"], json!(false), "{raw}");
        }
    }

    #[test]
    fn restore_with_null_snapshot_is_rejected() {
        let ptr = unsafe { bb_system_proxy_restore(ptr::null()) };
        assert!(!ptr.is_null());
        unsafe { crate::ffi::bb_string_free(ptr) };
    }
}
