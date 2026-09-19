import 'dart:async';

import 'package:bett_box/clash/core.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/manager/window_manager.dart';
import 'package:bett_box/plugins/app.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/quick_controls.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AppStateManager extends ConsumerStatefulWidget {
  final Widget child;

  const AppStateManager({super.key, required this.child});

  @override
  ConsumerState<AppStateManager> createState() => _AppStateManagerState();
}

class _AppStateManagerState extends ConsumerState<AppStateManager>
    with WidgetsBindingObserver {
  bool _isRefreshActive = false;
  Timer? _dashboardRefreshDebounceTimer;
  Timer? _missedUpdateCheckTimer;
  DateTime? _lastMissedUpdateCheck;
  late final VoidCallback _dashboardTickListener;

  static const _missedUpdateCheckDelay = Duration(seconds: 5);
  static const _missedUpdateCheckThrottle = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _dashboardTickListener = () {
      if (!globalState.isStart) {
        return;
      }
      unawaited(globalState.appController.updateRunTime());
    };
    dashboardRefreshManager.tick1s.addListener(_dashboardTickListener);
    ref.listenManual(layoutChangeProvider, (prev, next) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (prev != next) {
          globalState.computeHeightMapCache = {};
        }
      });
    });
    ref.listenManual(checkIpProvider, (prev, next) {
      if (next.b && (prev?.a != next.a)) {
        detectionState.startCheck();
      }
    });
    ref.listenManual(configStateProvider, (prev, next) {
      if (prev != next) {
        globalState.appController.savePreferencesDebounce();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateDashboardRefreshState();
      detectionState.tryStartCheck();
      globalState.appController.updateGroupsDebounce();
    });
    if (window == null) {
      return;
    }
    ref.listenManual(autoSetSystemDnsStateProvider, (prev, next) async {
      if (prev == next) {
        return;
      }
      final shouldSet = next.a == true && next.b == true;
      await macOS?.updateDns(!shouldSet);
    });
    ref.listenManual(currentBrightnessProvider, (prev, next) {
      if (prev == next) {
        return;
      }
      window?.updateMacOSBrightness(next);
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _dashboardRefreshDebounceTimer?.cancel();
    _missedUpdateCheckTimer?.cancel();
    dashboardRefreshManager.tick1s.removeListener(_dashboardTickListener);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _updateDashboardRefreshState() async {
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    final isForeground =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    var isVisible = true;
    var isMinimized = false;
    if (system.isDesktop) {
      final visible = await window?.isVisible;
      if (visible == false) {
        isVisible = false;
      }
      isMinimized = await window?.isMinimized ?? false;
    }
    final isPinned = system.isDesktop &&
        ref.read(windowSettingProvider.select((s) => s.isPinned));
    final shouldRun = system.isDesktop
        ? (isPinned || (isVisible && !isMinimized))
        : isForeground;

    if (!shouldRun) {
      _dashboardRefreshDebounceTimer?.cancel();
      _dashboardRefreshDebounceTimer = null;
      if (_isRefreshActive) {
        dashboardRefreshManager.stop();
        _isRefreshActive = false;
      }
      return;
    }

    if (_isRefreshActive) {
      return;
    }

    _dashboardRefreshDebounceTimer?.cancel();
    _dashboardRefreshDebounceTimer = Timer(
      const Duration(milliseconds: 1000),
      () {
        if (!mounted) return;
        if (_isRefreshActive) return;
        dashboardRefreshManager.start();
        _isRefreshActive = true;
      },
    );
  }

  bool get _shouldCheckMissedUpdates {
    if (_lastMissedUpdateCheck == null) return true;
    return DateTime.now().difference(_lastMissedUpdateCheck!) >
        _missedUpdateCheckThrottle;
  }

  void _scheduleMissedUpdateCheck() {
    if (!_shouldCheckMissedUpdates) return;
    _missedUpdateCheckTimer?.cancel();
    _missedUpdateCheckTimer = Timer(_missedUpdateCheckDelay, () {
      _lastMissedUpdateCheck = DateTime.now();
      globalState.appController.checkAndUpdateMissedProfiles();
    });
  }

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    final isBackgroundState =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        (state == AppLifecycleState.inactive && !system.isDesktop);

    if (isBackgroundState) {
      _missedUpdateCheckTimer?.cancel();
      globalState.appController.savePreferences();
      await globalState.handleBackground();
    } else if (state == AppLifecycleState.resumed) {
      globalState.handleForeground();
      render?.resume();
      await globalState.resumeForegroundUpdates();
      await globalState.appController.syncWakelockIfNeeded();
      _scheduleMissedUpdateCheck();
      final isInit = await clashCore.isInit;
      if (isInit) {
        globalState.appController.updateGroupsDebounce();
      }

      final hasDetection = ref
          .read(dashboardStateProvider)
          .dashboardWidgets
          .contains(DashboardWidget.networkDetection);
      if (hasDetection) {
        detectionState.tryStartCheck();
      }
    }
    if (state == AppLifecycleState.resumed && system.isAndroid) {
      final hidden = ref.read(appSettingProvider.select((s) => s.hidden));
      app.updateExcludeFromRecents(hidden);
      SystemChrome.setSystemUIOverlayStyle(
        globalState.appState.systemUiOverlayStyle,
      );
    }
    if (state == AppLifecycleState.inactive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        detectionState.tryStartCheck();
      });
    }
    _updateDashboardRefreshState();
  }

  @override
  void didChangePlatformBrightness() {
    globalState.appController.updateBrightness();
    globalState.appController.updateTray();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

class AppEnvManager extends StatelessWidget {
  final Widget child;

  const AppEnvManager({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (kDebugMode) {
      if (globalState.isPre) {
        return Banner(
          message: 'DEBUG',
          location: BannerLocation.topEnd,
          child: child,
        );
      }
    }
    if (globalState.isPre) {
      return Banner(
        message: 'PRE',
        location: BannerLocation.topEnd,
        child: child,
      );
    }
    return child;
  }
}

class AppSidebarContainer extends ConsumerStatefulWidget {
  final Widget child;

  const AppSidebarContainer({super.key, required this.child});

  @override
  ConsumerState<AppSidebarContainer> createState() =>
      _AppSidebarContainerState();
}

class _AppSidebarContainerState extends ConsumerState<AppSidebarContainer> {
  /// 左侧导航栏的实际宽度（含它的 1px 右边框）。`NavigationRail` 的宽度会随
  /// 导航项标签长度（不同语言）变化，右侧快捷栏要跟它对齐，所以运行时量一次。
  final GlobalKey _railKey = GlobalKey();

  /// 左栏第一个导航项（首页）的图标，用来把右栏首个控件对齐到同一条水平线。
  final GlobalKey _firstDestinationKey = GlobalKey();

  double _railWidth = quickRailWidth;

  /// 右栏内容距右栏顶部的距离：首个控件（出站模式）与左栏「首页」的图标同高。
  /// 左栏的图标受平台（macOS 多 22px 的窗口按钮带）与标签长度影响，量不到时
  /// 先用与页面标题栏齐平的老位置兜底。
  double _quickControlsTop = kToolbarHeight / 2 - quickControlSize / 2;

  void _syncRailMetrics() {
    if (!mounted) return;
    final railBox = _railKey.currentContext?.findRenderObject() as RenderBox?;
    if (railBox == null || !railBox.hasSize) return;
    final width = railBox.size.width;
    if ((width - _railWidth).abs() > 0.5) {
      setState(() => _railWidth = width);
    }
    final iconBox =
        _firstDestinationKey.currentContext?.findRenderObject() as RenderBox?;
    if (iconBox == null || !iconBox.hasSize) return;
    final railTop = railBox.localToGlobal(Offset.zero).dy;
    final iconCenterY =
        iconBox.localToGlobal(iconBox.size.center(Offset.zero)).dy - railTop;
    final top = iconCenterY - quickControlSize / 2;
    if ((top - _quickControlsTop).abs() > 0.5) {
      setState(() => _quickControlsTop = top);
    }
  }

  Widget _buildLoading() {
    return Consumer(
      builder: (_, ref, _) {
        final loading = ref.watch(loadingProvider);
        final isMobileView = ref.watch(isMobileViewProvider);
        return loading && !isMobileView
            ? RotatedBox(
                quarterTurns: 1,
                child: const LinearProgressIndicator(),
              )
            : Container();
      },
    );
  }

  Widget _buildBackground({
    required BuildContext context,
    required Widget child,
  }) {
    final isLight = context.colorScheme.brightness == Brightness.light;
    return Container(
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerHigh,
        border: Border(
          right: BorderSide(
            color: context.colorScheme.outlineVariant.withValues(
              alpha: isLight ? 0.6 : 0.45,
            ),
          ),
        ),
      ),
      child: Material(color: Colors.transparent, child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final navigationState = ref.watch(navigationStateProvider);
    final navigationItems = navigationState.navigationItems;
    final isMobileView = navigationState.viewMode == ViewMode.mobile;
    if (isMobileView) {
      // 手机布局没有两条侧栏，顶栏色带铺满整宽。
      if (!system.isDesktop) return widget.child;
      return Stack(
        children: [
          widget.child,
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: kHeaderHeight,
            child: const WindowHeader(),
          ),
        ],
      );
    }
    final currentIndex = navigationState.currentIndex;
    final showLabel = ref.watch(appSettingProvider).showLabel;
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncRailMetrics());
    final content = Expanded(
      child: Stack(
        children: [
          // 页面内容：右侧让出快捷栏的宽度，页面自身的布局与只有内容区时完全一致。
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(right: _railWidth),
              child: ClipRect(
                child: MediaQuery.removePadding(
                  context: context,
                  removeLeft: true,
                  child: widget.child,
                ),
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: QuickSidebar(
              width: _railWidth - 1,
              topOffset: _quickControlsTop,
            ),
          ),
          // 顶栏（色带 + 窗口按钮）横跨「页面内容 + 右侧快捷栏」，色带因此一直延伸到窗口右边缘，
          // 窗口按钮也落在该色带的右端。这一层在快捷栏之上，遮住它顶部的一条色带。
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: kHeaderHeight,
            child: const WindowHeader(),
          ),
        ],
      ),
    );
    return Row(
      children: [
        Stack(
          key: _railKey,
          alignment: Alignment.topRight,
          children: [
            _buildBackground(
              context: context,
              child: SafeArea(
                left: true,
                top: true,
                right: false,
                bottom: false,
                child: Column(
                  children: [
                    if (system.isMacOS) const SizedBox(height: 22),
                    const SizedBox(height: 16),
                    if (!system.isMacOS) ...[
                      const AppIcon(),
                      const SizedBox(height: 12),
                    ],
                    Expanded(
                      child: ScrollConfiguration(
                        behavior: HiddenBarScrollBehavior(),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            return SingleChildScrollView(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minHeight: constraints.maxHeight,
                                ),
                                child: IntrinsicHeight(
                                  child: CallbackShortcuts(
                                    bindings: <ShortcutActivator, VoidCallback>{
                                      const SingleActivator(
                                        LogicalKeyboardKey.arrowUp,
                                      ): () {
                                        if (currentIndex > 0) {
                                          globalState.appController.toPage(
                                            navigationItems[currentIndex - 1]
                                                .label,
                                          );
                                        }
                                      },
                                      const SingleActivator(
                                        LogicalKeyboardKey.arrowDown,
                                      ): () {
                                        if (currentIndex <
                                            navigationItems.length - 1) {
                                          globalState.appController.toPage(
                                            navigationItems[currentIndex + 1]
                                                .label,
                                          );
                                        }
                                      },
                                      const SingleActivator(
                                        LogicalKeyboardKey.select,
                                      ): () {},
                                      const SingleActivator(
                                        LogicalKeyboardKey.enter,
                                      ): () {},
                                    },
                                    child: Focus(
                                      autofocus: true,
                                      child: NavigationRail(
                                        backgroundColor: Colors.transparent,
                                        indicatorColor:
                                            context.colorScheme.primary
                                                .withValues(
                                                  alpha:
                                                      context
                                                              .colorScheme
                                                              .brightness ==
                                                          Brightness.light
                                                      ? 0.20
                                                      : 0.26,
                                                ),
                                        indicatorShape:
                                            const RoundedRectangleBorder(
                                              borderRadius: BorderRadius.all(
                                                Radius.circular(16),
                                              ),
                                            ),
                                        selectedIconTheme: IconThemeData(
                                          color: context.colorScheme.primary,
                                        ),
                                        unselectedIconTheme: IconThemeData(
                                          color:
                                              context.colorScheme.onSurfaceVariant,
                                        ),
                                        selectedLabelTextStyle: context
                                            .textTheme
                                            .labelLarge!
                                            .copyWith(
                                              color: context.colorScheme.primary,
                                              fontWeight: FontWeight.w600,
                                            ),
                                        unselectedLabelTextStyle: context
                                            .textTheme
                                            .labelLarge!
                                            .copyWith(
                                              color: context
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                        destinations: [
                                          for (final (index, item)
                                              in navigationItems.indexed)
                                            NavigationRailDestination(
                                              icon: index == 0
                                                  ? KeyedSubtree(
                                                      key: _firstDestinationKey,
                                                      child: item.icon,
                                                    )
                                                  : item.icon,
                                              label: Text(
                                                item.label.localizedName,
                                              ),
                                            ),
                                        ],
                                        onDestinationSelected: (index) {
                                          final label =
                                              navigationItems[index].label;
                                          if (currentIndex == index) {
                                            final pageContext = GlobalObjectKey(
                                              label,
                                            ).currentContext;
                                            if (pageContext != null) {
                                              Navigator.of(
                                                pageContext,
                                              ).popUntil(
                                                (route) => route.isFirst,
                                              );
                                            }
                                          }
                                          globalState.appController.toPage(
                                            label,
                                          );
                                        },
                                        extended: showLabel,
                                        selectedIndex: currentIndex,
                                        labelType: showLabel
                                            ? NavigationRailLabelType.none
                                            : NavigationRailLabelType.all,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _buildLoading(),
          ],
        ),
        content,
      ],
    );
  }
}

/// 右侧快捷控制栏：宽度与左侧导航栏一致，承载出站模式 / 系统代理 / 虚拟网卡。
///
/// 与左侧栏同样只在桌面布局（非移动布局）下渲染，切换动作与托盘菜单、
/// 全局快捷键共用 `AppController` 的入口。
class QuickSidebar extends StatelessWidget {
  /// 内层内容宽度。外层容器还有 1px 左边框，调用方减掉后左右两条栏总宽一致。
  final double width;

  /// 内容距栏顶部的距离，由左栏实测得出（首个控件与左栏首个导航项同高）。
  final double topOffset;

  const QuickSidebar({super.key, required this.width, required this.topOffset});

  @override
  Widget build(BuildContext context) {
    final isLight = context.colorScheme.brightness == Brightness.light;
    return Container(
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerHigh,
        border: Border(
          left: BorderSide(
            color: context.colorScheme.outlineVariant.withValues(
              alpha: isLight ? 0.6 : 0.45,
            ),
          ),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: SafeArea(
          left: false,
          top: true,
          right: true,
          bottom: false,
          child: SizedBox(
            width: width,
            child: Column(
              children: [
                // 首个控件与左栏首个导航项（首页）的图标同高：上边距由左栏实测得到，
                // 左栏图标的位置随平台（macOS 的窗口按钮带）与标签长度变化，写死会错位。
                SizedBox(height: topOffset),
                const QuickControls(showCaption: true),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
