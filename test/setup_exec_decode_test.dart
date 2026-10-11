// setup.dart 的 `Build.exec` 曾把子进程输出按严格 UTF-8 解码：Windows 子进程
// （flutter / MSBuild 的中文本地化消息）吐系统代码页字节时会抛 FormatException，
// 整个构建流程被打断。这里锁住修复后的两条性质：非法字节不再抛异常；逐块喂入时
// 被 chunk 边界拆开的多字节字符仍能正确还原。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../setup.dart';

void main() {
  group('Build.outputDecoder', () {
    test('非 UTF-8 字节降级为替换字符，不抛异常', () {
      // CP936 的「中文」= D6 D0 CE C4，不是合法 UTF-8 序列。
      const gbk = [0xD6, 0xD0, 0xCE, 0xC4];

      expect(() => Build.outputDecoder.convert(gbk), returnsNormally);
      expect(Build.outputDecoder.convert(gbk), contains('\uFFFD'));
    });

    test('逐字节喂入时跨块的多字节字符仍能正确还原', () async {
      const text = '中文测试';
      final chunks = utf8.encode(text).map((byte) => [byte]);

      final decoded = await Build.outputDecoder
          .bind(Stream.fromIterable(chunks))
          .join();

      expect(decoded, text);
    });
  });
}
