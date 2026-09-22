import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bett_box/clash/interface.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/helper/helper.dart';
import 'package:bett_box/models/core.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/utils/frame_codec.dart';
import 'package:bett_box/utils/platform_check.dart';
import 'package:path/path.dart' as p;

class ClashService extends ClashHandlerInterface {
  static ClashService? _instance;

  /// IPC 服务端就绪的上界：`_initServer` 失败时 [serverCompleter] 永不完成，
  /// 没有这个上界，整条内核生命周期链路（含 `_coreLifecycleLock`）会永久挂起。
  static const _serverReadyTimeout = Duration(seconds: 5);

  /// 上一个重启没有结束时继续等待的上界，避免重启链互相阻塞。
  static const _restartChainTimeout = Duration(seconds: 60);

  /// 等待内核连上 IPC 的上界，见 [sendMessage]。
  static const _socketReadyTimeout = Duration(seconds: 3);

  Completer<ServerSocket> serverCompleter = Completer();

  Completer<Socket> socketCompleter = Completer();

  bool isStarting = false;
  bool _isDestroying = false;

  Process? process;

  /// 内核在非过渡态下断开 IPC（或进程退出）时回调，用于让 UI 的启停状态与
  /// 事实对账，见 `AppController.reconcileCoreState`。
  void Function()? onCoreDisconnected;

  Completer<void>? _restartCompleter;

  TransportType _transportType = TransportType.unixSocket;
  String? _socketPath;
  int? _tcpPort;

  factory ClashService() {
    _instance ??= ClashService._internal();
    return _instance!;
  }

  ClashService._internal() {
    _initTransport();
  }

  Future<void> _initTransport() async {
    _transportType = await PlatformChecker.getRecommendedTransport();

    if (_transportType == TransportType.unixSocket) {
      final random = Random().nextInt(10000);
      final tempDir = Directory.systemTemp.path;
      _socketPath = p.join(tempDir, 'Bettbox_$random.sock');
      commonPrint.log('Using Unix Domain Socket: $_socketPath');
    } else {
      _tcpPort = PlatformChecker.getRandomPort();
      commonPrint.log('Using TCP Socket on port: $_tcpPort');
    }

    _initServer();
    reStart();
  }

  Future<void> _initServer() async {
    runZonedGuarded(
      () async {
        late final ServerSocket server;

        if (_transportType == TransportType.unixSocket) {
          final address = InternetAddress(
            _socketPath!,
            type: InternetAddressType.unix,
          );
          await _deleteSocketFile();
          server = await ServerSocket.bind(address, 0, shared: true);
        } else {
          server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
          _tcpPort = server.port;
          commonPrint.log('TCP Server bound to port: $_tcpPort');
        }

        serverCompleter.complete(server);
        await for (final socket in server) {
          await _destroySocket();
          socketCompleter.complete(socket);

          socket
              .transform(FrameDecoderTransformer())
              .listen(
                (data) {
                  handleResult(ActionResult.fromJson(json.decode(data)));
                },
                onError: (error) {
                  if (_isDestroying || globalState.isExiting) return;
                  commonPrint.log('Frame decode error: $error');
                  _notifyCoreDisconnected();
                },
                onDone: () {
                  commonPrint.log('Socket connection closed');
                  _notifyCoreDisconnected();
                },
              );
        }
      },
      (error, stack) {
        if (_isDestroying || globalState.isExiting) return;
        commonPrint.log(error.toString());
        if (error is SocketException &&
            !_isDestroying &&
            !globalState.isExiting) {
          globalState.showNotifier(error.toString());
        }
      },
    );
  }

  /// 只在非过渡态下上报断开：重启/退出过程中的 socket 关闭是预期行为。
  void _notifyCoreDisconnected() {
    if (_isDestroying || globalState.isExiting || isStarting) return;
    onCoreDisconnected?.call();
  }

  /// [serverCompleter] 的上界封装，绑定失败时抛错而不是永久等待。
  Future<ServerSocket> _awaitServerSocket() {
    if (serverCompleter.isCompleted) {
      return serverCompleter.future;
    }
    return serverCompleter.future.timeout(
      _serverReadyTimeout,
      onTimeout: () {
        throw StateError('IPC server did not bind in time');
      },
    );
  }

  @override
  Future<void> reStart() async {
    final completer = Completer<void>();
    final previous = _restartCompleter;
    _restartCompleter = completer;

    if (previous != null) {
      await previous.future.timeout(
        _restartChainTimeout,
        onTimeout: () {
          commonPrint.log('Previous core restart did not finish, continuing');
        },
      );
    }

    try {
      // Perform a real restart so every caller is guaranteed to see a fresh
      // core after this call returns. Queued calls will run sequentially.
      await _doRestart();
    } finally {
      if (_restartCompleter == completer) {
        _restartCompleter = null;
      }
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }

  Future<void> _doRestart() async {
    isStarting = true;
    _isDestroying = false;

    await _destroySocket();

    process?.kill();
    if (process != null) {
      await process!.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          process?.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }
    process = null;

    socketCompleter = Completer();

    final serverSocket = await _awaitServerSocket();

    final String arg;
    if (_transportType == TransportType.unixSocket) {
      arg = _socketPath!;
    } else {
      arg = '${serverSocket.port}';
    }

    final homeDirPath = await appPath.homeDirPath;
    final environment = Map<String, String>.from(Platform.environment);
    environment['SAFE_PATHS'] = homeDirPath;

    if (system.isWindows) {
      final serviceOk = await windows?.registerService() ?? false;
      if (serviceOk) {
        final started = await helperClient.startCore(
          corePath: appPath.corePath,
          arg: arg,
          homeDir: homeDirPath,
        );
        if (started) {
          await _waitForCoreReady();
          isStarting = false;
          if (system.isWindows && globalState.config.appSetting.enableHighPriority) {
            unawaited(
              helperClient
                  .setProcessPriority(
                    '${AppIdentity.coreExecutableName}.exe',
                    true,
                  )
                  .catchError((e) {
                    commonPrint.log('Failed to set core process priority: $e');
                    return false;
                  }),
            );
          }
          return;
        }
        commonPrint.log(
          'Helper start core failed, falling back to normal mode',
        );
      }
    }

    process = await Process.start(appPath.corePath, [
      arg,
    ], environment: environment);
    process?.stdout.listen((_) {});
    process?.stderr.listen((e) {
      final error = utf8.decode(e);
      if (error.isNotEmpty) commonPrint.log(error);
    });
    _watchCoreProcess();
    await _waitForCoreReady();
    isStarting = false;
    if (system.isWindows && globalState.config.appSetting.enableHighPriority) {
      unawaited(
        helperClient
            .setProcessPriority('${AppIdentity.coreExecutableName}.exe', true)
            .catchError((e) {
              commonPrint.log('Failed to set core process priority: $e');
              return false;
            }),
      );
    }
  }

  Future<void> _waitForCoreReady() async {
    try {
      await socketCompleter.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      commonPrint.log('Core ready timeout after 5s');
    }
  }

  /// 内核进程退出时上报一次（重启期间退出是预期行为，由 [_notifyCoreDisconnected] 过滤）。
  void _watchCoreProcess() {
    final current = process;
    if (current == null) return;
    unawaited(
      current.exitCode.then((code) {
        commonPrint.log('Core process exited with code $code');
        _notifyCoreDisconnected();
      }).catchError((_) {}),
    );
  }

  @override
  destroy() async {
    _isDestroying = true;
    ServerSocket? server;
    try {
      server = await serverCompleter.future.timeout(_serverReadyTimeout);
    } catch (e) {
      commonPrint.log('IPC server was not available on destroy: $e');
    }
    await server?.close();
    await _deleteSocketFile();
    return true;
  }

  @override
  sendMessage(String message) async {
    if (_isDestroying || globalState.isExiting) {
      return;
    }
    final Socket socket;
    try {
      // 内核没连上来时 socketCompleter 永不完成；加上界，否则每一次 invoke 都会
      // 留下一个永久 pending 的发送任务。
      socket = await socketCompleter.future.timeout(_socketReadyTimeout);
    } catch (e) {
      commonPrint.log('Core socket is not ready, message dropped: $e');
      return;
    }
    try {
      final frame = FrameCodec.encode(message);
      socket.add(frame);
    } on SocketException catch (e) {
      if (_isDestroying || globalState.isExiting || isStarting) {
        commonPrint.log(
          'Ignored message send on closed socket during transition: $e',
        );
        return;
      }
      commonPrint.log('Message send failed on closed socket: $e');
      _notifyCoreDisconnected();
    } on StateError catch (e) {
      if (_isDestroying || globalState.isExiting || isStarting) {
        commonPrint.log(
          'Ignored message send on closed socket during transition: $e',
        );
        return;
      }
      commonPrint.log('Message send failed on closed socket: $e');
      _notifyCoreDisconnected();
    }
  }

  Future<void> _deleteSocketFile() async {
    if (_transportType == TransportType.unixSocket && _socketPath != null) {
      final file = File(_socketPath!);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<void> _destroySocket() async {
    if (socketCompleter.isCompleted) {
      final lastSocket = await socketCompleter.future;
      await lastSocket.close();
      socketCompleter = Completer();
    }
  }

  @override
  shutdown() async {
    _isDestroying = true;
    if (system.isWindows) {
      await helperClient.stopCore();
    }
    await _destroySocket();
    process?.kill();
    process = null;
    return true;
  }

  Future<bool> checkCoreHealth({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (_isDestroying || globalState.isExiting || isStarting) return false;
    if (!socketCompleter.isCompleted) return false;
    try {
      final result = await invoke<bool>(
        method: ActionMethod.getIsInit,
        timeout: timeout,
      );
      return result == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> preload() async {
    try {
      await serverCompleter.future.timeout(_serverReadyTimeout);
    } catch (e) {
      commonPrint.log('IPC server is not available on preload: $e');
    }
    return true;
  }
}

final clashService = system.isDesktop ? ClashService() : null;
