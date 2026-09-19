import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 快捷控制栏的宽度，与左侧 `NavigationRail` 的默认宽度（minWidth = 72）对齐，
/// 因此左右两条栏的宽度一致。
const quickRailWidth = 72.0;

/// 快捷控制：出站模式、系统代理、虚拟网卡。
///
/// [showCaption] 为 true 时每个控件下方带一行小字标签（右侧栏用，右栏宽度有限，
/// 标签固定四字，故用比正文更小的字号）；为 false 时只有图标方块。
///
/// 与首页的 [OutboundModeV2] 共用模式配色，与托盘菜单共用核心状态判断
/// （核心未启动时系统代理与虚拟网卡不可切换）。
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
        _ModeButton(showCaption: showCaption),
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
      ],
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
          ? _Caption(title: appLocalizations.outboundMode, value: modeName, valueColor: foreground)
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
            width: 44,
            height: 44,
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
