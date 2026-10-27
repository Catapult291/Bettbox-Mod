import 'dart:convert';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实配置里的分片构成：脚本内容与订阅配置占绝大多数字节，窗口尺寸、
/// 主题这类热设置只有百字节级。
Config _config() {
  return Config(
    themeProps: defaultThemeProps.copyWith(pureBlack: true, primaryColor: 0xFF123456),
    windowProps: const WindowProps(width: 910, height: 620),
    appSetting: defaultAppSettingProps.copyWith(locale: 'zh'),
    networkProps: defaultNetworkProps.copyWith(systemProxy: true),
    vpnProps: defaultVpnProps.copyWith(trayEnhancement: true),
    proxiesStyle: defaultProxiesStyle.copyWith(showHiddenItems: true),
    profiles: [
      const Profile(
        id: 'p1',
        label: '订阅 A',
        url: 'https://example.com/a.yaml',
        autoUpdateDuration: Duration(hours: 12),
      ),
      const Profile(
        id: 'p2',
        label: '订阅 B',
        url: 'https://example.com/b.yaml',
        autoUpdateDuration: Duration(hours: 24),
      ),
    ],
    currentProfileId: 'p1',
    hotKeyActions: const [HotKeyAction(action: HotAction.start, key: 65)],
    patchClashConfig: defaultClashConfig.copyWith(mode: Mode.global),
    scriptProps: ScriptProps(
      currentId: 's1',
      scripts: [Script(id: 's1', label: 'main', content: 'x' * 30000)],
    ),
    processAccess: const ProcessAccessProps(mode: ProcessAccessMode.blacklist),
    nodeExcludeFilter: '过期',
    healthCheckTimeout: 8000,
  );
}

Config _decode(String blob) =>
    Config.fromJson(json.decode(blob) as Map<String, dynamic>);

void main() {
  test('分片键集与 Config.toJson 的键完全一致（新增字段必须补分片）', () {
    final keys = ConfigSlice.values.map((slice) => slice.key).toSet();
    expect(keys, _config().toJson().keys.toSet());
  });

  test('每个分片取出的值与整包 JSON 的同名字段逐字一致', () {
    final config = _config();
    final full = json.decode(json.encode(config)) as Map<String, dynamic>;
    for (final slice in ConfigSlice.values) {
      expect(
        json.encode(slice.valueOf(config)),
        json.encode(full[slice.key]),
        reason: '分片 ${slice.key} 与整包 JSON 的同名字段不一致',
      );
    }
  });

  test('首次落盘（无缓存）与 json.encode(config) 等价', () {
    final config = _config();
    final cache = <ConfigSlice, String>{};
    final blob = encodeConfigBlob(config, ConfigSlice.values.toSet(), cache);

    expect(json.decode(blob), json.decode(json.encode(config)));
    expect(_decode(blob), config, reason: '应能原样读回一份相等的配置');
    expect(cache.length, ConfigSlice.values.length);
    for (final slice in ConfigSlice.values) {
      expect(cache[slice], json.encode(slice.valueOf(config)));
    }
  });

  test('只改一个分片时其余分片复用缓存的编码结果', () {
    final config = _config();
    final cache = <ConfigSlice, String>{};
    encodeConfigBlob(config, ConfigSlice.values.toSet(), cache);
    final before = Map<ConfigSlice, String>.of(cache);

    final next = config.copyWith(
      windowProps: config.windowProps.copyWith(width: 1200),
    );
    final blob = encodeConfigBlob(next, {ConfigSlice.windowProps}, cache);

    expect(_decode(blob), next);
    expect(cache[ConfigSlice.windowProps], isNot(before[ConfigSlice.windowProps]));
    for (final slice in ConfigSlice.values) {
      if (slice == ConfigSlice.windowProps) continue;
      expect(
        identical(cache[slice], before[slice]),
        isTrue,
        reason: '分片 ${slice.key} 未变更，不应重新编码',
      );
    }
  });

  test('连续改多个分片：每次都等价于整包编码', () {
    var config = _config();
    final cache = <ConfigSlice, String>{};
    encodeConfigBlob(config, ConfigSlice.values.toSet(), cache);

    final steps = <(Config Function(Config), ConfigSlice)>[
      (
        (c) => c.copyWith(themeProps: c.themeProps.copyWith(pureBlack: false)),
        ConfigSlice.themeProps,
      ),
      (
        (c) => c.copyWith(profiles: [...c.profiles, c.profiles.first]),
        ConfigSlice.profiles,
      ),
      (
        (c) => c.copyWith(
          scriptProps: c.scriptProps.copyWith(
            scripts: [
              ...c.scriptProps.scripts,
              Script(id: 's2', label: 'extra', content: 'y' * 5000),
            ],
          ),
        ),
        ConfigSlice.scriptProps,
      ),
      (
        (c) => c.copyWith(healthCheckTimeout: 9000),
        ConfigSlice.healthCheckTimeout,
      ),
    ];

    for (final (build, slice) in steps) {
      final next = build(config);
      final blob = encodeConfigBlob(next, {slice}, cache);
      expect(json.decode(blob), json.decode(json.encode(next)));
      expect(_decode(blob), next);
      config = next;
    }
  });

  test('缓存缺失的分片会照常编码（首次落盘只标一个脏分片也写全）', () {
    final config = _config();
    final cache = <ConfigSlice, String>{};
    final blob = encodeConfigBlob(config, {ConfigSlice.themeProps}, cache);

    expect(cache.length, ConfigSlice.values.length);
    expect(_decode(blob), config);
  });

  test('空变更集也能拼出完整 JSON', () {
    final config = _config();
    final cache = <ConfigSlice, String>{};
    encodeConfigBlob(config, ConfigSlice.values.toSet(), cache);
    final blob = encodeConfigBlob(config, const {}, cache);
    expect(json.decode(blob), json.decode(json.encode(config)));
  });
}
