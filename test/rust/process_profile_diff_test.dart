import 'dart:convert';

import 'package:bett_box/rust/bettbox_config.dart';
import 'package:flutter_test/flutter_test.dart';

import '../common/json_diff.dart';
import 'pipeline_cases.dart';

void main() {
  final available = BettboxConfig.isAvailable;
  final skipReason = available
      ? null
      : '未找到 bettbox_native 动态库，先构建：cd rust && cargo build --release';

  group('bb_process_profile 合并入口', () {
    test('恒等脚本时与 patchConfig 结果一致', () {
      final input = minimalProcessInput();
      final referenceJson = BettboxConfig.patchConfig(jsonEncode(input));
      expect(referenceJson, isNotNull, reason: 'patchConfig 应接管');
      final reference = jsonDecode(referenceJson!);

      final processed = BettboxConfig.processProfile(
        jsonEncode(input),
        'function main(c){ return c; }',
      );
      expect(processed, isNotNull, reason: 'processProfile 应接管');
      expect(processed!.scriptError, isNull);

      // 防「两边一起空转」。
      expect(reference['external-ui'], input['env']['uiPath']);
      expect(processed.config['external-ui'], input['env']['uiPath']);

      final difference = firstJsonDifference(
        reference,
        processed.config,
        '',
      );
      expect(difference, isNull, reason: '$difference');
    });

    test('脚本真的跑过：脚本加的键出现在 patch 结果里', () {
      final processed = BettboxConfig.processProfile(
        jsonEncode(minimalProcessInput()),
        "function main(c){ c['scriptMarker'] = 'yes'; return c; }",
      );
      expect(processed, isNotNull);
      expect(processed!.config['scriptMarker'], 'yes');
      expect(processed.scriptError, isNull);
    });

    test('customOptions 合并进 ruleOptionsEnable', () {
      // 选项只合并进**已定义**的 `ruleOptionsEnable`（与 Dart 侧一致），
      // 所以脚本正文要先声明它。
      final processed = BettboxConfig.processProfile(
        jsonEncode(minimalProcessInput()),
        'var ruleOptionsEnable = {base: true};\n'
            "function main(c){ c['opt'] = ruleOptionsEnable; return c; }",
        customOptionsJson: jsonEncode({'add-quic': true}),
      );
      expect(processed, isNotNull);
      expect(processed!.config['opt'], {'base': true, 'add-quic': true});
    });

    test('脚本失败时回传 scriptError，且 patch 仍然产出', () {
      final processed = BettboxConfig.processProfile(
        jsonEncode(minimalProcessInput()),
        "function main(c){ throw new Error('boom'); }",
      );
      expect(processed, isNotNull);
      final error = processed!.scriptError;
      expect(error, isNotNull);
      expect(error, startsWith('JS Script Error: '));
      expect(error, contains('boom'));
      expect(processed.config['external-controller'], '127.0.0.1:9090');
    });

    test('rawConfig 不是对象时返回 null（ABI 级失败）', () {
      final input = copyJson(minimalProcessInput()) as Map<String, dynamic>;
      input['rawConfig'] = 'not an object';
      expect(
        BettboxConfig.processProfile(
          jsonEncode(input),
          'function main(c){ return c; }',
        ),
        isNull,
      );
    });

    test('入参非法 JSON 返回 null', () {
      expect(
        BettboxConfig.processProfile(
          '{not json',
          'function main(c){ return c; }',
        ),
        isNull,
      );
    });
  }, skip: skipReason);
}
