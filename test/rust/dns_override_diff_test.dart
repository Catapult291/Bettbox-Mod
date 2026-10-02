import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/rust/bettbox_config.dart';
import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('fixtures/$name').readAsStringSync()) as Map<String, dynamic>;

/// 跑一遍 Dart 与 Rust 两边的覆写，比较完整结果。
void _expectSame(
  Map<String, dynamic> rawConfig, {
  Map<String, dynamic>? originalDns,
  Map<String, dynamic>? originalHosts,
  required String reason,
}) {
  final dartConfig = jsonDecode(jsonEncode(rawConfig)) as Map<String, dynamic>;
  applyDnsNodeOverride(
    dartConfig,
    originalDns: originalDns == null ? null : jsonDecode(jsonEncode(originalDns)) as Map<String, dynamic>,
    originalHosts: originalHosts == null ? null : jsonDecode(jsonEncode(originalHosts)) as Map<String, dynamic>,
  );

  final rustJson = BettboxConfig.applyDnsNodeOverride(
    jsonEncode(rawConfig),
    originalDnsJson: originalDns == null ? null : jsonEncode(originalDns),
    originalHostsJson: originalHosts == null ? null : jsonEncode(originalHosts),
  );
  expect(rustJson, isNotNull, reason: reason);
  final rustConfig = jsonDecode(rustJson!) as Map<String, dynamic>;
  expect(
    DeepCollectionEquality().equals(rustConfig, dartConfig),
    isTrue,
    reason: '$reason\nRust: $rustJson\nDart: ${jsonEncode(dartConfig)}',
  );
}

void main() {
  final available = BettboxConfig.isAvailable;
  final skipReason = available
      ? null
      : '未找到 bettbox_config 动态库，先构建：cd rust && cargo build';

  group('Rust vs Dart 的 DNS 节点覆写差分', () {
    test('真实 fixture（两份 profile 的 dns 与无 dns）', () {
      final running = _fixture('config/running-config.json');
      final hosts = running['hosts'] as Map<String, dynamic>?;
      final profileA = _fixture('config/profile-a.json');
      final profileB = _fixture('config/profile-b.json');

      final cases = <String, Map<String, dynamic>?>{
        'profile-a 的 dns': profileA['dns'] as Map<String, dynamic>?,
        'profile-b 的 dns': profileB['dns'] as Map<String, dynamic>?,
        '无 originalDns': null,
      };

      for (final entry in cases.entries) {
        _expectSame(running, originalDns: entry.value, originalHosts: hosts, reason: entry.key);
      }
    });

    test('shouldRewriteByHosts 分支：按 hosts 重写代理 server', () {
      final running = _fixture('config/running-config.json');
      final dns = <String, dynamic>{
        'listen': '127.0.0.1:1053',
        'proxy-server-nameserver': ['127.0.0.1:1053'],
        'nameserver': ['https://doh.pub/dns-query', 'tls://8.8.4.4:853', '1.1.1.1'],
        'fake-ip-filter': ['+.lan', 'node1.example.com'],
        'nameserver-policy': {
          'node1.example.com': ['https://doh.pub/dns-query'],
          'node2.example.com': ['https://dns.alidns.com/dns-query#direct'],
          'other.example.net': ['https://dns.google/dns-query'],
        },
      };
      final hosts = <String, dynamic>{
        'node1.example.com': 'real1.example.net',
        'real1.example.net': '203.0.113.7',
        '+.example.com': 'wild.example.net',
      };

      _expectSame(running, originalDns: dns, originalHosts: hosts, reason: 'hosts 重写');
    });

    test('rawConfig 没有 dns 时不改动', () {
      final rawConfig = <String, dynamic>{
        'proxies': [
          {'name': 'a', 'server': 'node1.example.com'},
        ],
      };
      _expectSame(rawConfig, originalDns: {'nameserver': ['8.8.8.8']}, reason: '无 dns');
    });
  }, skip: skipReason);
}
