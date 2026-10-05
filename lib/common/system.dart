import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:ffi/ffi.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/common/helper_auth.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/helper/helper.dart';
import 'package:bett_box/plugins/app.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/input.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:synchronized/synchronized.dart';

class System {
  static System? _instance;

  System._internal();

  factory System() {
    _instance ??= System._internal();
    return _instance!;
  }

  bool get isDesktop => isWindows || isMacOS || isLinux;

  bool get isWindows => Platform.isWindows;

  bool get isMacOS => Platform.isMacOS;

  bool get isAndroid => Platform.isAndroid;

  bool get isLinux => Platform.isLinux;

  Future<int> get version async {
    final deviceInfo = await DeviceInfoPlugin().deviceInfo;
    return switch (Platform.operatingSystem) {
      'macos' => (deviceInfo as MacOsDeviceInfo).majorVersion,
      'android' => (deviceInfo as AndroidDeviceInfo).version.sdkInt,
      'windows' => (deviceInfo as WindowsDeviceInfo).majorVersion,
      String() => 0,
    };
  }

  static String _shellEscape(String value) {
    return "'${value.replaceAll("'", "'\\''")}'";
  }

  Future<bool> checkIsAdmin() async {
    final corePath = appPath.corePath;
    if (system.isWindows) {
      final result = await windows?.checkService();
      return result == WindowsHelperServiceStatus.running;
    }

    if (system.isMacOS) {
      final result = await Process.run('stat', ['-f', '%Su:%Sg %Sp', corePath]);
      final output = result.stdout.trim();
      final parts = output.split(' ');
      if (parts.length < 2) return false;
      return parts.first.startsWith('root:admin') && parts.last.contains('s');
    }

    if (Platform.isLinux) {
      final result = await Process.run('stat', ['-c', '%U:%G %A', corePath]);
      final output = result.stdout.trim();
      final parts = output.split(' ');
      if (parts.length < 2) return false;
      return parts.first.startsWith('root:') && parts.last.contains('s');
    }

    return true;
  }

  Future<AuthorizeCode> authorizeCore() async {
    if (system.isAndroid) return AuthorizeCode.none;

    if (await checkIsAdmin()) return AuthorizeCode.none;

    if (system.isWindows) {
      if (await windows?._isHelperHealthy() ?? false) return AuthorizeCode.none;
      final result = await windows?.registerService();
      return result == true ? AuthorizeCode.success : AuthorizeCode.error;
    }

    if (system.isMacOS) {
      final corePath = appPath.corePath;
      var quarantineCleared = true;

      final xattrCheck = await Process.run('/usr/bin/xattr', [
        '-p',
        'com.apple.quarantine',
        corePath,
      ]);
      if (xattrCheck.exitCode == 0) {
        final removeResult = await Process.run('/usr/bin/xattr', [
          '-d',
          'com.apple.quarantine',
          corePath,
        ]);
        if (removeResult.exitCode == 0) {
          commonPrint.log('Cleared quarantine attribute from BettboxCore');
        } else {
          quarantineCleared = false;
          commonPrint.log(
            'Failed to clear quarantine attribute: ${removeResult.stderr}',
          );
        }
      }

      final escapedPath = _shellEscape(corePath);
      final shell = 'chown root:admin $escapedPath && chmod u+s $escapedPath';
      final result = await Process.run('osascript', [
        '-e',
        'do shell script "$shell" with administrator privileges',
      ]);

      if (result.exitCode != 0) {
        if (!quarantineCleared) {
          globalState.showNotifier(
            'Failed to authorize BettboxCore. Try: xattr -dr com.apple.quarantine /Applications/Bettbox.app',
          );
        } else {
          globalState.showNotifier(appLocalizations.tunEnableRequireAdmin);
        }
        return AuthorizeCode.error;
      }
      return AuthorizeCode.success;
    }

    if (Platform.isLinux) {
      final escapedCorePath = _shellEscape(appPath.corePath);

      try {
        final pkexecResult = await Process.run('pkexec', [
          'sh',
          '-c',
          'chown root:root $escapedCorePath && chmod u+s $escapedCorePath && sync',
        ]);
        if (pkexecResult.exitCode == 0) {
          return AuthorizeCode.success;
        }
        if (pkexecResult.exitCode != 127) {
          globalState.showNotifier(appLocalizations.tunEnableRequireAdmin);
          return AuthorizeCode.error;
        }
      } catch (e) {
        commonPrint.log('pkexec failed: $e');
      }

      window?.show();
      final shell = Platform.environment['SHELL'] ?? 'bash';
      final password = await globalState.showCommonDialog<String>(
        child: InputDialog(
          obscureText: true,
          title: appLocalizations.pleaseInputAdminPassword,
          value: '',
        ),
      );
      if (password == null || password.isEmpty) {
        globalState.showNotifier(appLocalizations.tunEnableRequireAdmin);
        return AuthorizeCode.error;
      }
      final escapedPassword = _shellEscape(password);
      final result = await Process.run(shell, [
        '-c',
        'echo $escapedPassword | sudo -S chown root:root $escapedCorePath && echo $escapedPassword | sudo -S chmod u+s $escapedCorePath && sync',
      ]);
      if (result.exitCode != 0) {
        globalState.showNotifier(appLocalizations.tunEnableRequireAdmin);
      }
      return result.exitCode == 0 ? AuthorizeCode.success : AuthorizeCode.error;
    }

    return AuthorizeCode.error;
  }

  Future<void> back() async {
    if (system.isAndroid) await app.moveTaskToBack();
    await window?.hide();
  }

  Future<void> exit() async {
    if (system.isAndroid) await SystemNavigator.pop();
    await window?.close();
  }

  Future<void> setProcessPriority(String processName, bool enable) async {
    if (!isWindows) return;

    // 内核进程的优先级由 helper 的 `process.set_priority` 负责（见 `controller.dart`
    // 的 `setProcessPriority`）；这里只处理应用自身进程。
    // 旧实现对本进程还回退 `wmic ... call setpriority`，但新版 Win11 默认不带 wmic，
    // 那条分支只会失败，已移除。
    if (processName != '${AppIdentity.mainExecutableName}.exe') {
      commonPrint.log(
        'setProcessPriority ignored for $processName (handled by helper)',
      );
      return;
    }

    try {
      windows?.setCurrentProcessPriority(enable);
    } catch (e) {
      commonPrint.log('Failed to set current process priority: $e');
    }
  }
}

final system = System();

class Windows {
  static Windows? _instance;

  Windows._internal();

  factory Windows() {
    _instance ??= Windows._internal();
    return _instance!;
  }

  void setCurrentProcessPriority(bool enable) {
    final kernel32 = DynamicLibrary.open('kernel32.dll');

    final getCurrentProcess = kernel32
        .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');

    final setPriorityClass = kernel32
        .lookupFunction<
          Int32 Function(IntPtr hProcess, Int32 dwPriorityClass),
          int Function(int hProcess, int dwPriorityClass)
        >('SetPriorityClass');

    final setProcessInformation = kernel32
        .lookupFunction<
          Int32 Function(
            IntPtr hProcess,
            Int32 processInformationClass,
            Pointer<Void> processInformation,
            Uint32 processInformationSize,
          ),
          int Function(
            int hProcess,
            int processInformationClass,
            Pointer<Void> processInformation,
            int processInformationSize,
          )
        >('SetProcessInformation');

    final priorityClass = enable ? 0x00008000 : 0x00000020;

    final hProcess = getCurrentProcess();
    final result = setPriorityClass(hProcess, priorityClass);

    if (result == 0) {
      throw Exception('SetPriorityClass failed');
    }

    commonPrint.log(
      'Set current process priority to ${enable ? "above normal" : "normal"}',
    );

    if (enable) {
      final memoryPriorityInfo = calloc<Uint32>();
      try {
        memoryPriorityInfo.value = 5;
        final memoryResult = setProcessInformation(
          hProcess,
          0,
          memoryPriorityInfo.cast<Void>(),
          sizeOf<Uint32>(),
        );
        if (memoryResult == 0) {
          commonPrint.log('Set current process memory priority failed');
        } else {
          commonPrint.log('Set current process memory priority to normal');
        }
      } finally {
        calloc.free(memoryPriorityInfo);
      }
    }
  }

  /// 以管理员身份执行命令（UAC 提权）。
  ///
  /// `ShellExecuteW(..., "runas", ...)` 会一直阻塞到用户在 UAC 对话框上做出选择，
  /// 而 Dart 侧的根 isolate 就是 Flutter Windows 的消息泵线程——就地调用会让整个
  /// 界面停止响应（Windows 事件日志记为 Application Hang，HangType = "Top level
  /// window is idle"）。内核启动链上的 `registerService()` 会走到这里，所以放到
  /// 独立 isolate 执行，等待提权期间界面照常刷新。
  Future<bool> runas(
    String command,
    String arguments, {
    bool showWindow = false,
  }) async {
    final result = await Isolate.run(
      () => _runasSync(command, arguments, showWindow),
    );
    commonPrint.log('windows runas: [command masked] resultCode:$result');
    return result > 32;
  }

  static int _runasSync(String command, String arguments, bool showWindow) {
    final shell32 = DynamicLibrary.open('shell32.dll');
    final commandPtr = command.toNativeUtf16();
    final argumentsPtr = arguments.toNativeUtf16();
    final operationPtr = 'runas'.toNativeUtf16();

    final shellExecute = shell32
        .lookupFunction<
          Int32 Function(
            Pointer<Utf16> hwnd,
            Pointer<Utf16> lpOperation,
            Pointer<Utf16> lpFile,
            Pointer<Utf16> lpParameters,
            Pointer<Utf16> lpDirectory,
            Int32 nShowCmd,
          ),
          int Function(
            Pointer<Utf16> hwnd,
            Pointer<Utf16> lpOperation,
            Pointer<Utf16> lpFile,
            Pointer<Utf16> lpParameters,
            Pointer<Utf16> lpDirectory,
            int nShowCmd,
          )
        >('ShellExecuteW');

    // 0 = hide, 1 = show
    final result = shellExecute(
      nullptr,
      operationPtr,
      commandPtr,
      argumentsPtr,
      nullptr,
      showWindow ? 1 : 0,
    );

    calloc.free(commandPtr);
    calloc.free(argumentsPtr);
    calloc.free(operationPtr);

    return result;
  }

  Future<WindowsHelperServiceStatus> checkService() async {
    await HelperAuthManager.ensureAuthKey();
    final result = await Process.run('sc', ['query', appHelperService]);
    if (result.exitCode != 0) return WindowsHelperServiceStatus.none;

    final output = result.stdout.toString();
    if (!output.contains('RUNNING')) return WindowsHelperServiceStatus.presence;

    return await _pingHelper()
        ? WindowsHelperServiceStatus.running
        : WindowsHelperServiceStatus.presence;
  }

  Future<bool>? _registerServiceInFlight;

  Future<bool> registerService() {
    return _registerServiceInFlight ??= _registerService().whenComplete(
      () => _registerServiceInFlight = null,
    );
  }

  Future<bool> _registerService() async {
    await HelperAuthManager.ensureAuthKey();
    final healthy = await _isHelperHealthy();
    if (healthy && !await _serviceEnvHasLegacyPlaintextKey()) return true;

    if (healthy) {
      commonPrint.log(
        '[Helper] migrating the plaintext auth key out of the service registry',
      );
    }

    if (await _configureHelperService()) {
      if (await _waitForHelperHealthy()) return true;

      // key 文件下发后 helper 仍不健康（例如 SYSTEM 读不到该文件）：退回旧的明文
      // 下发方式，宁可暂时保留旧行为也不要让内核起不来。
      commonPrint.log(
        '[Helper] key-file delivery is unhealthy, falling back to env delivery',
      );
      if (await _configureHelperService(keyFileDelivery: false)) {
        return _waitForHelperHealthy();
      }
    }

    // 提权被拒时保持现状：旧配置仍然可用，就不必把已运行的服务停掉。
    return healthy;
  }

  Future<bool> _isHelperHealthy() async {
    final result = await Process.run('sc', ['query', appHelperService]);
    if (result.exitCode != 0) return false;

    if (!result.stdout.toString().contains('RUNNING')) return false;

    return _pingHelper();
  }

  Future<bool> _pingHelper() async {
    final coreSHA256 = globalState.coreSHA256;
    if (coreSHA256 == null || coreSHA256.isEmpty) return false;
    return helperClient.ping(coreSHA256);
  }

  /// 服务注册表里是否还留着旧版的明文 `HELPER_AUTH_KEY`。
  ///
  /// `HKLM\SYSTEM\CurrentControlSet\Services\<name>` 对 `BUILTIN\Users` 是
  /// `ReadKey`，明文写在那里等于本机任何用户都能拿到 key，所以要迁到
  /// `HELPER_AUTH_KEY_FILE`。注意 `HELPER_AUTH_KEY_FILE=` 不含
  /// `HELPER_AUTH_KEY=`，不会误判。
  Future<bool> _serviceEnvHasLegacyPlaintextKey() async {
    // 值里含用户目录路径，可能有非 UTF-8 字符（用户名、安装路径），用 latin1 读，
    // 只做 ASCII 子串判断。
    final result = await Process.run('reg', [
      'query',
      'HKLM\\SYSTEM\\CurrentControlSet\\Services\\$appHelperService',
      '/v',
      'Environment',
    ], stdoutEncoding: latin1);
    if (result.exitCode != 0) return false;
    return result.stdout.toString().contains('HELPER_AUTH_KEY=');
  }

  /// 配置/重装 helper 服务。
  ///
  /// [keyFileDelivery] 为 true（默认）时，服务 Environment 里只写 key 文件路径，
  /// helper 启动时自己读文件；false 是旧行为（把 key 明文写进 Environment），仅在
  /// 文件下发导致 helper 起不来时作为兼容回退使用。两种方式都会写
  /// `HELPER_ALLOWED_SID` 以收紧管道 ACL（旧版 helper 不认这个变量，会退回旧 ACL）。
  Future<bool> _configureHelperService({bool keyFileDelivery = true}) async {
    final authKey = HelperAuthManager.getAuthKey();
    if (authKey == null) return false;

    // key 文件写不出来（磁盘或权限异常）时退回明文 env 下发，helper 不至于直接不可用。
    String? keyFilePath;
    if (keyFileDelivery) {
      keyFilePath = await HelperAuthManager.writeServiceKeyFile();
      if (keyFilePath == null) {
        commonPrint.log(
          '[Helper] failed to write the service key file, using env delivery',
        );
      }
    }
    final allowedSid = await HelperAuthManager.currentUserSid();

    final environmentValue = [
      if (keyFilePath != null)
        'HELPER_AUTH_KEY_FILE=$keyFilePath'
      else
        'HELPER_AUTH_KEY=$authKey',
      'HELPER_SERVICE_NAME=$appHelperService',
      'HELPER_PIPE_NAME=$helperPipeName',
      if (allowedSid != null) 'HELPER_ALLOWED_SID=$allowedSid',
    ].join('\\0');

    final serviceRegistryPath =
        'HKLM\\SYSTEM\\CurrentControlSet\\Services\\$appHelperService';

    final command = [
      '/c',
      'sc',
      'stop',
      appHelperService,
      '>nul',
      '2>&1',
      '&',
      'sc',
      'delete',
      appHelperService,
      '>nul',
      '2>&1',
      '&',
      'sc',
      'create',
      appHelperService,
      'binPath= "${appPath.helperPath}"',
      'start= ${AppIdentity.isDev ? 'demand' : 'auto'}',
      '&&',
      'reg',
      'add',
      '"$serviceRegistryPath"',
      '/v',
      'Environment',
      '/t',
      'REG_MULTI_SZ',
      '/d',
      '"$environmentValue"',
      '/f',
      '&&',
      'sc',
      'start',
      appHelperService,
    ].join(' ');

    return runas('cmd.exe', command);
  }

  Future<bool> _waitForHelperHealthy() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      await Future.delayed(const Duration(milliseconds: 250));
      if (await _isHelperHealthy()) return true;

      if (attempt > 0 && attempt % 4 == 0) {
        final check = await Process.run('sc', ['query', appHelperService]);
        final output = check.stdout.toString();
        if (output.contains('STOPPED')) {
          commonPrint.log('Helper service stopped/failed, skipping wait');
          break;
        }
      }
    }

    return false;
  }

  Future<void> stopHelperService() async {
    await helperClient.stopCore();
    if (!AppIdentity.isDev) return;

    if (await helperClient.stopHelperService()) {
      return;
    }

    await Process.run('sc', ['stop', appHelperService]);
  }

  Future<bool> registerTask(String appName) async {
    final executablePath = Platform.resolvedExecutable;
    final workingDirectory = dirname(executablePath);

    final taskXml =
        '''
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>开机自动启动代理服务</Description>
    <URI>\\$appName</URI>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
  </Triggers>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>6</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>"$executablePath"</Command>
      <WorkingDirectory>$workingDirectory</WorkingDirectory>
    </Exec>
  </Actions>
</Task>''';
    final taskPath = join(await appPath.tempPath, 'task.xml');
    await File(taskPath).create(recursive: true);
    await File(
      taskPath,
    ).writeAsBytes(taskXml.encodeUtf16LeWithBom, flush: true);
    final commandLine = [
      '/Create',
      '/TN',
      appName,
      '/XML',
      '%s',
      '/F',
    ].join(' ');
    return runas('schtasks', commandLine.replaceFirst('%s', taskPath));
  }

  Future<bool> unregisterTask(String appName) async {
    final commandLine = ['/Delete', '/TN', appName, '/F'].join(' ');
    return runas('schtasks', commandLine);
  }
}

final windows = system.isWindows ? Windows() : null;

class MacOS {
  static MacOS? _instance;
  static const _dnsBackupFileName = 'macos_system_dns_backup.json';
  static const _hijackDns = '223.5.5.5';
  final Lock _dnsLock = Lock();

  MacOS._internal();

  factory MacOS() {
    _instance ??= MacOS._internal();
    return _instance!;
  }

  Future<String?> get defaultServiceName async {
    final result = await Process.run('route', ['-n', 'get', 'default']);
    final output = result.stdout.toString();
    final deviceLine = output
        .split('\n')
        .firstWhere((s) => s.contains('interface:'), orElse: () => '');
    final parts = deviceLine.trim().split(' ');
    if (parts.length != 2) return null;

    final device = parts[1];
    final serviceResult = await Process.run('networksetup', [
      '-listnetworkserviceorder',
    ]);
    final serviceOutput = serviceResult.stdout.toString();
    final currentService = serviceOutput
        .split('\n\n')
        .firstWhere((s) => s.contains('Device: $device'), orElse: () => '');
    if (currentService.isEmpty) return null;

    final serviceNameLine = currentService
        .split('\n')
        .firstWhere(
          (line) => RegExp(r'^\(\d+\).*').hasMatch(line),
          orElse: () => '',
        );
    final match = RegExp(
      r'^\(\d+\)\s+(.+)$',
    ).firstMatch(serviceNameLine.trim());
    return match?.group(1)?.trim();
  }

  Future<List<String>?> get systemDns async {
    final deviceServiceName = await defaultServiceName;
    if (deviceServiceName == null) return null;
    return _getSystemDns(deviceServiceName);
  }

  Future<List<String>?> _getSystemDns(String serviceName) async {
    final result = await Process.run('networksetup', [
      '-getdnsservers',
      serviceName,
    ]);
    if (result.exitCode != 0) {
      commonPrint.log(
        'Failed to get macOS system DNS: ${result.stderr.toString().trim()}',
      );
      return null;
    }
    final output = result.stdout.toString().trim();
    return output.startsWith("There aren't any DNS Servers set on")
        ? []
        : output.split('\n');
  }

  Future<void> updateDns(bool restore) {
    return _dnsLock.synchronized(() async {
      if (restore) {
        await _restoreDns();
      } else {
        await _setDns();
      }
    });
  }

  Future<void> _setDns() async {
    // Restore a previous managed value first so repeated enable operations never
    // overwrite the real system DNS backup with Bettbox's own hijack DNS.
    if (!await _restoreDns()) return;

    final serviceName = await defaultServiceName;
    if (serviceName == null) return;

    final currentDns = await _getSystemDns(serviceName);
    if (currentDns == null || currentDns.contains(_hijackDns)) return;

    final backup = jsonEncode({
      'serviceName': serviceName,
      'servers': currentDns,
    });
    try {
      final backupFile = await _dnsBackupFile;
      await backupFile.parent.create(recursive: true);
      final temporaryFile = File('${backupFile.path}.tmp');
      await temporaryFile.writeAsString(backup, flush: true);
      await temporaryFile.rename(backupFile.path);
    } catch (e) {
      commonPrint.log('Failed to persist the original macOS system DNS: $e');
      return;
    }

    final result = await Process.run('networksetup', [
      '-setdnsservers',
      serviceName,
      ...currentDns,
      _hijackDns,
    ]);
    if (result.exitCode != 0) {
      commonPrint.log(
        'Failed to set macOS system DNS: ${result.stderr.toString().trim()}',
      );
    }
  }

  Future<bool> _restoreDns() async {
    final backupFile = await _dnsBackupFile;
    if (!await backupFile.exists()) return true;

    try {
      final rawBackup = await backupFile.readAsString();
      final backup = jsonDecode(rawBackup) as Map<String, dynamic>;
      final serviceName = backup['serviceName'] as String?;
      final servers = (backup['servers'] as List?)
          ?.whereType<String>()
          .toList();
      if (serviceName == null || serviceName.isEmpty || servers == null) {
        throw const FormatException('Invalid macOS system DNS backup');
      }

      final result = await Process.run('networksetup', [
        '-setdnsservers',
        serviceName,
        if (servers.isNotEmpty) ...servers,
        if (servers.isEmpty) 'Empty',
      ]);
      if (result.exitCode != 0) {
        commonPrint.log(
          'Failed to restore macOS system DNS: '
          '${result.stderr.toString().trim()}',
        );
        return false;
      }
      await backupFile.delete();
      return true;
    } catch (e) {
      commonPrint.log('Failed to read macOS system DNS backup: $e');
      return false;
    }
  }

  Future<File> get _dnsBackupFile async {
    return File(join(await appPath.homeDirPath, _dnsBackupFileName));
  }
}

final macOS = system.isMacOS ? MacOS() : null;
