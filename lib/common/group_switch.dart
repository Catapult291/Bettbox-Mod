import 'package:bett_box/models/clash_config.dart';

/// 应用分组开关（`Profile.groupSwitches`）：把被禁用的分组从 `proxy-groups`
/// 里摘掉，并把目标指向这些分组的规则改判为 `PASS`。
///
/// 从 `state.dart` 的 `patchRawConfig` 里原样抽出，行为不变；抽出来是为了
/// 有一个可直接调用的纯函数参照，与 Rust 侧
/// `rust/bettbox-config/src/group_switch.rs` 做差分（见
/// `test/rust/group_switch_diff_test.dart`）。
///
/// 就地修改 [rawConfig] 的 `proxy-groups` 与 [rules]。
void applyGroupSwitches(
  Map<String, dynamic> rawConfig,
  List<dynamic> rules, {
  required Map<String, bool> groupSwitches,
  required bool scriptActive,
}) {
  if (groupSwitches.isEmpty || scriptActive) {
    return;
  }
  if (rawConfig['proxy-groups'] is! List) {
    return;
  }
  final disabledGroups = groupSwitches.entries
      .where((e) => !e.value)
      .map((e) => e.key)
      .toSet();
  if (disabledGroups.isEmpty) {
    return;
  }
  final proxyGroups = rawConfig['proxy-groups'] as List;
  proxyGroups.removeWhere((g) {
    if (g is Map && g['name'] is String) {
      return disabledGroups.contains(g['name']);
    }
    return false;
  });
  for (int i = 0; i < rules.length; i++) {
    if (rules[i] is String) {
      final parsed = ParsedRule.parseString(rules[i] as String);
      if (parsed.ruleTarget != null &&
          disabledGroups.contains(parsed.ruleTarget)) {
        rules[i] = parsed.copyWith(ruleTarget: 'PASS').value;
      }
    }
  }
}
