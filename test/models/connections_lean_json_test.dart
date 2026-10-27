import 'dart:convert';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IPC 连接快照瘦身形态', () {
    test('白名单字段可被 TrackerInfo 解析', () {
      final raw = jsonEncode({
        'connections': [
          {
            'id': 'u-1',
            'metadata': {
              'network': 'tcp',
              'sourceIP': '192.168.1.23',
              'sourcePort': '40000',
              'destinationIP': '142.250.72.14',
              'destinationPort': '443',
              'host': 'cdn.example.com',
              'dnsMode': 'fake-ip',
              'uid': 1000,
              'process': 'chrome.exe',
              'processPath': r'C:\Program Files\Google\Chrome\Application\chrome.exe',
              'remoteDestination': '142.250.72.14:443',
              'destinationGeoIP': ['US', 'US-CA'],
              'destinationIPASN': 'AS15169',
              'specialRules': 'SPECIAL',
              'specialProxy': 'PROXY',
            },
            'upload': 1024,
            'download': 4096,
            'start': '2026-10-26T10:00:00Z',
            'chains': ['AUTO', 'HK-01'],
            'rule': 'DomainSuffix',
            'rulePayload': 'example.com',
          },
        ],
      });

      final connections = (jsonDecode(raw)['connections'] as List)
          .map((e) => TrackerInfo.fromJson(e as Map<String, Object?>))
          .toList();

      expect(connections, hasLength(1));
      final conn = connections.single;
      expect(conn.id, 'u-1');
      expect(conn.upload, 1024);
      expect(conn.download, 4096);
      expect(conn.start, DateTime.parse('2026-10-26T10:00:00Z'));
      expect(conn.chains, ['AUTO', 'HK-01']);
      expect(conn.rule, 'DomainSuffix');
      expect(conn.rulePayload, 'example.com');
      expect(conn.metadata.network, 'tcp');
      expect(conn.metadata.sourceIP, '192.168.1.23');
      expect(conn.metadata.sourcePort, '40000');
      expect(conn.metadata.destinationIP, '142.250.72.14');
      expect(conn.metadata.destinationPort, '443');
      expect(conn.metadata.host, 'cdn.example.com');
      expect(conn.metadata.dnsMode, DnsMode.fakeIp);
      expect(conn.metadata.uid, 1000);
      expect(conn.metadata.process, 'chrome.exe');
      expect(conn.metadata.processPath, endsWith('chrome.exe'));
      expect(conn.metadata.remoteDestination, '142.250.72.14:443');
      expect(conn.metadata.destinationGeoIP, ['US', 'US-CA']);
      expect(conn.metadata.destinationIPASN, 'AS15169');
      expect(conn.metadata.specialRules, 'SPECIAL');
      expect(conn.metadata.specialProxy, 'PROXY');
      expect(conn.desc, 'tcp://cdn.example.com/142.250.72.14:443');
    });

    test('省略的空字段回落模型默认值', () {
      final raw = jsonEncode({
        'connections': [
          {
            'id': 'u-2',
            'metadata': {'network': 'udp'},
            'upload': 0,
            'download': 0,
            'start': '2026-10-26T10:00:00Z',
            'chains': <String>[],
            'rule': '',
            'rulePayload': '',
          },
        ],
      });

      final conn = TrackerInfo.fromJson(
        (jsonDecode(raw)['connections'] as List).single
            as Map<String, Object?>,
      );

      expect(conn.metadata.host, '');
      expect(conn.metadata.sourcePort, '');
      expect(conn.metadata.destinationPort, '');
      expect(conn.metadata.dnsMode, isNull);
      expect(conn.metadata.process, '');
      expect(conn.metadata.sourceGeoIP, isEmpty);
      expect(conn.metadata.destinationGeoIP, isEmpty);
      expect(conn.uploadSpeed, isNull);
      expect(conn.downloadSpeed, isNull);
    });
  });
}
