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

/// `sc query` 视角下的 helper 服务状态。
enum HelperServiceState {
  /// 服务不存在（`sc query` 非零退出，典型 1060）。
  missing,

  /// 服务存在但不是 RUNNING（STOPPED / START_PENDING / …）。
  inactive,

  /// 服务正在运行。
  running,
}

/// `registerService` 对「服务状态 × ping 分类 × binPath 指向」要执行的动作。
enum RegisterServiceAction {
  /// 执行 `service install`（停 → 删 → 建，binPath 会被改为当前 exe 所在目录）。
  install,

  /// 服务已在运行且健康：沿用现装服务（调用方再处理明文 key 迁移）。
  useExisting,

  /// 证据不足以重写现网服务：保持原样，调用方回退进程模式。
  leaveUntouched,
}

/// 由 `sc query` 的退出码与输出得出 [HelperServiceState]（纯函数，供单测）。
///
/// 判据与既有 `checkService` / `_isHelperHealthy` 逐字一致：exit≠0 → 不存在；
/// 输出含 `RUNNING` → 运行中；其余（含 STOPPED、START_PENDING）→ 存在但未运行。
HelperServiceState serviceStateFromScQuery(int exitCode, String stdout) {
  if (exitCode != 0) return HelperServiceState.missing;
  if (stdout.contains('RUNNING')) return HelperServiceState.running;
  return HelperServiceState.inactive;
}

/// 解析 `sc qc` 输出里的 `BINARY_PATH_NAME`；解析不出返回 null。
///
/// 值可能带外层引号（路径含空格时的常见写法），只剥最外层；带额外参数的原样
/// 保留——本服务的 binPath 只有 exe 路径，出现参数会因比较不等而按「指向别处」
/// 处理（保护优先）。
String? parseServiceBinPath(String scQcOutput) {
  final match = RegExp(
    r'BINARY_PATH_NAME\s*:\s*(.+)',
    caseSensitive: false,
  ).firstMatch(scQcOutput);
  if (match == null) return null;
  final raw = match.group(1)!.trim();
  if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) {
    return raw.substring(1, raw.length - 1).trim();
  }
  return raw;
}

/// 服务 binPath 比较用的规范化：剥外层引号、统一分隔符为 `\`、忽略大小写与首尾空白。
String normalizeServiceBinaryPath(String value) {
  var v = value.trim();
  if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
    v = v.substring(1, v.length - 1).trim();
  }
  return v.replaceAll('/', '\\').toLowerCase();
}

/// 两个服务二进制路径是否指向同一文件。
bool sameServiceBinaryPath(String a, String b) =>
    normalizeServiceBinaryPath(a) == normalizeServiceBinaryPath(b);

/// `registerService` 的决策表（纯函数，单测钉住全真值表）。
///
/// 原则：**没有 helper 应答给出的正向不兼容证据，绝不把现装于他处的服务改指
/// 当前 exe**——CHANGES 第 50 节未决① 的事故正是「ping 瞬时失败 → 一律
/// 重装」把现网服务改到了构建目录。`incompatible`（helper 应答了但 TOKEN/
/// 协议不匹配）保留重装，那是「新 app 对旧 helper」的升级路径（CHANGES 第 38
/// 节、stage-log §113）；`authFailed`/`unreachable` 没有这种证据，跨目录一律
/// 不动，同目录仍允许重装自愈（key 文件丢失、服务半坏等）。
RegisterServiceAction planRegisterService(
  HelperServiceState state,
  HelperPingStatus ping,
  bool binPathDiffers,
) {
  switch (state) {
    case HelperServiceState.missing:
      return RegisterServiceAction.install;
    case HelperServiceState.running:
      switch (ping) {
        case HelperPingStatus.healthy:
          return RegisterServiceAction.useExisting;
        case HelperPingStatus.incompatible:
          return RegisterServiceAction.install;
        case HelperPingStatus.authFailed:
        case HelperPingStatus.unreachable:
          return binPathDiffers
              ? RegisterServiceAction.leaveUntouched
              : RegisterServiceAction.install;
      }
    case HelperServiceState.inactive:
      return binPathDiffers
          ? RegisterServiceAction.leaveUntouched
          : RegisterServiceAction.install;
  }
}

/// 带瞬时重试的 ping 探测：仅 `unreachable` / `authFailed` 重试。
///
/// 这两类可能是管道/鉴权的瞬时抖动（第 50 节未决① 的疑点），多给两轮机会再
/// 做破坏性决定；`healthy` / `incompatible` 是确定性结论，重试只拖慢。
Future<HelperPingStatus> probeHelperPingWithRetry(
  Future<HelperPingStatus> Function() probe, {
  int attempts = 3,
  Duration delay = const Duration(milliseconds: 350),
}) async {
  var status = await probe();
  for (var i = 1; i < attempts; i++) {
    if (status != HelperPingStatus.unreachable &&
        status != HelperPingStatus.authFailed) {
      return status;
    }
    await Future.delayed(delay);
    status = await probe();
  }
  return status;
}

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

  /// 本进程**专用工作集**（Private Working Set，字节）——任务管理器「进程」页
  /// 默认「内存」列的口径：工作集中未与任何进程共享的页 × 页大小。
  ///
  /// 实现走 `NtQueryVirtualMemory(MemoryWorkingSetInformation)` 拿整张工作集
  /// 页块表，按 NT `MEMORY_WORKING_SET_BLOCK` 位布局（Protection:5 在低位、
  /// ShareCount 在 bit5..7）数 `ShareCount == 0` 的页；实测与 perf 计数器
  /// `WorkingSetPrivate` 同量级（0.2% 内）。**不能**用
  /// `PROCESS_MEMORY_COUNTERS_EX.PrivateUsage`——那是私有**提交**
  /// （commit charge，含已换出页），比专用工作集大一截。
  ///
  /// 查询失败（状态非 0 / 异常）返回 `null`，由调用方回落
  /// `ProcessInfo.currentRss`（完整工作集）。伪句柄 `GetCurrentProcess`
  /// 只指向本进程，不需要 `CloseHandle`。
  int? currentPrivateWorkingSet() {
    try {
      const pageSize = 4096;
      // 缓冲按「当前 RSS 折页 + 32 MiB 余量」给：查询间隙工作集增长被余量吃掉；
      // 不够时 NtQueryVirtualMemory 返回失败 → 走 null 回落，下个刷新周期再试。
      var capacityEntries = ProcessInfo.currentRss ~/ pageSize + 8192;
      const maxEntries = 1 << 21; // 8 GiB 工作集上限，防御性封顶
      if (capacityEntries > maxEntries) capacityEntries = maxEntries;

      final ntdll = DynamicLibrary.open('ntdll.dll');
      final ntQueryVirtualMemory = ntdll.lookupFunction<
        Int32 Function(
          IntPtr,
          IntPtr,
          Int32,
          Pointer<Void>,
          IntPtr,
          Pointer<IntPtr>,
        ),
        int Function(int, int, int, Pointer<Void>, int, Pointer<IntPtr>)
      >('NtQueryVirtualMemory');
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final getCurrentProcess = kernel32
          .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');

      // MEMORY_WORKING_SET_INFORMATION：ULONG_PTR NumberOfEntries + 页块数组。
      final bufBytes = 8 + capacityEntries * 8;
      final buf = calloc<Uint8>(bufBytes);
      final retLen = calloc<IntPtr>();
      try {
        final status = ntQueryVirtualMemory(
          getCurrentProcess(),
          0,
          1, // MemoryWorkingSetInformation
          buf.cast<Void>(),
          bufBytes,
          retLen,
        );
        if (status < 0) return null;

        final count = buf.cast<Uint64>().value;
        final blocks = (buf.cast<Uint64>() + 1); // 跳过头部 NumberOfEntries
        var privatePages = 0;
        for (var i = 0; i < count; i++) {
          // NT 位布局：Protection:5（bit0..4）、ShareCount:3（bit5..7）。
          // ShareCount == 0 = 独占页 = 专用工作集计数。
          if (((blocks[i] >> 5) & 0x7) == 0) privatePages++;
        }
        final privateBytes = privatePages * pageSize;
        return privateBytes > 0 ? privateBytes : null;
      } finally {
        calloc.free(buf);
        calloc.free(retLen);
      }
    } catch (e) {
      commonPrint.log('currentPrivateWorkingSet failed: $e');
      return null;
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
    final state = await _queryServiceState();
    if (state == HelperServiceState.missing) {
      return WindowsHelperServiceStatus.none;
    }
    if (state != HelperServiceState.running) {
      return WindowsHelperServiceStatus.presence;
    }

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

    final state = await _queryServiceState();
    final binPathDiffers = state == HelperServiceState.missing
        ? false
        : await _serviceBinPathDiffers();

    // 只有「正在运行」才有应答可探。探测带瞬时重试（unreachable/authFailed
    // 各再给两轮，单次 2s；healthy/incompatible 确定性不重试），把「疑管道/
    // 鉴权瞬时问题」的抖动窗口吸收在破坏性决定之前。
    var ping = HelperPingStatus.unreachable;
    if (state == HelperServiceState.running) {
      ping = await probeHelperPingWithRetry(
        () => _pingHelperStatus(timeout: const Duration(seconds: 2)),
      );
    }

    var action = planRegisterService(state, ping, binPathDiffers);
    commonPrint.log(
      '[Helper] registerService plan: state=${state.name} ping=${ping.name} '
      'binPathDiffers=$binPathDiffers → ${action.name}',
    );

    if (action == RegisterServiceAction.useExisting) {
      // 服务已在运行且健康：默认沿用。仅当注册表还留着旧版明文 key 且服务本来
      // 就指在本目录时才做迁移重装；指在他处时迁移会把 binPath 改到当前 exe，
      // 跳过（那份明文 key 属于对方安装的配置，由对方自己管）。
      if (!await _serviceEnvHasLegacyPlaintextKey()) return true;
      if (binPathDiffers) {
        commonPrint.log(
          '[Helper] skipping plaintext key migration: service binary is '
          'outside this build',
        );
        return true;
      }
      commonPrint.log(
        '[Helper] migrating the plaintext auth key out of the service registry',
      );
      action = RegisterServiceAction.install;
    }

    if (action == RegisterServiceAction.leaveUntouched) {
      commonPrint.log(
        '[Helper] leaving the existing helper service untouched: no positive '
        'evidence for a rewrite (state=${state.name} ping=${ping.name}, '
        'binPath points elsewhere); falling back to process mode',
      );
      return false;
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
    return state == HelperServiceState.running &&
        ping == HelperPingStatus.healthy;
  }

  Future<HelperServiceState> _queryServiceState() async {
    final result = await Process.run('sc', ['query', appHelperService]);
    return serviceStateFromScQuery(result.exitCode, result.stdout.toString());
  }

  /// 现装服务的 binPath 是否不指向本应用的 helper。
  ///
  /// `sc qc` 失败或解析不出 `BINARY_PATH_NAME` 一律按「指向别处」处理——
  /// 比较不了时保护优先，宁可不重装也不改写现网服务。
  Future<bool> _serviceBinPathDiffers() async {
    try {
      final result = await Process.run('sc', ['qc', appHelperService]);
      if (result.exitCode != 0) {
        commonPrint.log(
          '[Helper] sc qc failed (exit=${result.exitCode}), treating binPath '
          'as foreign',
        );
        return true;
      }
      final binPath = parseServiceBinPath(result.stdout.toString());
      if (binPath == null) {
        commonPrint.log(
          '[Helper] BINARY_PATH_NAME missing in sc qc output, treating binPath '
          'as foreign',
        );
        return true;
      }
      if (!sameServiceBinaryPath(binPath, appPath.helperPath)) {
        commonPrint.log(
          '[Helper] service binPath=$binPath differs from this build helper='
          '${appPath.helperPath}',
        );
        return true;
      }
      return false;
    } catch (e) {
      commonPrint.log(
        '[Helper] failed to query service binPath: $e, treating binPath as '
        'foreign',
      );
      return true;
    }
  }

  Future<bool> _isHelperHealthy() async {
    if (await _queryServiceState() != HelperServiceState.running) return false;
    return _pingHelper();
  }

  /// 分类 ping。core SHA 未就绪时记日志并按 `unreachable` 处理——不再静默
  /// 返回 false，这样跨目录场景会走到「不动现网服务」而不是重装。
  Future<HelperPingStatus> _pingHelperStatus({
    Duration timeout = helperDefaultTimeout,
  }) async {
    final coreSHA256 = globalState.coreSHA256;
    if (coreSHA256 == null || coreSHA256.isEmpty) {
      commonPrint.log('[Helper] ping skipped: core SHA256 is not ready');
      return HelperPingStatus.unreachable;
    }
    return helperClient.pingStatus(coreSHA256, timeout: timeout);
  }

  Future<bool> _pingHelper() async {
    return (await _pingHelperStatus()) == HelperPingStatus.healthy;
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

    final environment = [
      if (keyFilePath != null)
        'HELPER_AUTH_KEY_FILE=$keyFilePath'
      else
        'HELPER_AUTH_KEY=$authKey',
      'HELPER_SERVICE_NAME=$appHelperService',
      'HELPER_PIPE_NAME=$helperPipeName',
      if (allowedSid != null) 'HELPER_ALLOWED_SID=$allowedSid',
    ];

    final result = await _runHelperCommand('service', 'install', {
      'serviceName': appHelperService,
      'startType': AppIdentity.isDev ? 'demand' : 'auto',
      'environment': environment,
    });

    if (!result.ok) {
      commonPrint.log(
        '[Helper] failed to install the service: ${result.summary}',
      );
    }

    return result.ok;
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

    final result = await _runHelperCommand('task', 'register', {
      'taskName': appName,
      'executablePath': executablePath,
      'workingDirectory': workingDirectory,
      'description': '开机自动启动代理服务',
    });

    if (!result.ok) {
      commonPrint.log(
        '[Helper] failed to register the task: ${result.summary}',
      );
    }

    return result.ok;
  }

  Future<bool> unregisterTask(String appName) async {
    final result = await _runHelperCommand('task', 'unregister', {
      'taskName': appName,
    });

    if (!result.ok) {
      commonPrint.log(
        '[Helper] failed to unregister the task: ${result.summary}',
      );
    }

    return result.ok;
  }

  /// 以一次提权调用 helper 的子命令，并把结果文件读回来。
  ///
  /// 协议本体在 `helper_cli.dart` 的 `runHelperCommand()` 里（可注入 launcher，便于测试）；
  /// 这里只提供应用侧的 helper 路径、临时目录与提权方式。
  Future<HelperCliResult> _runHelperCommand(
    String group,
    String action,
    Map<String, Object?> request,
  ) async {
    return runHelperCommand(
      helperPath: appPath.helperPath,
      group: group,
      action: action,
      request: request,
      tempDirPath: await appPath.tempPath,
      launch: runas,
    );
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
