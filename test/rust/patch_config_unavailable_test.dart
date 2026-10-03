import 'dart:io';

import 'package:bett_box/rust/bettbox_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rust 管道默认开启后，动态库缺失（Android、未打包的桌面构建）必须回退 Dart，
/// 而不是让异常从 `patchRawConfig` 里冒出去。
void main() {
  test('动态库不可用时 patchConfig 返回 null 而不抛错', () {
    final original = Directory.current;
    final empty = Directory.systemTemp.createTempSync('bettbox_no_dll');
    try {
      // 两个候选路径都落空：exe 同目录（flutter_tester 旁）与 cwd 下的 cargo 产物。
      Directory.current = empty.path;
      expect(BettboxConfig.isAvailable, isFalse);
      expect(BettboxConfig.patchConfig('{}'), isNull);
    } finally {
      Directory.current = original;
      empty.deleteSync(recursive: true);
    }
  });
}
