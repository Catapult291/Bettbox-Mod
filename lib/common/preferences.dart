import 'dart:async';
import 'dart:convert';

import 'package:bett_box/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config_blob.dart';
import 'constant.dart';
import 'print.dart';

class Preferences {
  static Preferences? _instance;
  Completer<SharedPreferences?> sharedPreferencesCompleter = Completer();

  /// 各 [ConfigSlice] 上一次的编码结果，见 [encodeConfigBlob]。
  final Map<ConfigSlice, String> _configSliceCache = {};

  /// 落盘串行化：编码 + 写盘排队执行，避免先编码的后写盘把新值盖回旧值。
  Future<void> _saveChain = Future<void>.value();

  Future<bool> get isInit async => await sharedPreferencesCompleter.future != null;

  Preferences._internal() {
    SharedPreferences.getInstance()
        .then((value) => sharedPreferencesCompleter.complete(value))
        .onError((_, _) => sharedPreferencesCompleter.complete(null));
  }

  factory Preferences() {
    _instance ??= Preferences._internal();
    return _instance!;
  }

  Future<ClashConfig?> getClashConfig() async {
    final preferences = await sharedPreferencesCompleter.future;
    final clashConfigString = preferences?.getString(clashConfigKey);
    if (clashConfigString == null) return null;
    try {
      final clashConfigMap = json.decode(clashConfigString);
      return ClashConfig.fromJson(clashConfigMap);
    } catch (e, stackTrace) {
      commonPrint.log('Failed to parse clash config from preferences: $e\n$stackTrace');
      return null;
    }
  }

  Future<Config?> getConfig() async {
    final preferences = await sharedPreferencesCompleter.future;
    final configString = preferences?.getString(configKey);
    if (configString == null) return null;
    try {
      final configMap = json.decode(configString);
      final config = Config.compatibleFromJson(configMap);

      if (preferences?.getBool('autoLaunch') != config.appSetting.autoLaunch) {
        await preferences?.setBool('autoLaunch', config.appSetting.autoLaunch);
      }

      return config;
    } catch (e, stackTrace) {
      commonPrint.log('Failed to parse config from preferences: $e\n$stackTrace');
      return null;
    }
  }

  /// 在途落盘全部完成的 future；没有在途任务时立即完成。
  Future<void> get idle => _saveChain;

  /// 落盘配置。[changedSlices] 为空时写全部分片；只传实际变过的分片时，
  /// 其余分片复用缓存里的编码结果（格式仍是单个 `config` 键的整包 JSON）。
  Future<bool> saveConfig(
    Config config, {
    Set<ConfigSlice>? changedSlices,
  }) {
    final next = _saveChain.then(
      (_) => _saveConfig(config, changedSlices ?? ConfigSlice.values.toSet()),
    );
    // 链上只关心顺序，单次失败不能把后续落盘一起挡掉。
    _saveChain = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<bool> _saveConfig(
    Config config,
    Set<ConfigSlice> changedSlices,
  ) async {
    final preferences = await sharedPreferencesCompleter.future;

    await preferences?.setBool('autoLaunch', config.appSetting.autoLaunch);

    // 先编码到副本：写盘失败时缓存保持上一次成功的内容，这些分片在下次落盘时
    // 是缓存未命中，会连同当前值重新编码写进去（不必重发一次保存）。
    final cache = Map<ConfigSlice, String>.of(_configSliceCache);
    final blob = encodeConfigBlob(config, changedSlices, cache);
    final saved = await preferences?.setString(configKey, blob) ?? false;
    if (saved) {
      _configSliceCache
        ..clear()
        ..addAll(cache);
    }
    return saved;
  }

  /// 丢掉分片编码缓存：整包替换 [Config]（清空设置、外部导入）后下次落盘
  /// 必须重新编码全部字段。
  void clearConfigSliceCache() => _configSliceCache.clear();

  Future<void> clearClashConfig() async {
    final preferences = await sharedPreferencesCompleter.future;
    preferences?.remove(clashConfigKey);
  }

  Future<void> clearPreferences() async {
    clearConfigSliceCache();
    final sharedPreferencesIns = await sharedPreferencesCompleter.future;
    sharedPreferencesIns?.clear();
  }
}

final preferences = Preferences();
