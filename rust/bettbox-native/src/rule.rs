//! Clash 规则字符串的解析与序列化。
//!
//! 与 Dart 侧 `lib/models/clash_config.dart` 的 `ParsedRule.parseString` 和
//! `ParsedRuleExt.value` 语义对齐；任何偏差都应被 `tests/rule.rs` 捕获。

/// 规则动作。`as_str` 的返回值即配置里的关键字。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuleAction {
    Domain,
    DomainSuffix,
    DomainKeyword,
    DomainRegex,
    GeoSite,
    IpCidr,
    IpCidr6,
    IpSuffix,
    IpAsn,
    GeoIp,
    SrcGeoIp,
    SrcIpAsn,
    SrcIpCidr,
    SrcIpSuffix,
    DstPort,
    SrcPort,
    InPort,
    InType,
    InUser,
    InName,
    ProcessPath,
    ProcessPathRegex,
    ProcessName,
    ProcessNameRegex,
    Uid,
    Network,
    Dscp,
    RuleSet,
    And,
    Or,
    Not,
    SubRule,
    Match,
}

impl RuleAction {
    /// 全部动作，顺序与 Dart 侧 `RuleAction` 枚举一致。
    pub const ALL: [RuleAction; 33] = [
        RuleAction::Domain,
        RuleAction::DomainSuffix,
        RuleAction::DomainKeyword,
        RuleAction::DomainRegex,
        RuleAction::GeoSite,
        RuleAction::IpCidr,
        RuleAction::IpCidr6,
        RuleAction::IpSuffix,
        RuleAction::IpAsn,
        RuleAction::GeoIp,
        RuleAction::SrcGeoIp,
        RuleAction::SrcIpAsn,
        RuleAction::SrcIpCidr,
        RuleAction::SrcIpSuffix,
        RuleAction::DstPort,
        RuleAction::SrcPort,
        RuleAction::InPort,
        RuleAction::InType,
        RuleAction::InUser,
        RuleAction::InName,
        RuleAction::ProcessPath,
        RuleAction::ProcessPathRegex,
        RuleAction::ProcessName,
        RuleAction::ProcessNameRegex,
        RuleAction::Uid,
        RuleAction::Network,
        RuleAction::Dscp,
        RuleAction::RuleSet,
        RuleAction::And,
        RuleAction::Or,
        RuleAction::Not,
        RuleAction::SubRule,
        RuleAction::Match,
    ];

    /// 配置里的关键字。
    pub fn as_str(self) -> &'static str {
        match self {
            RuleAction::Domain => "DOMAIN",
            RuleAction::DomainSuffix => "DOMAIN-SUFFIX",
            RuleAction::DomainKeyword => "DOMAIN-KEYWORD",
            RuleAction::DomainRegex => "DOMAIN-REGEX",
            RuleAction::GeoSite => "GEOSITE",
            RuleAction::IpCidr => "IP-CIDR",
            RuleAction::IpCidr6 => "IP-CIDR6",
            RuleAction::IpSuffix => "IP-SUFFIX",
            RuleAction::IpAsn => "IP-ASN",
            RuleAction::GeoIp => "GEOIP",
            RuleAction::SrcGeoIp => "SRC-GEOIP",
            RuleAction::SrcIpAsn => "SRC-IP-ASN",
            RuleAction::SrcIpCidr => "SRC-IP-CIDR",
            RuleAction::SrcIpSuffix => "SRC-IP-SUFFIX",
            RuleAction::DstPort => "DST-PORT",
            RuleAction::SrcPort => "SRC-PORT",
            RuleAction::InPort => "IN-PORT",
            RuleAction::InType => "IN-TYPE",
            RuleAction::InUser => "IN-USER",
            RuleAction::InName => "IN-NAME",
            RuleAction::ProcessPath => "PROCESS-PATH",
            RuleAction::ProcessPathRegex => "PROCESS-PATH-REGEX",
            RuleAction::ProcessName => "PROCESS-NAME",
            RuleAction::ProcessNameRegex => "PROCESS-NAME-REGEX",
            RuleAction::Uid => "UID",
            RuleAction::Network => "NETWORK",
            RuleAction::Dscp => "DSCP",
            RuleAction::RuleSet => "RULE-SET",
            RuleAction::And => "AND",
            RuleAction::Or => "OR",
            RuleAction::Not => "NOT",
            RuleAction::SubRule => "SUB-RULE",
            RuleAction::Match => "MATCH",
        }
    }

    /// 按关键字解析；未知关键字返回 `None`，由调用方决定兜底动作。
    pub fn from_keyword(keyword: &str) -> Option<RuleAction> {
        Self::ALL.iter().copied().find(|a| a.as_str() == keyword)
    }

    /// 是否带参数：`src` / `no-resolve` 只对这部分动作生效。
    pub fn has_params(self) -> bool {
        matches!(
            self,
            RuleAction::GeoIp
                | RuleAction::IpAsn
                | RuleAction::SrcIpAsn
                | RuleAction::IpCidr
                | RuleAction::IpCidr6
                | RuleAction::IpSuffix
                | RuleAction::RuleSet
        )
    }
}

/// 一条解析后的规则。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedRule {
    pub action: RuleAction,
    pub content: Option<String>,
    pub target: Option<String>,
    pub rule_provider: Option<String>,
    pub sub_rule: Option<String>,
    pub no_resolve: bool,
    pub src: bool,
}

impl ParsedRule {
    /// 解析一条规则字符串。与 Dart `ParsedRule.parseString` 同语义：
    /// 未知关键字在有逗号时兜底为 `DOMAIN`、无逗号时兜底为 `MATCH`。
    pub fn parse(input: &str) -> ParsedRule {
        let mut raw = input.trim();
        let mut no_resolve = false;
        let mut src = false;

        loop {
            if let Some(stripped) = raw.strip_suffix(",no-resolve") {
                no_resolve = true;
                raw = stripped.trim();
            } else if let Some(stripped) = raw.strip_suffix(",src") {
                src = true;
                raw = stripped.trim();
            } else {
                break;
            }
        }

        let Some(first_comma) = raw.find(',') else {
            let action = RuleAction::from_keyword(raw).unwrap_or(RuleAction::Match);
            return ParsedRule {
                action,
                content: None,
                target: None,
                rule_provider: None,
                sub_rule: None,
                no_resolve,
                src,
            };
        };

        let action_str = raw[..first_comma].trim();
        let action = RuleAction::from_keyword(action_str).unwrap_or(RuleAction::Domain);
        let rest = raw[first_comma + 1..].trim();

        if action == RuleAction::Match {
            return ParsedRule {
                action,
                content: None,
                target: Some(rest.to_string()),
                rule_provider: None,
                sub_rule: None,
                no_resolve,
                src,
            };
        }

        let Some(last_comma) = rest.rfind(',') else {
            return ParsedRule {
                action,
                content: (action != RuleAction::RuleSet).then(|| rest.to_string()),
                target: None,
                rule_provider: (action == RuleAction::RuleSet).then(|| rest.to_string()),
                sub_rule: None,
                no_resolve,
                src,
            };
        };

        let main_content = rest[..last_comma].trim();
        let target_str = rest[last_comma + 1..].trim();

        let (sub_rule, target) = if action == RuleAction::SubRule {
            (Some(target_str.to_string()), None)
        } else {
            (None, Some(target_str.to_string()))
        };

        let (content, rule_provider) = if action == RuleAction::RuleSet {
            (None, Some(main_content.to_string()))
        } else {
            (Some(main_content.to_string()), None)
        };

        ParsedRule {
            action,
            content,
            target,
            rule_provider,
            sub_rule,
            no_resolve,
            src,
        }
    }

    /// 序列化回配置里的规则字符串。与 Dart `ParsedRuleExt.value` 同语义：
    /// `src` / `no-resolve` 只对 [`RuleAction::has_params`] 的动作输出。
    pub fn to_config_string(&self) -> String {
        if self.action == RuleAction::Match {
            return [Some(self.action.as_str()), self.target.as_deref()]
                .into_iter()
                .flatten()
                .filter(|part| !part.is_empty())
                .collect::<Vec<_>>()
                .join(",");
        }

        let target = if self.action == RuleAction::SubRule {
            self.sub_rule.as_deref()
        } else {
            self.target.as_deref()
        };
        let main = if self.action == RuleAction::RuleSet {
            self.rule_provider.as_deref()
        } else {
            self.content.as_deref()
        };

        let mut parts = vec![self.action.as_str()];
        if let Some(main) = main.filter(|value| !value.is_empty()) {
            parts.push(main);
        }
        if let Some(target) = target.filter(|value| !value.is_empty()) {
            parts.push(target);
        }
        if self.action.has_params() {
            if self.src {
                parts.push("src");
            }
            if self.no_resolve {
                parts.push("no-resolve");
            }
        }
        parts.join(",")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn action(keyword: &str) -> RuleAction {
        RuleAction::from_keyword(keyword).expect("keyword should map to an action")
    }

    #[test]
    fn every_action_round_trips_through_its_keyword() {
        for action in RuleAction::ALL {
            assert_eq!(RuleAction::from_keyword(action.as_str()), Some(action));
        }
    }

    #[test]
    fn unknown_keyword_falls_back_by_comma_presence() {
        assert_eq!(ParsedRule::parse("FOO").action, RuleAction::Match);
        assert_eq!(
            ParsedRule::parse("FOO,bar,DIRECT").action,
            RuleAction::Domain
        );
    }

    #[test]
    fn domain_rule_splits_content_and_target() {
        let parsed = ParsedRule::parse("DOMAIN,example.com,DIRECT");
        assert_eq!(parsed.action, action("DOMAIN"));
        assert_eq!(parsed.content.as_deref(), Some("example.com"));
        assert_eq!(parsed.target.as_deref(), Some("DIRECT"));
        assert!(parsed.rule_provider.is_none());
    }

    #[test]
    fn match_rule_has_no_content() {
        let parsed = ParsedRule::parse("MATCH,DIRECT");
        assert_eq!(parsed.action, RuleAction::Match);
        assert_eq!(parsed.content, None);
        assert_eq!(parsed.target.as_deref(), Some("DIRECT"));
        assert_eq!(parsed.to_config_string(), "MATCH,DIRECT");
    }

    #[test]
    fn rule_set_uses_rule_provider_field() {
        let parsed = ParsedRule::parse("RULE-SET,myrules,DIRECT");
        assert_eq!(parsed.rule_provider.as_deref(), Some("myrules"));
        assert_eq!(parsed.content, None);
        assert_eq!(parsed.target.as_deref(), Some("DIRECT"));
        assert_eq!(parsed.to_config_string(), "RULE-SET,myrules,DIRECT");
    }

    #[test]
    fn trailing_params_are_stripped_and_re_emitted() {
        let parsed = ParsedRule::parse("GEOIP,CN,DIRECT,no-resolve");
        assert!(parsed.no_resolve);
        assert!(!parsed.src);
        assert_eq!(parsed.content.as_deref(), Some("CN"));
        assert_eq!(parsed.target.as_deref(), Some("DIRECT"));
        assert_eq!(parsed.to_config_string(), "GEOIP,CN,DIRECT,no-resolve");
    }

    #[test]
    fn params_are_dropped_for_actions_without_params() {
        let parsed = ParsedRule::parse("DST-PORT,443,DIRECT,src");
        assert!(parsed.src);
        assert!(!parsed.action.has_params());
        assert_eq!(parsed.to_config_string(), "DST-PORT,443,DIRECT");
    }

    #[test]
    fn single_field_rule_without_target() {
        let parsed = ParsedRule::parse("DOMAIN-SUFFIX,example.com");
        assert_eq!(parsed.content.as_deref(), Some("example.com"));
        assert_eq!(parsed.target, None);
        assert_eq!(parsed.to_config_string(), "DOMAIN-SUFFIX,example.com");
    }

    #[test]
    fn match_without_comma_keeps_only_the_keyword() {
        let parsed = ParsedRule::parse("MATCH");
        assert_eq!(parsed.action, RuleAction::Match);
        assert_eq!(parsed.target, None);
        assert_eq!(parsed.to_config_string(), "MATCH");
    }

    #[test]
    fn sub_rule_stores_its_target_in_sub_rule() {
        let parsed = ParsedRule::parse("SUB-RULE,(DOMAIN,example.com),DIRECT");
        assert_eq!(parsed.action, RuleAction::SubRule);
        assert_eq!(parsed.content.as_deref(), Some("(DOMAIN,example.com)"));
        assert_eq!(parsed.sub_rule.as_deref(), Some("DIRECT"));
        assert_eq!(parsed.target, None);
        assert_eq!(
            parsed.to_config_string(),
            "SUB-RULE,(DOMAIN,example.com),DIRECT"
        );
    }

    #[test]
    fn leading_and_trailing_whitespace_is_ignored() {
        let parsed = ParsedRule::parse("  DOMAIN , example.com , DIRECT  ");
        assert_eq!(parsed.content.as_deref(), Some("example.com"));
        assert_eq!(parsed.target.as_deref(), Some("DIRECT"));
        assert_eq!(parsed.to_config_string(), "DOMAIN,example.com,DIRECT");
    }

    #[test]
    fn retargeting_preserves_everything_else() {
        let mut parsed = ParsedRule::parse("GEOIP,CN,OldGroup,no-resolve");
        parsed.target = Some("PASS".to_string());
        assert_eq!(parsed.to_config_string(), "GEOIP,CN,PASS,no-resolve");
    }
}
