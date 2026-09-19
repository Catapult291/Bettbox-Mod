import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 侧栏底部的常驻快捷控制：出站模式、系统代理、虚拟网卡。
///
/// 与首页的 [OutboundModeV2] 共用模式配色，与托盘菜单共用核心状态判断
/// （核心未启动时系统代理与虚拟网卡不可切换）。
///
/// 注意：侧栏位于 `MaterialApp.builder`（Navigator 之上），此位置没有 Overlay，
/// 不能用 [Tooltip]，否则抛 “No Overlay widget found” 并让整个界面变成错误屏；
/// 这里只给按钮加 [Semantics] 标注，悬停反馈交给 Material 自带的高亮。
class SidebarQuickControl extends ConsumerWidget {
  const SidebarQuickControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCoreRunning = ref.watch(
      runTimeProvider.select((state) => state != null),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _ModeButton(),
        // 系统代理与虚拟网卡是桌面专属（与首页 DashboardWidget 的平台限定一致）
        if (system.isDesktop) ...[
          const SizedBox(height: 6),
          _ToggleButton(
            label: appLocalizations.systemProxy,
            icon: Icons.shuffle,
            value: ref.watch(
              networkSettingProvider.select((state) => state.systemProxy),
            ),
            onPressed: isCoreRunning
                ? () => globalState.appController.updateSystemProxy()
                : null,
          ),
          const SizedBox(height: 6),
          _ToggleButton(
            label: appLocalizations.tun,
            icon: Icons.stacked_line_chart,
            value: ref.watch(
              patchClashConfigProvider.select((state) => state.tun.enable),
            ),
            onPressed: isCoreRunning
                ? () => globalState.appController.updateTun()
                : null,
          ),
        ],
        const SizedBox(height: 8),
      ],
    );
  }
}

class _ModeButton extends ConsumerWidget {
  const _ModeButton();

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
    return _QuickButton(
      label: '${appLocalizations.outboundMode} · ${_modeLabel(mode)}',
      icon: Icons.swap_horiz,
      background: background,
      foreground: foreground,
      onPressed: () => globalState.appController.updateMode(),
    );
  }
}

class _ToggleButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool value;
  final VoidCallback? onPressed;

  const _ToggleButton({
    required this.label,
    required this.icon,
    required this.value,
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
    );
  }
}

class _QuickButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color background;
  final Color foreground;
  final VoidCallback? onPressed;

  const _QuickButton({
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
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
  }
}
