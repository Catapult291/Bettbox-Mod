import 'dart:io';

import 'package:bett_box/rust/bettbox_script.dart';
import 'package:flutter_test/flutter_test.dart';

/// 动态库缺失（Android、未打包的桌面构建）时必须回退 qjs：`evaluateScript`
/// 返回 null 而不是抛错，也不去 spawn 后台 isolate。
void main() {
  test('动态库不可用时 evaluateScript 返回 null 而不抛错', () async {
    final original = Directory.current;
    final empty = Directory.systemTemp.createTempSync('bettbox_no_script_dll');
    try {
      // 两个候选路径都落空：exe 同目录与 cwd 下的 cargo 产物。
      Directory.current = empty.path;
      expect(BettboxScript.isAvailable, isFalse);
      final result = await BettboxScript.evaluateScript(
        'function main(c) { return c; }',
        <String, dynamic>{'a': 1},
      );
      expect(result, isNull);
      final options = await BettboxScript.extractScriptOptions(
        'var ruleOptionsEnable = { a: true };',
      );
      expect(options, isNull);
    } finally {
      Directory.current = original;
      empty.deleteSync(recursive: true);
    }
  });
}
