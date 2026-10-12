import 'package:bett_box/common/preferences.dart';
import 'package:bett_box/common/print.dart';
import 'package:bett_box/common/proxy.dart';
import 'package:bett_box/common/proxy_guard.dart';
import 'package:bett_box/common/system.dart';
import 'package:bett_box/rust/system_proxy.dart';
import 'package:flutter/foundation.dart';

/// 原生层的抽象，只为让快照的存取流程可测：默认实现直接走 [RustSystemProxy]。
abstract interface class SystemProxyNative {
  RustSystemProxyEnableResult enable(int port, List<String> bypass);

  RustSystemProxyRestoreReport restore(String snapshotJson);

  /// 认领没有快照可还原的残留（见 [RustSystemProxy.claimResidual]）。
  RustSystemProxyClaimReport claimResidual(int port);
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

  @override
  RustSystemProxyClaimReport claimResidual(int port) =>
      RustSystemProxy.claimResidual(port);
}

/// 系统代理的开关门面（桌面端）。
///
/// Windows 走 Rust（`rust/bettbox-native/src/system_proxy.rs`）：打开前先把当前设置存成
/// 快照，关闭时只还原**仍归我们管**的连接。旧实现（Flutter 插件 `plugins/proxy`）关闭时
/// 无差别把 `ProxyEnable` 置 0，会连带清掉其他程序设置的系统代理。
///
/// 快照缺失时的两条兜底（§108 未决⑪的收尾）：
///   - **升级过渡期 / 偏好丢失**：旧版本从不写快照，残留可能指向本应用端口。
///     没有快照时不直接放过，而是按 [SystemProxyNative.claimResidual] 认领
///     「正好是本应用会写的 `127.0.0.1:<port>`、显式代理开着、端口已无监听」的
///     残留；端口有人监听（别的代理客户端占着）不碰。
///   - **被强杀到下次启动**：启用成功后同步写一份看门狗快照（[ProxyGuard]），
///     应用进程被强杀时由 `BettboxProxyGuard` 在进程死后就地还原，不必等下次启动。
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

  /// 看门狗（ProxyManager 挂载时拉起）；测试里换成替身，避免真的拉起守护进程。
  static ProxyGuard guard = const NativeProxyGuard();

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
    // 「用户原有的设置」存进新快照。没有快照时按 port 认领升级过渡期的残留。
    await _restorePersisted(reason: 'enable', claimPort: port);

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
  ///
  /// [port] 传入时，没有快照也会按它认领残留（ProxyManager 启动对账那条路）；
  /// 退出流程拿不到端口就不认领——那种情形下次启动照样会认领。
  static Future<void> disable({int? port}) async {
    if (!system.isWindows) {
      try {
        await proxy?.stopProxy();
      } catch (error) {
        commonPrint.log('关闭系统代理失败：$error');
      }
      return;
    }
    await _restorePersisted(reason: 'disable', claimPort: port);
  }

  static Future<void> _restorePersisted({
    required String reason,
    int? claimPort,
  }) async {
    final prefs = await preferences.sharedPreferencesCompleter.future;
    final snapshotJson = prefs?.getString(snapshotKey);
    if (snapshotJson == null) {
      // 没有快照通常意味着「本应用没改过系统代理」——什么都不做（旧实现在这里会
      // 无差别清掉别的程序设置的系统代理）。但升级过渡期与偏好丢失会留下指向
      // 本应用端口的残留，这里按端口认领（端口活着的不碰）。
      if (claimPort != null) {
        await _claimResidual(claimPort, reason);
      }
      return;
    }

    try {
      final report = native.restore(snapshotJson);
      for (final warning in report.warnings) {
        commonPrint.log('系统代理还原：$warning');
      }
      // 看门狗快照先删：万一随后被强杀，看门狗最多多跑一次幂等还原。
      await guard.clearPayload();
      await prefs?.remove(snapshotKey);
      commonPrint.log(
        '系统代理已还原（$reason）：${report.restored} 项，跳过 ${report.skipped} 项',
      );
    } catch (error) {
      // 快照留着，下次启动或关闭时再试。
      commonPrint.log('还原系统代理失败（$reason）：$error');
    }
  }

  /// 没有快照时认领「指向本应用端口且端口已死」的残留；失败只记日志。
  static Future<void> _claimResidual(int port, String reason) async {
    try {
      final report = native.claimResidual(port);
      for (final warning in report.warnings) {
        commonPrint.log('系统代理残留认领：$warning');
      }
      if (report.claimed > 0) {
        commonPrint.log(
          '系统代理残留已认领（$reason）：${report.claimed} 项，127.0.0.1:$port',
        );
      } else if (report.listening) {
        commonPrint.log(
          '系统代理残留认领跳过（$reason）：127.0.0.1:$port 有监听',
        );
      }
    } catch (error) {
      commonPrint.log('认领系统代理残留失败（$reason）：$error');
    }
  }

  static Future<void> _saveSnapshot(String snapshotJson) async {
    // 看门狗那份先写：中途被强杀时它能立刻接手还原，偏好设置那份留给下次启动。
    await guard.writePayload(snapshotJson);
    final prefs = await preferences.sharedPreferencesCompleter.future;
    await prefs?.setString(snapshotKey, snapshotJson);
  }
}
