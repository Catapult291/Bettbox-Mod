//! DNS 节点覆写（Dart 侧 `lib/common/dns_override.dart` 的 Rust 移植）。
//!
//! 行为需与 Dart 逐字段一致，差分测试见 `test/rust/dns_override_diff_test.dart`。
//!
//! 已知差异：Dart `List.sort` 对短列表是稳定插入排序、长列表是不稳定快排；这里用稳定排序
//! 对齐。宿主的 `hosts` 条目数不大时两者一致；条目很多且 specificity 相同的情况下可能不同。

use std::collections::{HashMap, HashSet};

use serde_json::{Map, Value};

/// 公共 DNS 列表（与 Dart `commonDnsList` 一致）。
pub const COMMON_DNS_LIST: &[&str] = &[
    "223.5.5.5",
    "223.6.6.6",
    "119.29.29.29",
    "1.12.12.12",
    "120.53.53.53",
    "114.114.114.114",
    "180.76.76.76",
    "1.2.4.8",
    "116.116.116.116",
    "101.226.4.6",
    "123.125.81.6",
    "180.184.1.1",
    "180.184.2.2",
    "1.1.1.1",
    "1.0.0.1",
    "8.8.8.8",
    "8.8.4.4",
    "9.9.9.9",
    "149.112.112.112",
    "208.67.222.222",
    "208.67.220.220",
    "94.140.14.14",
    "94.140.15.15",
    "76.76.2.0",
    "76.76.10.0",
    "185.228.168.9",
    "185.228.169.9",
    "77.88.8.8",
    "77.88.8.1",
    "156.154.70.1",
    "156.154.71.1",
    "alidns",
    "doh.pub",
    "dot.pub",
    "dns.pub",
    "dnspod",
    "dns.baidu",
    "dns.google",
    "cloudflare",
    "quad9",
    "opendns",
    "nextdns",
    "adguard",
    "system",
];

/// 域名模式的匹配优先级（数值越大越具体）。
pub fn host_specificity(pattern: &str) -> i32 {
    if pattern.starts_with("+.") {
        2
    } else if pattern.starts_with('.') {
        1
    } else if pattern.contains('*') {
        0
    } else {
        3
    }
}

/// 判断 `pattern` 是否命中 `domains` 中的任一域名。
pub fn match_domain_pattern(pattern: &str, domains: &[String]) -> bool {
    let pattern = pattern.to_lowercase();

    if !pattern.contains('*') && !pattern.starts_with("+.") && !pattern.starts_with('.') {
        return domains
            .iter()
            .any(|domain| domain.to_lowercase() == pattern);
    }

    let domain_list: Vec<String> = domains.iter().map(|domain| domain.to_lowercase()).collect();

    if let Some(suffix) = pattern.strip_prefix("+.") {
        return domain_list
            .iter()
            .any(|domain| domain == suffix || domain.ends_with(&format!(".{suffix}")));
    }

    if let Some(suffix) = pattern.strip_prefix('.') {
        return domain_list
            .iter()
            .any(|domain| domain != suffix && domain.ends_with(&format!(".{suffix}")));
    }

    let pattern_parts: Vec<&str> = pattern.split('.').collect();
    domain_list.iter().any(|domain| {
        let domain_parts: Vec<&str> = domain.split('.').collect();
        pattern_parts.len() == domain_parts.len()
            && pattern_parts
                .iter()
                .zip(domain_parts.iter())
                .all(|(pattern_part, domain_part)| {
                    *pattern_part == "*" || pattern_part == domain_part
                })
    })
}

/// 去掉 `dns#suffix` 里的策略后缀；`#direct` / `#direct&...` 原样保留。
pub fn strip_dns_suffix(dns: &str) -> String {
    match dns.find('#') {
        None => dns.to_string(),
        Some(index) => {
            let suffix = dns[index + 1..].to_lowercase();
            let suffix = suffix.trim();
            if suffix == "direct" || suffix.starts_with("direct&") {
                dns.to_string()
            } else {
                dns[..index].to_string()
            }
        }
    }
}

fn as_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        other => other.to_string(),
    }
}

fn target_of(value: &Value) -> Option<String> {
    match value {
        Value::Array(items) => items.iter().find_map(|item| {
            item.as_str()
                .filter(|text| !text.is_empty())
                .map(String::from)
        }),
        Value::String(text) if !text.is_empty() => Some(text.clone()),
        _ => None,
    }
}

/// 按 `hosts` 把代理的 `server` 替换成映射目标（支持链式解析与环检测）。
pub fn apply_hosts_to_proxies(proxies: &[Value], hosts: Option<&Value>) -> Vec<Value> {
    let Some(hosts) = hosts.and_then(Value::as_object) else {
        return proxies.to_vec();
    };
    if hosts.is_empty() {
        return proxies.to_vec();
    }

    let mut host_entries: Vec<(&String, &Value)> = hosts
        .iter()
        .filter(|(_, value)| match value {
            Value::String(text) => !text.is_empty(),
            Value::Array(items) => !items.is_empty(),
            _ => false,
        })
        .collect();
    if host_entries.is_empty() {
        return proxies.to_vec();
    }
    // Dart 的 List.sort 在短列表上是稳定排序；这里用稳定排序对齐。
    host_entries.sort_by_key(|entry| std::cmp::Reverse(host_specificity(entry.0)));

    let mut cache: HashMap<String, String> = HashMap::new();
    proxies
        .iter()
        .map(|proxy| {
            let Some(map) = proxy.as_object() else {
                return proxy.clone();
            };
            let Some(server) = map.get("server").and_then(Value::as_str) else {
                return proxy.clone();
            };
            let resolved = resolve_server(server, &host_entries, &mut cache);
            if resolved == server {
                return proxy.clone();
            }
            let mut updated = map.clone();
            updated.insert("server".to_string(), Value::String(resolved));
            Value::Object(updated)
        })
        .collect()
}

fn resolve_server(
    server: &str,
    host_entries: &[(&String, &Value)],
    cache: &mut HashMap<String, String>,
) -> String {
    if let Some(cached) = cache.get(server) {
        return cached.clone();
    }

    let mut seen: HashSet<String> = HashSet::new();
    let mut current = server.to_lowercase();
    let mut result = server.to_string();

    while seen.insert(current.clone()) {
        let mut target: Option<String> = None;
        for (key, value) in host_entries {
            if match_domain_pattern(key, std::slice::from_ref(&current)) {
                target = target_of(value);
                break;
            }
        }
        let Some(target) = target else { break };
        result = target.clone();
        current = target.to_lowercase();
    }

    cache.insert(server.to_string(), result.clone());
    result
}

fn collect_servers(proxies: &[Value], domains: &mut HashSet<String>) {
    for proxy in proxies {
        let Some(map) = proxy.as_object() else {
            continue;
        };
        if let Some(server) = map.get("server").and_then(Value::as_str) {
            domains.insert(server.to_lowercase());
        }
    }
}

/// 就地覆写 `raw_config`：按 `original_dns` / `original_hosts` 补上代理节点专用的 DNS 设置。
pub fn apply_dns_node_override(
    raw_config: &mut Value,
    original_dns: Option<&Value>,
    original_hosts: Option<&Value>,
) {
    let empty = Value::Object(Map::new());
    let original_dns = original_dns.unwrap_or(&empty);
    let original_dns_object = original_dns.as_object();

    let proxy_server_nameservers: Vec<String> = original_dns_object
        .and_then(|object| object.get("proxy-server-nameserver"))
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    let listen_value = original_dns_object
        .and_then(|object| object.get("listen"))
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty());

    let should_rewrite_by_hosts = proxy_server_nameservers.len() == 1
        && listen_value.is_some()
        && proxy_server_nameservers.iter().any(|dns| {
            dns.to_lowercase()
                .contains(&listen_value.unwrap_or_default().to_lowercase())
        });

    let proxies: Vec<Value> = raw_config
        .get("proxies")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    let mapped_proxies = if should_rewrite_by_hosts {
        apply_hosts_to_proxies(&proxies, original_hosts)
    } else {
        proxies.clone()
    };
    if should_rewrite_by_hosts {
        raw_config["proxies"] = Value::Array(mapped_proxies.clone());
    }

    let mut proxy_domains: HashSet<String> = HashSet::new();
    collect_servers(&proxies, &mut proxy_domains);
    if should_rewrite_by_hosts {
        collect_servers(&mapped_proxies, &mut proxy_domains);
    }
    let proxy_domain_list: Vec<String> = proxy_domains.iter().cloned().collect();

    let mut common_dns: Vec<String> = COMMON_DNS_LIST
        .iter()
        .map(|dns| dns.to_lowercase())
        .collect();
    if should_rewrite_by_hosts {
        common_dns.push(listen_value.unwrap_or_default().to_lowercase());
    }
    let is_common_dns = |dns: &str| {
        let lower = dns.to_lowercase();
        common_dns.iter().any(|common| lower.contains(common))
    };

    let nameservers: Vec<Value> = original_dns_object
        .and_then(|object| object.get("nameserver"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    let mut private_dns: Vec<String> = Vec::new();
    let mut seen_private: HashSet<String> = HashSet::new();
    let candidates = nameservers
        .iter()
        .map(as_text)
        .chain(proxy_server_nameservers.iter().cloned());
    for dns in candidates {
        let stripped = strip_dns_suffix(&dns);
        if !stripped.is_empty()
            && !is_common_dns(&stripped)
            && seen_private.insert(stripped.clone())
        {
            private_dns.push(stripped);
        }
    }

    let original_policy = merged_policy(original_dns_object);
    let mut proxy_server_policy: Map<String, Value> = Map::new();
    for (key, value) in original_policy {
        if !match_domain_pattern(&key, &proxy_domain_list) {
            continue;
        }
        let stripped = match &value {
            Value::Array(items) => {
                let list: Vec<Value> = items
                    .iter()
                    .map(|item| Value::String(strip_dns_suffix(&as_text(item))))
                    .filter(|item| !item.as_str().unwrap_or_default().is_empty())
                    .collect();
                if list.is_empty() {
                    continue;
                }
                Value::Array(list)
            }
            other => Value::String(strip_dns_suffix(&as_text(other))),
        };
        proxy_server_policy.insert(key, stripped);
    }

    let proxy_fake_ip_filter: Vec<Value> = original_dns_object
        .and_then(|object| object.get("fake-ip-filter"))
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter(|item| match_domain_pattern(&as_text(item), &proxy_domain_list))
                .map(|item| Value::String(as_text(item)))
                .collect()
        })
        .unwrap_or_default();

    let Some(dns) = raw_config.get_mut("dns").and_then(Value::as_object_mut) else {
        return;
    };

    if !private_dns.is_empty() {
        dns.insert(
            "proxy-server-nameserver".to_string(),
            Value::Array(private_dns.into_iter().map(Value::String).collect()),
        );
    }
    if !proxy_server_policy.is_empty() {
        dns.insert(
            "proxy-server-nameserver-policy".to_string(),
            Value::Object(proxy_server_policy),
        );
    }
    if !proxy_fake_ip_filter.is_empty() {
        let mut existing = dns
            .get("fake-ip-filter")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        existing.extend(proxy_fake_ip_filter);
        dns.insert("fake-ip-filter".to_string(), Value::Array(existing));
    }
}

/// Dart `{...nameserver-policy, ...proxy-server-nameserver-policy}`：同键取后者，位置取首次出现。
fn merged_policy(original_dns: Option<&Map<String, Value>>) -> Vec<(String, Value)> {
    let mut order: Vec<String> = Vec::new();
    let mut values: HashMap<String, Value> = HashMap::new();
    for key in ["nameserver-policy", "proxy-server-nameserver-policy"] {
        let Some(map) = original_dns
            .and_then(|object| object.get(key))
            .and_then(Value::as_object)
        else {
            continue;
        };
        for (entry_key, entry_value) in map {
            if values
                .insert(entry_key.clone(), entry_value.clone())
                .is_none()
            {
                order.push(entry_key.clone());
            }
        }
    }
    order
        .into_iter()
        .filter_map(|key| values.remove(&key).map(|value| (key, value)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn host_specificity_orders_exact_over_wildcard() {
        assert_eq!(host_specificity("+.example.com"), 2);
        assert_eq!(host_specificity(".example.com"), 1);
        assert_eq!(host_specificity("*.example.com"), 0);
        assert_eq!(host_specificity("a.example.com"), 3);
    }

    #[test]
    fn match_domain_pattern_covers_each_branch() {
        let domains = |values: &[&str]| values.iter().map(|v| v.to_string()).collect::<Vec<_>>();
        assert!(match_domain_pattern(
            "a.example.com",
            &domains(&["A.Example.COM"])
        ));
        assert!(!match_domain_pattern(
            "a.example.com",
            &domains(&["b.example.com"])
        ));
        assert!(match_domain_pattern(
            "+.example.com",
            &domains(&["example.com"])
        ));
        assert!(match_domain_pattern(
            "+.example.com",
            &domains(&["a.example.com"])
        ));
        assert!(match_domain_pattern(
            ".example.com",
            &domains(&["a.example.com"])
        ));
        assert!(!match_domain_pattern(
            ".example.com",
            &domains(&["example.com"])
        ));
        assert!(match_domain_pattern(
            "*.example.com",
            &domains(&["a.example.com"])
        ));
        assert!(!match_domain_pattern(
            "*.example.com",
            &domains(&["a.b.example.com"])
        ));
    }

    #[test]
    fn strip_dns_suffix_keeps_direct_markers() {
        assert_eq!(
            strip_dns_suffix("https://doh.pub/dns-query"),
            "https://doh.pub/dns-query"
        );
        assert_eq!(strip_dns_suffix("8.8.8.8#direct"), "8.8.8.8#direct");
        assert_eq!(strip_dns_suffix("8.8.8.8#direct&x"), "8.8.8.8#direct&x");
        assert_eq!(strip_dns_suffix("8.8.8.8#proxy"), "8.8.8.8");
    }

    #[test]
    fn hosts_rewrite_resolves_chains() {
        let proxies = vec![json!({"name": "a", "server": "node1.example.com"})];
        let hosts = json!({
            "node1.example.com": "real1.example.net",
            "real1.example.net": "203.0.113.7",
            "+.example.com": "wild.example.net",
        });
        let mapped = apply_hosts_to_proxies(&proxies, Some(&hosts));
        assert_eq!(mapped[0]["server"], "203.0.113.7");
    }

    #[test]
    fn override_fills_proxy_specific_dns() {
        let mut raw = json!({
            "proxies": [{"name": "a", "server": "node1.example.com"}],
            "dns": {"enable": true},
        });
        let original_dns = json!({
            "nameserver": [
                "https://doh.pub/dns-query",
                "tls://1.1.1.1:853",
                "https://private.example.net/dns-query",
                "192.168.1.1#direct",
            ],
            "proxy-server-nameserver": ["https://private.example.net/dns-query"],
            "nameserver-policy": {
                "node1.example.com": ["https://private.example.net/dns-query"],
                "other.example.net": ["https://x.example.net/dns-query"],
            },
            "fake-ip-filter": ["+.lan", "node1.example.com"],
        });

        apply_dns_node_override(&mut raw, Some(&original_dns), None);

        assert_eq!(
            raw["dns"]["proxy-server-nameserver"],
            json!([
                "https://private.example.net/dns-query",
                "192.168.1.1#direct"
            ])
        );
        assert_eq!(
            raw["dns"]["proxy-server-nameserver-policy"],
            json!({"node1.example.com": ["https://private.example.net/dns-query"]})
        );
        assert_eq!(raw["dns"]["fake-ip-filter"], json!(["node1.example.com"]));
    }

    #[test]
    fn override_without_dns_section_is_a_noop() {
        let mut raw = json!({"proxies": [{"name": "a", "server": "node1.example.com"}]});
        let before = raw.clone();
        apply_dns_node_override(&mut raw, Some(&json!({"nameserver": ["8.8.8.8"]})), None);
        assert_eq!(raw, before);
    }
}
