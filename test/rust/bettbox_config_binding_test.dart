import 'package:bett_box/models/models.dart';
import 'package:bett_box/rust/bettbox_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// 覆盖 `ParsedRule.parseString` 各分支的规则集合。
const _rules = <String>[
  'DOMAIN,ads.example.com,REJECT',
  'DOMAIN-SUFFIX,google.com,PROXY',
  'DOMAIN-KEYWORD,tracker,REJECT',
  'GEOSITE,cn,DIRECT',
  'GEOIP,CN,DIRECT,no-resolve',
  'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve',
  'IP-CIDR6,::1/128,DIRECT',
  'IP-ASN,13335,DIRECT',
  'SRC-IP-CIDR,192.168.1.0/24,DIRECT',
  'DST-PORT,443,DIRECT',
  'SRC-PORT,443,DIRECT,src',
  'NETWORK,udp,DIRECT',
  'PROCESS-NAME,chrome.exe,PROXY',
  'RULE-SET,reject,REJECT',
  'RULE-SET,reject,REJECT,no-resolve',
  'SUB-RULE,(DOMAIN,example.com),PROXY',
  'AND,((NETWORK,UDP),(DST-PORT,443)),REJECT',
  'MATCH,DIRECT',
  'MATCH',
  'FOO,bar,DIRECT',
  'FOO',
  '  DOMAIN , example.com , DIRECT  ',
];

void main() {
  final available = BettboxConfig.isAvailable;
  final skipReason = available
      ? null
      : '未找到 bettbox_config 动态库，先构建：cd rust && cargo build';

  group('Rust 绑定 vs Dart 实现的规则解析差分', () {
    test('解析结果逐字段一致', () {
      for (final raw in _rules) {
        final dart = ParsedRule.parseString(raw);
        final rust = BettboxConfig.parseRule(raw);
        expect(rust, isNotNull, reason: raw);
        expect(rust!.action, dart.ruleAction.value, reason: raw);
        expect(rust.content, dart.content, reason: raw);
        expect(rust.target, dart.ruleTarget, reason: raw);
        expect(rust.ruleProvider, dart.ruleProvider, reason: raw);
        expect(rust.subRule, dart.subRule, reason: raw);
        expect(rust.noResolve, dart.noResolve, reason: raw);
        expect(rust.src, dart.src, reason: raw);
      }
    });

    test('往返序列化与 Dart 的 value 一致', () {
      for (final raw in _rules) {
        final dart = ParsedRule.parseString(raw);
        expect(BettboxConfig.roundTripRule(raw), dart.value, reason: raw);
      }
    });
  }, skip: skipReason);
}
