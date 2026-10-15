import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/helper/helper.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 面板阴影：页面里所有分区只靠阴影表达边界，不描边。
/// 深色底用更重的黑色阴影，浅色底用轻阴影，保证两种主题都看得见分界。
BoxShadow _panelShadow(BuildContext context) {
  final dark = context.colorScheme.brightness == Brightness.dark;
  return BoxShadow(
    color: Colors.black.withValues(alpha: dark ? 0.45 : 0.10),
    blurRadius: dark ? 22 : 16,
    offset: Offset(0, dark ? 6 : 4),
  );
}

/// 无边框分区面板：纯色背景 + 圆角 + 阴影，子级裁剪进圆角。
class _ElevatedPanel extends StatelessWidget {
  const _ElevatedPanel({required this.child});

  final Widget child;
  static const double radius = 20;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [_panelShadow(context)],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: child,
      ),
    );
  }
}

/// 分区标题（与 InfoHeader 同一排版语气）。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text,
        style: context.textTheme.titleSmall?.copyWith(
          color: context.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 桌面「进程分流」（§22 轻量档）：更多 → 设置入口。
///
/// 从运行进程里多选 exe 路径，按黑名单/白名单注入 `PROCESS-PATH` 规则
/// （见 `rust/bettbox-native/src/patch_config.rs`）。不复用安卓
/// `vpnProps.accessControl`。
///
/// UI 规范：无描边（不出现 BorderSide / OutlineInputBorder / 任何边框线），
/// 分区与输入区的边界一律由阴影表达；纯色背景，不使用渐变。
class ProcessAccessView extends ConsumerWidget {
  const ProcessAccessView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(processAccessStateProvider);
    final mode = access.mode;
    final paths = access.paths;
    final scheme = context.colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _SectionLabel(appLocalizations.processAccessMode),
        _ElevatedPanel(
          child: Column(
            children: [
              for (final m in const [
                ProcessAccessMode.off,
                ProcessAccessMode.blacklist,
                ProcessAccessMode.whitelist,
              ]) ...[
                if (m != ProcessAccessMode.off)
                  Divider(indent: 62, endIndent: 16, height: 1),
                _ModeRow(
                  mode: m,
                  selected: mode == m,
                  onTap: () => _apply(context, ref, mode: m, paths: paths),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        _ElevatedPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        appLocalizations.processAccessSelectedCount(
                          paths.length,
                        ),
                        style: context.textTheme.titleMedium,
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => _openPicker(context, ref),
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(
                        appLocalizations.processAccessSelectProcesses,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, endIndent: 0),
              if (paths.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Column(
                    children: [
                      Icon(
                        Icons.apps_outlined,
                        size: 40,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        appLocalizations.processAccessEmpty,
                        style: context.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                )
              else
                for (final (index, path) in paths.indexed) ...[
                  if (index > 0) Divider(indent: 68, height: 1),
                  _SelectedPathTile(
                    path: path,
                    onRemove: () {
                      _apply(
                        context,
                        ref,
                        mode: mode == ProcessAccessMode.off
                            ? ProcessAccessMode.blacklist
                            : mode,
                        paths: paths.where((p) => p != path).toList(),
                      );
                    },
                  ),
                ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                Icons.rule_outlined,
                size: 15,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                appLocalizations.processAccessFindProcessHint,
                style: context.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _apply(
    BuildContext context,
    WidgetRef ref, {
    required ProcessAccessMode mode,
    required List<String> paths,
  }) {
    final effectiveMode =
        paths.isEmpty ? ProcessAccessMode.off : mode;
    ref.read(processAccessStateProvider.notifier).updateState(
          (state) => state.copyWith(mode: effectiveMode, paths: paths),
        );
    // 进程规则依赖内核解析路径；名单非空时强制打开查找进程。
    if (effectiveMode != ProcessAccessMode.off) {
      final clash = ref.read(patchClashConfigProvider);
      if (clash.findProcessMode != FindProcessMode.always) {
        ref.read(patchClashConfigProvider.notifier).updateState(
              (state) =>
                  state.copyWith(findProcessMode: FindProcessMode.always),
            );
      }
    }
    // 规则经 patchRawConfig 注入 rules 数组，只有全量 setup 才会重算并
    // 写运行配置；updateClashConfig 只推 UpdateParams，带不动规则。
    globalState.appController.setupClashConfigDebounce();
  }

  Future<void> _openPicker(BuildContext context, WidgetRef ref) async {
    final access = ref.read(processAccessStateProvider);
    final selected = await globalState.showCommonDialog<Set<String>>(
      child: ProcessPickerDialog(initial: access.paths.toSet()),
    );
    if (selected == null || !context.mounted) return;
    final paths = selected.where((p) => p.isNotEmpty).toList()..sort();
    _apply(
      context,
      ref,
      mode: access.mode == ProcessAccessMode.off
          ? ProcessAccessMode.blacklist
          : access.mode,
      paths: paths,
    );
  }
}

/// 模式行：图标字形 + 名称 + 选中对勾，纯色高亮，无描边。
class _ModeRow extends StatelessWidget {
  const _ModeRow({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final ProcessAccessMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final label = switch (mode) {
      ProcessAccessMode.off => appLocalizations.processAccessOff,
      ProcessAccessMode.blacklist => appLocalizations.processAccessBlacklist,
      ProcessAccessMode.whitelist => appLocalizations.processAccessWhitelist,
    };
    final icon = switch (mode) {
      ProcessAccessMode.off => Icons.power_settings_new,
      ProcessAccessMode.blacklist => Icons.block_outlined,
      ProcessAccessMode.whitelist => Icons.verified_user_outlined,
    };

    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.07)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.secondaryContainer
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  size: 20,
                  color: selected
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label, style: context.textTheme.bodyMedium),
              ),
              Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                size: 22,
                color: selected
                    ? scheme.primary
                    : scheme.outlineVariant.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectedPathTile extends StatelessWidget {
  const _SelectedPathTile({required this.path, required this.onRemove});

  final String path;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final name = path.split(RegExp(r'[\\/]')).last;
    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SizedBox(
                width: 26,
                height: 26,
                child: _ProcessIconImage(path: path),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: appLocalizations.remove,
              icon: const Icon(Icons.close, size: 18),
              color: scheme.onSurfaceVariant,
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

/// 进程多选对话框：按路径去重（同 exe 多进程合并），图标懒加载。
class ProcessPickerDialog extends ConsumerStatefulWidget {
  const ProcessPickerDialog({super.key, this.initial = const {}});

  final Set<String> initial;

  @override
  ConsumerState<ProcessPickerDialog> createState() =>
      _ProcessPickerDialogState();
}

class _ProcessPickerDialogState extends ConsumerState<ProcessPickerDialog> {
  late final Set<String> _selected = Set.of(widget.initial);
  List<HelperProcessEntry> _entries = const [];
  bool _loading = true;
  bool _failed = false;
  bool _hideSystem = true;
  String _query = '';
  final FocusNode _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _searchFocus.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final list = await helperClient.listProcesses();
      // 同路径只保留一行（路径才是规则键）；读不到路径的丢弃。
      final byPath = <String, HelperProcessEntry>{};
      for (final e in list) {
        if (e.path.isEmpty) continue;
        byPath.putIfAbsent(e.path.toLowerCase(), () => e);
      }
      final entries = byPath.values.toList()
        ..sort((a, b) {
          final da = a.description.isEmpty ? a.name : a.description;
          final db = b.description.isEmpty ? b.name : b.description;
          return da.toLowerCase().compareTo(db.toLowerCase());
        });
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      commonPrint.log('[ProcessAccess] list processes failed: $e');
      if (!mounted) return;
      setState(() {
        _entries = const [];
        _loading = false;
        _failed = true;
      });
    }
  }

  bool _isSystemPath(String path) {
    final p = path.toLowerCase();
    return p.startsWith(r'c:\windows\') ||
        p.startsWith(r'c:\program files\windowsapps\');
  }

  List<HelperProcessEntry> get _filtered {
    final q = _query.trim().toLowerCase();
    return _entries.where((e) {
      if (_hideSystem && _isSystemPath(e.path)) return false;
      if (q.isEmpty) return true;
      return e.name.toLowerCase().contains(q) ||
          e.path.toLowerCase().contains(q) ||
          e.description.toLowerCase().contains(q);
    }).toList();
  }

  void _toggle(HelperProcessEntry e) {
    setState(() {
      if (!_selected.remove(e.path)) {
        _selected.add(e.path);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    final scheme = context.colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final focused = _searchFocus.hasFocus;

    return CommonDialog(
      title: appLocalizations.processAccessSelectProcesses,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      overrideScroll: true,
      // 路径列要能读全，默认 300 会截断。
      maxWidth: 600,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(appLocalizations.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(Set.of(_selected)),
          child: Text(
            appLocalizations.processAccessSelectedCount(_selected.length),
          ),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 搜索框：无描边，聚焦/非聚焦靠底色与阴影深浅表达。
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Container(
              decoration: BoxDecoration(
                color: focused
                    ? scheme.primary.withValues(alpha: 0.08)
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: dark
                          ? (focused ? 0.55 : 0.35)
                          : (focused ? 0.16 : 0.06),
                    ),
                    blurRadius: focused ? 18 : 10,
                    offset: Offset(0, focused ? 6 : 3),
                  ),
                ],
              ),
              child: TextField(
                focusNode: _searchFocus,
                style: context.textTheme.bodyMedium,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.transparent,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  hintText: appLocalizations.search,
                  hintStyle: context.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  prefixIcon: Icon(
                    Icons.search,
                    size: 20,
                    color: focused ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 40,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
          ),
          SwitchListTile(
            dense: true,
            title: Text(
              appLocalizations.processAccessHideSystem,
              style: context.textTheme.bodyMedium,
            ),
            value: _hideSystem,
            onChanged: (value) => setState(() => _hideSystem = value),
          ),
          Flexible(
            child: _loading
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 12),
                          Text(appLocalizations.processAccessLoading),
                        ],
                      ),
                    ),
                  )
                : _failed
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            appLocalizations.processAccessLoadFailed,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : items.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(appLocalizations.processAccessEmpty),
                            ),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            padding: const EdgeInsets.only(bottom: 8),
                            itemCount: items.length,
                            itemBuilder: (context, index) {
                              final e = items[index];
                              if (index > 0) {
                                return Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Divider(
                                      indent: 68,
                                      height: 1,
                                      color: scheme.outlineVariant
                                          .withValues(alpha: 0.35),
                                    ),
                                    _buildRow(context, e),
                                  ],
                                );
                              }
                              return _buildRow(context, e);
                            },
                          ),
          ),
        ],
      ),
    );
  }

  /// 选择器列表标题去掉 `.exe`；进程分流页的已选路径仍保留完整文件名。
  static String _stripExe(String name) =>
      name.replaceFirst(RegExp(r'\.exe$', caseSensitive: false), '');

  Widget _buildRow(BuildContext context, HelperProcessEntry e) {
    final scheme = context.colorScheme;
    final checked = _selected.contains(e.path);
    final title =
        e.description.isEmpty ? _stripExe(e.name) : e.description;
    return Material(
      color: checked
          ? scheme.primary.withValues(alpha: 0.06)
          : Colors.transparent,
      child: InkWell(
        onTap: e.path.isEmpty ? null : () => _toggle(e),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SizedBox(
                  width: 26,
                  height: 26,
                  child: _ProcessIconImage(path: e.path),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      e.path.isEmpty
                          ? appLocalizations.processAccessNoPath
                          : e.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                checked ? Icons.check_circle : Icons.circle_outlined,
                size: 22,
                color: checked
                    ? scheme.primary
                    : scheme.outlineVariant.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 从 helper 取 RGBA 图标并解码；失败显示占位图标。按 path 进程内缓存。
class _ProcessIconImage extends StatefulWidget {
  const _ProcessIconImage({required this.path});

  final String path;

  @override
  State<_ProcessIconImage> createState() => _ProcessIconImageState();
}

class _ProcessIconImageState extends State<_ProcessIconImage> {
  static final Map<String, Uint8List> _pngCache = {};
  late Future<Uint8List?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant _ProcessIconImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _future = _load();
    }
  }

  Future<Uint8List?> _load() async {
    final cached = _pngCache[widget.path];
    if (cached != null) return cached;
    final icon = await helperClient.getProcessIcon(widget.path);
    if (icon == null) return null;
    final png = await _rgbaToPng(icon);
    if (png != null) {
      _pngCache[widget.path] = png;
    }
    return png;
  }

  static Future<Uint8List?> _rgbaToPng(HelperProcessIcon icon) async {
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.FrameInfo? frame;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(icon.rgba);
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: icon.width,
        height: icon.height,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      codec = await descriptor.instantiateCodec();
      frame = await codec.getNextFrame();
      final byteData = await frame.image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      return byteData?.buffer.asUint8List();
    } catch (_) {
      return null;
    } finally {
      frame?.image.dispose();
      codec?.dispose();
      descriptor?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snapshot) {
        final png = snapshot.data;
        if (png == null) {
          return Icon(
            Icons.insert_drive_file_outlined,
            size: 24,
            color: context.colorScheme.onSurfaceVariant,
          );
        }
        return Image.memory(png, width: 24, height: 24, gaplessPlayback: true);
      },
    );
  }
}
