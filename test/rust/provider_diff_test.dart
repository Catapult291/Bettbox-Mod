import 'dart:convert';
import 'dart:io';

import 'package:bett_box/clash/core.dart';
import 'package:bett_box/rust/bettbox_config.dart';
import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('fixtures/$name').readAsStringSync()) as Map<String, dynamic>;

/// 内核 `/proxies` 返回的形状（现有测试同款）。
Map<String, dynamic> _kernelProxies() => {
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

String _providers() => jsonEncode([
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

/// 把 profile 里的分组类型换成内核返回的写法。
String _kernelGroupType(String type) => switch (type) {
  'select' => 'Selector',
  'url-test' => 'URLTest',
  'fallback' => 'Fallback',
  'load-balance' => 'LoadBalance',
  _ => type,
};

void main() {
  final available = BettboxConfig.isAvailable;
  final skipReason = available
      ? null
      : '未找到 bettbox_config 动态库，先构建：cd rust && cargo build';

  group('Rust vs Dart 的 provider 差分', () {
    test('元数据解析逐字段一致', () {
      final cases = <String, String>{
        '完整字段': _providers(),
        '缺 subscription-info': jsonEncode([
          {'name': '空机场', 'type': 'Rule', 'vehicle-type': 'File', 'count': 0, 'update-at': '2026-09-20T04:00:00Z'},
        ]),
        '空数组': '[]',
      };

      for (final entry in cases.entries) {
        final dartProviders = ClashCore.parseExternalProvidersMetaSync(entry.value);
        final rustJson = BettboxConfig.parseProviderMeta(entry.value);
        expect(rustJson, isNotNull, reason: entry.key);
        final rustMetas = jsonDecode(rustJson!) as List<dynamic>;

        expect(rustMetas.length, dartProviders.length, reason: entry.key);
        for (var i = 0; i < dartProviders.length; i++) {
          final dart = dartProviders[i];
          final rust = rustMetas[i] as Map<String, dynamic>;
          final where = '${entry.key}[$i]';
          expect(rust['name'], dart.name, reason: where);
          expect(rust['type'], dart.type, reason: where);
          expect(rust['path'], dart.path, reason: where);
          expect(rust['count'], dart.count, reason: where);
          expect(rust['vehicleType'], dart.vehicleType, reason: where);
          expect(rust['isUpdating'], dart.isUpdating, reason: where);
          expect(
            DateTime.parse(rust['updateAt'] as String).toUtc(),
            dart.updateAt.toUtc(),
            reason: where,
          );
          final info = dart.subscriptionInfo;
          if (info == null) {
            expect(rust['subscriptionInfo'], isNull, reason: where);
          } else {
            expect(rust['subscriptionInfo']['upload'], info.upload, reason: where);
            expect(rust['subscriptionInfo']['download'], info.download, reason: where);
            expect(rust['subscriptionInfo']['total'], info.total, reason: where);
            expect(rust['subscriptionInfo']['expire'], info.expire, reason: where);
          }
        }
      }
    });

    test('构组逐字段一致（内核形状 + provider 合并）', () {
      final cases = <String, (Map<String, dynamic>, String)>{
        '带 provider': (_kernelProxies(), _providers()),
        '无 provider 原文': (_kernelProxies(), ''),
        '没有 GLOBAL': ({
          'DIRECT': {'name': 'DIRECT', 'type': 'Direct'},
        }, _providers()),
        'GLOBAL 没有 all': ({
          'GLOBAL': {'name': 'GLOBAL', 'type': 'Selector'},
        }, _providers()),
      };

      for (final entry in cases.entries) {
        final (proxies, providers) = entry.value;
        final dartGroups = ClashCore.buildProxiesGroupsRaw(proxies, providers);

        final rustJson = BettboxConfig.buildProxiesGroups(
          jsonEncode(proxies),
          rawProviders: providers,
        );
        expect(rustJson, isNotNull, reason: entry.key);
        final rustGroups = jsonDecode(rustJson!) as List<dynamic>;

        expect(
          DeepCollectionEquality().equals(rustGroups, jsonDecode(jsonEncode(dartGroups))),
          isTrue,
          reason: '${entry.key}\nRust: $rustJson\nDart: ${jsonEncode(dartGroups)}',
        );
      }
    });

    test('真实 profile-b 规模样本逐字段一致', () {
      final profileB = _fixture('config/profile-b.json');
      final proxies = <String, dynamic>{};
      for (final proxy in profileB['proxies'] as List) {
        proxies[(proxy as Map)['name']] = proxy;
      }
      for (final group in profileB['proxy-groups'] as List) {
        final map = Map<String, dynamic>.from(group as Map);
        map['type'] = _kernelGroupType(map['type'] as String);
        proxies[map['name']] = map;
      }
      proxies['GLOBAL'] = {
        'name': 'GLOBAL',
        'type': 'Selector',
        'all': proxies.keys.toList(),
      };

      final providers = jsonEncode([
        {
          'name': '机场B',
          'type': 'Proxy',
          'vehicle-type': 'HTTP',
          'count': 2,
          'update-at': '2026-09-20T04:00:00Z',
          'proxies': [
            {'name': '额外节点1', 'type': 'ss'},
            {'name': (profileB['proxies'] as List).first['name'], 'type': 'ss'},
          ],
        },
      ]);

      final dartGroups = ClashCore.buildProxiesGroupsRaw(proxies, providers);
      final rustJson = BettboxConfig.buildProxiesGroups(
        jsonEncode(proxies),
        rawProviders: providers,
      );
      expect(rustJson, isNotNull);
      final rustGroups = jsonDecode(rustJson!) as List<dynamic>;

      expect(dartGroups.length, greaterThan(20), reason: '规模样本应识别出多个分组');
      expect(
        DeepCollectionEquality().equals(rustGroups, jsonDecode(jsonEncode(dartGroups))),
        isTrue,
        reason: '分组数 Rust=${rustGroups.length} Dart=${dartGroups.length}',
      );
    });
  }, skip: skipReason);
}
