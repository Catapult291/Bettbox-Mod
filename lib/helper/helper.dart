import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:bett_box/common/helper_auth.dart';
import 'package:bett_box/common/identity.dart';
import 'package:bett_box/common/print.dart';
import 'package:bett_box/common/win32_kernel.dart';
import 'package:ffi/ffi.dart';

const helperProtocolVersion = 2;
const helperPipeName = WindowsHelperIdentity.pipeName;
const helperMaxFrameSize = 1024 * 1024;
const helperDefaultTimeout = Duration(seconds: 5);

abstract class HelperTransport {
  Future<String> send(
    String payload, {
    Duration timeout = helperDefaultTimeout,
  });
}

class HelperAuth {
  const HelperAuth({
    required this.timestamp,
    required this.nonce,
    required this.signature,
  });

  final int timestamp;
  final String nonce;
  final String signature;

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp,
    'nonce': nonce,
    'signature': signature,
  };
}

class HelperRequest {
  const HelperRequest({
    required this.id,
    required this.method,
    required this.body,
    required this.auth,
  });

  final String id;
  final String method;
  final String body;
  final HelperAuth auth;

  String encode() {
    return json.encode({
      'version': helperProtocolVersion,
      'id': id,
      'method': method,
      'body': body,
      'auth': auth.toJson(),
    });
  }
}

class HelperResponse {
  const HelperResponse({
    required this.id,
    required this.ok,
    this.data,
    this.error,
  });

  final String id;
  final bool ok;
  final Object? data;
  final HelperResponseError? error;

  factory HelperResponse.decode(String value) {
    final data = json.decode(value);
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Invalid helper response');
    }
    return HelperResponse(
      id: data['id'] as String? ?? '',
      ok: data['ok'] == true,
      data: data['data'],
      error: data['error'] is Map<String, dynamic>
          ? HelperResponseError.fromJson(data['error'] as Map<String, dynamic>)
          : null,
    );
  }
}

class HelperResponseError {
  const HelperResponseError({required this.code, required this.message});

  final String code;
  final String message;

  factory HelperResponseError.fromJson(Map<String, dynamic> json) {
    return HelperResponseError(
      code: json['code'] as String? ?? 'UNKNOWN',
      message: json['message'] as String? ?? 'Unknown helper error',
    );
  }
}

class HelperRpcException implements Exception {
  const HelperRpcException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// `process.list` 的一行：运行中进程。`path` 为空表示读路径失败，不可入选。
class HelperProcessEntry {
  const HelperProcessEntry({
    required this.pid,
    required this.name,
    required this.path,
    required this.description,
  });

  factory HelperProcessEntry.fromJson(Map<String, Object?> json) {
    return HelperProcessEntry(
      pid: (json['pid'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      description: json['description'] as String? ?? '',
    );
  }

  final int pid;
  final String name;
  final String path;
  final String description;
}

/// `process.icon` 的应答：32 位 RGBA 像素（自上而下）。
class HelperProcessIcon {
  const HelperProcessIcon({
    required this.width,
    required this.height,
    required this.rgba,
  });

  factory HelperProcessIcon.fromJson(Map<String, Object?> json) {
    final width = (json['width'] as num?)?.toInt() ?? 0;
    final height = (json['height'] as num?)?.toInt() ?? 0;
    final b64 = json['rgba'] as String? ?? '';
    return HelperProcessIcon(
      width: width,
      height: height,
      rgba: base64Decode(b64),
    );
  }

  final int width;
  final int height;
  final Uint8List rgba;
}

/// `helper.ping` 探测的分类结果。
///
/// 折叠成布尔值会丢掉「为什么不健康」：`registerService` 拿不到区分度就只能
/// 一律走 `service install`，而 helper 的 `service install` 用 `current_exe()`
/// 重写 binPath——ping 瞬时失败会把现网服务改指到当前 exe 目录（CHANGES 第 50
/// 节未决① 的事故）。分类后才能区分「helper 有应答的确定性不兼容」与「管道/
/// 鉴权没走通的瞬时失败」。
enum HelperPingStatus {
  /// helper 有应答，TOKEN 与期望一致。
  healthy,

  /// helper 有应答，但 TOKEN 不一致或协议/请求形态不兼容——重装升级的正向证据。
  incompatible,

  /// 请求走到了鉴权环节但被拒（`UNAUTHORIZED` / `AUTH_NOT_READY` 等）。
  authFailed,

  /// 没拿到应答：连接失败、超时、响应无法解析。
  unreachable,
}

/// 把一次 `helper.ping` 的结果按 [expectedToken] 归类（纯函数，供单测钉住）。
///
/// [error] 非空是抛出路径（`_request` 的异常），否则 [data] 是成功应答的
/// `data` 字段。`HelperRpcException` 以外的异常（管道状态错、超时、帧解析
/// 失败）一律视为没有拿到有效应答。
HelperPingStatus classifyHelperPing({
  required String expectedToken,
  Object? data,
  Object? error,
}) {
  if (error != null) {
    if (error is HelperRpcException) {
      if (error.code == 'UNAUTHORIZED' ||
          error.code == 'AUTH_NOT_READY' ||
          error.code.startsWith('AUTH_')) {
        return HelperPingStatus.authFailed;
      }
      // UNSUPPORTED_VERSION / INVALID_REQUEST 等：helper 有应答，只是和我们
      // 讲的不是同一套协议——保留重装以覆盖「新 app 对旧 helper」升级路径。
      return HelperPingStatus.incompatible;
    }
    return HelperPingStatus.unreachable;
  }
  if (expectedToken.isEmpty) return HelperPingStatus.unreachable;
  return data == expectedToken
      ? HelperPingStatus.healthy
      : HelperPingStatus.incompatible;
}

class HelperClient {
  HelperClient({required HelperTransport transport}) : _transport = transport;

  final HelperTransport _transport;
  final Random _random = Random.secure();

  /// 带分类的 ping：[ping] 的布尔包装，供需要区分失败原因的调用方使用。
  Future<HelperPingStatus> pingStatus(
    String expectedToken, {
    Duration timeout = helperDefaultTimeout,
  }) async {
    try {
      final response = await _request('helper.ping', timeout: timeout);
      final status = classifyHelperPing(
        expectedToken: expectedToken,
        data: response.data,
      );
      if (status != HelperPingStatus.healthy) {
        commonPrint.log(
          status == HelperPingStatus.incompatible
              ? '[HelperClient] ping status=incompatible: helper responded '
                    'but token/protocol mismatch'
              : '[HelperClient] ping status=${status.name}: expected token '
                    'is not ready',
        );
      }
      return status;
    } catch (e) {
      final status = classifyHelperPing(expectedToken: expectedToken, error: e);
      commonPrint.log('[HelperClient] ping status=${status.name}: $e');
      return status;
    }
  }

  Future<bool> ping(String expectedToken) async {
    final status = await pingStatus(expectedToken);
    return status == HelperPingStatus.healthy;
  }

  Future<bool> startCore({
    required String corePath,
    required String arg,
    required String homeDir,
  }) async {
    try {
      await _request(
        'core.start',
        body: {'path': corePath, 'arg': arg, 'home_dir': homeDir},
        timeout: const Duration(seconds: 5),
      );
      return true;
    } catch (e) {
      commonPrint.log('[HelperClient] startCore failed: $e');
      return false;
    }
  }

  Future<bool> stopCore() async {
    try {
      await _request('core.stop', timeout: const Duration(milliseconds: 2000));
      return true;
    } catch (e) {
      commonPrint.log('[HelperClient] stopCore failed: $e');
      return false;
    }
  }

  Future<bool> stopHelperService() async {
    try {
      await _request(
        'helper.stop_service',
        timeout: const Duration(milliseconds: 2000),
      );
      return true;
    } catch (e) {
      commonPrint.log('[HelperClient] stopHelperService failed: $e');
      return false;
    }
  }

  Future<bool> setProcessPriority(String processName, bool enable) async {
    try {
      await _request(
        'process.set_priority',
        body: {'process_name': processName, 'enable': enable},
        timeout: const Duration(milliseconds: 2000),
      );
      return true;
    } catch (e) {
      commonPrint.log('[HelperClient] setProcessPriority failed: $e');
      return false;
    }
  }

  /// 枚举运行中进程（pid / exe 名 / 完整路径 / 版本资源描述）。
  Future<List<HelperProcessEntry>> listProcesses() async {
    final response = await _request(
      'process.list',
      timeout: const Duration(seconds: 10),
    );
    final data = response.data;
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((e) => HelperProcessEntry.fromJson(Map<String, Object?>.from(e)))
        .toList();
  }

  /// 按 exe 路径取 32 位 RGBA 图标；失败返回 null。
  Future<HelperProcessIcon?> getProcessIcon(String path) async {
    try {
      final response = await _request(
        'process.icon',
        body: {'path': path},
        timeout: const Duration(seconds: 5),
      );
      final data = response.data;
      if (data is! Map) return null;
      return HelperProcessIcon.fromJson(Map<String, Object?>.from(data));
    } catch (e) {
      commonPrint.log('[HelperClient] getProcessIcon failed: $e');
      return null;
    }
  }

  Future<List<String>> getLogs() async {
    final response = await _request('helper.logs');
    final data = response.data;
    if (data is List) {
      return data.whereType<String>().toList();
    }
    return const [];
  }

  Future<HelperResponse> _request(
    String method, {
    Map<String, dynamic>? body,
    Duration timeout = helperDefaultTimeout,
  }) async {
    await HelperAuthManager.ensureAuthKey();

    final bodyPayload = body == null ? '' : json.encode(body);
    final authPayload = '$helperProtocolVersion:$method:$bodyPayload';
    final headers = HelperAuthManager.generateAuthHeaders(authPayload);
    final timestamp = int.tryParse(headers['X-Timestamp'] ?? '');
    final nonce = headers['X-Nonce'];
    final signature = headers['X-Signature'];
    if (timestamp == null || nonce == null || signature == null) {
      throw const HelperRpcException(
        'AUTH_NOT_READY',
        'Helper auth key is not ready',
      );
    }

    final request = HelperRequest(
      id: _nextId(),
      method: method,
      body: bodyPayload,
      auth: HelperAuth(
        timestamp: timestamp,
        nonce: nonce,
        signature: signature,
      ),
    );
    final responsePayload = await _transport.send(
      request.encode(),
      timeout: timeout,
    );
    final response = HelperResponse.decode(responsePayload);
    if (!response.ok) {
      final error = response.error;
      throw HelperRpcException(
        error?.code ?? 'HELPER_ERROR',
        error?.message ?? 'Unknown helper error',
      );
    }
    return response;
  }

  String _nextId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final suffix = _random.nextInt(0x7fffffff).toRadixString(16);
    return '$now-$suffix';
  }
}

HelperTransport _createHelperTransport() {
  if (Platform.isWindows) {
    return const NamedPipeHelperTransport();
  }
  return _UnsupportedHelperTransport();
}

class _UnsupportedHelperTransport implements HelperTransport {
  @override
  Future<String> send(
    String payload, {
    Duration timeout = helperDefaultTimeout,
  }) {
    throw UnsupportedError(
      'Helper IPC transport is not available on this platform',
    );
  }
}

final helperClient = HelperClient(transport: _createHelperTransport());

class NamedPipeHelperTransport implements HelperTransport {
  const NamedPipeHelperTransport({this.pipeName = helperPipeName});

  final String pipeName;

  @override
  Future<String> send(
    String payload, {
    Duration timeout = helperDefaultTimeout,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Named Pipe helper transport is Windows-only');
    }
    // timeout 原先只约束连接阶段：`_readExactly` 卡在读上时 `Isolate.run`
    // 会永久挂住，探测方等不到结论。外层兜底让调用方按 timeout 解除阻塞
    // （isolate 内的读要等对端关管道才醒，滞留的 isolate 由进程退出回收）。
    return Isolate.run(
      () => _sendNamedPipeRequest(pipeName, payload, timeout.inMilliseconds),
    ).timeout(timeout);
  }
}

String _sendNamedPipeRequest(String pipeName, String payload, int timeoutMs) {
  final client = _NamedPipeClient(pipeName: pipeName, timeoutMs: timeoutMs);
  return client.send(payload);
}

class _NamedPipeClient {
  _NamedPipeClient({required this.pipeName, required this.timeoutMs});

  final String pipeName;
  final int timeoutMs;

  String send(String payload) {
    final handle = _connect();
    try {
      final bytes = utf8.encode(payload);
      if (bytes.length > helperMaxFrameSize) {
        throw StateError('Helper request frame is too large');
      }
      final frame = Uint8List(4 + bytes.length);
      final frameView = ByteData.sublistView(frame);
      frameView.setUint32(0, bytes.length, Endian.little);
      frame.setRange(4, frame.length, bytes);
      _writeAll(handle, frame);

      final header = _readExactly(handle, 4);
      final length = ByteData.sublistView(header).getUint32(0, Endian.little);
      if (length > helperMaxFrameSize) {
        throw StateError('Helper response frame is too large');
      }
      final response = _readExactly(handle, length);
      return utf8.decode(response);
    } finally {
      Kernel32.instance.closeHandle(handle);
    }
  }

  int _connect() {
    final kernel32 = Kernel32.instance;
    final pipeNamePtr = pipeName.toNativeUtf16();
    final stopwatch = Stopwatch()..start();

    try {
      while (true) {
        final handle = kernel32.createFile(
          pipeNamePtr,
          genericRead | genericWrite,
          0,
          nullptr,
          openExisting,
          0,
          0,
        );
        if (handle != invalidHandleValue) {
          return handle;
        }

        final error = kernel32.getLastError();
        final remainingMs = timeoutMs - stopwatch.elapsedMilliseconds;
        if (remainingMs <= 0) {
          throw StateError('Helper pipe connection timed out: $error');
        }

        if (error == errorPipeBusy) {
          kernel32.waitNamedPipe(pipeNamePtr, remainingMs);
        } else if (error == errorFileNotFound) {
          sleep(const Duration(milliseconds: 50));
        } else {
          throw StateError('Helper pipe connection failed: $error');
        }
      }
    } finally {
      calloc.free(pipeNamePtr);
    }
  }

  void _writeAll(int handle, Uint8List data) {
    final kernel32 = Kernel32.instance;
    final buffer = calloc<Uint8>(data.length);
    final written = calloc<Uint32>();

    try {
      buffer.asTypedList(data.length).setAll(0, data);
      var offset = 0;
      while (offset < data.length) {
        written.value = 0;
        final result = kernel32.writeFile(
          handle,
          buffer + offset,
          data.length - offset,
          written,
          nullptr,
        );
        if (result == 0 || written.value == 0) {
          throw StateError(
            'Helper pipe write failed: ${kernel32.getLastError()}',
          );
        }
        offset += written.value;
      }
    } finally {
      calloc.free(written);
      calloc.free(buffer);
    }
  }

  Uint8List _readExactly(int handle, int length) {
    final kernel32 = Kernel32.instance;
    final buffer = calloc<Uint8>(length);
    final bytesRead = calloc<Uint32>();

    try {
      var offset = 0;
      while (offset < length) {
        bytesRead.value = 0;
        final result = kernel32.readFile(
          handle,
          buffer + offset,
          length - offset,
          bytesRead,
          nullptr,
        );
        if (result == 0 || bytesRead.value == 0) {
          throw StateError(
            'Helper pipe read failed: ${kernel32.getLastError()}',
          );
        }
        offset += bytesRead.value;
      }
      return Uint8List.fromList(buffer.asTypedList(length));
    } finally {
      calloc.free(bytesRead);
      calloc.free(buffer);
    }
  }
}
