import 'dart:convert';

import 'package:bett_box/clash/core.dart';
import 'package:bett_box/models/core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('provider 元数据解析（全节点列表不进常驻状态）', () {
    final rawContent = jsonEncode([
      {
        'name': '机场A',
        'type': 'Proxy',
        'vehicle-type': 'HTTP',
        'path': 'providers/a.yaml',
        'count': 2,
        'update-at': '2026-09-20T04:00:00Z',
        'subscription-info': {
          'Upload': 1,
          'Download': 2,
          'Total': 3,
          'Expire': 4,
        },
        'proxies': [
          {'name': '节点1', 'type': 'ss', 'server': 'a.example.com', 'port': 443},
          {
            'name': '节点2',
            'type': 'vmess',
            'server': 'b.example.com',
            'port': 8443,
          },
        ],
      },
    ]);

    test('元数据字段全部保留', () {
      final providers = ClashCore.parseExternalProvidersMetaSync(rawContent);

      expect(providers, hasLength(1));
      final provider = providers.first;
      expect(provider.name, '机场A');
      expect(provider.type, 'Proxy');
      expect(provider.vehicleType, 'HTTP');
      expect(provider.path, 'providers/a.yaml');
      expect(provider.count, 2);
      expect(provider.subscriptionInfo?.total, 3);
      expect(provider.updateAt.toUtc(), DateTime.utc(2026, 9, 20, 4));
    });

    test('全节点列表被剥掉', () {
      final providers = ClashCore.parseExternalProvidersMetaSync(rawContent);

      expect(providers.first.proxies, isNull);
    });

    test('withoutProxies 只清 proxies，其余字段原样', () {
      final full = ExternalProvider.fromJson(
        (jsonDecode(rawContent) as List).first as Map<String, Object?>,
      );

      expect(full.proxies, hasLength(2));

      final meta = full.withoutProxies;
      expect(meta.proxies, isNull);
      expect(meta.name, full.name);
      expect(meta.type, full.type);
      expect(meta.vehicleType, full.vehicleType);
      expect(meta.count, full.count);
      expect(meta.updateAt, full.updateAt);
      expect(meta.subscriptionInfo?.total, full.subscriptionInfo?.total);
    });

    test('没有 proxies 字段时不会被改成 null 以外的值', () {
      final provider = ExternalProvider.fromJson({
        'name': '空机场',
        'type': 'Rule',
        'vehicle-type': 'File',
        'count': 0,
        'update-at': '2026-09-20T04:00:00Z',
      });

      expect(provider.withoutProxies.proxies, isNull);
      expect(provider.withoutProxies.name, '空机场');
    });

    test('空数组原文返回空列表', () {
      expect(ClashCore.parseExternalProvidersMetaSync('[]'), isEmpty);
    });
  });
}
