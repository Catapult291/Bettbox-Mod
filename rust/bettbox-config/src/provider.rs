//! provider 元数据解析与「内核代理表 + provider 原文」构组。
//!
//! 对应 Dart 侧 `lib/clash/core.dart` 的 `parseExternalProvidersMetaSync` 与
//! `buildProxiesGroups`（原始形态 `buildProxiesGroupsRaw`）。差分测试见
//! `test/rust/provider_diff_test.dart`。
//!
//! 与 Dart 的差异（仅在畸形输入上体现，正常内核输出不会触发）：
//! Dart 对 provider 列表做 `ExternalProvider.fromJson`，字段缺失会抛错；这里缺字段就跳过该 provider。

use serde_json::{Map, Value};

/// 分组类型（与 Dart `GroupTypeExtension.valueList` 一致）。
pub const GROUP_TYPE_VALUES: [&str; 4] = ["Selector", "URLTest", "Fallback", "LoadBalance"];

/// provider 的元数据（剥掉全节点列表）。键名与 Dart 模型字段对应。
pub fn parse_provider_meta(raw: &str) -> Result<Vec<Value>, serde_json::Error> {
    let Value::Array(providers) = serde_json::from_str::<Value>(raw)? else {
        return Ok(Vec::new());
    };

    Ok(providers
        .iter()
        .map(|provider| {
            let mut meta = Map::new();
            meta.insert(
                "name".to_string(),
                Value::String(text_of(provider.get("name"))),
            );
            meta.insert(
                "type".to_string(),
                Value::String(text_of(provider.get("type"))),
            );
            meta.insert(
                "path".to_string(),
                match provider.get("path") {
                    Some(Value::String(path)) => Value::String(path.clone()),
                    _ => Value::Null,
                },
            );
            meta.insert(
                "count".to_string(),
                Value::Number(
                    provider
                        .get("count")
                        .and_then(Value::as_i64)
                        .unwrap_or(0)
                        .into(),
                ),
            );
            meta.insert(
                "subscriptionInfo".to_string(),
                subscription_info(provider.get("subscription-info")),
            );
            meta.insert(
                "isUpdating".to_string(),
                Value::Bool(
                    provider
                        .get("isUpdating")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                ),
            );
            meta.insert(
                "vehicleType".to_string(),
                Value::String(text_of(provider.get("vehicle-type"))),
            );
            meta.insert(
                "updateAt".to_string(),
                Value::String(text_of(provider.get("update-at"))),
            );
            Value::Object(meta)
        })
        .collect())
}

/// 由内核代理表 + provider 原文构建分组；provider 节点会并入代理表。
///
/// 返回的是喂给 Dart `Group.fromJson` 的原始分组 map（typed 模型会丢字段，
/// 用原始 map 才能和 Rust 侧逐字段差分）。
pub fn build_proxies_groups(proxies: &Value, raw_providers: &str) -> Vec<Value> {
    let Some(proxies_object) = proxies.as_object() else {
        return Vec::new();
    };
    let mut all_proxies: Map<String, Value> = proxies_object.clone();

    if !raw_providers.is_empty() {
        if let Ok(Value::Array(providers)) = serde_json::from_str::<Value>(raw_providers) {
            for provider in &providers {
                let Some(provider_name) = provider.get("name").and_then(Value::as_str) else {
                    continue;
                };
                let Some(list) = provider.get("proxies").and_then(Value::as_array) else {
                    continue;
                };
                let suffix = format!("[{provider_name}]");
                for proxy in list {
                    let Some(proxy_map) = proxy.as_object() else {
                        continue;
                    };
                    let Some(name) = proxy_map.get("name").and_then(Value::as_str) else {
                        continue;
                    };
                    all_proxies.insert(name.to_string(), proxy.clone());
                    if !name.ends_with(&suffix) {
                        all_proxies.insert(format!("{name}{suffix}"), proxy.clone());
                    }
                }
            }
        }
    }

    let Some(global) = all_proxies.get("GLOBAL") else {
        return Vec::new();
    };
    let Some(all_list) = global.get("all").and_then(Value::as_array) else {
        return Vec::new();
    };

    let mut group_names: Vec<String> = vec!["GLOBAL".to_string()];
    for entry in all_list {
        let Some(key) = entry.as_str() else { continue };
        let Some(proxy) = all_proxies.get(key) else {
            continue;
        };
        if let Some(kind) = proxy.get("type").and_then(Value::as_str) {
            if GROUP_TYPE_VALUES.contains(&kind) {
                group_names.push(key.to_string());
            }
        }
    }

    group_names
        .iter()
        .filter_map(|group_name| {
            let mut group = all_proxies.get(group_name)?.as_object()?.clone();
            let members = group
                .get("all")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let resolved: Vec<Value> = members
                .iter()
                .filter_map(|member| {
                    member
                        .as_str()
                        .and_then(|key| all_proxies.get(key))
                        .cloned()
                })
                .collect();
            group.insert("all".to_string(), Value::Array(resolved));
            Some(Value::Object(group))
        })
        .collect()
}

fn text_of(value: Option<&Value>) -> String {
    value
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn subscription_info(value: Option<&Value>) -> Value {
    let Some(object) = value.and_then(Value::as_object) else {
        return Value::Null;
    };
    let mut info = Map::new();
    for (key, target) in [
        ("Upload", "upload"),
        ("Download", "download"),
        ("Total", "total"),
        ("Expire", "expire"),
    ] {
        info.insert(
            target.to_string(),
            Value::Number(object.get(key).and_then(Value::as_i64).unwrap_or(0).into()),
        );
    }
    Value::Object(info)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn provider_meta_strips_proxies_and_keeps_fields() {
        let raw = json!([{
            "name": "机场A",
            "type": "Proxy",
            "vehicle-type": "HTTP",
            "path": "providers/a.yaml",
            "count": 2,
            "update-at": "2026-09-20T04:00:00Z",
            "subscription-info": {"Upload": 1, "Download": 2, "Total": 3, "Expire": 4},
            "proxies": [{"name": "节点1", "type": "ss"}],
        }])
        .to_string();

        let metas = parse_provider_meta(&raw).unwrap();
        assert_eq!(metas.len(), 1);
        let meta = &metas[0];
        assert_eq!(meta["name"], "机场A");
        assert_eq!(meta["type"], "Proxy");
        assert_eq!(meta["vehicleType"], "HTTP");
        assert_eq!(meta["path"], "providers/a.yaml");
        assert_eq!(meta["count"], 2);
        assert_eq!(meta["updateAt"], "2026-09-20T04:00:00Z");
        assert_eq!(meta["subscriptionInfo"]["total"], 3);
        assert_eq!(meta["isUpdating"], false);
        assert!(meta.get("proxies").is_none());
    }

    #[test]
    fn provider_meta_without_subscription_info_is_null() {
        let raw = json!([{"name": "空机场", "type": "Rule", "count": 0}]).to_string();
        let metas = parse_provider_meta(&raw).unwrap();
        assert_eq!(metas[0]["subscriptionInfo"], Value::Null);
        assert_eq!(metas[0]["count"], 0);
    }

    #[test]
    fn groups_merge_provider_nodes_and_resolve_suffixed_refs() {
        let proxies = json!({
            "GLOBAL": {
                "name": "GLOBAL",
                "type": "Selector",
                "now": "节点1",
                "all": ["节点1", "节点2[机场A]", "DIRECT", "自动选择"],
            },
            "自动选择": {
                "name": "自动选择",
                "type": "URLTest",
                "now": "节点1",
                "all": ["节点1", "节点2[机场A]"],
            },
            "DIRECT": {"name": "DIRECT", "type": "Direct"},
        });
        let providers = json!([{
            "name": "机场A",
            "type": "Proxy",
            "vehicle-type": "HTTP",
            "count": 2,
            "update-at": "2026-09-20T04:00:00Z",
            "proxies": [
                {"name": "节点1", "type": "ss"},
                {"name": "节点2", "type": "vmess"},
            ],
        }])
        .to_string();

        let groups = build_proxies_groups(&proxies, &providers);
        let names: Vec<&str> = groups
            .iter()
            .map(|group| group["name"].as_str().unwrap_or_default())
            .collect();
        assert_eq!(names, vec!["GLOBAL", "自动选择"]);

        let global_members: Vec<&str> = groups[0]["all"]
            .as_array()
            .unwrap()
            .iter()
            .map(|member| member["name"].as_str().unwrap_or_default())
            .collect();
        assert!(global_members.contains(&"节点1"));
        assert!(global_members.contains(&"DIRECT"));
        assert!(global_members.contains(&"节点2"));
        assert!(!global_members.contains(&"节点2[机场A]"));
    }

    #[test]
    fn without_provider_content_nodes_stay_unresolved() {
        let proxies = json!({
            "GLOBAL": {"name": "GLOBAL", "type": "Selector", "all": ["节点1", "DIRECT"]},
            "DIRECT": {"name": "DIRECT", "type": "Direct"},
        });
        let groups = build_proxies_groups(&proxies, "");
        let members: Vec<&str> = groups[0]["all"]
            .as_array()
            .unwrap()
            .iter()
            .map(|member| member["name"].as_str().unwrap_or_default())
            .collect();
        assert_eq!(members, vec!["DIRECT"]);
    }

    #[test]
    fn missing_global_returns_empty() {
        let proxies = json!({"DIRECT": {"name": "DIRECT", "type": "Direct"}});
        assert!(build_proxies_groups(&proxies, "[]").is_empty());
    }
}
