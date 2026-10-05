import 'dart:io';

import 'package:bett_box/rust/bettbox_script.dart';
import 'package:flutter_test/flutter_test.dart';

/// 失败策略（路线稿 §1.5 第 4 步）：脚本引擎是唯一实现，动态库缺失或 ABI 失配时
/// 抛错，而不是静默回退到另一套引擎。
void main() {
  test('动态库不可用时脚本求值抛错，而不是回退', () async {
    final original = Directory.current;
    final empty = Directory.systemTemp.createTempSync('bettbox_no_script_dll');
    try {
      // 两个候选路径都落空：exe 同目录与 cwd 下的 cargo 产物。
      Directory.current = empty.path;
      expect(BettboxScript.isAvailable, isFalse);
      await expectLater(
        BettboxScript.evaluateScript('function main(c) { return c; }', {
          'a': 1,
        }),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        BettboxScript.extractScriptOptions('var ruleOptionsEnable = { a: true };'),
        throwsA(isA<StateError>()),
      );
    } finally {
      Directory.current = original;
      empty.deleteSync(recursive: true);
    }
  });
}
