import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/theme.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/plugins/app.dart';
import 'package:bett_box/plugins/service.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/providers/state.dart' as providers_state;
import 'package:bett_box/rust/bettbox_config.dart';

import 'package:bett_box/widgets/dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as flutter_riverpod;
import 'package:material_color_utilities/palettes/core_palette.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:synchronized/synchronized.dart';
import 'package:url_launcher/url_launcher.dart';

import 'common/common.dart';
import 'controller.dart';
import 'models/models.dart';

typedef UpdateTasks = List<FutureOr Function()>;

/// `shared_preferences` 中"内核本应在运行"的键，见 [GlobalState.shouldCoreBeRunning]。
const listenerRunningKey = 'core_listener_running';

class GlobalState {
  static GlobalState? _instance;
  Map<CacheTag, FixedMap<String, double>> computeHeightMapCache = {};
  bool isService = false;
  bool isExiting = false;
  bool isScreenOn = true;
  Timer? timer;
  Timer? groupsUpdateTimer;
  late Config config;
  late AppState appState;
  bool isPre = true;
  String? coreSHA256;
  late PackageInfo packageInfo;
  Function? updateCurrentDelayDebounce;
  VoidCallback? focusDashboardStartSwitch;
  bool isDashboardStartSwitchFocused = false;
  late Measure measure;
  late CommonTheme theme;
  late Color accentColor;
  // ignore: deprecated_member_use
  CorePalette? corePalette;
  DateTime? startTime;
  UpdateTasks tasks = [];
  final navigatorKey = GlobalKey<NavigatorState>();
  final backgroundMode = ValueNotifier<bool>(false);
  final animationEnabled = ValueNotifier<bool>(true);
  AppController? _appController;
  bool? _isAndroidTV;
  int _taskLoopToken = 0;
  bool _isExecutingTasks = false;
  bool _needsTaskRestart = false;
  Timer? _backgroundCleanupTimer;
  final Lock _scriptEvaluateLock = Lock();
  bool isInit = false;

  bool get isStart => startTime != null && startTime!.isBeforeNow;

  AppController get appController => _appController!;

  set appController(AppController appController) {
    _appController = appController;
    isInit = true;
  }

  GlobalState._internal();

  factory GlobalState() {
    _instance ??= GlobalState._internal();
    return _instance!;
  }

  Future<void> initApp(int version) async {
    isExiting = false;
    coreSHA256 = const String.fromEnvironment('CORE_SHA256');
    if (system.isWindows && (coreSHA256 == null || coreSHA256!.isEmpty)) {
      coreSHA256 = await _calcCoreSHA256();
    }
    isPre = const String.fromEnvironment('APP_ENV') != 'stable';
    appState = AppState(
      brightness: WidgetsBinding.instance.platformDispatcher.platformBrightness,
      version: version,
      viewSize: Size.zero,
      requests: FixedList(maxLength),
      logs: FixedList(maxLength),
      traffics: FixedList(30),
      totalTraffic: Traffic(),
      systemUiOverlayStyle: const SystemUiOverlayStyle(),
    );
    await _initDynamicColor();
    await init();
  }

  Future<String?> _calcCoreSHA256() async {
    try {
      final file = File(appPath.corePath);
      if (!await file.exists()) return null;
      final digest = await sha256.bind(file.openRead()).first;
      return digest.toString();
    } catch (e) {
      commonPrint.log('Failed to calculate core SHA256: $e');
      return null;
    }
  }

  Future<void> _initDynamicColor() async {
    try {
      corePalette = await DynamicColorPlugin.getCorePalette();
      accentColor =
          await DynamicColorPlugin.getAccentColor() ??
          Color(defaultPrimaryColor);
    } catch (_) {}
  }

  Future<void> init() async {
    packageInfo = await PackageInfo.fromPlatform();
    if (system.isAndroid) {
      _isAndroidTV = await app.isAndroidTV();
    }
    config =
        await preferences.getConfig() ??
        Config(
          themeProps: defaultThemeProps,
          patchClashConfig: system.isAndroid
              ? const ClashConfig(findProcessMode: FindProcessMode.always)
              : defaultClashConfig,
          networkProps: defaultNetworkProps.copyWith(
            systemProxy: system.isDesktop,
          ),
          appSetting: defaultAppSettingProps.copyWith(
            showStartSwitch: _isAndroidTV ?? false,
          ),
        );
    await globalState.migrateOldData(config);
    final locale =
        utils.getLocaleForString(config.appSetting.locale) ??
        utils.getSystemLocale();
    await AppLocalizations.load(locale);
  }

  bool get isAndroidTV => _isAndroidTV ?? false;

  String get ua => config.patchClashConfig.globalUa ?? packageInfo.ua;

  Future<void> startUpdateTasks([UpdateTasks? tasks]) async {
    if (tasks != null) {
      this.tasks = tasks;
    }
    final token = ++_taskLoopToken;
    timer?.cancel();
    timer = null;
    if (_isExecutingTasks) {
      _needsTaskRestart = true;
      return;
    }
    await _runUpdateLoop(token);
  }

  Future<void> _runUpdateLoop(int token) async {
    if (token != _taskLoopToken) return;
    _isExecutingTasks = true;
    try {
      await executorUpdateTask();
    } finally {
      _isExecutingTasks = false;
    }
    if (_needsTaskRestart) {
      _needsTaskRestart = false;
      await _runUpdateLoop(_taskLoopToken);
      return;
    }
    if (token != _taskLoopToken) return;
    timer = Timer(const Duration(seconds: 1), () {
      unawaited(_runUpdateLoop(token));
    });
  }

  Future<void> executorUpdateTask() async {
    for (final task in tasks) {
      try {
        await task();
      } catch (e) {
        commonPrint.log('Background task failed: $e');
      }
    }
    timer = null;
  }

  void stopUpdateTasks() {
    _taskLoopToken++;
    _needsTaskRestart = false;
    timer?.cancel();
    timer = null;
  }

  Future<void> handleBackground() async {
    if (system.isDesktop) {
      final isMinimized = await window?.isMinimized ?? false;
      final isVisible = await window?.isVisible ?? true;
      if (!isMinimized && isVisible) {
        return;
      }
      animationEnabled.value = false;
    }
    if (!backgroundMode.value) {
      backgroundMode.value = true;
      _scheduleBackgroundCleanup();
    }
    render?.pause();

    final vpnProps = appController.ref.read(vpnSettingProvider);
    final keepTrafficUpdates =
        (system.isAndroid && vpnProps.networkSpeedNotification) ||
        (system.isMacOS && vpnProps.enableTraySpeed);
    if (!keepTrafficUpdates) {
      stopUpdateTasks();
    }

    dashboardRefreshManager.stop();
  }

  void handleForeground() {
    if (system.isDesktop) {
      animationEnabled.value = true;
    }
    if (!backgroundMode.value) {
      return;
    }
    backgroundMode.value = false;
    _backgroundCleanupTimer?.cancel();
    _backgroundCleanupTimer = null;
    _syncVpnState();
  }

  Future<void> _syncVpnState() async {
    if (!system.isAndroid) return;
    try {
      final actuallyRunning = await service?.getStatus() ?? false;
      final flutterState = appState.runTime != null;

      if (actuallyRunning && !flutterState) {
        await updateStartTime();
        if (startTime != null) {
          appState = appState.copyWith(runTime: 0);
          await startUpdateTasks([appController.updateTraffic]);
        }
      } else if (!actuallyRunning && flutterState) {
        appState = appState.copyWith(runTime: null);
        startTime = null;
      }
    } catch (e) {
      commonPrint.log('Sync VPN state error: $e');
    }
  }

  Future<void> resumeForegroundUpdates() async {
    dashboardRefreshManager.start();
    if (system.isDesktop) {
      // 先对账再决定要不要恢复每秒刷新：桌面端回到前台时可能内核状态已经变了
      // （内核退出、或运行状态在后台期间与事实脱节），只按内存里的 isStart 判断
      // 会把刚恢复的界面留在错误状态上。
      await appController.reconcileCoreState();
    }
    if (!isStart) {
      return;
    }

    await appController.updateRunTime();
    await appController.updateTraffic();
    await startUpdateTasks([
      appController.updateRunTime,
      appController.updateTraffic,
    ]);
  }

  void _scheduleBackgroundCleanup() {
    _backgroundCleanupTimer?.cancel();
    _backgroundCleanupTimer = Timer(const Duration(minutes: 3), () {
      _backgroundCleanupTimer = null;
      if (!backgroundMode.value) {
        return;
      }
      cleanupBackgroundResources();
    });
  }

  void cleanupBackgroundResources() async {
    if (!backgroundMode.value) return;

    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clearLiveImages();

    await Future.delayed(const Duration(milliseconds: 250));
    if (!backgroundMode.value) return;
    WidgetsBinding.instance.handleMemoryPressure();

    await Future.delayed(const Duration(milliseconds: 250));
    if (!backgroundMode.value) return;
    await clashCore.requestGc();
  }

  Future<void> handleStart([
    UpdateTasks? tasks,
    bool includeVpnService = true,
  ]) async {
    startTime ??= DateTime.now();
    if (system.isAndroid && isService) {
      await clashLibHandler?.startListener();
    } else if (!await _startListenerChecked()) {
      // 监听没建立（指令被丢、IPC 超时，或内核接受了但 mixed-port 没起来）：
      // 不能把开关停在"运行中"这个假状态上——那时内核可能只剩个进程、端口没人
      // 听，代理实际不通。拨回已停止，让用户看到真实状态。
      startTime = null;
      _applyStoppedState();
      showNotifier(appLocalizations.coreExited);
      return;
    }
    if (includeVpnService) {
      await service?.startVpn();
    }
    final prefs = await preferences.sharedPreferencesCompleter.future;
    await prefs?.setBool('is_vpn_running', true);
    await prefs?.setBool(listenerRunningKey, true);

    if (system.isAndroid) {
      await service?.setQuickResponse(config.vpnProps.quickResponse);
      await service?.setHighPriorityNotification(
        config.vpnProps.highPriorityNotification,
      );
    }
    await startUpdateTasks(tasks);
  }

  /// 启动内核监听，并确认端口真的在听。
  ///
  /// 内核的 `startListener` 只回报"指令被接受"（内部只置运行标志，建立监听失败
  /// 也只写日志），所以指令被丢、IPC 超时、或 mixed-port 没建立起来时它照样报
  /// 成功。这里真连一次端口才算数，失败重试一次（新内核刚起来时监听可能还在建）。
  Future<bool> _startListenerChecked() async {
    final port = config.patchClashConfig.mixedPort;
    // 内核已死时没必要再等 startListener 的整段 IPC 超时：先探一次健康度，
    // 探测失败就直接判失败（2 秒），不把用户晾在几十秒的空等里。内核正在重启
    // 过渡中（isStarting）时探测本身就会报"不应答"，那种情况交给下面的
    // startListener 去等。
    final service = clashService;
    if (service != null &&
        !service.isStarting &&
        !await service.checkCoreHealth()) {
      commonPrint.log('Core is not reachable, listener not started');
      return false;
    }
    for (var attempt = 1; attempt <= 2; attempt++) {
      // 内核处理启动指令是同步的内存操作，正常毫秒级返回；这里不必给长任务
      // 那样的余量，短超时能让故障更快暴露给用户。
      final accepted = await clashCore.startListener(
        timeout: const Duration(seconds: 5),
      );
      final listening = port <= 0 || await isLoopbackPortListening(port);
      if (accepted && listening) return true;
      if (attempt == 1) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    commonPrint.log('Core did not open the listener on port $port');
    return false;
  }

  /// 把界面拨回"已停止"（内核没能服务时，开关不能停在运行中）。
  void _applyStoppedState() {
    final controller = _appController;
    if (controller == null) return;
    final context = controller.context;
    if (!context.mounted) return;
    flutter_riverpod.ProviderScope.containerOf(
      context,
      listen: false,
    ).read(runTimeProvider.notifier).value = null;
  }

  /// 内核本应在运行的持久化意图，`handleStart` / `handleStop` 维护。
  ///
  /// 桌面端 UI 的运行状态（`runTimeProvider`）只活在内存里，一旦与内核真实状态
  /// 脱节（停止指令没被应答、GUI 被强杀后重启），就得有第二个来源来判断开关该
  /// 拨回哪一边；见 `AppController.reconcileCoreState`。
  Future<bool> shouldCoreBeRunning() async {
    final prefs = await preferences.sharedPreferencesCompleter.future;
    return prefs?.getBool(listenerRunningKey) ?? false;
  }

  Future<void> updateStartTime() async {
    startTime = await clashLib?.getRunTime();
  }

  void updateWakelockState(bool enabled) {
    if (_appController != null) {
      final container = _appController!.context;
      if (container.mounted) {
        final providerContainer = flutter_riverpod.ProviderScope.containerOf(
          container,
          listen: false,
        );
        providerContainer
                .read(providers_state.wakelockStateProvider.notifier)
                .state =
            enabled;
      }
    }
  }

  /// 返回内核是否应答了停止指令。
  ///
  /// 内核没应答（IPC 超时）时不再清掉运行状态：以前 `startTime` 先被置空，
  /// 界面随即显示"已停止"，而内核仍在代理，用户只能退出重进应用才恢复。
  Future<bool> handleStop([bool includeVpnService = true]) async {
    bool stopped = true;
    if (system.isAndroid && isService) {
      stopped = await clashLibHandler?.stopListener() ?? true;
    } else {
      stopped = await clashCore.stopListener();
    }
    if (!stopped) {
      commonPrint.log('Core did not acknowledge the stop request');
      return false;
    }
    startTime = null;
    final prefs = await preferences.sharedPreferencesCompleter.future;
    await prefs?.setBool(listenerRunningKey, false);
    if (!includeVpnService) {
      stopUpdateTasks();
      return true;
    }
    await service?.stopVpn();
    await prefs?.setBool('is_vpn_running', false);
    if (system.isDesktop) {
      await prefs?.setBool('is_tun_running', false);
    }
    stopUpdateTasks();
    return true;
  }

  Future<bool?> showMessage({
    String? title,
    required InlineSpan message,
    String? confirmText,
    bool cancelable = true,
  }) async {
    return await showCommonDialog<bool>(
      child: Builder(
        builder: (context) {
          return CommonDialog(
            title: title ?? appLocalizations.tip,
            actions: [
              if (cancelable)
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop(false);
                  },
                  child: Text(appLocalizations.cancel),
                ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(true);
                },
                child: Text(confirmText ?? appLocalizations.confirm),
              ),
            ],
            child: Container(
              width: 300,
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                child: SelectableText.rich(
                  TextSpan(
                    style: Theme.of(context).textTheme.labelLarge,
                    children: [message],
                  ),
                  style: const TextStyle(overflow: TextOverflow.visible),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<T?> showCommonDialog<T>({
    required Widget child,
    bool dismissible = true,
  }) async {
    final state = navigatorKey.currentState;
    if (state == null) return null;
    final context = state.context;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return await showGeneralDialog<T>(
      context: context,
      barrierColor: isDark ? const Color(0xCC000000) : const Color(0x99000000),
      barrierDismissible: dismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (context, animation, secondaryAnimation) => child,
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return RepaintBoundary(
          child: FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: curved.drive(Tween<double>(begin: 0.94, end: 1.0)),
              child: child,
            ),
          ),
        );
      },
    );
  }

  bool _dialogWarmedUp = false;

  void warmupCommonDialog() {
    if (_dialogWarmedUp) return;
    _dialogWarmedUp = true;

    final state = navigatorKey.currentState;
    if (state == null) return;
    final overlayState = state.overlay;
    if (overlayState == null) return;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          entry.remove();
          entry.dispose();
        });
        return Offstage(
          offstage: true,
          child: RepaintBoundary(
            child: Material(
              type: MaterialType.transparency,
              child: FadeTransition(
                opacity: const AlwaysStoppedAnimation(1.0),
                child: ScaleTransition(
                  scale: const AlwaysStoppedAnimation(1.0),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: const [
                        BoxShadow(blurRadius: 10, color: Colors.black12),
                      ],
                    ),
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle_outline),
                        SizedBox(height: 8),
                        Text('warmup'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    overlayState.insert(entry);
  }

  void showNotifier(
    String text, {
    VoidCallback? onAction,
    String? actionLabel,
    bool showCountdown = false,
  }) {
    if (text.isEmpty) return;
    navigatorKey.currentContext?.showNotifier(
      text,
      onAction: onAction,
      actionLabel: actionLabel,
      showCountdown: showCountdown,
    );
  }

  Future<void> openUrl(String url, {bool needConfirm = false}) async {
    if (needConfirm) {
      final res = await showMessage(
        message: TextSpan(text: url),
        title: appLocalizations.externalLink,
        confirmText: appLocalizations.go,
      );
      if (res != true) {
        return;
      }
    }
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Future<void> migrateOldData(Config config) async {
    final clashConfig = await preferences.getClashConfig();
    if (clashConfig != null) {
      config = config.copyWith(patchClashConfig: clashConfig);
      preferences.clearClashConfig();
      preferences.saveConfig(config);
    }

    if (config.appSetting.locale == null) {
      final systemLocale = utils.getSystemLocale();
      config = config.copyWith(
        appSetting: config.appSetting.copyWith(locale: systemLocale.toString()),
      );
      preferences.saveConfig(config);
      this.config = config;
    }
  }

  CoreState getCoreState() {
    final currentProfile = config.currentProfile;
    return CoreState(
      vpnProps: config.vpnProps,
      onlyStatisticsProxy: config.appSetting.onlyStatisticsProxy,
      currentProfileName: currentProfile?.label ?? currentProfile?.id ?? '',
      bypassDomain: config.networkProps.bypassDomain,
    );
  }

  Future<SetupParams> getSetupParams({required ClashConfig pathConfig}) async {
    final clashConfig = await patchRawConfig(patchConfig: pathConfig);
    await _writeRunningConfig(clashConfig);
    return SetupParams(
      selectedMap: config.currentProfile?.selectedMap ?? {},
      testUrl: config.appSetting.testUrl,
      overrideTestUrl: config.overrideTestUrl,
    );
  }

  Future<void> _writeRunningConfig(Map<String, dynamic> clashConfig) async {
    final content = await encodeCompactYamlTask(clashConfig);
    final configPath = await appPath.configFilePath;
    // 临时文件名带时间戳：同一路径的并发写入不再互相踩，重试时也绝不会
    // 先把目标配置删掉（旧实现 rename 失败会先 delete 目标，第二次再失败
    // 就把运行配置写没了）。
    final tempFile = File(
      '$configPath.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await tempFile.parent.create(recursive: true);
    try {
      await tempFile.writeAsString(content, flush: true);
      var success = false;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          await tempFile.rename(configPath);
          success = true;
          break;
        } catch (_) {
          try {
            await tempFile.copy(configPath);
            success = true;
            break;
          } catch (_) {
            if (attempt < 2) {
              await Future.delayed(Duration(milliseconds: 50 * (attempt + 1)));
            }
          }
        }
      }
      if (!success) {
        throw FileSystemException(
          'Failed to write running config after retries',
          configPath,
        );
      }
    } finally {
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    }
  }

  Future<Map<String, dynamic>> patchRawConfig({
    required ClashConfig patchConfig,
    Profile? profile,
  }) async {
    final targetProfile = profile ?? config.currentProfile;
    if (targetProfile == null) {
      return {};
    }
    final profileId = targetProfile.id;
    final configMap = await getProfileConfig(profileId);
    final rawConfig = await handleEvaluate(configMap, profile: targetProfile);

    final realPatchConfig = patchConfig.copyWith(
      dns: patchConfig.dns.copyWith(
        fakeIpRangeV6: patchConfig.dns.effectiveFakeIpRangeV6(
          ipv6Enabled: patchConfig.ipv6,
        ),
      ),
      tun: patchConfig.tun.getRealTun(
        config.networkProps.bypassPrivateRoute,
        fakeIpRange: patchConfig.dns.fakeIpRange,
        fakeIpRangeV6: patchConfig.dns.effectiveFakeIpRangeV6(
          ipv6Enabled: patchConfig.ipv6,
        ),
        bypassPrivateRouteAddress:
            config.networkProps.realBypassPrivateRouteAddress,
      ),
    );
    final input = buildConfigPatchInput(
      rawConfig: rawConfig,
      patch: realPatchConfig,
      profile: targetProfile,
      isAndroid: system.isAndroid,
      isLinux: system.isLinux,
      uiPath: await appPath.uiPath,
      profilesPath: await appPath.profilesPath,
      overrideDns: config.overrideDns,
      overrideNtp: config.overrideNtp,
      overrideSniffer: config.overrideSniffer,
      overrideExperimental: config.overrideExperimental,
      nodeExcludeFilter: config.nodeExcludeFilter,
      healthCheckTimeout: config.healthCheckTimeout,
      scriptAddedRules: config.scriptProps.addedRules,
      hasCurrentScript: config.scriptProps.currentScript != null,
      disableQuic: config.vpnProps.disableQuic,
      excludeChina: config.vpnProps.excludeChina,
      locale: config.appSetting.locale,
    );

    if (useRustConfigPipeline) {
      final output = BettboxConfig.patchConfig(jsonEncode(input));
      if (output != null) {
        return (jsonDecode(output) as Map).cast<String, dynamic>();
      }
      if (BettboxConfig.isAvailable) {
        commonPrint.log(
          'Rust 配置管道未接管（输入含未支持的写法或内部出错），回退 Dart 路径',
        );
      }
    }
    return applyConfigPatch(input);
  }

  Future<Map<String, dynamic>> getProfileConfig(String profileId) async {
    final profile = config.profiles.getProfile(profileId);
    final ageSecretKey = profile?.ageSecretKey;
    final configMap = await switch (clashLibHandler != null) {
      true => clashLibHandler!.getConfig(profileId, ageSecretKey: ageSecretKey),
      false => clashCore.getConfig(profileId, ageSecretKey: ageSecretKey),
    };
    configMap['rules'] = configMap['rule'];
    configMap.remove('rule');
    return configMap;
  }

  Future<Map<String, dynamic>> handleEvaluate(
    Map<String, dynamic> config, {
    Profile? profile,
  }) async {
    return _scriptEvaluateLock.synchronized(() async {
      final currentScript = globalState.config.scriptProps.currentScript;
      if (currentScript == null) return config;

      if (profile != null && !profile.useScriptOverride) return config;

      config['proxy-providers'] ??= {};

      try {
        return await JavaScriptRuntimeManager.evaluateScriptPreferRust(
          currentScript.content,
          config,
          customOptions: currentScript.customOptions,
        );
      } catch (e) {
        commonPrint.log('Script execution failed: $e');
        globalState.showNotifier(
          '${appLocalizations.profileParseErrorDesc}: $e',
        );
        return config;
      }
    });
  }
}

class DashboardRefreshManager {
  Timer? _timer;
  bool _isRunning = false;
  int _counter = 0;
  int _tickToken = 0;

  final tick1s = ValueNotifier<int>(0);
  final tick2s = ValueNotifier<int>(0);
  final tick5s = ValueNotifier<int>(0);

  bool get isRunning => _isRunning;

  Future<bool> _isActive() async {
    if (system.isDesktop) {
      final isPinned = globalState.config.windowProps.isPinned;
      if (isPinned) return true;
      final visible = await window?.isVisible;
      if (visible == false) {
        return false;
      }
      final minimized = await window?.isMinimized ?? false;
      if (minimized) {
        return false;
      }
      return true;
    }

    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState != null && lifecycleState != AppLifecycleState.resumed) {
      return false;
    }
    return true;
  }

  Future<void> _tryTick(int token) async {
    if (!await _isActive()) {
      return;
    }
    if (token != _tickToken) return;
    _counter++;
    tick1s.value++;
    if (_counter % 2 == 0) {
      tick2s.value++;
    }
    if (_counter % 5 == 0) {
      tick5s.value++;
    }
  }

  void start() {
    if (_isRunning) return;
    _isRunning = true;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _tryTick(_tickToken);
    });
  }

  void stop() {
    if (!_isRunning) return;
    _tickToken++;
    _timer?.cancel();
    _timer = null;
    _isRunning = false;
  }
}

final dashboardRefreshManager = DashboardRefreshManager();

final globalState = GlobalState();

class DetectionState {
  static DetectionState? _instance;
  bool? _preIsStart;
  int _requestId = 0;
  CancelToken? _cancelToken;
  bool _isIpMasked = false;
  IpInfo? _rawIpInfo;
  bool _isFirstLaunch = true;

  final state = ValueNotifier<NetworkDetectionState>(
    const NetworkDetectionState(
      isLoading: true,
      ipInfo: null,
      errorMessage: null,
    ),
  );

  DetectionState._internal();

  factory DetectionState() {
    _instance ??= DetectionState._internal();
    return _instance!;
  }

  bool get isIpMasked => _isIpMasked;
  IpInfo? get rawIpInfo => _rawIpInfo;

  IpInfo? _maskIpInfo(IpInfo? ipInfo) {
    if (ipInfo == null) return null;
    return _isIpMasked ? ipInfo.copyWith(ip: '*** *** *** ***') : ipInfo;
  }

  void toggleIpPrivacy() {
    _isIpMasked = !_isIpMasked;
    if (_rawIpInfo != null) {
      state.value = state.value.copyWith(ipInfo: _maskIpInfo(_rawIpInfo));
    }
  }

  void manualRefresh() {
    _rawIpInfo = null;
    _isIpMasked = false;
    state.value = state.value.copyWith(
      isLoading: true,
      ipInfo: null,
      errorMessage: null,
    );
    startCheck(immediate: true, showLoading: true);
  }

  void _onIpProgress(int requestId, IpInfo info) {
    if (requestId != _requestId) return;
    _rawIpInfo = info;
    state.value = state.value.copyWith(
      isLoading: false,
      ipInfo: _maskIpInfo(_rawIpInfo),
      errorMessage: null,
    );
  }

  Future<void> switchToDomesticIp() async {
    _rawIpInfo = null;
    _isIpMasked = false;

    _cancelPreviousRequest();
    _cancelToken = CancelToken();
    final requestId = ++_requestId;

    state.value = state.value.copyWith(
      isLoading: true,
      ipInfo: null,
      errorMessage: null,
    );

    final res = await request.checkIpDomestic(
      cancelToken: _cancelToken,
      onUpdate: (info) => _onIpProgress(requestId, info),
    );

    if (requestId != _requestId) return;

    _handleResponse(res);
  }

  void startCheck({bool immediate = false, bool showLoading = false}) {
    final appState = globalState.appState;
    if (!appState.isInit) return;

    if (showLoading || state.value.ipInfo == null) {
      state.value = state.value.copyWith(
        isLoading: true,
        errorMessage: null,
      );
    }

    final delay = immediate
        ? Duration.zero
        : const Duration(milliseconds: 1000);

    debouncer.call(
      FunctionTag.checkIp,
      () => _checkIp(showLoading: showLoading),
      duration: delay,
    );
  }

  void tryStartCheck() {
    if (!state.value.isLoading &&
        state.value.ipInfo == null &&
        (_preIsStart == null || state.value.errorMessage != null)) {
      startCheck();
    }
  }

  void _cancelPreviousRequest() {
    _cancelToken?.cancel();
    _cancelToken = null;
  }

  void _handleResponse(Result<IpInfo?> res) {
    if (res.isError) {
      if (res.message == 'cancelled') {
        state.value = state.value.copyWith(
          isLoading: false,
          errorMessage: null,
        );
        return;
      }
      if (state.value.ipInfo == null) {
        _rawIpInfo = null;
        state.value = state.value.copyWith(
          isLoading: false,
          ipInfo: null,
          errorMessage: appLocalizations.tryManualRefresh,
        );
      } else {
        state.value = state.value.copyWith(isLoading: false);
      }
      return;
    }

    if (res.data != null) {
      _rawIpInfo ??= res.data;
    }
    state.value = state.value.copyWith(
      isLoading: false,
      ipInfo: _maskIpInfo(_rawIpInfo),
      errorMessage: _rawIpInfo != null
          ? null
          : (state.value.ipInfo == null
              ? appLocalizations.tryManualRefresh
              : null),
    );
  }

  Future<void> _checkIp({bool showLoading = false}) async {
    final appState = globalState.appState;

    if (!appState.isInit) return;

    final isStart = appState.runTime != null;

    final isStateChanged = _preIsStart != isStart;
    _preIsStart = isStart;

    if (!isStart &&
        _rawIpInfo != null &&
        !state.value.isLoading &&
        !isStateChanged) {
      return;
    }

    _cancelPreviousRequest();
    _cancelToken = CancelToken();
    final requestId = ++_requestId;

    final shouldShowLoading =
        showLoading || state.value.ipInfo == null || isStateChanged;
    if (shouldShowLoading) {
      _rawIpInfo = null;
      state.value = state.value.copyWith(
        isLoading: true,
        errorMessage: null,
        ipInfo: isStateChanged ? null : state.value.ipInfo,
      );
    }

    final timeout = const Duration(seconds: 5);

    final res = isStart
        ? await request.checkIp(
            cancelToken: _cancelToken,
            timeout: timeout,
            onUpdate: (info) => _onIpProgress(requestId, info),
          )
        : await request.checkIpDomestic(
            cancelToken: _cancelToken,
            timeout: timeout,
            onUpdate: (info) => _onIpProgress(requestId, info),
          );

    if (requestId != _requestId) return;

    if (_isFirstLaunch && (res.isError || res.data == null)) {
      _isFirstLaunch = false;
      _handleResponse(res);

      Future.delayed(const Duration(seconds: 3), () {
        if (state.value.ipInfo == null && !state.value.isLoading) {
          startCheck();
        }
      });
    } else {
      _isFirstLaunch = false;
      _handleResponse(res);
    }
  }
}

final detectionState = DetectionState();
