import 'dart:async';
import 'dart:io';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/common.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';

class MemoryInfo extends StatefulWidget {
  const MemoryInfo({
    super.key,
    this.kernelMemoryBytes,
    this.appMemoryBytes,
  });

  /// 测试接缝：内核堆读数；缺省走 `clashCore.getMemory()`。
  final Future<int> Function()? kernelMemoryBytes;

  /// 测试接缝：本进程内存读数；缺省按平台取专用工作集 / `ProcessInfo.currentRss`。
  final int Function()? appMemoryBytes;

  /// 清掉静态读数缓存（卡片用静态字段避免重建时闪 0），供测试隔离用例。
  @visibleForTesting
  static void debugResetCache() => _MemoryInfoState.debugResetCache();

  @override
  State<MemoryInfo> createState() => _MemoryInfoState();
}

class _MemoryInfoState extends State<MemoryInfo> {
  late final VoidCallback _tickListener;
  // Cache last memory value to avoid showing 0 on rebuild
  static TrafficValue _lastMemoryValue = TrafficValue(value: 0);
  TrafficValue _memoryValue = _lastMemoryValue;

  /// 本应用自身的内存。Windows 上取专用工作集（任务管理器「内存」列同口径），
  /// 其余平台取 `ProcessInfo.currentRss`；内核内存由 [clashCore.getMemory]
  /// 单列，两者含义不同故分开显示。
  static TrafficValue _lastAppMemoryValue = TrafficValue(value: 0);
  TrafficValue _appMemoryValue = _lastAppMemoryValue;
  Timer? _initTimer;
  bool _isUpdating = false;

  static void debugResetCache() {
    _lastMemoryValue = TrafficValue(value: 0);
    _lastAppMemoryValue = TrafficValue(value: 0);
  }

  /// 内核读数的限时等待：`getMemory` 的 invoke 没有超时，内核进程死亡而
  /// socket 半死时回包永远不会到——不限时会让 `_isUpdating` 卡死，
  /// 整张卡片（含应用读数）一起冻结（§25 实测）。取值需小于 2s 刷新周期，
  /// 保证病态下应用读数仍按 tick 前进。
  static const _kernelReadTimeout = Duration(milliseconds: 1500);

  Future<int> _readKernelMemory() =>
      widget.kernelMemoryBytes?.call() ?? clashCore.getMemory();

  int _readAppMemory() {
    final override = widget.appMemoryBytes;
    if (override != null) return override();
    final privateWorkingSet = windows?.currentPrivateWorkingSet();
    if (privateWorkingSet != null) return privateWorkingSet;
    return ProcessInfo.currentRss;
  }

  @override
  void initState() {
    super.initState();
    _tickListener = _updateMemory;
    dashboardRefreshManager.tick2s.addListener(_tickListener);

    // Get immediately on first open, otherwise delay 1000ms
    if (_lastMemoryValue.value == 0) {
      _retryUpdateMemory();
    } else {
      // Has cached value, delay
      _initTimer = Timer(const Duration(milliseconds: 1000), _updateMemory);
    }
  }

  Future<void> _retryUpdateMemory() async {
    for (int i = 0; i < 5; i++) {
      if (!mounted) return;
      await _updateMemory();
      if (_memoryValue.value > 0) break;
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  @override
  void dispose() {
    _initTimer?.cancel();
    dashboardRefreshManager.tick2s.removeListener(_tickListener);
    super.dispose();
  }

  Future<void> _updateMemory() async {
    if (!mounted) return;
    if (_isUpdating) return;
    _isUpdating = true;

    try {
      // 应用读数与内核无关，先读先上屏：内核 IPC 挂死也不拖住它（§25/A⑥）。
      final appMemoryValue = _readAppMemory();
      if (appMemoryValue > 0 && mounted) {
        setState(() {
          _appMemoryValue = TrafficValue(value: appMemoryValue);
          _lastAppMemoryValue = _appMemoryValue;
        });
      }

      // 内核读数限时等待：超时/不可达按 0 →「内核」保持上次有效值不闪 0。
      int kernelMemoryValue = 0;
      try {
        kernelMemoryValue = await _readKernelMemory().timeout(
          _kernelReadTimeout,
        );
      } catch (_) {
        // 超时或抛错都按不应答处理
      }
      if (!mounted) return;

      if (kernelMemoryValue > 0) {
        setState(() {
          _memoryValue = TrafficValue(value: kernelMemoryValue);
          _lastMemoryValue = _memoryValue;
        });
      }
    } catch (e) {
      // Ignore error, keep current value
    } finally {
      _isUpdating = false;
    }
  }

  Future<void> _showMemoryInfoDialog(BuildContext context) async {
    await globalState.showCommonDialog<void>(
      child: CommonDialog(
        title: appLocalizations.memoryInfo,
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context, rootNavigator: true).pop();
            },
            child: Text(appLocalizations.confirm),
          ),
        ],
        child: Text(appLocalizations.memoryInfoDesc),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: getWidgetHeight(1),
      child: CommonCard(
        onLongPress: () async {
          // Show confirmation dialog
          final result = await globalState.showCommonDialog<bool>(
            child: CommonDialog(
              title: appLocalizations.forceGCTitle,
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context, rootNavigator: true).pop(false);
                  },
                  child: Text(appLocalizations.cancel),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.of(context, rootNavigator: true).pop(true);
                  },
                  child: Text(appLocalizations.confirm),
                ),
              ],
              child: Text(appLocalizations.forceGCDesc),
            ),
          );

          // Execute force GC after user confirms
          if (result == true) {
            await clashCore.requestGc(forceFreeOSMemory: true);
            globalState.showNotifier(appLocalizations.success);
          }
        },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              height: globalState.measure.titleMediumHeight + 16,
              padding: baseInfoEdgeInsets.copyWith(bottom: 0),
              child: Row(
                mainAxisSize: MainAxisSize.max,
                children: [
                  Icon(
                    Icons.memory,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    flex: 1,
                    child: TooltipText(
                      text: Text(
                        appLocalizations.memoryInfo,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: context.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  AspectRatio(
                    aspectRatio: 1,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      onPressed: () => _showMemoryInfoDialog(context),
                      icon: Icon(
                        size: 16.ap,
                        Icons.info_outline,
                        color: context.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: baseInfoEdgeInsets.copyWith(top: 0),
              child: Column(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: globalState.measure.bodyMediumHeight + 2,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${appLocalizations.app} ${_appMemoryValue.shortShow}',
                            style: context.textTheme.bodyMedium
                                ?.toLight
                                .adjustSize(1),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '·',
                            style: context.textTheme.labelMedium?.toLight,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${appLocalizations.core} ${_memoryValue.shortShow}',
                            style: context.textTheme.labelMedium?.toLight,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}