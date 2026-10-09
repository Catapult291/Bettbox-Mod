import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'package:bett_box/rust/generated/bettbox_system_proxy_ffi.dart';
import 'package:bett_box/rust/native_library.dart';

/// Rust 侧系统代理（`rust/bettbox-native/src/system_proxy.rs`）的窄 C ABI 封装。
///
/// ABI 见 `rust/bettbox-native/include/bettbox_system_proxy.h`，Dart 绑定由 ffigen 生成
/// （`ffigen.bettbox_system_proxy.yaml`）。与配置管道/脚本引擎共用同一个动态库
/// （`bettbox_native`）。
///
/// 与另外两块不同，这里的三个入口返回的总是 JSON 信封
/// （`{"ok":true,...}` / `{"ok":false,"message":"..."}`），只有 ABI 级失败才是 NULL：
/// Win32 层的失败原因要交给调用方（见 `lib/common/system_proxy.dart`），
/// 失败策略与配置管道一致——**抛错，不回退到第二套实现**。
abstract final class RustSystemProxy {
  static BettboxSystemProxyFFI? _bindings;
  static Object? _loadError;

  /// 动态库是否可用。不可用时所有入口都会抛错。
  static bool get isAvailable => _tryLoad() != null;

  /// 读取当前系统代理设置（LAN 连接 + 所有 RAS 拨号项），返回快照 JSON 文本。
  static String query() {
    return _snapshotFrom(_call((bindings) => bindings.bb_system_proxy_query()));
  }

  /// 启用指向 `127.0.0.1:<port>` 的系统代理，返回**启用前**的设置快照。
  ///
  /// 失败抛 [StateError]；`warnings` 是 LAN 之外那些没能设置成功的连接。
  static RustSystemProxyEnableResult enable(int port, List<String> bypass) {
    final bypassPtr = bypass.join(';').toNativeUtf8();
    try {
      final envelope = _call(
        (bindings) => bindings.bb_system_proxy_enable(
          port,
          bypassPtr.cast<Char>(),
        ),
      );
      return RustSystemProxyEnableResult(
        snapshotJson: _snapshotFrom(envelope),
        warnings: _stringList(envelope['warnings']),
      );
    } finally {
      malloc.free(bypassPtr);
    }
  }

  /// 按快照还原系统代理：只还原仍归本应用管的连接。
  static RustSystemProxyRestoreReport restore(String snapshotJson) {
    final snapshotPtr = snapshotJson.toNativeUtf8();
    try {
      final envelope = _call(
        (bindings) => bindings.bb_system_proxy_restore(snapshotPtr.cast<Char>()),
      );
      return RustSystemProxyRestoreReport(
        restored: (envelope['restored'] as num?)?.toInt() ?? 0,
        skipped: (envelope['skipped'] as num?)?.toInt() ?? 0,
        warnings: _stringList(envelope['warnings']),
      );
    } finally {
      malloc.free(snapshotPtr);
    }
  }

  /// 调用一个返回信封的入口：解析 JSON、按 `ok` 决定抛错还是把信封交回调用方。
  static Map<String, dynamic> _call(
    Pointer<Char> Function(BettboxSystemProxyFFI bindings) invoke,
  ) {
    final bindings = _require();
    final outputPtr = invoke(bindings);
    if (outputPtr == nullptr) {
      throw StateError('Rust 系统代理入口未返回结果（ABI 级失败）');
    }
    final Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(outputPtr.cast<Utf8>().toDartString())
          as Map<String, dynamic>;
    } finally {
      bindings.bb_string_free(outputPtr);
    }
    if (envelope['ok'] != true) {
      throw StateError(
        '系统代理操作失败：${envelope['message'] ?? '未知原因'}',
      );
    }
    return envelope;
  }

  static String _snapshotFrom(Map<String, dynamic> envelope) {
    final snapshot = envelope['snapshot'];
    if (snapshot is! Map) {
      throw StateError('系统代理信封里没有 snapshot');
    }
    return jsonEncode(snapshot);
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) return const [];
    return value.whereType<String>().toList();
  }

  static BettboxSystemProxyFFI? _tryLoad() {
    final cached = _bindings;
    if (cached != null) return cached;
    if (_loadError != null) return null;
    try {
      return _bindings = BettboxSystemProxyFFI(openBettboxNativeLibrary());
    } catch (error) {
      _loadError = error;
      return null;
    }
  }

  static BettboxSystemProxyFFI _require() {
    final bindings = _tryLoad();
    if (bindings == null) {
      throw StateError('bettbox_native 动态库不可用：$_loadError');
    }
    return bindings;
  }
}

/// [RustSystemProxy.enable] 的结果：启用前的快照 + 逐连接的非致命失败。
class RustSystemProxyEnableResult {
  const RustSystemProxyEnableResult({
    required this.snapshotJson,
    required this.warnings,
  });

  /// 启用前的系统代理设置，交给调用方持久化（还原时用）。
  final String snapshotJson;

  /// LAN 之外没能设置成功的连接，形如 `VPN: InternetSetOptionW 失败（…）`。
  final List<String> warnings;
}

/// [RustSystemProxy.restore] 的结果。
class RustSystemProxyRestoreReport {
  const RustSystemProxyRestoreReport({
    required this.restored,
    required this.skipped,
    required this.warnings,
  });

  /// 已还原的连接数。
  final int restored;

  /// 跳过的连接数（期间被用户或别的程序改过、或已不存在）。
  final int skipped;

  final List<String> warnings;
}
