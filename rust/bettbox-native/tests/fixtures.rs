//! 校验仓库内脱敏 fixture 可读、结构完整。
//!
//! fixture 在仓库根的 `fixtures/`（跨语言共享，Dart 侧差分测试也用同一份），
//! 脱敏方式见 `fixtures/README.txt` 与 `fixtures/sanitize_fixtures.py`。

use std::path::PathBuf;

use serde_json::Value;

fn fixture(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures")
        .join(name);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("读取 fixture {} 失败: {error}", path.display()));
    serde_json::from_str(&text)
        .unwrap_or_else(|error| panic!("解析 fixture {} 失败: {error}", path.display()))
}

#[test]
fn profiles_have_proxies_groups_and_rules() {
    for name in ["config/profile-a.json", "config/profile-b.json"] {
        let profile = fixture(name);
        assert!(profile.is_object(), "{name} 顶层应为对象");
        for key in ["proxies", "proxy-groups", "rules"] {
            let list = profile[key]
                .as_array()
                .unwrap_or_else(|| panic!("{name} 缺少数组字段 {key}"));
            assert!(!list.is_empty(), "{name} 的 {key} 不应为空");
        }
    }
}

#[test]
fn running_config_and_app_config_are_objects() {
    assert!(fixture("config/running-config.json").is_object());
    let app_config = fixture("config/app-config.json");
    assert!(app_config.is_object());
    assert!(app_config["profiles"].is_array());
}

#[test]
fn fixtures_contain_no_placeholder_leaks() {
    // 脱敏后所有主机名都应落在 example.com 下；出现其它域名说明脱敏漏了。
    let text = std::fs::read_to_string(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/config/profile-a.json"),
    )
    .unwrap();
    let profile: Value = serde_json::from_str(&text).unwrap();
    for proxy in profile["proxies"].as_array().unwrap() {
        let server = proxy["server"].as_str().unwrap_or_default();
        assert!(
            server.is_empty() || server.ends_with(".example.com"),
            "未脱敏的 server: {server}"
        );
    }
}
