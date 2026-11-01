import 'package:bett_box/common/common.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/profiles/scripts.dart';
import 'package:bett_box/widgets/sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';

/// 快捷控制栏的宽度，与左侧 `NavigationRail` 的默认宽度（minWidth = 72）对齐，
/// 因此左右两条栏的宽度一致。
const quickRailWidth = 72.0;

/// 单个控件（图标方块）的边长。
const quickControlSize = 44.0;

/// 快捷控制：总开关、系统代理、虚拟网卡、脚本。
///
/// [showCaption] 为 true 时每个控件下方带一行小字标签（右侧栏用，右栏宽度有限，
/// 标签固定四字，故用比正文更小的字号）；为 false 时只有图标方块。
///
/// 与托盘菜单共用核心状态判断（核心未启动时系统代理与虚拟网卡不可切换）。
/// 首个控件是总开关，它也是右栏唯一能启动核心的入口——核心没跑时下面三个
/// 控件都不可用；右栏的上边距就是按它（44px 方块）的中心对到左栏「首页」的
/// 图标中心算出来的。
///
/// 注意：侧栏位于 `MaterialApp.builder`（Navigator 之上），此位置没有 Overlay，
/// 不能用 [Tooltip]，否则抛 “No Overlay widget found” 并让整个界面变成错误屏；
/// 这里只给按钮加 [Semantics] 标注，悬停反馈交给 Material 自带的高亮。
class QuickControls extends ConsumerWidget {
  final bool showCaption;

  const QuickControls({super.key, this.showCaption = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCoreRunning = ref.watch(
      runTimeProvider.select((state) => state != null),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 总开关排在最上：它是下面三个控件的前提，位置不再变动（右栏以它为对齐基准）
        _PowerButton(showCaption: showCaption),
        // 系统代理与虚拟网卡是桌面专属（与首页 DashboardWidget 的平台限定一致）
        if (system.isDesktop) ...[
          const SizedBox(height: 16),
          _ToggleButton(
            label: appLocalizations.systemProxy,
            icon: Icons.shuffle,
            showCaption: showCaption,
            value: ref.watch(
              networkSettingProvider.select((state) => state.systemProxy),
            ),
            onPressed: isCoreRunning
                ? () => globalState.appController.updateSystemProxy()
                : null,
          ),
          const SizedBox(height: 16),
          _ToggleButton(
            label: appLocalizations.tun,
            icon: Icons.stacked_line_chart,
            showCaption: showCaption,
            value: ref.watch(
              patchClashConfigProvider.select((state) => state.tun.enable),
            ),
            onPressed: isCoreRunning
                ? () => globalState.appController.updateTun()
                : null,
          ),
        ],
        const SizedBox(height: 16),
        _ScriptButton(showCaption: showCaption),
      ],
    );
  }
}

/// 总开关：启动 / 停止核心，与首页「电源开关」卡片、首页顶栏开关、托盘菜单同一个入口。
///
/// 停在核心时右栏只剩它能点，所以它同时充当「核心在跑没跑」的常驻指示——运行中
/// 用 `primary` 底色 + `primary` 图标，与右栏两个开关的开启态是同一表达式。
///
/// 无配置 / 初始化未完成 / 重启核心中 / 被智能停机挂起时不可点（与首页两处同口径）；
/// 这里不去开「添加配置」弹层——右栏位于 `MaterialApp.builder` 之上，没有 Navigator 祖先。
class _PowerButton extends ConsumerStatefulWidget {
  final bool showCaption;

  const _PowerButton({required this.showCaption});

  @override
  ConsumerState<_PowerButton> createState() => _PowerButtonState();
}

class _PowerButtonState extends ConsumerState<_PowerButton> {
  bool _isDisabled = false;
  bool? _optimisticStart;

  Future<void> _handleStart() async {
    if (_isDisabled) return;
    final newState = ref.read(runTimeProvider) == null;
    setState(() {
      _isDisabled = true;
      _optimisticStart = newState;
    });
    try {
      await globalState.appController
          .updateStatus(newState)
          .timeout(
            updateStatusTimeout,
            onTimeout: () {
              commonPrint.log('updateStatus did not return in time');
            },
          );
    } catch (e) {
      commonPrint.log('updateStatus failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isDisabled = false;
          _optimisticStart = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final state = ref.watch(startButtonSelectorStateProvider);
    final isRestarting = ref.watch(isRestartingCoreProvider);
    final isBusy = ref.watch(isCoreBusyProvider);
    final isSmartStopped = ref.watch(isSmartStoppedProvider);
    final isStart = ref.watch(runTimeProvider.select((value) => value != null));
    final displayStart = isSmartStopped ? false : (_optimisticStart ?? isStart);

    // 有没有可切换的对象：没配置 / 还没初始化 / 被智能停机挂起时显示为禁用灰
    final usable = state.isInit && state.hasProfile && !isSmartStopped;
    final canPress = usable && !_isDisabled && !isRestarting && !isBusy;

    Color background = Colors.transparent;
    Color foreground = colorScheme.onSurfaceVariant;
    if (isRestarting || isBusy) {
      // 内核启停/自动恢复过程中：用运行中的配色 + 转圈，明确告诉用户"在处理，
      // 别退出应用"。以前这里只是变灰禁用，用户会当成开关又卡死而直接退出。
      final isLight = colorScheme.brightness == Brightness.light;
      background = colorScheme.primary.withValues(alpha: isLight ? 0.20 : 0.26);
      foreground = colorScheme.primary;
    } else if (!usable) {
      foreground = colorScheme.onSurfaceVariant.withValues(alpha: 0.38);
    } else if (displayStart) {
      // 启动过程中（_isDisabled）保持运行中的配色，避免中途闪成灰的
      final isLight = colorScheme.brightness == Brightness.light;
      background = colorScheme.primary.withValues(alpha: isLight ? 0.20 : 0.26);
      foreground = colorScheme.primary;
    }

    return _QuickButton(
      label: appLocalizations.powerSwitch,
      icon: Icons.power_settings_new,
      loading: isRestarting || isBusy || _isDisabled,
      background: background,
      foreground: foreground,
      onPressed: canPress ? _handleStart : null,
      under: widget.showCaption
          ? _Caption(title: appLocalizations.powerSwitch)
          : null,
    );
  }
}

/// 脚本按钮：开关式入口——点一下弹出脚本页，再点一下收回。
///
/// 与配置页右上角的脚本按钮同一个入口（把 [ScriptsView] 推到根导航；右栏位于
/// `MaterialApp.builder` 之上、自身没有 Navigator 祖先，必须显式取根导航操作）。
/// 不随「脚本覆写生效」高亮：右栏管的是「弹出/收回脚本页」这个动作，覆写状态
/// 在配置页与弹层内部自有反馈，这里常亮反而会被当成另一个常开的开关。
class _ScriptButton extends StatefulWidget {
  final bool showCaption;

  const _ScriptButton({required this.showCaption});

  @override
  State<_ScriptButton> createState() => _ScriptButtonState();
}

class _ScriptButtonState extends State<_ScriptButton> {
  /// 脚本页是否已由本按钮弹出；弹层无论以何种方式关闭（遮罩、关闭钮、返回键）
  /// 都会经 [Future] 把它复位，下一次点击重新弹出。
  bool _scriptsOpen = false;

  void _toggleScripts() {
    final navigator = globalState.navigatorKey.currentState;
    if (navigator == null) return;
    if (_scriptsOpen) {
      // 已弹出：收一层。用 maybePop 让编辑器这类带返回拦截的页面先走自己的流程
      // （如保存提示）；脚本页回到栈顶后，下一次点击就直接收回它。
      navigator.maybePop();
      return;
    }
    final context = navigator.context;
    if (!context.mounted) return;
    final closed = showExtend(
      context,
      builder: (_, type) {
        return AdaptiveSheetScaffold(type: type, body: const ScriptsView(), title: appLocalizations.script);
      },
    );
    _scriptsOpen = true;
    closed.whenComplete(() => _scriptsOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    return _QuickButton(
      label: appLocalizations.script,
      icon: Icons.functions,
      background: Colors.transparent,
      foreground: context.colorScheme.onSurfaceVariant,
      onPressed: _toggleScripts,
      under: widget.showCaption ? _Caption(title: appLocalizations.script) : null,
    );
  }
}

class _ToggleButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool value;
  final bool showCaption;
  final VoidCallback? onPressed;

  const _ToggleButton({
    required this.label,
    required this.icon,
    required this.value,
    required this.showCaption,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final bool disabled = onPressed == null;
    Color background = Colors.transparent;
    Color foreground = colorScheme.onSurfaceVariant;
    if (disabled) {
      foreground = colorScheme.onSurfaceVariant.withValues(alpha: 0.38);
    } else if (value) {
      final isLight = colorScheme.brightness == Brightness.light;
      background = colorScheme.primary.withValues(alpha: isLight ? 0.20 : 0.26);
      foreground = colorScheme.primary;
    }
    return _QuickButton(
      label: label,
      icon: icon,
      background: background,
      foreground: foreground,
      onPressed: onPressed,
      under: showCaption ? _Caption(title: label) : null,
    );
  }
}

/// 控件下方的小字标签。栏宽有限（与左栏一致），中文四字用 labelSmall 字号正好排下，
/// 其它语言（如 `System Proxy`）允许折成两行。
class _Caption extends StatelessWidget {
  final String title;

  const _Caption({required this.title});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: context.colorScheme.onSurfaceVariant,
      height: 1.1,
    );
    return Text(title, textAlign: TextAlign.center, maxLines: 2, style: style);
  }
}

class _QuickButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color background;
  final Color foreground;
  final VoidCallback? onPressed;
  final Widget? under;

  /// 转圈代替图标：表示这件控件正在执行（右栏总开关在内核自动重启期间用）。
  final bool loading;

  const _QuickButton({
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
    this.onPressed,
    this.under,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final button = Semantics(
      label: label,
      button: true,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: quickControlSize,
            height: quickControlSize,
            child: loading
                ? Center(
                    child: OverflowBox(
                      maxWidth: 30,
                      maxHeight: 16,
                      child: SpinKitThreeBounce(color: foreground, size: 16),
                    ),
                  )
                : Icon(icon, size: 22, color: foreground),
          ),
        ),
      ),
    );
    final under = this.under;
    if (under == null) {
      return button;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [button, const SizedBox(height: 6), under],
    );
  }
}
