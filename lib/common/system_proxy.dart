import 'package:bett_box/common/preferences.dart';
import 'package:bett_box/common/print.dart';
import 'package:bett_box/common/proxy.dart';
import 'package:bett_box/common/system.dart';
import 'package:bett_box/rust/system_proxy.dart';
import 'package:flutter/foundation.dart';

/// 原生层的抽象，只为让快照的存取流程可测：默认实现直接走 [RustSystemProxy]。
abstract interface class SystemProxyNative {
  RustSystemProxyEnableResult enable(int port, List<String> bypass);

  RustSystemProxyRestoreReport restore(String snapshotJson);
}

/// 默认的原生层：Rust 侧 `bettbox_native`（见 `rust/bettbox-native/src/system_proxy.rs`）。
class RustSystemProxyNative implements SystemProxyNative {
  const RustSystemProxyNative();

  @override
  RustSystemProxyEnableResult enable(int port, List<String> bypass) =>
      RustSystemProxy.enable(port, bypass);

  @override
  RustSystemProxyRestoreReport restore(String snapshotJson) =>
      RustSystemProxy.restore(snapshotJson);
}

/// 系统代理的开关门面（桌面端）。
///
/// Windows 走 Rust（`rust/bettbox-native/src/system_proxy.rs`）：打开前先把当前设置存成
/// 快照，关闭时只还原**仍归我们管**的连接。旧实现（Flutter 插件 `plugins/proxy`）关闭时
/// 无差别把 `ProxyEnable` 置 0，会连带清掉其他程序设置的系统代理；被强杀后留下的设置
/// 也靠这份快照在下次启动时还原——此前只能等下次启动无脑清掉，而用户在「被强杀到下次
/// 启动」之间是系统代理指向没人监听的端口、上不了网的状态。
///
/// macOS / Linux 仍走 `plugins/proxy` 的 Dart 实现（这两个平台不发布产物，行为不变）。
///
/// 失败策略与配置管道一致：不回退到第二套实现，只记日志。这里不抛错是因为调用方是
/// UI 状态监听与退出流程，都没有能接住异常的地方；失败时快照会保留，下次再试。
abstract final class SystemProxy {
  /// 偏好设置里存「启用前的系统代理设置」的键。
  static const snapshotKey = 'system_proxy_snapshot';

  /// 原生层；测试里换成替身以覆盖快照的存取流程。
  @visibleForTesting
  static SystemProxyNative native = const RustSystemProxyNative();

  /// 打开系统代理。[port] 是内核的混合端口，[bypass] 是绕过域名。
  static Future<void> enable({
    required int port,
    required List<String> bypass,
  }) async {
    if (!system.isWindows) {
      try {
        await proxy?.startProxy(port, bypass);
      } catch (error) {
        commonPrint.log('打开系统代理失败：$error');
      }
      return;
    }

    // 上次会话（多半是被强杀）留下的设置先还原，免得把自己的旧值当成
    // 「用户原有的设置」存进新快照。
    await _restorePersisted(reason: 'enable');

    try {
      final result = native.enable(port, bypass);
      await _saveSnapshot(result.snapshotJson);
      for (final warning in result.warnings) {
        commonPrint.log('系统代理：$warning');
      }
    } catch (error) {
      commonPrint.log('打开系统代理失败：$error');
    }
  }

  /// 关闭系统代理：还原启用前存下的快照。
  static Future<void> disable() async {
    if (!system.isWindows) {
      try {
        await proxy?.stopProxy();
      } catch (error) {
        commonPrint.log('关闭系统代理失败：$error');
      }
      return;
    }
    await _restorePersisted(reason: 'disable');
  }

  static Future<void> _restorePersisted({required String reason}) async {
    final prefs = await preferences.sharedPreferencesCompleter.future;
    final snapshotJson = prefs?.getString(snapshotKey);
    if (snapshotJson == null) {
      // 没有快照 = 本应用没改过系统代理，什么都不做（旧实现在这里会无差别
      // 清掉别的程序设置的系统代理）。
      return;
    }

    try {
      final report = native.restore(snapshotJson);
      for (final warning in report.warnings) {
        commonPrint.log('系统代理还原：$warning');
      }
      await prefs?.remove(snapshotKey);
      commonPrint.log(
        '系统代理已还原（$reason）：${report.restored} 项，跳过 ${report.skipped} 项',
      );
    } catch (error) {
      // 快照留着，下次启动或关闭时再试。
      commonPrint.log('还原系统代理失败（$reason）：$error');
    }
  }

  static Future<void> _saveSnapshot(String snapshotJson) async {
    final prefs = await preferences.sharedPreferencesCompleter.future;
    await prefs?.setString(snapshotKey, snapshotJson);
  }
}
