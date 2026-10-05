//! 配置改写的整管道：输入输出都是 JSON 结构，无 IO、无全局状态。
//!
//! 对应 Dart 侧 `lib/common/config_patch.dart` 的 `applyConfigPatch`
//! （由 `lib/state.dart` 的 `patchRawConfig` 抽取而来）。差分测试见
//! `test/rust/patch_config_diff_test.dart`。
//!
//! 输入结构见 Dart 侧文档注释。宿主职责（读 profile 文件、跑 JS 脚本、解析
//! `ClashConfig`、取应用数据目录）留在 Dart，这里只做对配置 map 的手术。
//!
//! 与 Dart 的已知差异（只在畸形输入上体现）：
//! - `nodeExcludeFilter` 用本 crate 的 [`crate::regex_matcher`]（QuickJS libregexp，非 unicode
//!   模式，与 Dart `RegExp` 同语义）；模式语法错误时与 Dart 的 `catch (_) {}` 一致，跳过过滤。
//! - `tun` 不是对象、`proxy-groups` 元素不是对象等情形，这里返回错误（FFI 侧得到 NULL），
//!   Dart 会直接抛异常。

use std::collections::HashSet;

use serde_json::{json, Map, Value};

use crate::dns_override::apply_dns_node_override;
use crate::group_switch::apply_group_switches;
use crate::regex_matcher::RegexMatcher;

const EXTERNAL_UI_URL: &str =
    "https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip";
const MSFT_NCSI_HOSTS: [&str; 2] = ["131.107.255.255", "fd3e:4f5a:5b81::1"];
const QUIC_RULE: &str = "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT";
const QUIC_RULE_EXCLUDE_CHINA: &str = "AND,((NETWORK,UDP),(DST-PORT,443),(NOT,((OR,((GEOSITE,geolocation-cn),(GEOIP,CN,no-resolve)))))),REJECT";

/// 跑完整条改写管道，返回改写后的配置。
pub fn patch_config(input: &Value) -> Result<Value, String> {
    let raw_config = object_of(input, "rawConfig")?;
    let patch = object_of(input, "patch")?;
    let profile = object_of(input, "profile")?;
    let env = object_of(input, "env")?;

    let is_android = env_bool(env, "isAndroid");
    let is_linux = env_bool(env, "isLinux");
    let profile_id = env_str(profile, "id");

    let mut config = raw_config.clone();
    let original_proxy_groups = config.get("proxy-groups").cloned();

    let external_controller = take(patch, "external-controller");
    let allow_lan = env_bool(patch, "allow-lan");
    config.insert(
        "external-controller".to_string(),
        match (allow_lan, external_controller.as_str()) {
            (true, Some(value)) => Value::String(value.replace("127.0.0.1", "0.0.0.0")),
            _ => external_controller.clone(),
        },
    );
    if external_controller.as_str() == Some("127.0.0.1:9090") {
        if let Some(secret) = patch.get("secret").and_then(Value::as_str) {
            if !secret.is_empty() {
                config.insert("secret".to_string(), Value::String(secret.to_string()));
            }
        }
    }
    config.insert("external-ui".to_string(), env_value(env, "uiPath"));
    config.insert(
        "external-ui-url".to_string(),
        Value::String(EXTERNAL_UI_URL.to_string()),
    );
    config.remove("external-ui-name");
    if config.get("interface-name").is_none_or(Value::is_null) {
        config.insert("interface-name".to_string(), Value::String(String::new()));
    }

    for key in [
        "tcp-concurrent",
        "unified-delay",
        "ipv6",
        "log-level",
        "keep-alive-interval",
        "mixed-port",
        "redir-port",
        "tproxy-port",
        "find-process-mode",
        "allow-lan",
        "mode",
        "geodata-loader",
        "geox-url",
        "global-ua",
    ] {
        config.insert(key.to_string(), take(patch, key));
    }
    // 先清零再按配置写入，顺序与原实现一致。
    config.insert("port".to_string(), json!(0));
    config.insert("socks-port".to_string(), json!(0));
    for key in ["port", "socks-port"] {
        config.insert(key.to_string(), take(patch, key));
    }

    let patch_tun = nested_object(patch, "tun")?;
    if config.get("tun").is_none_or(Value::is_null) {
        config.insert("tun".to_string(), Value::Object(Map::new()));
    }
    let tun = ensure_object(&mut config, "tun")?;
    for key in [
        "enable",
        "device",
        "stack",
        "route-address",
        "route-exclude-address",
    ] {
        tun.insert(key.to_string(), take(patch_tun, key));
    }
    let dns_hijack = patch_tun
        .get("dns-hijack")
        .and_then(Value::as_array)
        .filter(|list| !list.is_empty())
        .cloned()
        .unwrap_or_else(|| vec![Value::String("any:53".to_string())]);
    tun.insert("dns-hijack".to_string(), Value::Array(dns_hijack));
    tun.insert("auto-route".to_string(), Value::Bool(!is_android));
    tun.insert(
        "auto-detect-interface".to_string(),
        Value::Bool(!is_android),
    );
    tun.insert("auto-redirect".to_string(), Value::Bool(is_linux));
    for key in [
        "strict-route",
        "endpoint-independent-nat",
        "disable-icmp-forwarding",
        "mtu",
    ] {
        tun.insert(key.to_string(), take(patch_tun, key));
    }

    config.insert("geodata-mode".to_string(), Value::Bool(false));

    // sniffer 端口统一转成字符串（内核要求）。注意这一步在 `sniffer ??= {}` 之前，
    // 作用于 profile 自带的 sniffer。
    if let Some(sniff) = config
        .get_mut("sniffer")
        .and_then(Value::as_object_mut)
        .and_then(|sniffer| sniffer.get_mut("sniff"))
        .and_then(Value::as_object_mut)
    {
        for entry in sniff.values_mut() {
            if let Some(ports) = entry.get_mut("ports") {
                if let Some(list) = ports.as_array() {
                    let converted: Vec<Value> = list
                        .iter()
                        .map(|item| Value::String(text_of(item)))
                        .collect();
                    *ports = Value::Array(converted);
                }
            }
        }
    }

    if config.get("profile").is_none_or(Value::is_null) {
        config.insert("profile".to_string(), Value::Object(Map::new()));
    }
    rewrite_provider_paths(&mut config, "proxy-providers", &profile_id, "proxies", env)?;
    rewrite_provider_paths(&mut config, "rule-providers", &profile_id, "rules", env)?;

    let profile_map = ensure_object(&mut config, "profile")?;
    for key in ["store-selected", "store-fake-ip"] {
        if profile_map.get(key).is_none_or(Value::is_null) {
            profile_map.insert(key.to_string(), Value::Bool(true));
        }
    }

    if config.get("hosts").is_none_or(Value::is_null) {
        config.insert("hosts".to_string(), Value::Object(Map::new()));
    }
    let hosts = ensure_object(&mut config, "hosts")?;
    if let Some(patch_hosts) = patch.get("hosts").and_then(Value::as_object) {
        for (key, value) in patch_hosts {
            hosts.insert(key.clone(), split_by_multiple_separators(&text_of(value)));
        }
    }
    hosts.insert(
        "dns.msftncsi.com".to_string(),
        json!(MSFT_NCSI_HOSTS.to_vec()),
    );

    if config.get("dns").is_none_or(Value::is_null) {
        config.insert("dns".to_string(), Value::Object(Map::new()));
    }
    let is_enable_dns = config
        .get("dns")
        .and_then(|dns| dns.get("enable"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if env_bool(env, "overrideDns") || !is_enable_dns {
        let original_dns = config.get("dns").cloned();
        let original_hosts = config.get("hosts").cloned();
        let patch_dns = nested_object(patch, "dns")?;

        let mut dns = patch_dns.clone();
        if !is_enable_dns {
            let mut nameserver = patch_dns
                .get("nameserver")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            nameserver.push(Value::String("system://".to_string()));
            dns.insert("nameserver".to_string(), Value::Array(nameserver));
        }
        let mut policy = Map::new();
        if let Some(entries) = dns.get("nameserver-policy").and_then(Value::as_object) {
            for (key, value) in entries {
                policy.insert(key.clone(), split_by_multiple_separators(&text_of(value)));
            }
        }
        dns.insert("nameserver-policy".to_string(), Value::Object(policy));
        config.insert("dns".to_string(), Value::Object(dns));

        // `apply_dns_node_override` 收的是整份配置的 `Value`，这里临时换手一次。
        let mut holder = Value::Object(std::mem::take(&mut config));
        apply_dns_node_override(&mut holder, original_dns.as_ref(), original_hosts.as_ref());
        if let Value::Object(back) = holder {
            config = back;
        }
    }

    if let Some(fallback_filter) = config
        .get_mut("dns")
        .and_then(Value::as_object_mut)
        .and_then(|dns| dns.get_mut("fallback-filter"))
        .and_then(Value::as_object_mut)
    {
        fallback_filter.remove("geosite");
    }

    if is_android {
        let no_providers =
            config.get("proxy-providers").is_none() && config.get("rule-providers").is_none();
        if let Some(dns) = config.get_mut("dns").and_then(Value::as_object_mut) {
            if let Some(listen) = dns.get("listen").and_then(Value::as_str) {
                let listen = listen.to_string();
                if listen.ends_with(":53") {
                    dns.insert(
                        "listen".to_string(),
                        Value::String(listen.replace(":53", ":10053")),
                    );
                }
                let has_local = match dns.get("proxy-server-nameserver") {
                    Some(Value::Array(list)) => list
                        .iter()
                        .any(|item| text_of(item).starts_with("127.0.0.1")),
                    Some(Value::String(text)) => text.starts_with("127.0.0.1"),
                    _ => false,
                };
                if no_providers && has_local && listen.starts_with("0.0.0.0") {
                    dns.insert(
                        "listen".to_string(),
                        Value::String(format!("127.0.0.1{}", &listen["0.0.0.0".len()..])),
                    );
                }
            }
        }
    }

    if config.get("ntp").is_none_or(Value::is_null) {
        config.insert("ntp".to_string(), Value::Object(Map::new()));
    }
    if env_bool(env, "overrideNtp") {
        config.insert("ntp".to_string(), take(patch, "ntp"));
    }
    if is_android {
        ensure_object(&mut config, "ntp")?
            .insert("write-to-system".to_string(), Value::Bool(false));
    }

    if config.get("sniffer").is_none_or(Value::is_null) {
        config.insert("sniffer".to_string(), Value::Object(Map::new()));
    }
    if env_bool(env, "overrideSniffer") {
        config.insert("sniffer".to_string(), take(patch, "sniffer"));
    }

    let gui_tunnels = patch
        .get("tunnels")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if !gui_tunnels.is_empty() {
        let mut tunnels = config
            .get("tunnels")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        tunnels.extend(gui_tunnels);
        config.insert("tunnels".to_string(), Value::Array(tunnels));
    }

    if config.get("experimental").is_none_or(Value::is_null) {
        config.insert("experimental".to_string(), Value::Object(Map::new()));
    }
    if env_bool(env, "overrideExperimental") {
        config.insert("experimental".to_string(), take(patch, "experimental"));
    }

    apply_node_filter(&mut config, env)?;
    normalize_tolerance(&mut config);

    let mut rules = match (config.remove("rules"), config.remove("rule")) {
        (Some(Value::Array(rules)), _) => rules,
        (_, Some(Value::Array(rules))) => rules,
        _ => Vec::new(),
    };

    let script_override = env_bool(profile, "useScriptOverride");
    let added_rules = env
        .get("scriptAddedRules")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let script_active =
        (env_bool(env, "hasCurrentScript") || !added_rules.is_empty()) && script_override;

    let override_data = nested_object(profile, "overrideData")?;
    if env_bool(override_data, "enable") && !script_active {
        let running_rule = override_data
            .get("rules")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if override_data.get("type").and_then(Value::as_str) == Some("override") {
            rules = running_rule;
        } else {
            rules = running_rule.into_iter().chain(rules).collect();
        }
    }

    if script_override && !added_rules.is_empty() {
        rules = added_rules.into_iter().chain(rules).collect();
    }

    if env_bool(env, "disableQuic") {
        let is_russian = env
            .get("locale")
            .and_then(Value::as_str)
            .map(|locale| locale.to_lowercase().starts_with("ru"))
            .unwrap_or(false);
        let quic_rule = if env_bool(env, "excludeChina") && !is_russian {
            QUIC_RULE_EXCLUDE_CHINA
        } else {
            QUIC_RULE
        };
        rules.insert(0, Value::String(quic_rule.to_string()));
    }

    if config.get("proxy-groups").is_none_or(Value::is_null) {
        if let Some(original) = original_proxy_groups {
            config.insert("proxy-groups".to_string(), original);
        }
    }

    apply_proxy_field_patches(&mut config);

    let switches = profile
        .get("groupSwitches")
        .cloned()
        .unwrap_or_else(|| Value::Object(Map::new()));
    let (groups, rules) = apply_group_switches(
        config.get("proxy-groups").unwrap_or(&Value::Null),
        &Value::Array(rules),
        &switches,
        script_active,
    );
    if !groups.is_null() {
        config.insert("proxy-groups".to_string(), groups);
    }
    config.remove("rule");
    config.insert("rules".to_string(), rules);

    Ok(Value::Object(config))
}

/// 节点过滤：把匹配 `nodeExcludeFilter` 的节点从分组里剔除，并按需补 `timeout`。
fn apply_node_filter(
    config: &mut Map<String, Value>,
    env: &Map<String, Value>,
) -> Result<(), String> {
    let node_exclude_filter = env_str(env, "nodeExcludeFilter");
    let health_check_timeout = env
        .get("healthCheckTimeout")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    if (node_exclude_filter.is_empty() && health_check_timeout == 5000)
        || !config.get("proxy-groups").is_some_and(Value::is_array)
    {
        return Ok(());
    }

    let filter_regex = if node_exclude_filter.is_empty() {
        None
    } else {
        // 编译失败（模式语法非法）时与 Dart 侧 `try { RegExp(...) } catch (_) {}` 一致：
        // 跳过节点过滤，而不是让整条管道失败。
        RegexMatcher::compile(&node_exclude_filter).ok()
    };

    let mut protected_names: HashSet<String> =
        ["DIRECT", "REJECT", "REJECT-DROP", "COMPATIBLE", "PASS"]
            .iter()
            .map(|name| name.to_string())
            .collect();
    let mut groups = config
        .remove("proxy-groups")
        .and_then(|value| match value {
            Value::Array(groups) => Some(groups),
            _ => None,
        })
        .unwrap_or_default();
    for group in &groups {
        if let Some(name) = group.get("name").and_then(Value::as_str) {
            protected_names.insert(name.to_string());
        }
    }

    for group in groups.iter_mut() {
        let Some(group) = group.as_object_mut() else {
            continue;
        };
        if filter_regex.is_some() && group.get("use").is_some_and(|use_| !use_.is_null()) {
            let existing = group.get("exclude-filter").and_then(Value::as_str);
            let merged = match existing {
                Some(existing) if !existing.is_empty() => {
                    format!("{existing}|{node_exclude_filter}")
                }
                _ => node_exclude_filter.clone(),
            };
            group.insert("exclude-filter".to_string(), Value::String(merged));
        }

        if filter_regex.is_some() && group.get("proxies").is_some_and(Value::is_array) {
            let regex = filter_regex.as_ref();
            let mut filtered: Vec<Value> = group
                .get("proxies")
                .and_then(Value::as_array)
                .map(|proxies| {
                    proxies
                        .iter()
                        .filter(|item| match (item.as_str(), regex) {
                            (Some(name), Some(regex)) => {
                                protected_names.contains(name) || !regex.is_match(name)
                            }
                            _ => true,
                        })
                        .cloned()
                        .collect()
                })
                .unwrap_or_default();
            let use_is_empty = match group.get("use") {
                None | Some(Value::Null) => true,
                Some(Value::Array(list)) => list.is_empty(),
                _ => false,
            };
            if filtered.is_empty() && use_is_empty {
                filtered.push(Value::String("DIRECT".to_string()));
            }
            group.insert("proxies".to_string(), Value::Array(filtered));
        }

        if health_check_timeout != 5000 && group.get("timeout").is_none_or(Value::is_null) {
            group.insert("timeout".to_string(), json!(health_check_timeout));
        }
    }

    if filter_regex.is_some() {
        if let Some(providers) = config
            .get_mut("proxy-providers")
            .and_then(Value::as_object_mut)
        {
            for provider in providers.values_mut() {
                let Some(provider) = provider.as_object_mut() else {
                    continue;
                };
                let existing = provider.get("exclude-filter").and_then(Value::as_str);
                let merged = match existing {
                    Some(existing) if !existing.is_empty() => {
                        format!("{existing}|{node_exclude_filter}")
                    }
                    _ => node_exclude_filter.clone(),
                };
                provider.insert("exclude-filter".to_string(), Value::String(merged));
            }
        }
    }

    config.insert("proxy-groups".to_string(), Value::Array(groups));
    Ok(())
}

/// `tolerance` 归一化：double 截断为 int，数字字符串转 int。
fn normalize_tolerance(config: &mut Map<String, Value>) {
    let Some(groups) = config.get_mut("proxy-groups").and_then(Value::as_array_mut) else {
        return;
    };
    for group in groups.iter_mut() {
        let Some(group) = group.as_object_mut() else {
            continue;
        };
        match group.get("tolerance") {
            Some(Value::Number(number)) if number.is_f64() => {
                if let Some(value) = number.as_f64() {
                    group.insert("tolerance".to_string(), json!(value as i64));
                }
            }
            Some(Value::String(text)) => {
                if let Ok(value) = text.parse::<i64>() {
                    group.insert("tolerance".to_string(), json!(value));
                }
            }
            _ => {}
        }
    }
}

/// 代理级字段补丁：补 `client-fingerprint`，`reality-opts.short-id` 数字转字符串。
fn apply_proxy_field_patches(config: &mut Map<String, Value>) {
    let global_client_fingerprint = config
        .get("global-client-fingerprint")
        .filter(|value| !value.is_null())
        .cloned();
    let Some(proxies) = config.get_mut("proxies").and_then(Value::as_array_mut) else {
        return;
    };
    for proxy in proxies.iter_mut() {
        let Some(proxy) = proxy.as_object_mut() else {
            continue;
        };
        let kind = proxy
            .get("type")
            .map(text_of)
            .unwrap_or_default()
            .to_lowercase();
        let is_tls = proxy.get("tls").and_then(Value::as_bool).unwrap_or(false);
        let supports = matches!(kind.as_str(), "trojan" | "anytls")
            || (matches!(kind.as_str(), "vmess" | "vless") && is_tls);
        if supports
            && global_client_fingerprint.is_some()
            && proxy.get("client-fingerprint").is_none_or(Value::is_null)
        {
            proxy.insert(
                "client-fingerprint".to_string(),
                global_client_fingerprint.clone().unwrap_or(Value::Null),
            );
        }
        if let Some(short_id) = proxy
            .get_mut("reality-opts")
            .and_then(Value::as_object_mut)
            .and_then(|reality| reality.get_mut("short-id"))
        {
            if short_id.is_number() {
                *short_id = Value::String(text_of(short_id));
            }
        }
    }
}

/// provider 的缓存文件路径（`AppPath.getProvidersFilePath` 的纯函数形态）。
fn rewrite_provider_paths(
    config: &mut Map<String, Value>,
    key: &str,
    profile_id: &str,
    kind: &str,
    env: &Map<String, Value>,
) -> Result<(), String> {
    let profiles_path = env_str(env, "profilesPath");
    let Some(providers) = config.get_mut(key).and_then(Value::as_object_mut) else {
        return Ok(());
    };
    for provider in providers.values_mut() {
        let Some(provider) = provider.as_object_mut() else {
            continue;
        };
        if provider.get("type").and_then(Value::as_str) != Some("http") {
            continue;
        }
        if let Some(url) = provider.get("url").and_then(Value::as_str) {
            let path = join_windows(
                &profiles_path,
                &["providers", profile_id, kind, &md5_hex(url)],
            );
            provider.insert("path".to_string(), Value::String(path));
        }
    }
    Ok(())
}

/// Dart `String.splitByMultipleSeparators`：按 `[, ;]+` 切分并丢空串；
/// 结果多于一段才返回数组，否则原样返回字符串。
fn split_by_multiple_separators(value: &str) -> Value {
    let parts: Vec<&str> = value
        .split([',', ' ', ';'])
        .filter(|part| !part.is_empty())
        .collect();
    if parts.len() > 1 {
        Value::Array(
            parts
                .into_iter()
                .map(|part| Value::String(part.to_string()))
                .collect(),
        )
    } else {
        Value::String(value.to_string())
    }
}

fn md5_hex(value: &str) -> String {
    format!("{:x}", md5::compute(value.as_bytes()))
}

/// `package:path` 的 `join`，本 crate 只服务 Windows。
fn join_windows(base: &str, parts: &[&str]) -> String {
    let mut result = base.trim_end_matches(['\\', '/']).to_string();
    for part in parts {
        result.push('\\');
        result.push_str(part.trim_matches(['\\', '/']));
    }
    result
}

fn object_of<'a>(parent: &'a Value, key: &str) -> Result<&'a Map<String, Value>, String> {
    parent
        .get(key)
        .and_then(Value::as_object)
        .ok_or_else(|| format!("`{key}` 必须是对象"))
}

fn nested_object<'a>(
    parent: &'a Map<String, Value>,
    key: &str,
) -> Result<&'a Map<String, Value>, String> {
    parent
        .get(key)
        .and_then(Value::as_object)
        .ok_or_else(|| format!("`{key}` 必须是对象"))
}

fn ensure_object<'a>(
    parent: &'a mut Map<String, Value>,
    key: &str,
) -> Result<&'a mut Map<String, Value>, String> {
    parent
        .get_mut(key)
        .and_then(Value::as_object_mut)
        .ok_or_else(|| format!("`{key}` 必须是对象"))
}

fn take(parent: &Map<String, Value>, key: &str) -> Value {
    parent.get(key).cloned().unwrap_or(Value::Null)
}

fn env_value(env: &Map<String, Value>, key: &str) -> Value {
    env.get(key).cloned().unwrap_or(Value::Null)
}

fn env_bool(parent: &Map<String, Value>, key: &str) -> bool {
    parent.get(key).and_then(Value::as_bool).unwrap_or(false)
}

fn env_str(parent: &Map<String, Value>, key: &str) -> String {
    parent
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

/// Dart 侧 `item.toString()` / `shortId.toString()` 的等价物。
fn text_of(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Number(number) => number.to_string(),
        Value::Bool(value) => value.to_string(),
        Value::Null => "null".to_string(),
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn minimal_input() -> Value {
        json!({
            "rawConfig": {
                "proxies": [
                    {"name": "节点1", "type": "ss", "server": "a.example.com"},
                    {"name": "节点2", "type": "ss", "server": "b.example.com"},
                ],
                "proxy-groups": [
                    {"name": "自动选择", "type": "url-test", "proxies": ["节点1", "节点2"]},
                    {"name": "DIRECT", "type": "select", "proxies": ["DIRECT"]},
                ],
                "rules": ["DOMAIN,a.example.com,自动选择", "MATCH,自动选择"],
            },
            "patch": {
                "dns": {"enable": true},
                "tun": {"enable": false, "device": "Bettbox", "dns-hijack": []},
                "ipv6": false,
                "allow-lan": false,
                "external-controller": "127.0.0.1:9090",
                "secret": "s3cret",
                "log-level": "error",
                "mode": "rule",
                "find-process-mode": "off",
                "geodata-loader": "memconservative",
                "mixed-port": 7890,
                "port": 7891,
                "geox-url": {"mmdb": "m", "asn": "a", "geosite": "g"},
                "hosts": {"example.com": "203.0.113.10, 203.0.113.11"},
                "tunnels": [],
                "sniffer": {},
                "ntp": {},
                "experimental": {},
            },
            "profile": {
                "id": "p1",
                "useScriptOverride": true,
                "groupSwitches": {"自动选择": false},
                "overrideData": {"enable": false, "type": "override", "rules": []},
            },
            "env": {
                "isAndroid": false,
                "isLinux": false,
                "uiPath": "C:\\demo\\ui",
                "profilesPath": "C:\\demo\\profiles",
                "nodeExcludeFilter": "",
                "healthCheckTimeout": 5000,
                "scriptAddedRules": [],
                "hasCurrentScript": false,
                "disableQuic": false,
                "excludeChina": false,
            },
        })
    }

    #[test]
    fn applies_patch_fields_and_rewrites_rules() {
        let output = patch_config(&minimal_input()).unwrap();
        assert_eq!(output["external-ui"], "C:\\demo\\ui");
        assert_eq!(output["port"], 7891);
        assert_eq!(output["secret"], "s3cret");
        // 禁用分组被移除，指向它的规则改判 PASS。
        assert_eq!(output["proxy-groups"].as_array().unwrap().len(), 1);
        assert_eq!(output["rules"][0], "DOMAIN,a.example.com,PASS");
        assert_eq!(output["rules"][1], "MATCH,PASS");
        assert_eq!(output["hosts"]["dns.msftncsi.com"][0], "131.107.255.255");
        // 多值 hosts 走分隔符切分，单值原样保留字符串。
        assert_eq!(
            output["hosts"]["example.com"],
            json!(["203.0.113.10", "203.0.113.11"])
        );
        assert!(output.get("rule").is_none());
    }

    #[test]
    fn node_filter_is_applied_when_supported() {
        let mut input = minimal_input();
        input["env"]["nodeExcludeFilter"] = json!("节点2");
        // 关掉分组开关，否则 `自动选择` 会被移除、看不到过滤结果。
        input["profile"]["groupSwitches"] = json!({});
        let output = patch_config(&input).unwrap();
        let members = output["proxy-groups"][0]["proxies"].as_array().unwrap();
        assert_eq!(members, &vec![json!("节点1")]);
    }

    #[test]
    fn brace_quantifier_filter_works_after_libregexp() {
        // 旧 mini_regex 对 `{n}` 会整条回退；换成 libregexp 后直接可用，不再需要 Dart 兜底。
        let mut input = minimal_input();
        input["env"]["nodeExcludeFilter"] = json!("^节点1{1}$");
        input["profile"]["groupSwitches"] = json!({});
        let output = patch_config(&input).unwrap();
        let members = output["proxy-groups"][0]["proxies"].as_array().unwrap();
        assert_eq!(members, &vec![json!("节点2")]);
    }

    #[test]
    fn invalid_filter_pattern_skips_filtering_like_dart() {
        // Dart 侧 `try { RegExp(...) } catch (_) {}`：语法错误时 filterRegex 为 null、
        // 整段过滤被跳过。Rust 现在与之一致，而不是让整条管道失败。
        let mut input = minimal_input();
        input["env"]["nodeExcludeFilter"] = json!("[a");
        input["profile"]["groupSwitches"] = json!({});
        let output = patch_config(&input).unwrap();
        let members = output["proxy-groups"][0]["proxies"].as_array().unwrap();
        assert_eq!(members, &vec![json!("节点1"), json!("节点2")]);
    }

    #[test]
    fn missing_sections_are_reported_as_errors() {
        let mut input = minimal_input();
        input.as_object_mut().unwrap().remove("patch");
        assert!(patch_config(&input).is_err());

        let mut input = minimal_input();
        input["patch"].as_object_mut().unwrap().remove("tun");
        assert!(patch_config(&input).is_err());
    }

    #[test]
    fn provider_paths_use_the_profiles_directory_and_md5() {
        let mut input = minimal_input();
        input["rawConfig"]["proxy-providers"] = json!({
            "机场A": {"type": "http", "url": "https://example.com/sub.yaml"},
            "本地": {"type": "file", "path": "./local.yaml"},
        });
        let output = patch_config(&input).unwrap();
        let path = output["proxy-providers"]["机场A"]["path"].as_str().unwrap();
        assert!(path.starts_with("C:\\demo\\profiles\\providers\\p1\\proxies\\"));
        assert_eq!(
            path.rsplit('\\').next().unwrap(),
            md5_hex("https://example.com/sub.yaml")
        );
        // 非 http provider 的 path 保持原样。
        assert_eq!(output["proxy-providers"]["本地"]["path"], "./local.yaml");
    }

    #[test]
    fn split_by_multiple_separators_matches_dart() {
        assert_eq!(split_by_multiple_separators("a"), json!("a"));
        assert_eq!(
            split_by_multiple_separators("a, b;c"),
            json!(["a", "b", "c"])
        );
        assert_eq!(split_by_multiple_separators(""), json!(""));
        // 只有一段时返回原字符串（连分隔符一起）。
        assert_eq!(split_by_multiple_separators("a,"), json!("a,"));
        assert_eq!(split_by_multiple_separators(" , "), json!(" , "));
    }

    #[test]
    fn md5_hex_matches_dart_crypto() {
        assert_eq!(md5_hex(""), "d41d8cd98f00b204e9800998ecf8427e");
        assert_eq!(md5_hex("abc"), "900150983cd24fb0d6963f7d28e17f72");
    }
}
