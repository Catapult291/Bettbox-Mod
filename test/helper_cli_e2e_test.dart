import 'dart:io';

import 'package:bett_box/common/helper_cli.dart';
import 'package:bett_box/common/system.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// helper CLI 的端到端联调：Dart 侧 `windows.runas` 提权 → `helper.exe` 子命令 → 真实 SCM /
/// Task Scheduler → 结果文件 → Dart 侧解析。
///
/// 它需要管理员权限（建服务、注册计划任务）与一个已构建的 release helper，所以默认跳过：
/// `BETTBOX_E2E_HELPER` 指到 helper.exe 才会跑。`.github/workflows/helper-e2e.yaml` 就是
/// 这样调的（构建 release helper → 提权自检 → 跑本文件）。
///
/// 与 `test/common/helper_cli_test.dart` 的分工：那边用假 launcher 验协议本体（引号、结果
/// 文件轮询、清理），这边验协议接上真实提权与真实 helper 之后还能不能跑通。
const _helperEnv = 'BETTBOX_E2E_HELPER';

/// 探针名字统一带时间戳：本用例会在真实机器上建服务与计划任务，名字必须避开已有的。
final _stamp = DateTime.now().millisecondsSinceEpoch;

void main() {
  final helperPath = Platform.environment[_helperEnv];
  final String? skipReason;
  if (!Platform.isWindows) {
    skipReason = '本用例只在 Windows 上有意义';
  } else if (helperPath == null || helperPath.isEmpty) {
    skipReason =
        '未设置 $_helperEnv（需要提权与已构建的 release helper.exe，'
        '见 .github/workflows/helper-e2e.yaml）';
  } else {
    skipReason = null;
  }

  group('helper CLI 端到端联调', () {
    // 目录名故意带空格与非 ASCII：参数走文件就是为了绕开命令行引号与代码页，这里顺带把
    // 「请求/结果文件路径本身很刁钻」这一条也压进去。
    late Directory workspace;

    setUpAll(() async {
      workspace = await Directory(
        p.join(Directory.systemTemp.path, 'Bettbox E2E 探针 $_stamp'),
      ).create(recursive: true);
    });

    tearDownAll(() async {
      try {
        await workspace.delete(recursive: true);
      } catch (_) {}
    });

    /// 走生产路径调用 helper：真实 `windows.runas` 提权 + 真实结果文件轮询。
    Future<HelperCliResult> call(
      String group,
      String action,
      Map<String, Object?> request,
    ) {
      return runHelperCommand(
        helperPath: helperPath!,
        group: group,
        action: action,
        request: request,
        tempDirPath: workspace.path,
        launch: windows!.runas,
      );
    }

    /// 协议要求：用完的请求/结果文件不能留在临时目录里。
    void expectNoTempFilesLeft() {
      final leftovers = workspace
          .listSync()
          .map((entry) => p.basename(entry.path))
          .where((name) => name.startsWith('bettbox_helper_'))
          .toList();
      expect(leftovers, isEmpty, reason: 'helper 调用后临时文件未清理：$leftovers');
    }

    test('task register → schtasks 回读 → unregister（幂等）', () async {
      final taskName = 'BettboxE2ETask$_stamp';
      final executable = Platform.environment['COMSPEC'] ?? r'C:\Windows\System32\cmd.exe';
      // 兜底：断言中途失败时别把探针任务留在机器上（用例本身最后会正常注销）。
      addTearDown(
        () => Process.run('schtasks', ['/Delete', '/TN', taskName, '/F']),
      );

      final registered = await call('task', 'register', {
        'taskName': taskName,
        'executablePath': executable,
        'workingDirectory': r'C:\Windows\System32',
        'description': 'Bettbox E2E 探针（可删）',
      });
      expect(registered.ok, isTrue, reason: 'task register: ${registered.summary}');
      expect(registered.command, 'task register');
      expectNoTempFilesLeft();

      // 计划任务真的进了 Task Scheduler，而不是只回了个 ok。
      final xml = await Process.run('schtasks', [
        '/Query',
        '/TN',
        taskName,
        '/XML',
      ]);
      expect(xml.exitCode, 0, reason: 'schtasks 查不到刚注册的任务');
      final xmlText = xml.stdout.toString();
      expect(xmlText, contains('HighestAvailable'));
      expect(xmlText, contains('LogonTrigger'));
      expect(xmlText.toLowerCase(), contains(p.basename(executable).toLowerCase()));

      final unregistered = await call('task', 'unregister', {'taskName': taskName});
      expect(unregistered.ok, isTrue, reason: 'task unregister: ${unregistered.summary}');

      final gone = await Process.run('schtasks', ['/Query', '/TN', taskName]);
      expect(gone.exitCode, isNot(0), reason: '注销后任务仍在');

      // 注销是幂等的：任务不存在也算成功。
      final again = await call('task', 'unregister', {'taskName': taskName});
      expect(again.ok, isTrue, reason: '重复注销应幂等：${again.summary}');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('service install → RUNNING + 管道 → 重装 → uninstall（幂等）', () async {
      final serviceName = 'BettboxE2EService$_stamp';
      final pipeName = 'Bettbox.E2E.$_stamp';
      final pipePath = r'\\.\pipe\' + pipeName;
      // 兜底：断言中途失败时别把探针服务留在机器上（用例本身最后会正常卸载）。
      addTearDown(() => Process.run('sc', ['delete', serviceName]));

      final request = {
        'serviceName': serviceName,
        'startType': 'demand',
        'environment': [
          // 64 位 hex：helper 的 key 必须是合法 hex，否则它只记一条日志、鉴权不可用。
          'HELPER_AUTH_KEY=${'a1' * 32}',
          'HELPER_SERVICE_NAME=$serviceName',
          'HELPER_PIPE_NAME=$pipePath',
        ],
      };

      final installed = await call('service', 'install', request);
      expect(installed.ok, isTrue, reason: 'service install: ${installed.summary}');
      expect(installed.command, 'service install');
      expectNoTempFilesLeft();

      final query = await Process.run('sc', ['query', serviceName]);
      expect(query.exitCode, 0, reason: 'sc 查不到刚装的服务');
      expect(query.stdout.toString(), contains('RUNNING'));

      // `Environment` 真的进了服务进程才会绑定这个管道名——它同时证明 REG_MULTI_SZ 写对了。
      expect(
        await _waitForPipe(pipePath),
        isTrue,
        reason: '服务在跑但没绑定 $pipePath（Environment 没生效？）',
      );

      // 对正在运行的同一个服务再装一次：走的是「停 → 等停 → 删 → 等消失 → 建」的替换路径。
      final reinstalled = await call('service', 'install', request);
      expect(reinstalled.ok, isTrue, reason: 'service 重装: ${reinstalled.summary}');
      final requery = await Process.run('sc', ['query', serviceName]);
      expect(requery.stdout.toString(), contains('RUNNING'));

      final uninstalled = await call('service', 'uninstall', {'serviceName': serviceName});
      expect(uninstalled.ok, isTrue, reason: 'service uninstall: ${uninstalled.summary}');

      final gone = await Process.run('sc', ['query', serviceName]);
      expect(gone.exitCode, isNot(0), reason: '卸载后服务仍在');

      final again = await call('service', 'uninstall', {'serviceName': serviceName});
      expect(again.ok, isTrue, reason: '重复卸载应幂等：${again.summary}');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('请求文件缺失时仍写出结构化结果（退出码 3）', () async {
      // 这条不走提权：只验 helper 的兜底契约（结果文件总会被写出来），Dart 侧据此拿失败原因。
      final resultFile = File(p.join(workspace.path, 'missing-request.result.json'));
      final missingRequest = p.join(workspace.path, 'does-not-exist.request.json');

      final run = await Process.run(helperPath!, [
        'task',
        'unregister',
        missingRequest,
        resultFile.path,
      ]);

      expect(run.exitCode, 3);
      expect(resultFile.existsSync(), isTrue);
      final result = HelperCliResult.parse(resultFile.readAsStringSync());
      expect(result.ok, isFalse);
      expect(result.code, 'REQUEST_READ_FAILED');
    });
  }, skip: skipReason);
}

/// 服务报 RUNNING 之后才去绑管道，两者之间有个小窗口，所以这里等一下。
Future<bool> _waitForPipe(String pipePath) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "Test-Path '$pipePath'",
    ]);
    if (result.stdout.toString().trim().toLowerCase() == 'true') return true;
    await Future.delayed(const Duration(milliseconds: 500));
  }
  return false;
}
