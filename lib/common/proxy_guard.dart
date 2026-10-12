import 'dart:io';

import 'package:bett_box/common/path.dart';
import 'package:bett_box/common/print.dart';
import 'package:bett_box/common/system.dart';

/// 系统代理看门狗的契约（Windows）。
///
/// 应用启动时 [start] 拉起 `BettboxProxyGuard.exe`（GUI 子系统、无窗口），
/// 它持有应用进程句柄等到进程退出；系统代理启用成功后 [writePayload] 写入
/// 快照文件，还原成功后 [clearPayload] 删除。看门狗醒来后按文件还原——
/// 「被强杀 → 下次启动」这段窗口不再依赖下次启动才闭合。
///
/// 与偏好设置里的 `system_proxy_snapshot` 是两份互为兜底的存储：
/// 还原逻辑自带归属判定，任何一侧多出来的一次还原都是幂等 no-op；
/// 一侧缺失时另一侧仍能兜住（偏好设置那份管下次启动，这份管进程死后）。
abstract interface class ProxyGuard {
  /// 拉起看门狗。非 Windows、可执行文件缺失或启动失败时只记日志，
  /// 退化为「等下次启动还原」的旧行为，不阻断应用。
  Future<void> start();

  /// 写入看门狗要用的快照（启用系统代理成功后调用）。
  Future<void> writePayload(String snapshotJson);

  /// 删除快照（还原成功后调用）。
  Future<void> clearPayload();
}

/// 生产实现：数据目录里的快照文件 + `Process.start(detached)` 拉起守护进程。
class NativeProxyGuard implements ProxyGuard {
  const NativeProxyGuard();

  @override
  Future<void> start() async {
    if (!system.isWindows) return;
    try {
      final executable = appPath.proxyGuardPath;
      if (!File(executable).existsSync()) {
        commonPrint.log('系统代理看门狗：可执行文件不存在（$executable）');
        return;
      }
      final snapshot = await appPath.proxyGuardSnapshotPath;
      final log = await appPath.proxyGuardLogPath;
      // 每轮只留本次会话的日志，避免跨会话无限增长。
      await _deleteIfExists(log);
      await Process.start(
        executable,
        ['--pid', '$pid', '--snapshot', snapshot, '--log', log],
        mode: ProcessStartMode.detached,
      );
      commonPrint.log('系统代理看门狗已拉起（等待本进程 $pid 退出）');
    } catch (error) {
      commonPrint.log('系统代理看门狗拉起失败：$error');
    }
  }

  @override
  Future<void> writePayload(String snapshotJson) async {
    try {
      final path = await appPath.proxyGuardSnapshotPath;
      await File(path).writeAsString(snapshotJson, flush: true);
    } catch (error) {
      // 写不进只影响「进程死后立即还原」，下次启动还有偏好设置那份兜底。
      commonPrint.log('系统代理看门狗快照写入失败：$error');
    }
  }

  @override
  Future<void> clearPayload() async {
    try {
      final path = await appPath.proxyGuardSnapshotPath;
      await _deleteIfExists(path);
    } catch (error) {
      // 删不掉时看门狗会多跑一次还原，归属判定保证它是 no-op。
      commonPrint.log('系统代理看门狗快照删除失败：$error');
    }
  }

  Future<void> _deleteIfExists(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
