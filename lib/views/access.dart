import 'dart:async';
import 'dart:convert';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/plugins/app.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// Force refresh icon flag
final forceRefreshIconProvider = StateProvider<bool>((ref) => false);

enum _AppListFilter { selected, unselected }

class AccessView extends ConsumerStatefulWidget {
  const AccessView({super.key});

  @override
  ConsumerState<AccessView> createState() => _AccessViewState();
}

class _AccessViewState extends ConsumerState<AccessView>
    with WidgetsBindingObserver {
  _AppListFilter _appListFilter = _AppListFilter.selected;
  late ScrollController _controller;
  late AccessControl _initialAccessControl;
  final Completer<void> _completer = Completer<void>();
  bool _requestedPackageListPermission = false;
  bool _notifiedPackageListPermissionDenied = false;
  bool _isCheckingPermissionOrLoading = false;
  bool _packageListPermissionDenied = false;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _initialAccessControl = globalState.config.vpnProps.accessControl;
    // 页面内的勾选不再逐次生效，改动统一在退出页面时应用；期间不弹重启提示。
    globalState.isEditingAccessControl = true;
    WidgetsBinding.instance.addObserver(this);
    _checkPermissionAndLoadPackages(interactive: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!mounted) return;
    if (ref.read(packagesProvider).isNotEmpty &&
        !_packageListPermissionDenied) {
      return;
    }
    _checkPermissionAndLoadPackages(interactive: false);
  }

  void _completeLoadingIfNeeded() {
    if (_completer.isCompleted) return;
    _completer.complete();
  }

  Widget _buildPackageListPermissionDeniedView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.apps_outlined,
              size: 72,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              appLocalizations.packageListPermissionDenied,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              appLocalizations.packageListPermissionRequired,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () async {
                    _requestedPackageListPermission = true;
                    await app.requestPackageListPermission();
                  },
                  icon: const Icon(Icons.settings),
                  label: Text(appLocalizations.openSettings),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkPermissionAndLoadPackages({
    required bool interactive,
    bool forceReload = false,
    bool openSettingsFallback = false,
  }) async {
    if (_isCheckingPermissionOrLoading) return;
    _isCheckingPermissionOrLoading = true;
    try {
      final hasPermission = await app.hasPackageListPermission();
      if (!mounted) return;

      if (!hasPermission) {
        if (!_packageListPermissionDenied) {
          setState(() {
            _packageListPermissionDenied = true;
          });
        }
        if (interactive) {
          if (openSettingsFallback) {
            _requestedPackageListPermission = true;
            await app.requestPackageListPermission();
          } else {
            final res = await globalState.showMessage(
              title: appLocalizations.tip,
              message: TextSpan(
                text: appLocalizations.packageListPermissionRequired,
              ),
              confirmText: appLocalizations.openSettings,
            );
            if (!mounted) return;
            if (res == true) {
              _requestedPackageListPermission = true;
              await app.requestPackageListPermission();
            } else if (!_notifiedPackageListPermissionDenied) {
              _notifiedPackageListPermissionDenied = true;
              globalState.showNotifier(
                appLocalizations.packageListPermissionDenied,
              );
            }
          }
        } else if (_requestedPackageListPermission &&
            !_notifiedPackageListPermissionDenied) {
          _notifiedPackageListPermissionDenied = true;
          globalState.showNotifier(
            appLocalizations.packageListPermissionDenied,
          );
        }
        _completeLoadingIfNeeded();
        return;
      }

      if (_packageListPermissionDenied) {
        setState(() {
          _packageListPermissionDenied = false;
        });
      }
      await globalState.appController.getPackages(forceRefresh: forceReload);
      if (!mounted) return;
      if (system.isAndroid && ref.read(packagesProvider).isEmpty) {
        if (!_packageListPermissionDenied) {
          setState(() {
            _packageListPermissionDenied = true;
          });
        }
        if (interactive) {
          final res = await globalState.showMessage(
            title: appLocalizations.tip,
            message: TextSpan(
              text: appLocalizations.packageListPermissionRequired,
            ),
            confirmText: appLocalizations.openSettings,
          );
          if (!mounted) return;
          if (res == true) {
            _requestedPackageListPermission = true;
            await app.requestPackageListPermission();
          }
        }
        _completeLoadingIfNeeded();
        return;
      }
      _completeLoadingIfNeeded();
    } catch (e) {
      _completeLoadingIfNeeded();
      if (e is PlatformException && e.code == 'PACKAGE_LIST_PERMISSION') {
        if (!mounted) return;
        if (!_packageListPermissionDenied) {
          setState(() {
            _packageListPermissionDenied = true;
          });
        }
        if (interactive) {
          if (openSettingsFallback) {
            _requestedPackageListPermission = true;
            await app.requestPackageListPermission();
            return;
          }
          final res = await globalState.showMessage(
            title: appLocalizations.tip,
            message: TextSpan(
              text: appLocalizations.packageListPermissionRequired,
            ),
            confirmText: appLocalizations.openSettings,
          );
          if (!mounted) return;
          if (res == true) {
            _requestedPackageListPermission = true;
            await app.requestPackageListPermission();
          } else if (!_notifiedPackageListPermissionDenied) {
            _notifiedPackageListPermissionDenied = true;
            globalState.showNotifier(
              appLocalizations.packageListPermissionDenied,
            );
          }
          return;
        }
        if (_requestedPackageListPermission &&
            !_notifiedPackageListPermissionDenied) {
          _notifiedPackageListPermissionDenied = true;
          globalState.showNotifier(
            appLocalizations.packageListPermissionDenied,
          );
          return;
        }
      }
      globalState.showNotifier(e.toString());
    } finally {
      _isCheckingPermissionOrLoading = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    globalState.isEditingAccessControl = false;
    if (!globalState.isExiting) {
      final current = globalState.config.vpnProps.accessControl;
      final acceptListChanged =
          current.acceptList.length != _initialAccessControl.acceptList.length ||
          !current.acceptList.toSet().containsAll(
            _initialAccessControl.acceptList,
          );
      if (current.enable != _initialAccessControl.enable || acceptListChanged) {
        final controller = globalState.appControllerOrNull;
        if (controller != null) {
          unawaited(controller.applyAccessControlChanges());
        }
      }
    }
    super.dispose();
  }

  Widget _buildSearchButton() {
    return IconButton(
      tooltip: appLocalizations.search,
      onPressed: () {
        showSearch(context: context, delegate: AccessControlSearchDelegate());
      },
      icon: const Icon(Icons.search),
    );
  }

  Widget _buildRefreshButton() {
    return IconButton(
      tooltip: appLocalizations.refreshAppList,
      onPressed: () async {
        final res = await globalState.showMessage(
          title: appLocalizations.tip,
          message: TextSpan(text: appLocalizations.refreshAppListConfirm),
        );
        if (res != true) return;

        // Reload app list (auto-checks and requests permissions)
        await globalState.appController.safeRun(() async {
          // Clear cache, force reload
          // Mark as force refresh mode
          ref.read(forceRefreshIconProvider.notifier).state = true;
          await _checkPermissionAndLoadPackages(
            interactive: true,
            forceReload: true,
          );
          // Reset force refresh flag
          if (mounted) {
            ref.read(forceRefreshIconProvider.notifier).state = false;
          }
        }, needLoading: true);
      },
      icon: const Icon(Icons.sync),
    );
  }

  Widget _buildFilterButton() {
    final (icon, tooltip) = switch (_appListFilter) {
      _AppListFilter.selected => (
        Icons.check_circle_outline,
        appLocalizations.selected,
      ),
      _AppListFilter.unselected => (
        Icons.radio_button_unchecked,
        appLocalizations.unselected,
      ),
    };
    return IconButton(
      tooltip: tooltip,
      onPressed: () {
        setState(() {
          _appListFilter = switch (_appListFilter) {
            _AppListFilter.selected => _AppListFilter.unselected,
            _AppListFilter.unselected => _AppListFilter.selected,
          };
        });
      },
      icon: Icon(icon),
    );
  }

  Future<void> _intelligentSelected() async {
    final packageNames = ref.read(
      packageListSelectorStateProvider.select(
        (state) => state.list.map((item) => item.packageName),
      ),
    );
    final commonScaffoldState = context.commonScaffoldState;
    if (commonScaffoldState?.mounted != true) return;
    final selectedPackageNames =
        (await globalState.appController.safeRun<List<String>>(
          needLoading: true,
          () async {
            return await app.getChinaPackageNames();
          },
        ))?.toSet() ??
        {};
    final acceptList = packageNames
        .where((item) => !selectedPackageNames.contains(item))
        .toList();
    ref
        .read(vpnSettingProvider.notifier)
        .updateState(
          (state) => state.copyWith.accessControl(acceptList: acceptList),
        );
  }

  Widget _buildSettingButton() {
    return IconButton(
      onPressed: () async {
        final res = await showSheet<int>(
          context: context,
          props: SheetProps(isScrollControlled: true),
          builder: (_, type) {
            return AdaptiveSheetScaffold(
              type: type,
              body: AccessControlPanel(),
              title: appLocalizations.proxiesSetting,
            );
          },
        );
        if (res == 1) {
          _intelligentSelected();
        }
      },
      icon: const Icon(Icons.tune),
    );
  }

  void _handleSelected(List<String> valueList, Package package, bool? value) {
    if (value == true) {
      valueList.add(package.packageName);
    } else {
      valueList.remove(package.packageName);
    }
    ref.read(vpnSettingProvider.notifier).updateState((state) {
      final currentManualList = state.accessControl.manualList;
      final newManualList = value == false &&
              currentManualList.contains(package.packageName)
          ? currentManualList.where((e) => e != package.packageName).toList()
          : currentManualList;
      return state.copyWith.accessControl(
        acceptList: valueList,
        manualList: newManualList,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(packageListSelectorStateProvider);
    final accessControl = state.accessControl;
    final sortedPackages = state.getSortList(accessControl.acceptList);
    final packageNameList = sortedPackages.map((e) => e.packageName).toList();
    final valueList = accessControl.acceptList.intersection(packageNameList);
    final selectedSet = valueList.toSet();
    final unselectedCount = packageNameList.length - valueList.length;
    final packages = switch (_appListFilter) {
      _AppListFilter.selected =>
        sortedPackages
            .where((e) => selectedSet.contains(e.packageName))
            .toList(),
      _AppListFilter.unselected =>
        sortedPackages
            .where((e) => !selectedSet.contains(e.packageName))
            .toList(),
    };
    final isUnselectedFilter = _appListFilter == _AppListFilter.unselected;
    final headerLabel = isUnselectedFilter
        ? appLocalizations.unselected
        : appLocalizations.selected;
    final headerCount = isUnselectedFilter ? unselectedCount : valueList.length;

    return Column(
      mainAxisSize: MainAxisSize.max,
      children: [
        Flexible(
          flex: 0,
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, top: 12),
            child: CommonCard(
              type: CommonCardType.filled,
              child: ListItem.switchItem(
                title: Text(appLocalizations.appAccessControl),
                trailing: accessControl.enable ? _buildRefreshButton() : null,
                delegate: SwitchDelegate(
                  value: accessControl.enable,
                  onChanged: (enable) {
                    ref
                        .read(vpnSettingProvider.notifier)
                        .updateState(
                          (state) =>
                              state.copyWith.accessControl(enable: enable),
                        );
                  },
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Flexible(
          child: DisabledMask(
            status: !accessControl.enable,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 5,
                  ),
                  child: CommonCard(
                    type: CommonCardType.filled,
                    child: ActivateBox(
                      active: accessControl.enable,
                      child: Padding(
                        padding: const EdgeInsets.only(
                          top: 4,
                          bottom: 4,
                          left: 16,
                          right: 8,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          mainAxisSize: MainAxisSize.max,
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      headerLabel,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelLarge
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                          ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      '$headerCount',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelLarge
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Flexible(child: _buildSearchButton()),
                                Flexible(child: _buildFilterButton()),
                                Flexible(child: _buildSettingButton()),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  flex: 1,
                  child: FutureBuilder(
                    future: _completer.future,
                    builder: (_, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return Center(child: CircularProgressIndicator());
                      }
                      if (_packageListPermissionDenied) {
                        return _buildPackageListPermissionDeniedView();
                      }
                      return packages.isEmpty
                          ? NullStatus(label: appLocalizations.noData)
                          : CommonScrollBar(
                              controller: _controller,
                              child: ListView.separated(
                                controller: _controller,
                                itemCount: packages.length,
                                padding: const EdgeInsets.only(
                                  bottom: 24,
                                  top: 4,
                                ),
                                itemBuilder: (_, index) {
                                  final package = packages[index];
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    child: PackageListItem(
                                      key: Key(package.packageName),
                                      package: package,
                                      value: valueList.contains(
                                        package.packageName,
                                      ),
                                      isActive: accessControl.enable,
                                      onChanged: (value) {
                                        _handleSelected(
                                          valueList,
                                          package,
                                          value,
                                        );
                                      },
                                    ),
                                  );
                                },
                                separatorBuilder: (context, _) => Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  child: Divider(
                                    height: 1,
                                    thickness: 1,
                                    color: context.colorScheme.outlineVariant
                                        .withValues(
                                          alpha:
                                              context.colorScheme.brightness ==
                                                  Brightness.light
                                              ? 0.3
                                              : 0.2,
                                        ),
                                  ),
                                ),
                              ),
                            );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class PackageListItem extends ConsumerWidget {
  final Package package;
  final bool value;
  final bool isActive;
  final void Function(bool?) onChanged;

  const PackageListItem({
    super.key,
    required this.package,
    required this.value,
    required this.isActive,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final forceRefresh = ref.watch(forceRefreshIconProvider);

    return GestureDetector(
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: package.packageName));
        globalState.showNotifier(
          '${appLocalizations.copiedPackageName}: ${package.packageName}',
        );
      },
      child: ActivateBox(
        active: isActive,
        child: ListItem.checkbox(
          leading: SizedBox(
            width: 48,
            height: 48,
            child: FutureBuilder<Uint8List?>(
              future: app.getPackageIcon(
                package.packageName,
                forceRefresh: forceRefresh,
              ),
              builder: (context, snapshot) {
                if (snapshot.hasData && snapshot.data != null) {
                  final devicePixelRatio = MediaQuery.of(
                    context,
                  ).devicePixelRatio;
                  final cacheSize = (48 * devicePixelRatio).ceil();

                  return Image.memory(
                    snapshot.data!,
                    gaplessPlayback: true,
                    width: 48,
                    height: 48,
                    cacheWidth: cacheSize,
                    cacheHeight: cacheSize,
                    errorBuilder: (_, _, _) => _buildDefaultIcon(context),
                  );
                }
                return _buildDefaultIcon(context);
              },
            ),
          ),
          title: EmojiText(
            package.label,
            style: const TextStyle(overflow: TextOverflow.ellipsis),
            maxLines: 1,
          ),
          subtitle: Text(
            package.packageName,
            style: const TextStyle(overflow: TextOverflow.ellipsis),
            maxLines: 1,
          ),
          delegate: CheckboxDelegate(value: value, onChanged: onChanged),
        ),
      ),
    );
  }

  Widget _buildDefaultIcon(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        Icons.apps,
        size: 24,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class AccessControlSearchDelegate extends SearchDelegate {
  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      IconButton(
        onPressed: () {
          if (query.isEmpty) {
            close(context, null);
            return;
          }
          query = '';
        },
        icon: const Icon(Icons.clear),
      ),
      const SizedBox(width: 8),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      onPressed: () {
        close(context, null);
      },
      icon: const Icon(Icons.arrow_back),
    );
  }

  void _handleSelected(
    WidgetRef ref,
    List<String> valueList,
    Package package,
    bool? value,
  ) {
    if (value == true) {
      valueList.add(package.packageName);
    } else {
      valueList.remove(package.packageName);
    }
    ref.read(vpnSettingProvider.notifier).updateState((state) {
      final currentManualList = state.accessControl.manualList;
      final newManualList = value == false &&
              currentManualList.contains(package.packageName)
          ? currentManualList.where((e) => e != package.packageName).toList()
          : currentManualList;
      return state.copyWith.accessControl(
        acceptList: valueList,
        manualList: newManualList,
      );
    });
  }

  Widget _packageList() {
    final lowQuery = query.toLowerCase();
    return Consumer(
      builder: (context, ref, _) {
        final vm3 = ref.watch(
          packageListSelectorStateProvider.select(
            (state) => VM3(
              a: state.getSortList(state.accessControl.acceptList),
              b: state.accessControl.enable,
              c: state.accessControl.acceptList,
            ),
          ),
        );
        final packages = vm3.a;

        // Search filter (inside Consumer, auto-responds to query changes)
        final queryPackages = query.isEmpty
            ? packages
            : packages
                  .where(
                    (package) =>
                        package.label.toLowerCase().contains(lowQuery) ||
                        package.packageName.contains(lowQuery),
                  )
                  .toList();

        final isAccessControl = vm3.b;
        final currentList = vm3.c;
        final packageNameList = packages.map((e) => e.packageName).toList();
        final valueList = currentList.intersection(packageNameList);

        return DisabledMask(
          status: !isAccessControl,
          child: ListView.builder(
            itemCount: queryPackages.length,
            itemExtent: 72,
            itemBuilder: (_, index) {
              final package = queryPackages[index];
              return PackageListItem(
                key: Key(package.packageName),
                package: package,
                value: valueList.contains(package.packageName),
                isActive: isAccessControl,
                onChanged: (value) {
                  _handleSelected(ref, valueList, package, value);
                },
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    return buildSuggestions(context);
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    return _packageList();
  }
}

class AccessControlPanel extends ConsumerStatefulWidget {
  const AccessControlPanel({super.key});

  @override
  ConsumerState createState() => _AccessControlPanelState();
}

class _AccessControlPanelState extends ConsumerState<AccessControlPanel> {
  String _getTextWithAccessSortType(AccessSortType type) {
    return switch (type) {
      AccessSortType.none => appLocalizations.defaultText,
      AccessSortType.installTime => appLocalizations.installTime,
      AccessSortType.updateTime => appLocalizations.updateTime,
    };
  }

  IconData _getIconWithProxiesSortType(AccessSortType type) {
    return switch (type) {
      AccessSortType.none => Icons.sort,
      AccessSortType.installTime => Icons.install_mobile,
      AccessSortType.updateTime => Icons.update,
    };
  }

  List<Widget> _buildModeSetting() {
    return generateSection(
      plain: true,
      title: appLocalizations.mode,
      items: [
        SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          scrollDirection: Axis.horizontal,
          child: Consumer(
            builder: (_, ref, _) {
              final accessControlMode = ref.watch(
                vpnSettingProvider.select((state) => state.accessControl.mode),
              );
              return Wrap(
                spacing: 16,
                children: [
                  for (final item in AccessControlMode.values)
                    SettingInfoCard(
                      Info(
                        label: appLocalizations.whitelistMode,
                        iconData: Icons.adjust_outlined,
                      ),
                      isSelected: accessControlMode == item,
                      onPressed: () {
                        ref
                            .read(vpnSettingProvider.notifier)
                            .updateState(
                              (state) =>
                                  state.copyWith.accessControl(mode: item),
                            );
                      },
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  List<Widget> _buildSortSetting() {
    return generateSection(
      plain: true,
      title: appLocalizations.sort,
      items: [
        SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          scrollDirection: Axis.horizontal,
          child: Consumer(
            builder: (_, ref, _) {
              final accessSortType = ref.watch(
                vpnSettingProvider.select((state) => state.accessControl.sort),
              );
              return Wrap(
                spacing: 16,
                children: [
                  for (final item in AccessSortType.values)
                    SettingInfoCard(
                      Info(
                        label: _getTextWithAccessSortType(item),
                        iconData: _getIconWithProxiesSortType(item),
                      ),
                      isSelected: accessSortType == item,
                      onPressed: () {
                        ref
                            .read(vpnSettingProvider.notifier)
                            .updateState(
                              (state) =>
                                  state.copyWith.accessControl(sort: item),
                            );
                      },
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  List<Widget> _buildSourceSetting() {
    return generateSection(
      plain: true,
      title: appLocalizations.source,
      items: [
        SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          scrollDirection: Axis.horizontal,
          child: Consumer(
            builder: (_, ref, _) {
              final vm2 = ref.watch(
                vpnSettingProvider.select(
                  (state) => VM2(
                    a: state.accessControl.isFilterSystemApp,
                    b: state.accessControl.isFilterNonInternetApp,
                  ),
                ),
              );
              return Wrap(
                spacing: 16,
                children: [
                  SettingTextCard(
                    appLocalizations.systemApp,
                    isSelected: vm2.a == false,
                    onPressed: () {
                      ref
                          .read(vpnSettingProvider.notifier)
                          .updateState(
                            (state) => state.copyWith.accessControl(
                              isFilterSystemApp: !vm2.a,
                            ),
                          );
                    },
                  ),
                  SettingTextCard(
                    appLocalizations.noNetworkApp,
                    isSelected: vm2.b == false,
                    onPressed: () {
                      ref
                          .read(vpnSettingProvider.notifier)
                          .updateState(
                            (state) => state.copyWith.accessControl(
                              isFilterNonInternetApp: !vm2.b,
                            ),
                          );
                    },
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _copyToClipboard() async {
    await globalState.appController.safeRun(() {
      final data = globalState.config.vpnProps.accessControl.toJson();
      Clipboard.setData(ClipboardData(text: json.encode(data)));
    });
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _pasteToClipboard() async {
    await globalState.appController.safeRun(() async {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text;
      if (text == null) return;

      AccessControl newAccessControl;
      try {
        newAccessControl = AccessControl.fromJson(json.decode(text));
      } catch (_) {
        final packageNameRegex = RegExp(r'^[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+)+$');
        final packages = text
            .split(RegExp(r'[\n,\s]+'))
            .map((e) => e.trim())
            .where((e) => packageNameRegex.hasMatch(e))
            .toList();

        final currentState = ref.read(vpnSettingProvider).accessControl;
        final newList = {...currentState.acceptList, ...packages}.toList();
        final newManualList = {...currentState.manualList, ...packages}.toList();

        newAccessControl = currentState.copyWith(
          acceptList: newList,
          manualList: newManualList,
        );
      }

      ref.read(vpnSettingProvider.notifier).updateState(
            (state) => state.copyWith(accessControl: newAccessControl),
          );
    });
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  List<Widget> _buildActionSetting() {
    return generateSection(
      plain: true,
      title: appLocalizations.action,
      items: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            runSpacing: 16,
            spacing: 16,
            children: [
              CommonChip(
                avatar: const Icon(Icons.auto_awesome),
                label: appLocalizations.intelligentSelected,
                onPressed: () {
                  Navigator.of(context).pop(1);
                },
              ),
              CommonChip(
                avatar: const Icon(Icons.paste),
                label: appLocalizations.clipboardImport,
                onPressed: _pasteToClipboard,
              ),
              CommonChip(
                avatar: const Icon(Icons.content_copy),
                label: appLocalizations.clipboardExport,
                onPressed: _copyToClipboard,
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ..._buildModeSetting(),
            ..._buildSortSetting(),
            ..._buildSourceSetting(),
            ..._buildActionSetting(),
          ],
        ),
      ),
    );
  }
}
