import 'package:bett_box/common/helper_cli.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('helper 结果文件', () {
    test('读得懂成功与失败两种结果', () {
      final ok = HelperCliResult.parse(
        '{"ok":true,"command":"task register","code":null,"message":null,'
        '"osError":null}',
      );
      expect(ok.ok, isTrue);
      expect(ok.summary, 'ok');

      final failed = HelperCliResult.parse(
        '{"ok":false,"command":"service install","code":"ACCESS_DENIED",'
        '"message":"拒绝访问。","osError":5}',
      );
      expect(failed.ok, isFalse);
      expect(failed.code, 'ACCESS_DENIED');
      expect(failed.osError, 5);
      expect(failed.summary, contains('拒绝访问。'));
    });

    test('内容不合法时按失败处理而不是抛异常', () {
      for (final raw in ['', 'not json', '[1,2,3]']) {
        final result = HelperCliResult.parse(raw);
        expect(result.ok, isFalse);
        expect(result.code, 'INVALID_RESULT');
      }
    });
  });

  group('Windows 命令行引号', () {
    test('不带空格与引号的参数原样输出', () {
      expect(quoteWindowsArgument('task'), 'task');
      expect(
        quoteWindowsArgument(r'C:\Users\bypassnro\AppData\Local\Temp\a.json'),
        r'C:\Users\bypassnro\AppData\Local\Temp\a.json',
      );
    });

    test('带空格的参数整段加引号', () {
      expect(
        quoteWindowsArgument(r'C:\Program Files\Bettbox\a.json'),
        r'"C:\Program Files\Bettbox\a.json"',
      );
      expect(quoteWindowsArgument(''), '""');
    });

    test('反斜杠只在引号前翻倍，引号本身要转义', () {
      // 参数以反斜杠结尾：不翻倍的话会转义掉结尾的引号。
      expect(quoteWindowsArgument(r'a b\'), r'"a b\\"');
      // 参数里有引号：前面的反斜杠翻倍，引号写成 \"。
      expect(quoteWindowsArgument('a b\\"c'), r'"a b\\\"c"');
    });

    test('整条命令行按参数逐个加引号', () {
      expect(
        quoteWindowsArguments([
          'service',
          'install',
          r'C:\Users\John Doe\a.json',
          r'C:\Users\John Doe\b.json',
        ]),
        r'service install "C:\Users\John Doe\a.json" "C:\Users\John Doe\b.json"',
      );
    });
  });
}
