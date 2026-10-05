//! 覆写脚本引擎的集成测试。
//!
//! 语料来自 `fixtures/`（脱敏后的真实脚本与真实配置），断言分两类：
//!   * 引擎契约（返回对象 / 非对象 / 抛错 / 超时 / 内存上限 / options 合并）；
//!   * 真实脚本在真实规模配置上的行为不变量（脚本头部自述的行为）。

use std::path::PathBuf;

use bettbox_native::eval::{self, EvalOutcome, ExtractOutcome, Limits};

fn fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures")
}

fn read_fixture(relative: &str) -> String {
    let path = fixtures_dir().join(relative);
    std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("读取 fixture {} 失败：{error}", path.display()))
}

fn config_value(outcome: &EvalOutcome) -> serde_json::Value {
    match outcome {
        EvalOutcome::Config(json) => serde_json::from_str(json).expect("结果不是合法 JSON"),
        other => panic!("期望脚本返回对象，实际：{other:?}"),
    }
}

#[test]
fn real_script_runs_on_real_configs() {
    let script = read_fixture("scripts/dns.js");
    for fixture in ["config/profile-a.json", "config/profile-b.json"] {
        let config = read_fixture(fixture);
        let outcome = eval::evaluate(&script, &config, None);
        let value = config_value(&outcome);

        // 脚本自述：DNS 监听收窄到 127.0.0.1:1053。
        assert_eq!(
            value["dns"]["listen"], "127.0.0.1:1053",
            "{fixture}: DNS listen 未被改写"
        );
        // 脚本自述：新增 final 兜底组，MATCH 指向 final。
        let groups = value["proxy-groups"]
            .as_array()
            .expect("proxy-groups 不是数组");
        assert!(
            groups.iter().any(|group| group["name"] == "final"),
            "{fixture}: 缺少 final 分组"
        );
        let rules = value["rules"].as_array().expect("rules 不是数组");
        assert_eq!(
            rules.last().and_then(|rule| rule.as_str()),
            Some("MATCH,final"),
            "{fixture}: 末条规则不是 MATCH,final"
        );
        // 脚本自述：保留所有原始节点。
        let input: serde_json::Value = serde_json::from_str(&config).unwrap();
        assert_eq!(
            value["proxies"].as_array().map(Vec::len),
            input["proxies"].as_array().map(Vec::len),
            "{fixture}: 节点数被改动"
        );
    }
}

#[test]
fn real_script_handles_scale_fixture() {
    let script = read_fixture("scripts/dns.js");
    let config = read_fixture("config/profile-b.json");
    let input: serde_json::Value = serde_json::from_str(&config).unwrap();
    assert_eq!(input["rules"].as_array().map(Vec::len), Some(3486));

    let outcome = eval::evaluate(&script, &config, None);
    let value = config_value(&outcome);
    // 脚本会合并/去重规则，产出远小于输入；这里只锁「确实处理了大规模输入」。
    let rules = value["rules"].as_array().unwrap();
    assert!(
        rules.len() > 100 && rules.len() < 3486,
        "规则数异常：{}",
        rules.len()
    );
    assert_eq!(value["proxies"].as_array().map(Vec::len), Some(172));
}

#[test]
fn evaluation_is_deterministic_across_runs() {
    let script = read_fixture("scripts/dns.js");
    let config = read_fixture("config/profile-b.json");
    let first = eval::evaluate(&script, &config, None);
    let second = eval::evaluate(&script, &config, None);
    match (first, second) {
        (EvalOutcome::Config(a), EvalOutcome::Config(b)) => assert_eq!(a, b),
        (a, b) => panic!("两次求值结果类型不一致：{a:?} / {b:?}"),
    }
}

#[test]
fn undefined_return_keeps_original_config() {
    let outcome = eval::evaluate("function main(c){ return undefined; }", "{\"a\":1}", None);
    assert!(matches!(outcome, EvalOutcome::NotAMap), "{outcome:?}");
}

#[test]
fn array_return_is_not_a_map() {
    let outcome = eval::evaluate("function main(c){ return [1, 2]; }", "{}", None);
    assert!(matches!(outcome, EvalOutcome::NotAMap), "{outcome:?}");
}

#[test]
fn missing_main_reports_dart_style_error() {
    let outcome = eval::evaluate("var x = 1;", "{}", None);
    match outcome {
        EvalOutcome::Error(message) => {
            assert!(message.starts_with("JS Script Error: "), "{message}");
            assert!(message.contains("main"), "{message}");
        }
        other => panic!("期望错误，实际：{other:?}"),
    }
}

#[test]
fn console_log_is_a_no_op_without_print() {
    let outcome = eval::evaluate(
        "function main(c){ console.log('hello', 1); return c; }",
        "{\"a\":1}",
        None,
    );
    assert_eq!(config_value(&outcome)["a"], 1);
}

#[test]
fn custom_options_merge_into_rule_options_enable() {
    let script = "\
var ruleOptionsEnable = { flag: false };
function main(c) { return { flag: ruleOptionsEnable.flag }; }
";
    let disabled = eval::evaluate(script, "{}", None);
    assert_eq!(config_value(&disabled)["flag"], false);
    let enabled = eval::evaluate(script, "{}", Some("{\"flag\":true}"));
    assert_eq!(config_value(&enabled)["flag"], true);
}

#[test]
fn options_are_ignored_when_rule_options_enable_is_absent() {
    let script = "function main(c){ return { ok: true }; }";
    let outcome = eval::evaluate(script, "{}", Some("{\"flag\":true}"));
    assert_eq!(config_value(&outcome)["ok"], true);
}

#[test]
fn runaway_script_is_interrupted_by_timeout() {
    let limits = Limits {
        timeout_ms: 300,
        ..Limits::default()
    };
    let outcome =
        eval::evaluate_with_limits("function main(c){ while (true) {} }", "{}", None, &limits);
    match outcome {
        EvalOutcome::Error(message) => {
            assert!(message.starts_with("JS Script Error: "), "{message}");
        }
        other => panic!("期望超时被中断，实际：{other:?}"),
    }
}

#[test]
fn runaway_script_is_stopped_by_memory_limit() {
    let limits = Limits {
        timeout_ms: 30_000,
        memory_limit_bytes: 16 * 1024 * 1024,
    };
    let outcome = eval::evaluate_with_limits(
        "function main(c){ var a = []; while (true) { a.push(new Array(100000).fill(0)); } }",
        "{}",
        None,
        &limits,
    );
    assert!(matches!(outcome, EvalOutcome::Error(_)), "{outcome:?}");
}

#[test]
fn utf8_survives_round_trip() {
    let outcome = eval::evaluate(
        "function main(c){ c.备注 = '中文节点'; return c; }",
        "{\"名称\":\"香港\"}",
        None,
    );
    let value = config_value(&outcome);
    assert_eq!(value["名称"], "香港");
    assert_eq!(value["备注"], "中文节点");
}

#[test]
fn config_is_not_mutated_when_script_returns_nothing() {
    let config = "{\"a\":{\"b\":[1,2,3]}}";
    let outcome = eval::evaluate("function main(c){ return null; }", config, None);
    assert!(matches!(outcome, EvalOutcome::NotAMap), "{outcome:?}");
}

fn extract_value(outcome: &ExtractOutcome) -> serde_json::Value {
    match outcome {
        ExtractOutcome::Options(json) => serde_json::from_str(json).expect("结果不是合法 JSON"),
        other => panic!("期望抽取成功，实际：{other:?}"),
    }
}

#[test]
fn extract_options_reads_options_and_icons() {
    let script = "\
var ruleOptionsEnable = { enableIPv6: false, fixBug: true };
var serviceConfigs = [
  { name: 'OpenAI', icon: 'https://example.com/openai.png' },
  { name: 'NoIcon' },
  { icon: 'https://example.com/orphan.png' },
  'not-an-object',
];
function main(c) { return c; }
";
    let value = extract_value(&eval::extract_options(script));
    assert_eq!(value["options"]["enableIPv6"], false);
    assert_eq!(value["options"]["fixBug"], true);
    let icons = value["icons"].as_object().expect("icons 不是对象");
    // 只收「有 name 且 icon 是字符串」的项。
    assert_eq!(icons.len(), 1);
    assert_eq!(icons["OpenAI"], "https://example.com/openai.png");
}

#[test]
fn extract_options_falls_back_to_empty_for_odd_declarations() {
    for script in [
        // 没声明任何东西。
        "function main(c) { return c; }",
        // ruleOptionsEnable 不是对象。
        "var ruleOptionsEnable = 'nope'; function main(c) { return c; }",
        // serviceConfigs 不是数组。
        "var serviceConfigs = { name: 'x', icon: 'y' }; function main(c) { return c; }",
    ] {
        let value = extract_value(&eval::extract_options(script));
        assert_eq!(
            value["options"].as_object().map(serde_json::Map::len),
            Some(0),
            "{script}"
        );
        assert_eq!(
            value["icons"].as_object().map(serde_json::Map::len),
            Some(0),
            "{script}"
        );
    }
}

#[test]
fn extract_options_error_has_no_dart_style_prefix() {
    // 注意必须是**顶层**抛错：这条路径不调用 `main`，只跑脚本正文。
    let outcome = eval::extract_options("var x = 1;\nthrow new Error('boom');");
    match outcome {
        ExtractOutcome::Error(message) => {
            assert!(!message.starts_with("JS Script Error: "), "{message}");
            assert!(message.starts_with("Error: boom"), "{message}");
        }
        other => panic!("期望错误，实际：{other:?}"),
    }
}

/// 回归闸门：排查阶段见过「同一份字节偶发解析失败」，失败率随 C 侧代码形态在
/// 0/2000 与 28/30 之间摆动。这个用例连续求值同一份输入，把那次现象钉住。
#[test]
fn many_evaluations_stay_stable() {
    let script = "function main(c){ c.备注 = '中文节点'; return c; }";
    let config = "{\"名称\":\"香港\"}";
    let mut failures = Vec::new();
    for index in 0..1000 {
        match eval::evaluate(script, config, None) {
            EvalOutcome::Config(json) if json.contains("中文节点") => {}
            other => failures.push((index, format!("{other:?}"))),
        }
    }
    assert!(failures.is_empty(), "偶发失败：{failures:?}");
}
