import 'package:bett_box/common/group_switch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<dynamic> groups() => [
    {'name': '自动选择', 'type': 'url-test', 'proxies': ['节点1']},
    {'name': '手动选择', 'type': 'select', 'proxies': ['节点1']},
    {'name': 'DIRECT', 'type': 'select', 'proxies': ['DIRECT']},
  ];

  test('禁用分组被移除，指向它的规则改判为 PASS 并保留参数', () {
    final rawConfig = <String, dynamic>{'proxy-groups': groups()};
    final rules = <dynamic>[
      'DOMAIN,example.com,自动选择',
      'GEOIP,CN,自动选择,no-resolve',
      'DOMAIN,other.com,手动选择',
      'MATCH,自动选择',
      'SUB-RULE,(DOMAIN,example.com),自动选择',
    ];

    applyGroupSwitches(
      rawConfig,
      rules,
      groupSwitches: {'自动选择': false, '手动选择': true},
      scriptActive: false,
    );

    final names = (rawConfig['proxy-groups'] as List)
        .map((g) => g['name'])
        .toList();
    expect(names, ['手动选择', 'DIRECT']);
    expect(rules, [
      'DOMAIN,example.com,PASS',
      'GEOIP,CN,PASS,no-resolve',
      'DOMAIN,other.com,手动选择',
      'MATCH,PASS',
      // SUB-RULE 的目标存在 subRule 而非 ruleTarget，与原实现一致地不改写。
      'SUB-RULE,(DOMAIN,example.com),自动选择',
    ]);
  });

  test('全部启用时不做任何改动', () {
    final rawConfig = <String, dynamic>{'proxy-groups': groups()};
    final rules = <dynamic>['DOMAIN,example.com,自动选择'];

    applyGroupSwitches(
      rawConfig,
      rules,
      groupSwitches: {'自动选择': true, '手动选择': true},
      scriptActive: false,
    );

    expect(rawConfig['proxy-groups'], groups());
    expect(rules, ['DOMAIN,example.com,自动选择']);
  });

  test('脚本覆写生效时整段跳过', () {
    final rawConfig = <String, dynamic>{'proxy-groups': groups()};
    final rules = <dynamic>['DOMAIN,example.com,自动选择'];

    applyGroupSwitches(
      rawConfig,
      rules,
      groupSwitches: {'自动选择': false},
      scriptActive: true,
    );

    expect(rawConfig['proxy-groups'], groups());
    expect(rules, ['DOMAIN,example.com,自动选择']);
  });

  test('proxy-groups 不是列表时连规则也不动', () {
    final rawConfig = <String, dynamic>{
      'proxy-groups': {'自动选择': {'type': 'select'}},
    };
    final rules = <dynamic>['DOMAIN,example.com,自动选择'];

    applyGroupSwitches(
      rawConfig,
      rules,
      groupSwitches: {'自动选择': false},
      scriptActive: false,
    );

    expect(rawConfig['proxy-groups'], {
      '自动选择': {'type': 'select'},
    });
    expect(rules, ['DOMAIN,example.com,自动选择']);
  });

  test('开关表为空时不做任何改动', () {
    final rawConfig = <String, dynamic>{'proxy-groups': groups()};
    final rules = <dynamic>['DOMAIN,example.com,自动选择'];

    applyGroupSwitches(
      rawConfig,
      rules,
      groupSwitches: const {},
      scriptActive: false,
    );

    expect(rawConfig['proxy-groups'], groups());
    expect(rules, ['DOMAIN,example.com,自动选择']);
  });
}
