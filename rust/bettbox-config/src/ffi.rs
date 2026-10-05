//! Dart ↔ Rust 的窄 C ABI。
//!
//! 声明在 `include/bettbox_config.h`，Dart 绑定由 ffigen 生成。约定见该头文件：
//! 字符串一律 UTF-8、Rust 分配、调用方用 [`bb_string_free`] 释放，出错返回 NULL。

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use serde_json::Value;

use crate::rule::ParsedRule;

/// 单个 JSON 输入串的字节上限（64 MiB）。超过即视为 ABI 级失败返回 NULL，
/// 由 Dart 侧回退，避免异常订阅把内存撑爆。
const MAX_JSON_INPUT_BYTES: usize = 64 * 1024 * 1024;

/// 在 `extern "C"` 边界上捕获 panic。
///
/// Rust 1.81 起 `extern "C"` 内 unwind 会直接 abort（整个应用闪退），所以每个导出
/// 入口都包一层：panic 时返回兜底值，交给调用方的回退/报错逻辑处理。
/// `AssertUnwindSafe`：导出入口只使用本次调用传入的指针，panic 后不复用被污染的状态。
fn catch_panic<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(body)).unwrap_or(fallback)
}

/// 受上限保护的 JSON 解析；超限或语法错误都返回 `None`。
fn parse_json_limited(raw: &str) -> Option<Value> {
    if raw.len() > MAX_JSON_INPUT_BYTES {
        return None;
    }
    serde_json::from_str::<Value>(raw).ok()
}

/// 解析一条 Clash 规则，返回 JSON 对象。
///
/// # Safety
///
/// `rule` 必须是 NUL 结尾的 UTF-8 C 字符串，或为 NULL。返回的指针所有权归调用方，
/// 用完必须传给 [`bb_string_free`]。
#[no_mangle]
pub unsafe extern "C" fn bb_rule_parse(rule: *const c_char) -> *mut c_char {
    catch_panic(ptr::null_mut(), || -> *mut c_char {
        let Some(text) = (unsafe { borrow_str(rule) }) else {
            return ptr::null_mut();
        };
        into_c_string(&parsed_to_json(&ParsedRule::parse(text)))
    })
}

/// 解析后再序列化回配置字符串（往返校验用）。
///
/// # Safety
///
/// 同 [`bb_rule_parse`]。
#[no_mangle]
pub unsafe extern "C" fn bb_rule_round_trip(rule: *const c_char) -> *mut c_char {
    catch_panic(ptr::null_mut(), || -> *mut c_char {
        let Some(text) = (unsafe { borrow_str(rule) }) else {
            return ptr::null_mut();
        };
        into_c_string(&ParsedRule::parse(text).to_config_string())
    })
}

/// 就地应用 DNS 节点覆写，返回改写后的配置 JSON。
///
/// `original_dns_json` / `original_hosts_json` 传 NULL 表示没有对应数据。
///
/// # Safety
///
/// 三个入参都必须是 NUL 结尾的 UTF-8 C 字符串或 NULL；返回的指针所有权归调用方，
/// 用完必须传给 [`bb_string_free`]。
#[no_mangle]
pub unsafe extern "C" fn bb_apply_dns_node_override(
    raw_config_json: *const c_char,
    original_dns_json: *const c_char,
    original_hosts_json: *const c_char,
) -> *mut c_char {
    catch_panic(ptr::null_mut(), || -> *mut c_char {
        let Some(raw) = (unsafe { borrow_str(raw_config_json) }) else {
            return ptr::null_mut();
        };
        let Some(mut config) = parse_json_limited(raw) else {
            return ptr::null_mut();
        };

        let original_dns = (unsafe { borrow_str(original_dns_json) }).and_then(parse_json_limited);
        let original_hosts =
            (unsafe { borrow_str(original_hosts_json) }).and_then(parse_json_limited);

        crate::dns_override::apply_dns_node_override(
            &mut config,
            original_dns.as_ref(),
            original_hosts.as_ref(),
        );
        into_c_string(&config.to_string())
    })
}

/// 解析 provider 列表原文，返回元数据数组（已剥掉全节点列表）。
///
/// # Safety
///
/// `raw_providers_json` 必须是 NUL 结尾的 UTF-8 C 字符串或 NULL；返回的指针所有权归调用方，
/// 用完必须传给 [`bb_string_free`]。
#[no_mangle]
pub unsafe extern "C" fn bb_parse_provider_meta(raw_providers_json: *const c_char) -> *mut c_char {
    catch_panic(ptr::null_mut(), || -> *mut c_char {
        let Some(raw) = (unsafe { borrow_str(raw_providers_json) }) else {
            return ptr::null_mut();
        };
        if raw.len() > MAX_JSON_INPUT_BYTES {
            return ptr::null_mut();
        }
        match crate::provider::parse_provider_meta(raw) {
            Ok(metas) => into_c_string(&Value::Array(metas).to_string()),
            Err(_) => ptr::null_mut(),
        }
    })
}

/// 由内核代理表 + provider 原文构建分组，返回分组数组 JSON。
///
/// `raw_providers` 传 NULL 或空串表示没有 provider 数据。
///
/// # Safety
///
/// 两个入参都必须是 NUL 结尾的 UTF-8 C 字符串或 NULL；返回的指针所有权归调用方，
/// 用完必须传给 [`bb_string_free`]。
#[no_mangle]
pub unsafe extern "C" fn bb_build_proxies_groups(
    proxies_json: *const c_char,
    raw_providers: *const c_char,
) -> *mut c_char {
    catch_panic(ptr::null_mut(), || -> *mut c_char {
        let Some(raw_proxies) = (unsafe { borrow_str(proxies_json) }) else {
            return ptr::null_mut();
        };
        let Some(proxies) = parse_json_limited(raw_proxies) else {
            return ptr::null_mut();
        };
        let providers = (unsafe { borrow_str(raw_providers) }).unwrap_or_default();
        if providers.len() > MAX_JSON_INPUT_BYTES {
            return ptr::null_mut();
        }
        let groups = crate::provider::build_proxies_groups(&proxies, providers);
        into_c_string(&Value::Array(groups).to_string())
    })
}

/// 应用分组开关，返回 `{"proxy-groups":[...],"rules":[...]}` JSON。
///
/// # Safety
///
/// 三个入参都必须是 NUL 结尾的 UTF-8 C 字符串或 NULL；返回的指针所有权归调用方，
/// 用完必须传给 [`bb_string_free`]。
#[no_mangle]
pub unsafe extern "C" fn bb_apply_group_switches(
    proxy_groups_json: *const c_char,
    rules_json: *const c_char,
    group_switches_json: *const c_char,
    script_active: bool,
) -> *mut c_char {
    catch_panic(ptr::null_mut(), || -> *mut c_char {
        let Some(groups_raw) = (unsafe { borrow_str(proxy_groups_json) }) else {
            return ptr::null_mut();
        };
        let Some(rules_raw) = (unsafe { borrow_str(rules_json) }) else {
            return ptr::null_mut();
        };
        let Some(groups) = parse_json_limited(groups_raw) else {
            return ptr::null_mut();
        };
        let Some(rules) = parse_json_limited(rules_raw) else {
            return ptr::null_mut();
        };
        let switches = (unsafe { borrow_str(group_switches_json) })
            .and_then(parse_json_limited)
            .unwrap_or_else(|| Value::Object(Default::default()));

        let (groups, rules) =
            crate::group_switch::apply_group_switches(&groups, &rules, &switches, script_active);
        into_c_string(&serde_json::json!({"proxy-groups": groups, "rules": rules}).to_string())
    })
}

/// 跑完整条配置改写管道，返回改写后的配置 JSON。
///
/// 输入结构见 [`crate::patch_config::patch_config`]。
///
/// # Safety
///
/// `input_json` 必须是 NUL 结尾的 UTF-8 C 字符串或 NULL；返回的指针所有权归调用方，
/// 用完必须传给 [`bb_string_free`]。
#[no_mangle]
pub unsafe extern "C" fn bb_patch_config(input_json: *const c_char) -> *mut c_char {
    catch_panic(ptr::null_mut(), || -> *mut c_char {
        let Some(raw) = (unsafe { borrow_str(input_json) }) else {
            return ptr::null_mut();
        };
        let Some(input) = parse_json_limited(raw) else {
            return ptr::null_mut();
        };
        match crate::patch_config::patch_config(&input) {
            Ok(config) => into_c_string(&config.to_string()),
            Err(_) => ptr::null_mut(),
        }
    })
}

/// 节点过滤用的最小正则匹配：命中返回 1，未命中返回 0，模式不支持返回 -1。
///
/// # Safety
///
/// 两个入参都必须是 NUL 结尾的 UTF-8 C 字符串或 NULL。
#[no_mangle]
pub unsafe extern "C" fn bb_node_filter_match(pattern: *const c_char, text: *const c_char) -> i32 {
    catch_panic(-1, || -> i32 {
        let Some(pattern) = (unsafe { borrow_str(pattern) }) else {
            return -1;
        };
        let Some(text) = (unsafe { borrow_str(text) }) else {
            return -1;
        };
        match crate::mini_regex::compile(pattern) {
            Ok(regex) => i32::from(regex.is_match(text)),
            Err(_) => -1,
        }
    })
}

/// 释放本库返回的字符串。
///
/// # Safety
///
/// `value` 必须是本库通过 [`bb_rule_parse`] / [`bb_rule_round_trip`] / [`bb_apply_dns_node_override`] /
/// [`bb_parse_provider_meta`] / [`bb_build_proxies_groups`] / [`bb_apply_group_switches`] /
/// [`bb_patch_config`] 返回、且尚未释放的指针，或为 NULL。
#[no_mangle]
pub unsafe extern "C" fn bb_string_free(value: *mut c_char) {
    catch_panic((), || {
        if value.is_null() {
            return;
        }
        drop(unsafe { CString::from_raw(value) });
    })
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

fn parsed_to_json(parsed: &ParsedRule) -> String {
    serde_json::json!({
        "action": parsed.action.as_str(),
        "content": parsed.content,
        "target": parsed.target,
        "ruleProvider": parsed.rule_provider,
        "subRule": parsed.sub_rule,
        "noResolve": parsed.no_resolve,
        "src": parsed.src,
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_via_ffi(rule: &str) -> String {
        let input = CString::new(rule).unwrap();
        let out = unsafe { bb_rule_parse(input.as_ptr()) };
        assert!(!out.is_null(), "bb_rule_parse returned null for {rule}");
        let text = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_string();
        unsafe { bb_string_free(out) };
        text
    }

    #[test]
    fn parse_returns_expected_json_shape() {
        let value: serde_json::Value =
            serde_json::from_str(&parse_via_ffi("GEOIP,CN,DIRECT,no-resolve")).unwrap();
        assert_eq!(value["action"], "GEOIP");
        assert_eq!(value["content"], "CN");
        assert_eq!(value["target"], "DIRECT");
        assert_eq!(value["ruleProvider"], serde_json::Value::Null);
        assert_eq!(value["subRule"], serde_json::Value::Null);
        assert_eq!(value["noResolve"], true);
        assert_eq!(value["src"], false);
    }

    #[test]
    fn null_input_returns_null() {
        assert!(unsafe { bb_rule_parse(ptr::null()) }.is_null());
        assert!(unsafe { bb_rule_round_trip(ptr::null()) }.is_null());
    }

    #[test]
    fn free_accepts_null() {
        unsafe { bb_string_free(ptr::null_mut()) };
    }

    #[test]
    fn round_trip_returns_config_string() {
        let input = CString::new("IP-CIDR,10.0.0.0/8,DIRECT,no-resolve").unwrap();
        let out = unsafe { bb_rule_round_trip(input.as_ptr()) };
        assert!(!out.is_null());
        let text = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_string();
        unsafe { bb_string_free(out) };
        assert_eq!(text, "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve");
    }

    #[test]
    fn catch_panic_returns_fallback() {
        assert_eq!(catch_panic(-1, || panic!("boom")), -1);
    }

    #[test]
    fn oversized_json_input_is_rejected() {
        let huge = "x".repeat(MAX_JSON_INPUT_BYTES + 1);
        assert!(parse_json_limited(&huge).is_none());

        let input = CString::new(huge).unwrap();
        assert!(unsafe { bb_patch_config(input.as_ptr()) }.is_null());
    }
}
