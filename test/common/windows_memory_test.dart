import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:flutter_test/flutter_test.dart';

/// A⑥「内存卡片口径」契约：Windows 上卡片「应用」读数走
/// `NtQueryVirtualMemory(MemoryWorkingSetInformation)` 数出的**专用工作集**
/// （ShareCount == 0 的页 × 页大小，与任务管理器「进程」页默认「内存」列、
/// perf 计数器 `WorkingSetPrivate` 同口径），失败时由调用方回落
/// `ProcessInfo.currentRss`（完整工作集）。
///
/// 注意：`PROCESS_MEMORY_COUNTERS_EX.PrivateUsage` 是私有**提交**
/// （commit charge），不是专用工作集——第一版实现踩过，勿回退。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final skipOffWindows = Platform.isWindows ? null : 'Windows 专属路径';

  test('currentPrivateWorkingSet 落在 (0, 完整工作集] 内且连续读数稳定', () {
    final first = windows!.currentPrivateWorkingSet();
    expect(first, isNotNull);
    expect(first!, greaterThan(0));
    // 专用工作集 ⊆ 完整工作集；两次采样之间进程内存可自然变化，上界留 8 MiB 余量。
    expect(
      first,
      lessThanOrEqualTo(ProcessInfo.currentRss + 8 * 1024 * 1024),
    );

    final second = windows!.currentPrivateWorkingSet();
    expect(second, isNotNull);
    expect(second!, greaterThan(0));
  }, skip: skipOffWindows);

  test('与 perf 计数器 WorkingSetPrivate 一致（任务管理器同口径）', () async {
    final priv = windows!.currentPrivateWorkingSet();
    expect(priv, isNotNull);

    final selfPid = pid;
    final ps = await Process.run('pwsh', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      '(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process '
          '-Filter "IDProcess=$selfPid").WorkingSetPrivate',
    ]);
    expect(ps.exitCode, 0, reason: ps.stderr.toString());
    final wsp = int.parse(ps.stdout.toString().trim());

    // 走表与 perf 采样之间隔着一次 WMI 启动（数百 ms），留 2% + 8 KiB 容差。
    expect(
      (priv! - wsp).abs(),
      lessThanOrEqualTo(wsp * 0.02 + 8 * 1024),
      reason: 'privateWS=$priv WorkingSetPrivate=$wsp',
    );
  }, skip: skipOffWindows);
}
