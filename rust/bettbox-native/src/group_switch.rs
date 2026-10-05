//! 分组开关：禁用分组从 `proxy-groups` 移除，命中禁用分组目标的规则改判为 `PASS`。
//!
//! 对应 Dart 侧 `lib/common/group_switch.dart` 的 `applyGroupSwitches`
//! （由 `lib/state.dart` 的 `patchRawConfig` 调用）。差分测试见
//! `test/rust/group_switch_diff_test.dart`。
//!
//! 与 Dart 的差异（仅在畸形输入上体现）：Dart 的 `groupSwitches` 是
//! `Map<String, bool>`，值必为 bool；这里把非 bool 的值当作「启用」（跳过），
//! `rules` 不是数组时原样返回。

use std::collections::HashSet;

use serde_json::Value;

use crate::rule::ParsedRule;

/// 就地应用分组开关，返回 `(proxy-groups, rules)`。
///
/// 不满足条件时（无开关 / 全部启用 / `script_active` / `proxy-groups` 不是数组）
/// 原样返回输入。
pub fn apply_group_switches(
    proxy_groups: &Value,
    rules: &Value,
    group_switches: &Value,
    script_active: bool,
) -> (Value, Value) {
    let unchanged = || (proxy_groups.clone(), rules.clone());

    let Some(switches) = group_switches.as_object() else {
        return unchanged();
    };
    if switches.is_empty() || script_active {
        return unchanged();
    }
    let Some(groups) = proxy_groups.as_array() else {
        return unchanged();
    };

    let disabled: HashSet<&str> = switches
        .iter()
        .filter(|(_, enabled)| enabled.as_bool() == Some(false))
        .map(|(name, _)| name.as_str())
        .collect();
    if disabled.is_empty() {
        return unchanged();
    }

    let filtered: Vec<Value> = groups
        .iter()
        .filter(|group| match group.get("name").and_then(Value::as_str) {
            Some(name) => !disabled.contains(name),
            None => true,
        })
        .cloned()
        .collect();

    let rewritten = match rules.as_array() {
        Some(items) => Value::Array(
            items
                .iter()
                .map(|rule| match rule.as_str() {
                    Some(text) => {
                        let mut parsed = ParsedRule::parse(text);
                        match parsed.target.as_deref() {
                            Some(target) if disabled.contains(target) => {
                                parsed.target = Some("PASS".to_string());
                                Value::String(parsed.to_config_string())
                            }
                            _ => rule.clone(),
                        }
                    }
                    None => rule.clone(),
                })
                .collect(),
        ),
        None => rules.clone(),
    };

    (Value::Array(filtered), rewritten)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn disabled_group_is_removed_and_its_rules_retargeted() {
        let groups = json!([
            {"name": "自动选择", "type": "url-test", "proxies": ["节点1"]},
            {"name": "手动选择", "type": "select", "proxies": ["节点1"]},
            {"name": "DIRECT", "type": "select", "proxies": ["DIRECT"]},
        ]);
        let rules = json!([
            "DOMAIN,example.com,自动选择",
            "GEOIP,CN,自动选择,no-resolve",
            "DOMAIN,other.com,手动选择",
            "MATCH,自动选择",
        ]);
        let switches = json!({"自动选择": false, "手动选择": true});

        let (groups, rules) = apply_group_switches(&groups, &rules, &switches, false);

        let names: Vec<&str> = groups
            .as_array()
            .unwrap()
            .iter()
            .map(|g| g["name"].as_str().unwrap())
            .collect();
        assert_eq!(names, vec!["手动选择", "DIRECT"]);
        assert_eq!(
            rules,
            json!([
                "DOMAIN,example.com,PASS",
                "GEOIP,CN,PASS,no-resolve",
                "DOMAIN,other.com,手动选择",
                "MATCH,PASS",
            ])
        );
    }

    #[test]
    fn all_enabled_leaves_everything_alone() {
        let groups = json!([{"name": "自动选择", "type": "select"}]);
        let rules = json!(["DOMAIN,example.com,自动选择"]);
        let switches = json!({"自动选择": true});
        let (out_groups, out_rules) = apply_group_switches(&groups, &rules, &switches, false);
        assert_eq!(out_groups, groups);
        assert_eq!(out_rules, rules);
    }

    #[test]
    fn script_active_skips_the_whole_step() {
        let groups = json!([{"name": "自动选择", "type": "select"}]);
        let rules = json!(["DOMAIN,example.com,自动选择"]);
        let switches = json!({"自动选择": false});
        let (out_groups, out_rules) = apply_group_switches(&groups, &rules, &switches, true);
        assert_eq!(out_groups, groups);
        assert_eq!(out_rules, rules);
    }

    #[test]
    fn non_list_proxy_groups_skips_rule_rewriting_too() {
        let groups = json!({"自动选择": {"type": "select"}});
        let rules = json!(["DOMAIN,example.com,自动选择"]);
        let switches = json!({"自动选择": false});
        let (out_groups, out_rules) = apply_group_switches(&groups, &rules, &switches, false);
        assert_eq!(out_groups, groups);
        assert_eq!(out_rules, rules);
    }

    #[test]
    fn nameless_groups_and_non_string_rules_survive() {
        let groups = json!([
            {"type": "select"},
            "not-a-group",
            {"name": "自动选择", "type": "select"},
        ]);
        let rules = json!([42, null, "SUB-RULE,(DOMAIN,example.com),自动选择"]);
        let switches = json!({"自动选择": false});

        let (out_groups, out_rules) = apply_group_switches(&groups, &rules, &switches, false);
        assert_eq!(out_groups.as_array().unwrap().len(), 2);
        // SUB-RULE 的目标存在 subRule 而非 target，Dart 同样不改写。
        assert_eq!(out_rules, rules);
    }

    #[test]
    fn empty_switch_map_is_a_no_op() {
        let groups = json!([]);
        let rules = json!([]);
        let switches = json!({});
        let (out_groups, out_rules) = apply_group_switches(&groups, &rules, &switches, false);
        assert_eq!(out_groups, groups);
        assert_eq!(out_rules, rules);
    }
}
