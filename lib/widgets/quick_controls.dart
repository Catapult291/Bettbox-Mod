import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 快捷控制栏的宽度，与左侧 `NavigationRail` 的默认宽度（minWidth = 72）对齐，
/// 因此左右两条栏的宽度一致。
const quickRailWidth = 72.0;

/// 单个控件（图标方块）的边长。
const quickControlSize = 44.0;

/// 快捷控制：总开关、系统代理、虚拟网卡、出站模式。
///
/// [showCaption] 为 true 时每个控件下方带一行小字标签（右侧栏用，右栏宽度有限，
/// 标签固定四字，故用比正文更小的字号）；为 false 时只有图标方块。
///
/// 与首页的 [OutboundModeV2] 共用模式配色，与托盘菜单共用核心状态判断
/// （核心未启动时系统代理与虚拟网卡不可切换）。首个控件是总开关，它也是右栏
/// 唯一能启动核心的入口——核心没跑时下面三个控件都不可用；右栏的上边距就是
/// 按它（44px 方块）的中心对到左栏「首页」的图标中心算出来的。
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
        _ModeButton(showCaption: showCaption),
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
    final isSmartStopped = ref.watch(isSmartStoppedProvider);
    final isStart = ref.watch(runTimeProvider.select((value) => value != null));
    final displayStart = isSmartStopped ? false : (_optimisticStart ?? isStart);

    // 有没有可切换的对象：没配置 / 还没初始化 / 被智能停机挂起时显示为禁用灰
    final usable = state.isInit && state.hasProfile && !isSmartStopped;
    final canPress = usable && !_isDisabled && !isRestarting;

    Color background = Colors.transparent;
    Color foreground = colorScheme.onSurfaceVariant;
    if (!usable) {
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
      background: background,
      foreground: foreground,
      onPressed: canPress ? _handleStart : null,
      under: widget.showCaption
          ? _Caption(title: appLocalizations.powerSwitch)
          : null,
    );
  }
}

class _ModeButton extends ConsumerWidget {
  final bool showCaption;

  const _ModeButton({required this.showCaption});

  String _modeLabel(Mode mode) {
    return switch (mode) {
      Mode.rule => appLocalizations.rule,
      Mode.global => appLocalizations.global,
      Mode.direct => appLocalizations.direct,
    };
  }

  /// 模式名在侧栏底色上的文字色。
  ///
  /// 图标方块的前景色（`on*Container`）是配方块自身 `*Container` 底色挑的：
  /// `content` 配色下 `onPrimaryContainer` / `onTertiaryContainer` 接近白色，
  /// 直接当侧栏底色上的小字用对比度只有约 1.2:1（几乎看不见）。同色族的
  /// `primary` / `secondary` / `tertiary` 才是给底色上的强调文字用的，各配色
  /// （含深浅两套）相对侧栏底色 `surfaceContainerHigh` 都在 5:1 以上。
  Color _captionColor(BuildContext context, Mode mode) {
    final colorScheme = context.colorScheme;
    return switch (mode) {
      Mode.rule => colorScheme.secondary,
      Mode.global => colorScheme.primary,
      Mode.direct => colorScheme.tertiary,
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(
      patchClashConfigProvider.select((state) => state.mode),
    );
    final colorScheme = context.colorScheme;
    final Color background;
    final Color foreground;
    switch (mode) {
      case Mode.rule:
        background = colorScheme.secondaryContainer;
        foreground = colorScheme.onSecondaryContainer;
      case Mode.global:
        background = globalState.theme.darken3PrimaryContainer;
        foreground = colorScheme.onPrimaryContainer;
      case Mode.direct:
        background = colorScheme.tertiaryContainer;
        foreground = colorScheme.onTertiaryContainer;
    }
    final modeName = _modeLabel(mode);
    return _QuickButton(
      label: '${appLocalizations.outboundMode} · $modeName',
      icon: Icons.swap_horiz,
      background: background,
      foreground: foreground,
      onPressed: () => globalState.appController.updateMode(),
      // 模式名单独一行显示，只靠方块颜色不易记
      under: showCaption
          ? _Caption(
              title: appLocalizations.outboundMode,
              value: modeName,
              valueColor: _captionColor(context, mode),
            )
          : null,
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
/// 其它语言（如 `Outbound Mode`）允许折成两行。
class _Caption extends StatelessWidget {
  final String title;
  final String? value;
  final Color? valueColor;

  const _Caption({required this.title, this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: context.colorScheme.onSurfaceVariant,
      height: 1.1,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, textAlign: TextAlign.center, maxLines: 2, style: style),
        if (value != null)
          Text(
            value!,
            textAlign: TextAlign.center,
            maxLines: 1,
            style: style?.copyWith(
              color: valueColor,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }
}

class _QuickButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color background;
  final Color foreground;
  final VoidCallback? onPressed;
  final Widget? under;

  const _QuickButton({
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
    this.onPressed,
    this.under,
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
            child: Icon(icon, size: 22, color: foreground),
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
