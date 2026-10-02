//! 从 crate 外部验证公开 API，并固定一批代表性规则的解析结果。
//!
//! 这批字符串取自真实配置里常见的写法；后续接入真实 profile 语料时，
//! 应在此基础上扩充为「Dart 输出 vs Rust 输出」的差分用例。

use bettbox_config::rule::{ParsedRule, RuleAction};

const SAMPLE_RULES: [&str; 10] = [
    "DOMAIN,ads.example.com,REJECT",
    "DOMAIN-SUFFIX,google.com,PROXY",
    "DOMAIN-KEYWORD,tracker,REJECT",
    "GEOIP,CN,DIRECT",
    "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
    "SRC-IP-CIDR,192.168.1.0/24,DIRECT",
    "PROCESS-NAME,chrome.exe,PROXY",
    "RULE-SET,reject,REJECT",
    "SUB-RULE,(DOMAIN,example.com),PROXY",
    "MATCH,PROXY",
];

#[test]
fn sample_rules_round_trip_through_parse_and_serialize() {
    for raw in SAMPLE_RULES {
        let parsed = ParsedRule::parse(raw);
        assert_eq!(
            parsed.to_config_string(),
            raw,
            "round trip failed for {raw}"
        );
    }
}

#[test]
fn ip_cidr_keeps_no_resolve_param() {
    let parsed = ParsedRule::parse("IP-CIDR,10.0.0.0/8,DIRECT,no-resolve");
    assert_eq!(parsed.action, RuleAction::IpCidr);
    assert_eq!(parsed.content.as_deref(), Some("10.0.0.0/8"));
    assert_eq!(parsed.target.as_deref(), Some("DIRECT"));
    assert!(parsed.no_resolve);
}
