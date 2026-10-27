import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/clash/groups_build_cache.dart';
import 'package:bett_box/clash/interface.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:path/path.dart';

class ClashCore {
  static ClashCore? _instance;
  late ClashHandlerInterface clashInterface;

  final _groupsCache = GroupsBuildCache();

  ClashCore._internal() {
    if (system.isAndroid) {
      clashInterface = clashLib!;
    } else {
      clashInterface = clashService!;
    }
  }

  factory ClashCore() {
    _instance ??= ClashCore._internal();
    return _instance!;
  }

  Future<bool> preload() {
    return clashInterface.preload();
  }

  static Future<void> initGeo() async {
    final homePath = await appPath.homeDirPath;
    final homeDir = Directory(homePath);
    if (!await homeDir.exists()) {
      await homeDir.create(recursive: true);
    }
    const geoFileNameList = [mmdbFileName, geoSiteFileName, asnFileName, bundleMRSFileName];
    try {
      for (final geoFileName in geoFileNameList) {
        final geoFile = File(join(homePath, geoFileName));
        if (await geoFile.exists()) continue;
        final data = await rootBundle.load('assets/data/$geoFileName');
        await geoFile.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
    } catch (e) {
      exit(0);
    }
  }

  Future<bool> init() async {
    await initGeo();
    if (globalState.config.appSetting.openLogs) {
      clashCore.startLog();
    } else {
      clashCore.stopLog();
    }
    final homeDirPath = await appPath.homeDirPath;
    return await clashInterface.init(
      InitParams(homeDir: homeDirPath, version: globalState.appState.version),
    );
  }

  Future<bool> setState(CoreState state) async {
    return await clashInterface.setState(state);
  }

  Future<void> shutdown() async {
    await clashInterface.shutdown();
  }

  FutureOr<bool> get isInit => clashInterface.isInit;

  FutureOr<String> validateConfig(String data, {String? ageSecretKey}) {
    return clashInterface.validateConfig(data, ageSecretKey: ageSecretKey);
  }

  FutureOr<String> decryptAgeConfig(String data, String ageSecretKey) {
    return clashInterface.decryptAgeConfig(data, ageSecretKey);
  }

  Future<String> updateConfig(UpdateParams updateParams) async {
    return await clashInterface.updateConfig(updateParams);
  }

  Future<String> setupConfig(
    SetupParams setupParams, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    return await clashInterface.setupConfig(setupParams, timeout: timeout);
  }

  /// [providersRawContent] 是 provider 列表的原始 JSON 原文（见
  /// [getExternalProvidersRawContent]）。传进来只为了避免同一份数据取两次。
  ///
  /// provider 的全节点列表体积最大，这里把它当作构组的临时输入：原文送进
  /// isolate 内解码，主 isolate 不物化它，isolate 结束即随之释放，
  /// 不会被任何常驻状态持有。
  ///
  /// 代理表与 provider 原文都没变（见 [groupsSourceDigest]）时直接复用上一次
  /// 结果：`updateGroups` 的多数触发（延迟测速、回前台、切模式）并不改内容，
  /// 这类刷新只付取数的 IPC，不再付 isolate 与 `Group.fromJson`。
  Future<List<Group>> getProxiesGroups({String? providersRawContent}) async {
    final proxies = await clashInterface.getProxies();
    if (proxies.isEmpty) return [];

    final rawContent =
        providersRawContent ?? await getExternalProvidersRawContent();

    return buildGroupsWithCache(
      cache: _groupsCache,
      proxies: proxies,
      rawProvidersContent: rawContent,
    );
  }

  /// [getProxiesGroups] 取数之后的构组步骤：指纹命中就复用上次结果，否则在
  /// isolate 内重建。单独抽出来是为了能直接测「跳过重建」这条分支。
  @visibleForTesting
  static Future<List<Group>> buildGroupsWithCache({
    required GroupsBuildCache cache,
    required Map proxies,
    required String rawProvidersContent,
  }) async {
    final digest = groupsSourceDigest(proxies, rawProvidersContent);
    final cached = cache.lookup(digest);
    if (cached != null) {
      return cached;
    }

    final groups = await Isolate.run<List<Group>>(
      () => buildProxiesGroups(proxies, rawProvidersContent),
    );
    cache.store(digest, groups);
    return groups;
  }

  /// 内核重启、换配置后作废构组缓存（旧结果可能来自另一个内核实例）。
  void invalidateGroupsCache() {
    _groupsCache.clear();
  }

  /// 由内核代理表 + provider 原文构建分组（含把 provider 节点并入代理表）。
  ///
  /// 单独抽出来是为了能直接测：provider 节点合并是这条链路上最容易出错的
  /// 一步（漏并会让分组里少节点），而它原先埋在 `Isolate.run` 的闭包里。
  static List<Group> buildProxiesGroups(
    Map proxies,
    String rawProvidersContent,
  ) {
    return buildProxiesGroupsRaw(proxies, rawProvidersContent)
        .map((e) => Group.fromJson(e))
        .toList();
  }

  /// [buildProxiesGroups] 的原始形态：返回喂给 `Group.fromJson` 的分组 map。
  ///
  /// 单独暴露是为了能和 Rust 侧逐字段差分（typed 的 `Group` 会丢掉模型外的字段）。
  static List<Map<String, dynamic>> buildProxiesGroupsRaw(
    Map proxies,
    String rawProvidersContent,
  ) {
    final providers = rawProvidersContent.isEmpty
        ? const <ExternalProvider>[]
        : (json.decode(rawProvidersContent) as List<dynamic>)
              .map((item) => ExternalProvider.fromJson(item))
              .toList();
    final allProxies = Map<String, dynamic>.from(proxies);
    for (final provider in providers) {
      if (provider.proxies != null) {
        for (final proxy in provider.proxies!) {
          if (proxy is Map) {
            final proxyMap = Map<String, dynamic>.from(proxy);
            final name = proxyMap['name'];
            if (name != null) {
              allProxies[name] = proxyMap;
              final suffix = '[${provider.name}]';
              if (!name.endsWith(suffix)) {
                allProxies['$name$suffix'] = proxyMap;
              }
            }
          }
        }
      }
    }

    final globalProxy = allProxies[UsedProxy.GLOBAL.name];
    if (globalProxy == null) return [];

    final allList = globalProxy['all'] as List?;
    if (allList == null) return [];

    final groupNames = [
      UsedProxy.GLOBAL.name,
      ...allList.where((e) {
        final proxy = allProxies[e];
        if (proxy is Map) {
          return GroupTypeExtension.valueList.contains(proxy['type']);
        }
        return false;
      }),
    ];
    final groupsRaw = groupNames.map((groupName) {
      final proxyData = allProxies[groupName] as Map?;
      if (proxyData == null) return null;
      final group = Map<String, dynamic>.from(
        proxyData.cast<String, dynamic>(),
      );
      group['all'] = ((group['all'] ?? []) as List)
          .map((name) {
            final p = allProxies[name];
            return p is Map ? Map<String, dynamic>.from(p) : null;
          })
          .whereType<Map<String, dynamic>>()
          .toList();
      return group;
    }).whereType<Map<String, dynamic>>().toList();
    return groupsRaw;
  }

  FutureOr<String> changeProxy(ChangeProxyParams changeProxyParams) async {
    return await clashInterface.changeProxy(changeProxyParams);
  }

  Future<Mode> getMode() async {
    final modeStr = await clashInterface.getMode();
    return Mode.values.firstWhere(
      (m) => m.name == modeStr.toLowerCase(),
      orElse: () => Mode.rule,
    );
  }

  Future<List<TrackerInfo>> getConnections() async {
    final res = await clashInterface.getConnections();
    if (res.isEmpty) {
      return [];
    }
    try {
      final connectionsData = json.decode(res) as Map;
      final connectionsRaw = connectionsData['connections'] as List? ?? [];
      return connectionsRaw.map((e) => TrackerInfo.fromJson(e)).toList();
    } catch (e) {
      commonPrint.log('Failed to parse connections: $e');
      return [];
    }
  }

  /// 只取连接数：内核走 `Manager.Count()`，不物化连接表也不序列化。
  /// 首页计数卡片用它替代整包 [getConnections]。
  Future<int> getConnectionsCount() async {
    final res = await clashInterface.getConnectionsCount();
    if (res.isEmpty) {
      return 0;
    }
    return int.tryParse(res) ?? 0;
  }

  void closeConnection(String id) {
    clashInterface.closeConnection(id);
  }

  Future<void> closeConnections() async {
    await clashInterface.closeConnections();
  }

  void resetConnections() {
    clashInterface.resetConnections();
  }

  /// provider 列表的原始 JSON 原文。取原文是为了让调用方既能拿到元数据，
  /// 又能把同一份原文转交给 [getProxiesGroups] 构组，避免取两次。
  Future<String> getExternalProvidersRawContent() async {
    return await clashInterface.getExternalProviders();
  }

  /// 只回传 provider 的元数据（名字/类型/条目数/订阅信息/更新时间），
  /// 不含全节点列表 —— 后者只在 [getProxiesGroups] 里瞬时使用。
  Future<List<ExternalProvider>> getExternalProviders() async {
    final rawContent = await getExternalProvidersRawContent();
    return parseExternalProvidersMeta(rawContent);
  }

  Future<List<ExternalProvider>> parseExternalProvidersMeta(
    String rawContent,
  ) async {
    if (rawContent.isEmpty) return [];
    try {
      return await Isolate.run<List<ExternalProvider>>(
        () => parseExternalProvidersMetaSync(rawContent),
      );
    } catch (e) {
      commonPrint.log('Failed to parse external providers: $e');
      return [];
    }
  }

  /// [parseExternalProvidersMeta] 的同步实现，单独暴露以便直接测试。
  static List<ExternalProvider> parseExternalProvidersMetaSync(
    String rawContent,
  ) {
    return (json.decode(rawContent) as List<dynamic>)
        .map((item) => ExternalProvider.fromJson(item).withoutProxies)
        .toList();
  }

  Future<ExternalProvider?> getExternalProvider(
    String externalProviderName,
  ) async {
    final externalProvidersRawString = await clashInterface.getExternalProvider(
      externalProviderName,
    );
    if (externalProvidersRawString.isEmpty) {
      return null;
    }
    try {
      return ExternalProvider.fromJson(
        json.decode(externalProvidersRawString),
      ).withoutProxies;
    } catch (e) {
      commonPrint.log('Failed to parse external provider: $e');
      return null;
    }
  }

  Future<String> updateGeoData(UpdateGeoDataParams params) {
    return clashInterface.updateGeoData(params);
  }

  Future<String> sideLoadExternalProvider({
    required String providerName,
    required String data,
  }) {
    return clashInterface.sideLoadExternalProvider(
      providerName: providerName,
      data: data,
    );
  }

  Future<String> updateExternalProvider({required String providerName}) async {
    return clashInterface.updateExternalProvider(providerName);
  }

  Future<String> parseExternalProviderContent(String providerName) {
    return clashInterface.parseExternalProviderContent(providerName);
  }

  /// 返回内核是否真的把监听建起来了。
  ///
  /// 内核侧 `handleStartListener` 会核对自己是否持有 mixed-port（被别的程序
  /// 占用时会回报 false，而不是只置运行标志）。IPC 超时/指令被丢时仍可能拿
  /// 不到真实结果，调用方最好再配合 [isLoopbackPortListening] 探测一次。
  Future<bool> startListener({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    try {
      return await clashInterface.startListener(timeout: timeout);
    } catch (e) {
      commonPrint.log('Core startListener failed: $e');
      return false;
    }
  }

  /// 返回内核是否应答了停止指令（IPC 超时会被 [ClashHandlerInterface.invoke]
  /// 兜成 false），调用方据此判断能不能把状态改成"已停止"。
  Future<bool> stopListener() async {
    return await clashInterface.stopListener();
  }

  Future<Delay> getDelay(String url, String proxyName) async {
    final data = await clashInterface.asyncTestDelay(url, proxyName);
    if (data.isEmpty) {
      throw Exception('Empty delay response');
    }
    try {
      return Delay.fromJson(json.decode(data));
    } catch (e) {
      commonPrint.log('Failed to parse delay: $e');
      rethrow;
    }
  }

  /// 批量延迟测速：一次 IPC 拿回一整批节点的结果。
  ///
  /// 内核按请求顺序回包；超时、未连上内核或整批应答不可解析时，
  /// 每个目标都落回 -1（Timeout），不让界面停在测速动画上。
  Future<List<Delay>> getDelays(List<Map<String, String>> targets) async {
    if (targets.isEmpty) {
      return const [];
    }
    final data = await clashInterface.asyncTestDelayBatch(targets);
    return parseDelays(data, targets);
  }

  Future<Map<String, dynamic>> getConfig(String id, {String? ageSecretKey}) async {
    final profilePath = await appPath.getProfilePath(id);
    final res = await clashInterface.getConfig(profilePath, ageSecretKey: ageSecretKey);
    if (res.isSuccess) {
      // 内核回的类型不可信：直接强转会抛错打断整条启动链，这里按类型收敛。
      final data = res.data;
      if (data is Map<String, dynamic>) {
        return data;
      }
      if (data is Map) {
        return Map<String, dynamic>.from(data);
      }
      return <String, dynamic>{};
    } else {
      throw res.message;
    }
  }

  /// 当前速率与累计流量的合并读取：内核 `getTraffic` 单包返回
  /// `{up, down, totalUp, totalDown}`，一次 IPC 取全。原先每秒各调一次
  /// getTraffic/getTotalTraffic 是固定两次往返，合并后减半。
  Future<TrafficSnapshot> getTraffic() async {
    final trafficString = await clashInterface.getTraffic();
    if (trafficString.isEmpty) {
      return TrafficSnapshot.empty();
    }
    try {
      return TrafficSnapshot.fromMap(json.decode(trafficString));
    } catch (e) {
      commonPrint.log('Failed to parse traffic: $e');
      return TrafficSnapshot.empty();
    }
  }

  Future<IpInfo?> getCountryCode(String ip) async {
    final countryCode = await clashInterface.getCountryCode(ip);
    if (countryCode.isEmpty) {
      return null;
    }
    return IpInfo(ip: ip, countryCode: countryCode);
  }

  Future<int> getMemory() async {
    final value = await clashInterface.getMemory();
    if (value.isEmpty) {
      return 0;
    }
    return int.parse(value);
  }

  void resetTraffic() {
    clashInterface.resetTraffic();
  }

  void startLog() {
    clashInterface.startLog();
  }

  void stopLog() {
    clashInterface.stopLog();
  }

  Future<void> requestGc({bool forceFreeOSMemory = false}) async {
    await clashInterface.forceGc(forceFreeOSMemory: forceFreeOSMemory);
  }

  Future<void> flushFakeIP() async {
    await clashInterface.flushFakeIP();
  }

  Future<void> flushDnsCache() async {
    await clashInterface.flushDnsCache();
  }

  Future<Map<String, String>> generateAgeKeyPair() {
    return clashInterface.generateAgeKeyPair();
  }

  Future<Result<String>> convertAgeSecretKeyToPublicKey(String secretKey) {
    return clashInterface.convertAgeSecretKeyToPublicKey(secretKey);
  }

  Future<void> destroy() async {
    await clashInterface.destroy();
  }
}

final clashCore = ClashCore();

/// 解析 `asyncTestDelayBatch` 的应答。
///
/// [targets] 是发起请求时的目标列表，用于两件事：缺项补 -1，以及把内核
/// 找不到节点时回的空 `url`（与单节点应答形态一致）换回请求里的地址——
/// 界面按 url 查延迟，空 url 会让卡片一直停在测速动画上。
@visibleForTesting
List<Delay> parseDelays(String raw, List<Map<String, String>> targets) {
  List<Delay> fallback() => targets
      .map(
        (t) => Delay(
          name: t['proxy-name'] ?? '',
          url: t['test-url'] ?? '',
          value: -1,
        ),
      )
      .toList();

  if (raw.isEmpty) {
    return fallback();
  }

  final List decoded;
  try {
    final value = json.decode(raw);
    if (value is! List) {
      commonPrint.log('Failed to parse delay batch: not a list');
      return fallback();
    }
    decoded = value;
  } catch (e) {
    commonPrint.log('Failed to parse delay batch: $e');
    return fallback();
  }

  final delays = fallback();
  final count =
      decoded.length < targets.length ? decoded.length : targets.length;
  for (var i = 0; i < count; i++) {
    final item = decoded[i];
    if (item is! Map) {
      continue;
    }
    try {
      final delay = Delay.fromJson(Map<String, dynamic>.from(item));
      delays[i] = delay.url.isEmpty
          ? delay.copyWith(url: targets[i]['test-url'] ?? '')
          : delay;
    } catch (e) {
      commonPrint.log('Failed to parse delay at $i: $e');
    }
  }
  return delays;
}