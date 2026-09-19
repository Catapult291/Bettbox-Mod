import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_ext/window_ext.dart';
import 'package:window_manager/window_manager.dart';

class WindowManager extends ConsumerStatefulWidget {
  final Widget child;

  const WindowManager({super.key, required this.child});

  @override
  ConsumerState<WindowManager> createState() => _WindowContainerState();
}

class _WindowContainerState extends ConsumerState<WindowManager>
    with WindowListener, WindowExtListener {
  Timer? _renderToggleTimer;
  bool? _pendingRenderResume;
  Timer? _windowGeometryTimer;
  int _windowGeometryRevision = 0;

  void _scheduleRenderToggle(bool resume) {
    _pendingRenderResume = resume;
    _renderToggleTimer?.cancel();
    _renderToggleTimer = Timer(const Duration(milliseconds: 500), () {
      if (_pendingRenderResume == true) {
        render?.resume();
      } else {
        render?.pause();
      }
    });
  }

  void _scheduleWindowGeometryCapture() {
    final revision = ++_windowGeometryRevision;
    _windowGeometryTimer?.cancel();
    _windowGeometryTimer = Timer(const Duration(milliseconds: 125), () async {
      if (!mounted || revision != _windowGeometryRevision) return;
      final isAbnormal = (await windowManager.isMaximized()) ||
          (await windowManager.isFullScreen()) ||
          (await windowManager.isMinimized());
      if (isAbnormal) return;

      final bounds = await windowManager.getBounds();
      if (!bounds.width.isFinite ||
          !bounds.height.isFinite ||
          bounds.width <= 0 ||
          bounds.height <= 0) {
        return;
      }
      if (!bounds.left.isFinite || !bounds.top.isFinite) return;

      ref.read(windowSettingProvider.notifier).updateState(
            (state) => state.copyWith(
              width: bounds.width,
              height: bounds.height,
              left: bounds.left,
              top: bounds.top,
            ),
          );
    });
  }

  void _invalidateWindowGeometryCapture() {
    _windowGeometryRevision++;
    _windowGeometryTimer?.cancel();
    _windowGeometryTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

  ProviderSubscription? _autoLaunchSub;

  @override
  void initState() {
    super.initState();
    _autoLaunchSub = ref.listenManual(
      appSettingProvider.select((state) => state.autoLaunch),
      (prev, next) {
        if (prev != next) {
          debouncer.call(FunctionTag.autoLaunch, () {
            autoLaunch?.updateStatus(next);
          });
        }
      },
    );
    windowExtManager.addListener(this);
    windowManager.addListener(this);
  }

  @override
  void onWindowClose() async {
    globalState.appController.unBackBlock();
    await globalState.appController.handleBackOrExit();
  }

  @override
  Future<void> onShouldTerminate() async {
    await globalState.appController.handleExit();
    super.onShouldTerminate();
  }

  @override
  void onWindowMove() {
    super.onWindowMove();
    _scheduleWindowGeometryCapture();
  }

  @override
  void onWindowMoved() {
    super.onWindowMoved();
    _scheduleWindowGeometryCapture();
  }

  @override
  void onWindowResize() {
    super.onWindowResize();
    _scheduleWindowGeometryCapture();
  }

  @override
  void onWindowResized() {
    super.onWindowResized();
    _scheduleWindowGeometryCapture();
  }

  @override
  void onWindowMaximize() {
    _invalidateWindowGeometryCapture();
    super.onWindowMaximize();
  }

  @override
  void onWindowUnmaximize() {
    super.onWindowUnmaximize();
    _scheduleWindowGeometryCapture();
  }

  @override
  void onWindowEnterFullScreen() {
    _invalidateWindowGeometryCapture();
    super.onWindowEnterFullScreen();
  }

  @override
  void onWindowLeaveFullScreen() {
    super.onWindowLeaveFullScreen();
    _scheduleWindowGeometryCapture();
  }

  @override
  void onWindowMinimize() async {
    globalState.appController.savePreferencesDebounce();
    _renderToggleTimer?.cancel();
    await globalState.handleBackground();
    super.onWindowMinimize();
  }

  @override
  void onWindowRestore() {
    globalState.handleForeground();
    _scheduleRenderToggle(true);
    unawaited(globalState.resumeForegroundUpdates());
    unawaited(globalState.appController.syncWakelockIfNeeded());
    super.onWindowRestore();
  }

  @override
  void onTaskbarCreated() {
    globalState.appController.updateTray(true);
    super.onTaskbarCreated();
  }

  @override
  Future<void> dispose() async {
    _autoLaunchSub?.close();
    windowManager.removeListener(this);
    windowExtManager.removeListener(this);
    _renderToggleTimer?.cancel();
    _windowGeometryTimer?.cancel();
    super.dispose();
  }
}

/// 给窗口顶栏留出高度的内容容器。
///
/// 顶栏本身（色带 + 窗口按钮）由 `AppSidebarContainer` 渲染——它要横向跨过
/// 「页面内容 + 右侧快捷栏」，色带与按钮才能一直延伸到窗口右边缘，所以不在这里画；
/// 这一层只负责把内容整体下移一条色带的高度（macOS 常规桌面用系统标题栏，不下移也不画顶栏）。
class WindowHeaderContainer extends StatelessWidget {
  final Widget child;

  const WindowHeaderContainer({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (_, ref, child) {
        final isMobileView = ref.watch(isMobileViewProvider);
        final version = ref.watch(versionProvider);
        if ((version <= 10 || !isMobileView) && system.isMacOS) {
          return child!;
        }
        return Column(
          children: [
            SizedBox(height: kHeaderHeight),
            Expanded(flex: 1, child: child!),
          ],
        );
      },
      child: child,
    );
  }
}

class WindowHeader extends ConsumerStatefulWidget {
  const WindowHeader({super.key});

  @override
  ConsumerState<WindowHeader> createState() => _WindowHeaderState();
}

class _WindowHeaderState extends ConsumerState<WindowHeader> {
  final isMaximizedNotifier = ValueNotifier<bool>(false);
  final isPinNotifier = ValueNotifier<bool>(false);
  final isHoveringNotifier = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    _initNotifier();
  }

  Future<void> _initNotifier() async {
    final isMaximized = await windowManager.isMaximized();
    if (!mounted) return;
    isMaximizedNotifier.value = isMaximized;
    
    final isAlwaysOnTop = await windowManager.isAlwaysOnTop();
    if (!mounted) return;
    isPinNotifier.value = isAlwaysOnTop;
  }

  @override
  void dispose() {
    isMaximizedNotifier.dispose();
    isPinNotifier.dispose();
    isHoveringNotifier.dispose();
    super.dispose();
  }

  Future<void> _updateMaximized() async {
    final isMaximized = await windowManager.isMaximized();
    switch (isMaximized) {
      case true:
        await windowManager.unmaximize();
        break;
      case false:
        await windowManager.maximize();
        break;
    }
    isMaximizedNotifier.value = await windowManager.isMaximized();
  }

  Future<void> _updatePin() async {
    final isAlwaysOnTop = await windowManager.isAlwaysOnTop();
    final newIsPinned = !isAlwaysOnTop;
    await windowManager.setAlwaysOnTop(newIsPinned);
    isPinNotifier.value = newIsPinned;
    ref.read(windowSettingProvider.notifier).updateState(
          (state) => state.copyWith(isPinned: newIsPinned),
        );
  }

  Widget _buildActions() {
    final shouldUseHoverEffect = system.isWindows || system.isLinux;
    final alwaysShowTitleBar = ref.watch(
      vpnSettingProvider.select((state) => state.alwaysShowTitleBar),
    );

    return MouseRegion(
      onEnter: shouldUseHoverEffect
          ? (_) => isHoveringNotifier.value = true
          : null,
      onExit: shouldUseHoverEffect
          ? (_) {
              Future.delayed(const Duration(milliseconds: 100), () {
                if (mounted) {
                  isHoveringNotifier.value = false;
                }
              });
            }
          : null,
      child: ValueListenableBuilder<bool>(
        valueListenable: isHoveringNotifier,
        builder: (_, isHovering, _) {
          final showButtons =
              !shouldUseHoverEffect || alwaysShowTitleBar || isHovering;
          return Opacity(
            opacity: showButtons ? 1.0 : 0.0,
            child: IgnorePointer(
              ignoring: !showButtons,
              child: Row(
                children: [
                  ValueListenableBuilder(
                    valueListenable: isPinNotifier,
                    builder: (_, value, _) {
                      return IconButton(
                        onPressed: _updatePin,
                        icon: value
                            ? const Icon(Icons.push_pin)
                            : const Icon(Icons.push_pin_outlined),
                      );
                    },
                  ),
                  IconButton(
                    onPressed: () {
                      windowManager.minimize();
                    },
                    icon: const Icon(Icons.remove),
                  ),
                  ValueListenableBuilder(
                    valueListenable: isMaximizedNotifier,
                    builder: (_, value, _) {
                      return IconButton(
                        onPressed: () async {
                          _updateMaximized();
                        },
                        icon: value
                            ? const Icon(Icons.filter_none, size: 20)
                            : const Icon(Icons.crop_square),
                      );
                    },
                  ),
                  IconButton(
                    onPressed: () {
                      FocusManager.instance.primaryFocus?.unfocus();
                      globalState.appController.unBackBlock();
                      globalState.appController.handleBackOrExit();
                    },
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMobileView = ref.watch(isMobileViewProvider);
    final version = ref.watch(versionProvider);
    // 与 `WindowHeaderContainer` 留白的那条判断保持一致：macOS 常规桌面用系统标题栏，
    // 既不下移内容也不画自绘顶栏，所以这里整块不渲染。
    if ((version <= 10 || !isMobileView) && system.isMacOS) {
      return const SizedBox.shrink();
    }
    return Material(
      child: Stack(
        alignment: AlignmentDirectional.center,
        children: [
          Positioned(
            child: GestureDetector(
              onPanStart: (_) {
                windowManager.startDragging();
              },
              onDoubleTap: () {
                _updateMaximized();
              },
              child: Container(
                color: context.colorScheme.secondary.opacity15,
                alignment: Alignment.centerLeft,
                height: kHeaderHeight,
              ),
            ),
          ),
          if (system.isMacOS)
            const Text(appName)
          else ...[
            // 顶栏已横跨到窗口右边缘（含右侧快捷栏），按钮组直接贴右边缘。
            Positioned(right: 0, child: _buildActions()),
          ],
        ],
      ),
    );
  }
}

final sidebarIconPathProvider =
    StateNotifierProvider<SidebarIconPathNotifier, String?>((ref) {
      return SidebarIconPathNotifier();
    });

class SidebarIconPathNotifier extends StateNotifier<String?> {
  SidebarIconPathNotifier() : super(null) {
    _init();
  }

  Future<void> _init() async {
    final prefs = await preferences.sharedPreferencesCompleter.future;
    state = prefs?.getString(customSidebarIconKey);
  }

  Future<void> updatePath(String? path) async {
    state = path;
    final prefs = await preferences.sharedPreferencesCompleter.future;
    if (path == null) {
      prefs?.remove(customSidebarIconKey);
    } else {
      prefs?.setString(customSidebarIconKey, path);
    }
  }
}

class AppIcon extends ConsumerWidget {
  const AppIcon({super.key});

  Future<void> _handlePickImage(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);

    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      final file = File(path);
      final size = await file.length();
      if (size > 1024 * 1024) {
        if (context.mounted) {
          globalState.showNotifier('Image size exceeds 1MB');
        }
        return;
      }
      ref.read(sidebarIconPathProvider.notifier).updatePath(path);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final customIconPath = ref.watch(sidebarIconPathProvider);

    Widget icon;
    if (customIconPath != null && customIconPath.isNotEmpty) {
      icon = ClipOval(
        child: Image.file(
          File(customIconPath),
          width: 32,
          height: 32,
          fit: BoxFit.cover,
          cacheWidth: 64,
          cacheHeight: 64,
          errorBuilder: (_, _, _) {
            // Fallback if file load fails
            return Image.asset(
              isDark
                  ? 'assets/images/icon.png'
                  : 'assets/images/icon_light.png',
              fit: BoxFit.contain,
            );
          },
        ),
      );
    } else {
      icon = Image.asset(
        isDark ? 'assets/images/icon.png' : 'assets/images/icon_light.png',
        fit: BoxFit.contain,
      );
    }

    return GestureDetector(
      onLongPress: () => _handlePickImage(context, ref),
      child: SizedBox(width: 40, height: 40, child: icon),
    );
  }
}
