import 'dart:convert';

import 'package:bett_box/clash/core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildProxiesGroups：provider 节点必须并入代理表', () {
    // 内核 /proxies 返回的形状：GLOBAL 与各分组的 all 里可能出现只存在于
    // provider 里的节点名（含带 [provider] 后缀的引用）。
    final proxies = {
      'GLOBAL': {
        'name': 'GLOBAL',
        'type': 'Selector',
        'now': '节点1',
        'all': ['节点1', '节点2[机场A]', 'DIRECT', '自动选择'],
      },
      '自动选择': {
        'name': '自动选择',
        'type': 'URLTest',
        'now': '节点1',
        'all': ['节点1', '节点2[机场A]'],
      },
      'DIRECT': {'name': 'DIRECT', 'type': 'Direct'},
    };

    final rawProviders = jsonEncode([
      {
        'name': '机场A',
        'type': 'Proxy',
        'vehicle-type': 'HTTP',
        'count': 2,
        'update-at': '2026-09-20T04:00:00Z',
        'proxies': [
          {'name': '节点1', 'type': 'ss'},
          {'name': '节点2', 'type': 'vmess'},
        ],
      },
    ]);

    test('分组 all 里的 provider 节点被解析出来', () {
      final groups = ClashCore.buildProxiesGroups(proxies, rawProviders);
      final global = groups.firstWhere((group) => group.name == 'GLOBAL');

      expect(
        global.all.map((proxy) => proxy.name),
        containsAll(['节点1', 'DIRECT']),
      );
    });

    test('带 [provider] 后缀的引用解析到同一个节点', () {
      final groups = ClashCore.buildProxiesGroups(proxies, rawProviders);
      final global = groups.firstWhere((group) => group.name == 'GLOBAL');
      final names = global.all.map((proxy) => proxy.name).toList();

      expect(names, contains('节点2'));
      expect(names, isNot(contains('节点2[机场A]')));
      expect(names, isNot(contains('节点2[机场A][机场A]')));
    });

    test('不给 provider 原文时这些节点解析不到（证明合并确实在起作用）', () {
      final groups = ClashCore.buildProxiesGroups(proxies, '');
      final global = groups.firstWhere((group) => group.name == 'GLOBAL');
      final names = global.all.map((proxy) => proxy.name).toList();

      expect(names, isNot(contains('节点1')));
      expect(names, contains('DIRECT'));
    });

    test('GLOBAL 里引用的分组也出现在结果里', () {
      final groups = ClashCore.buildProxiesGroups(proxies, rawProviders);

      expect(
        groups.map((group) => group.name),
        containsAll(['GLOBAL', '自动选择']),
      );
    });

    test('没有 GLOBAL 时返回空', () {
      final groups = ClashCore.buildProxiesGroups({
        'DIRECT': {'name': 'DIRECT', 'type': 'Direct'},
      }, rawProviders);

      expect(groups, isEmpty);
    });
  });
}
