import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/group_switch.dart';
import 'package:bett_box/rust/bettbox_config.dart';
import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('fixtures/$name').readAsStringSync()) as Map<String, dynamic>;

dynamic _copy(Object? value) => jsonDecode(jsonEncode(value));

/// Dart 参照实现的结果，返回 `(proxy-groups, rules)`。
///
/// [proxyGroups] 可以是任意 JSON 值（含非列表），与 `rawConfig['proxy-groups']`
/// 的取值方式一致。
(dynamic, List<dynamic>) _dartApply(
  Object? proxyGroups,
  List<dynamic> rules,
  Map<String, bool> groupSwitches, {
  required bool scriptActive,
}) {
  final rawConfig = <String, dynamic>{'proxy-groups': _copy(proxyGroups)};
  final copiedRules = _copy(rules) as List<dynamic>;
  applyGroupSwitches(
    rawConfig,
    copiedRules,
    groupSwitches: groupSwitches,
    scriptActive: scriptActive,
  );
  return (rawConfig['proxy-groups'], copiedRules);
}

/// 调用 Rust 侧，返回解码后的 `{"proxy-groups":..., "rules":...}`。
Map<String, dynamic> _rustApply(
  Object? proxyGroups,
  List<dynamic> rules,
  Map<String, bool> groupSwitches, {
  required bool scriptActive,
}) {
  final rustJson = BettboxConfig.applyGroupSwitches(
    jsonEncode(proxyGroups),
    jsonEncode(rules),
    jsonEncode(groupSwitches),
    scriptActive: scriptActive,
  );
  expect(rustJson, isNotNull);
  return jsonDecode(rustJson!) as Map<String, dynamic>;
}

void _expectSameAsDart(
  Object? proxyGroups,
  List<dynamic> rules,
  Map<String, bool> groupSwitches, {
  required bool scriptActive,
  required String where,
}) {
  final (dartGroups, dartRules) = _dartApply(
    proxyGroups,
    rules,
    groupSwitches,
    scriptActive: scriptActive,
  );
  final rust = _rustApply(
    proxyGroups,
    rules,
    groupSwitches,
    scriptActive: scriptActive,
  );

  expect(
    DeepCollectionEquality().equals(rust['proxy-groups'], _copy(dartGroups)),
    isTrue,
    reason: '$where（proxy-groups）\nRust: ${jsonEncode(rust['proxy-groups'])}\nDart: ${jsonEncode(dartGroups)}',
  );
  expect(
    DeepCollectionEquality().equals(rust['rules'], _copy(dartRules)),
    isTrue,
    reason: '$where（rules）\nRust: ${jsonEncode(rust['rules'])}\nDart: ${jsonEncode(dartRules)}',
  );
}

void main() {
  final available = BettboxConfig.isAvailable;
  final skipReason = available
      ? null
      : '未找到 bettbox_config 动态库，先构建：cd rust && cargo build';

  group('Rust vs Dart 的分组开关差分', () {
    test('构造用例逐字段一致', () {
      final groups = [
        {'name': '自动选择', 'type': 'url-test', 'proxies': ['节点1']},
        {'name': '手动选择', 'type': 'select', 'proxies': ['节点1']},
        {'name': 'DIRECT', 'type': 'select', 'proxies': ['DIRECT']},
        {'type': 'select'},
        'not-a-group',
      ];
      final rules = [
        'DOMAIN,example.com,自动选择',
        'GEOIP,CN,自动选择,no-resolve',
        'DOMAIN,other.com,手动选择',
        'MATCH,自动选择',
        'SUB-RULE,(DOMAIN,example.com),自动选择',
        42,
        null,
      ];

      final cases = <String, (Map<String, bool>, bool)>{
        '禁用部分分组': ({
          '自动选择': false,
          '手动选择': true,
        }, false),
        '全部启用': ({
          '自动选择': true,
          '手动选择': true,
        }, false),
        '空开关表': (<String, bool>{}, false),
        '脚本覆写生效': ({
          '自动选择': false,
        }, true),
        '禁用的分组不在列表里': ({
          '不存在的分组': false,
        }, false),
      };

      for (final entry in cases.entries) {
        final (switches, scriptActive) = entry.value;
        _expectSameAsDart(
          groups,
          rules,
          switches,
          scriptActive: scriptActive,
          where: entry.key,
        );
      }

      // 非列表输入单独跑一遍：两边都必须原样返回，规则也不改写。
      _expectSameAsDart(
        {'自动选择': {'type': 'select'}},
        rules,
        {'自动选择': false},
        scriptActive: false,
        where: 'proxy-groups 为 map',
      );
    });

    test('真实 profile-b 规模样本逐字段一致', () {
      final profileB = _fixture('config/profile-b.json');
      final groups = profileB['proxy-groups'] as List<dynamic>;
      final rules = profileB['rules'] as List<dynamic>;

      final switches = <String, bool>{
        for (final (index, group) in groups.indexed)
          if (group is Map && group['name'] is String)
            group['name'] as String: index.isEven,
      };
      expect(
        switches.values.where((enabled) => !enabled).length,
        greaterThan(10),
        reason: '样本应禁用足够多的分组',
      );

      final (dartGroups, dartRules) = _dartApply(
        groups,
        rules,
        switches,
        scriptActive: false,
      );
      expect(dartGroups.length, lessThan(groups.length), reason: '应有分组被禁用');
      expect(dartRules, isNot(equals(rules)), reason: '应有规则被改判为 PASS');

      _expectSameAsDart(
        groups,
        rules,
        switches,
        scriptActive: false,
        where: 'profile-b',
      );
    });
  }, skip: skipReason);
}
