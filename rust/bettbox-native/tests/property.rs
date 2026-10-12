//! 属性测试（proptest）：随机生成规则与配置输入，钉住纯函数的不变量。
//!
//! 路线稿 §4.2 的另一半。golden 用例覆盖「已知输入 → 已知输出」，这里覆盖
//! 「任意输入不炸、序列化可稳定、管道输出结构不变量」。与 `tests/golden.rs`
//! 的固定快照互补；`cargo test` 一并跑，无需单独开关。

use proptest::prelude::*;
use serde_json::{json, Map, Value};

use bettbox_native::group_switch::apply_group_switches;
use bettbox_native::patch_config::patch_config;
use bettbox_native::regex_matcher::RegexMatcher;
use bettbox_native::rule::{ParsedRule, RuleAction};

/// 有界深度的任意 JSON 值。
fn arb_json() -> impl Strategy<Value = Value> {
    let leaf = prop_oneof![
        Just(Value::Null),
        any::<bool>().prop_map(Value::Bool),
        any::<i8>().prop_map(|n| json!(n)),
        any::<u16>().prop_map(|n| json!(n)),
        "-?[0-9]{1,6}\\.[0-9]{1,3}"
            .prop_map(|s: String| { serde_json::from_str::<Value>(&s).unwrap_or(Value::Null) }),
        "[\\x20-\\x7e]{0,48}".prop_map(Value::String),
    ];
    leaf.prop_recursive(3, 20, 5, |inner| {
        prop_oneof![
            proptest::collection::vec(inner.clone(), 0..6).prop_map(Value::Array),
            proptest::collection::btree_map("[A-Za-z0-9_-]{0,12}", inner, 0..6)
                .prop_map(|map| Value::Object(Map::from_iter(map))),
        ]
    })
}

/// 任意 JSON 对象（`patch_config` 四个顶层字段都要求对象）。
fn arb_json_object() -> impl Strategy<Value = Value> {
    proptest::collection::btree_map("[A-Za-z0-9_-]{0,12}", arb_json(), 0..6)
        .prop_map(|map| Value::Object(Map::from_iter(map)))
}

/// 信封完整的 `patch_config` 输入：四个顶层键均为对象。
fn arb_patch_input() -> impl Strategy<Value = Value> {
    (
        arb_json_object(),
        arb_json_object(),
        arb_json_object(),
        arb_json_object(),
    )
        .prop_map(|(raw_config, patch, profile, env)| {
            json!({
                "rawConfig": raw_config,
                "patch": patch,
                "profile": profile,
                "env": env,
            })
        })
}

/// 受限规则字符串：关键字 + 常见内容/目标，提高有效解析比例。
fn arb_rule_string() -> impl Strategy<Value = String> {
    let keyword = prop_oneof![
        Just("DOMAIN".to_string()),
        Just("DOMAIN-SUFFIX".to_string()),
        Just("DOMAIN-KEYWORD".to_string()),
        Just("GEOIP".to_string()),
        Just("IP-CIDR".to_string()),
        Just("DST-PORT".to_string()),
        Just("RULE-SET".to_string()),
        Just("SUB-RULE".to_string()),
        Just("MATCH".to_string()),
        Just("FOO".to_string()),
        "[A-Z][A-Z0-9-]{0,16}",
    ];
    prop_oneof![
        keyword.clone(),
        keyword.clone().prop_map(|k| format!("{k},example.com")),
        keyword
            .clone()
            .prop_map(|k| format!("{k},example.com,DIRECT")),
        keyword.prop_map(|k| format!("{k},example.com,DIRECT,no-resolve")),
    ]
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    /// 任意字符串上解析不 panic，且第二次序列化稳定（round-trip 不再漂移）。
    #[test]
    fn rule_parse_never_panics_and_round_trip_stabilizes(input in "\\PC{0,200}") {
        let first = ParsedRule::parse(&input);
        let serialized = first.to_config_string();
        let second = ParsedRule::parse(&serialized);
        prop_assert_eq!(second.to_config_string(), serialized);
    }

    /// 常见规则写法：序列化一次后，再 parse→serialize 字节级不变。
    ///
    /// 注意不是「struct 相等」：`src`/`no-resolve` 对 `has_params()==false` 的动作
    /// 会在解析时记下标志、序列化时按约定丢掉，字符串层面稳定即可。
    #[test]
    fn well_formed_rules_string_round_trip_stabilizes(raw in arb_rule_string()) {
        let out = ParsedRule::parse(&raw).to_config_string();
        let again = ParsedRule::parse(&out).to_config_string();
        prop_assert_eq!(again, out);
    }

    /// 解析结果的 action 必须是表内枚举（from_keyword / 兜底都只返回 ALL 之一）。
    #[test]
    fn parsed_action_is_always_from_the_table(input in "\\PC{0,80}") {
        let parsed = ParsedRule::parse(&input);
        prop_assert!(RuleAction::ALL.contains(&parsed.action));
    }

    /// `src` / `no-resolve` 只对 `has_params` 动作出现在序列化输出里。
    #[test]
    fn params_flags_only_emitted_for_actions_that_have_them(
        content in "[\\x20-\\x7e]{0,24}",
        target in "[\\x20-\\x7e]{0,24}",
        src: bool,
        no_resolve: bool,
    ) {
        for action in RuleAction::ALL {
            let mut parsed = ParsedRule {
                action,
                content: Some(content.clone()),
                target: Some(target.clone()),
                rule_provider: None,
                sub_rule: None,
                no_resolve,
                src,
            };
            if action == RuleAction::RuleSet {
                parsed.content = None;
                parsed.rule_provider = Some(content.clone());
            }
            if action == RuleAction::SubRule {
                parsed.sub_rule = Some(target.clone());
                parsed.target = None;
            }
            if action == RuleAction::Match {
                parsed.content = None;
            }
            let text = parsed.to_config_string();
            let has_src = text.split(',').any(|part| part == "src");
            let has_no_resolve = text.split(',').any(|part| part == "no-resolve");
            prop_assert_eq!(
                has_src,
                action.has_params() && src,
                "action={:?} text={}",
                action,
                text
            );
            prop_assert_eq!(
                has_no_resolve,
                action.has_params() && no_resolve,
                "action={:?} text={}",
                action,
                text
            );
        }
    }

    /// 正则：编译要么 Err 要么可安全 is_match；非法模式绝不 panic。
    #[test]
    fn regex_compile_and_match_never_panics(
        pattern in "\\PC{0,64}",
        text in "\\PC{0,64}",
    ) {
        if let Ok(matcher) = RegexMatcher::compile(&pattern) {
            let _ = matcher.is_match(&text);
        }
    }

    /// 字面量模式与含自身的文本恒匹配（libregexp 搜索语义）。
    #[test]
    fn literal_regex_matches_itself(text in "[a-z]{1,24}") {
        let matcher = RegexMatcher::compile(&text)
            .unwrap_or_else(|error| panic!("字面量 `{text}` 应可编译：{error}"));
        prop_assert!(matcher.is_match(&text));
        let wrapped = format!("x{text}x");
        prop_assert!(matcher.is_match(&wrapped));
    }

    /// `patch_config`：合法信封绝不 panic；成功时输出是对象且带结构不变量。
    #[test]
    fn patch_config_never_panics_and_preserves_structure(input in arb_patch_input()) {
        match patch_config(&input) {
            Ok(output) => {
                prop_assert!(output.is_object(), "成功输出必须是对象：{}", output);
                let object = output.as_object().expect("已断言对象");
                prop_assert!(
                    object.get("rules").is_some_and(Value::is_array),
                    "输出缺 rules 数组"
                );
                prop_assert!(
                    object.get("external-ui-url").is_some_and(Value::is_string),
                    "输出缺 external-ui-url"
                );
                prop_assert!(object.get("port").is_some(), "输出缺 port");
                prop_assert!(object.get("socks-port").is_some(), "输出缺 socks-port");
                prop_assert!(
                    object.get("tun").is_some_and(Value::is_object),
                    "输出缺 tun 对象"
                );
            }
            Err(_) => {
                // 契约失败路径：四个顶层对象已保证，剩余错误来自
                // tun / proxy-groups 等「类型不对」的中间结构——允许 Err，不允许 panic。
            }
        }
    }

    /// 最小合法信封：四个顶层对象 + 管道硬性要求的嵌套对象
    /// （`patch.tun`、`patch.dns`〔未启用 DNS 时走 override 分支〕、`profile.overrideData`）。
    /// `port`/`socks-port` 在 patch 缺席时被 `take` 覆盖成 Null（键仍在），只断言键存在。
    #[test]
    fn minimal_envelope_always_succeeds(extra in arb_json()) {
        let mut raw = Map::new();
        if let Some(text) = extra.as_str() {
            raw.insert("mixed-port".to_string(), Value::String(text.to_string()));
        }
        let input = json!({
            "rawConfig": Value::Object(raw),
            "patch": {"tun": {}, "dns": {}},
            "profile": {"overrideData": {}},
            "env": {},
        });
        let output = patch_config(&input)
            .unwrap_or_else(|error| panic!("最小合法信封应成功：{error}"));
        prop_assert!(output["rules"].is_array());
        prop_assert!(output.get("port").is_some(), "输出缺 port 键");
        prop_assert!(output.get("socks-port").is_some(), "输出缺 socks-port 键");
        prop_assert!(output["tun"].is_object());
    }

    /// 分组开关：script_active 或空开关是 no-op；禁用组从列表消失。
    #[test]
    fn group_switch_invariants(
        names in proptest::collection::vec("[\\x20-\\x7e]{0,16}", 0..8),
        script_active: bool,
    ) {
        let mut unique: Vec<String> = Vec::new();
        for name in names {
            if !unique.contains(&name) {
                unique.push(name);
            }
        }
        let groups: Vec<Value> = unique
            .iter()
            .map(|name| json!({"name": name, "type": "select"}))
            .collect();
        let rules = json!([]);
        let groups_value = Value::Array(groups);

        if unique.is_empty() || script_active {
            let switches = if unique.is_empty() {
                json!({})
            } else {
                let mut map = Map::new();
                for name in &unique {
                    map.insert(name.clone(), json!(false));
                }
                Value::Object(map)
            };
            let (out_groups, out_rules) =
                apply_group_switches(&groups_value, &rules, &switches, script_active);
            prop_assert_eq!(out_groups, groups_value);
            prop_assert_eq!(out_rules, rules);
        } else {
            let mut map = Map::new();
            for name in &unique {
                map.insert(name.clone(), json!(false));
            }
            let switches = Value::Object(map);
            let (out_groups, _) = apply_group_switches(&groups_value, &rules, &switches, false);
            prop_assert_eq!(
                out_groups.as_array().map(Vec::len).unwrap_or(0),
                0,
                "全部禁用后应无剩余分组"
            );
        }
    }
}
