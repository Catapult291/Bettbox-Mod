import 'dart:convert';

import 'package:bett_box/models/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ScriptProps addedRules (UI 添加规则)', () {
    test('added-rules JSON 往返保持规则行', () {
      const props = ScriptProps(addedRules: [
        'DOMAIN-SUFFIX,example.com,🚀 节点选择',
        'GEOIP,CN,DIRECT',
      ]);

      final restored = ScriptProps.fromJson(
        jsonDecode(jsonEncode(props.toJson())) as Map<String, dynamic>,
      );

      expect(restored.addedRules, props.addedRules);
      expect(props.toJson()['added-rules'], isA<List>());
    });

    test('空列表默认且 hasAddedRules 判定正确', () {
      expect(const ScriptProps().addedRules, isEmpty);
      expect(const ScriptProps().hasAddedRules, isFalse);
      expect(const ScriptProps(addedRules: ['MATCH,DIRECT']).hasAddedRules, isTrue);
    });

    test('copyWith 替换规则且不影响其他字段', () {
      const base = ScriptProps(
        currentId: 'a',
        scripts: [],
        addedRules: ['old'],
      );
      final updated = base.copyWith(addedRules: ['new']);
      expect(updated.addedRules, ['new']);
      expect(updated.currentId, 'a');
      expect(base.addedRules, ['old']);
    });
  });
}
