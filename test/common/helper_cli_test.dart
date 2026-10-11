import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/helper_cli.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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

  group('提权调用 helper', () {
    late Directory tempDir;

    setUp(() async {
      // 目录名带空格：请求/结果文件路径会被引号包住，顺带把「带空格的参数」压进这条协议。
      tempDir = await Directory.systemTemp.createTemp('bettbox helper cli ');
    });

    tearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    File fakeHelper() =>
        File(p.join(tempDir.path, 'helper.exe'))..writeAsStringSync('');

    /// 协议文件用完必须清掉；假 helper 本身留在目录里不算残留。
    void expectNoProtocolFilesLeft() {
      final leftovers = tempDir
          .listSync()
          .map((entry) => p.basename(entry.path))
          .where((name) => name.startsWith('bettbox_helper_'))
          .toList();
      expect(leftovers, isEmpty, reason: '临时文件未清理：$leftovers');
    }

    /// 假 helper 侧：从目录里找到刚写下的请求文件，据此推出结果文件路径。
    File requestFileInFlight() {
      final requests = tempDir
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.request.json'))
          .toList();
      expect(requests, hasLength(1), reason: '应当只有一个待处理的请求文件');
      return requests.single;
    }

    test('写请求文件、轮询结果文件、用完把两个临时文件都删掉', () async {
      final helper = fakeHelper();
      final request = {
        'taskName': 'Bettbox E2E',
        'executablePath': r'C:\Program Files\Bettbox\Bettbox.exe',
      };
      String? seenRequest;
      String? seenCommandLine;
      String? requestFilePath;

      final result = await runHelperCommand(
        helperPath: helper.path,
        group: 'task',
        action: 'register',
        request: request,
        tempDirPath: tempDir.path,
        launch: (command, arguments) async {
          seenCommandLine = arguments;
          final requestFile = requestFileInFlight();
          requestFilePath = requestFile.path;
          seenRequest = requestFile.readAsStringSync();
          File(requestFile.path.replaceAll('.request.json', '.result.json'))
              .writeAsStringSync('{"ok":true,"command":"task register"}');
          return true;
        },
      );

      expect(seenCommandLine, startsWith('task register '));
      // 带空格的路径要整段加引号，否则 helper 收到的 argv 会被拆开。
      expect(seenCommandLine, contains('"$requestFilePath"'));
      expect(jsonDecode(seenRequest!), request);
      expect(result.ok, isTrue);
      expect(result.command, 'task register');
      expectNoProtocolFilesLeft();
    });

    test('结果文件一直不出现时按超时失败，临时文件照样清掉', () async {
      final helper = fakeHelper();

      final result = await runHelperCommand(
        helperPath: helper.path,
        group: 'service',
        action: 'uninstall',
        request: {'serviceName': 'BettboxHelperService'},
        tempDirPath: tempDir.path,
        timeout: const Duration(milliseconds: 300),
        launch: (_, _) async => true,
      );

      expect(result.ok, isFalse);
      expect(result.code, 'HELPER_TIMEOUT');
      expectNoProtocolFilesLeft();
    });

    test('提权没起来时报 ELEVATION_DENIED，不写结果文件', () async {
      final helper = fakeHelper();

      final result = await runHelperCommand(
        helperPath: helper.path,
        group: 'task',
        action: 'unregister',
        request: {'taskName': 'Bettbox E2E'},
        tempDirPath: tempDir.path,
        launch: (_, _) async => false,
      );

      expect(result.ok, isFalse);
      expect(result.code, 'ELEVATION_DENIED');
      expectNoProtocolFilesLeft();
    });

    test('helper 不在时直接报 HELPER_MISSING，不调用 launcher', () async {
      final result = await runHelperCommand(
        helperPath: p.join(tempDir.path, 'missing.exe'),
        group: 'service',
        action: 'install',
        request: {'serviceName': 'BettboxHelperService'},
        tempDirPath: tempDir.path,
        launch: (_, _) async => fail('helper 不存在时不该尝试启动'),
      );

      expect(result.ok, isFalse);
      expect(result.code, 'HELPER_MISSING');
      expectNoProtocolFilesLeft();
    });
  });
}
