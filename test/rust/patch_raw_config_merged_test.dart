import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/rust/bettbox_config.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 测试环境没有 `path_provider_windows`，`AppPath` 构造时就要这三个目录。
class _FakePathProvider extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async => Directory.systemTemp.path;

  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;

  @override
  Future<String?> getDownloadsPath() async => Directory.systemTemp.path;
}

/// 只替换 [GlobalState.getProfileConfig]（避免真内核），并记录两段式路径是否被走到。
///
/// 本用例只验证 `patchRawConfig` 在合并入口与两段式之间的**分支选择**，不重复覆盖
/// Dart 镜像的实现，所以 [handleEvaluate] 只做标记、原样返回。
class _TestGlobalState extends GlobalState {
  _TestGlobalState(this.profileConfig) : super.forTest();

  final Map<String, dynamic> profileConfig;
  bool twoStageReached = false;

  @override
  Future<Map<String, dynamic>> getProfileConfig(String profileId) async =>
      jsonDecode(jsonEncode(profileConfig)) as Map<String, dynamic>;

  @override
  Future<Map<String, dynamic>> handleEvaluate(
    Map<String, dynamic> config, {
    Profile? profile,
  }) async {
    twoStageReached = true;
    return config;
  }
}

Map<String, dynamic> _rawConfig() => jsonDecode('''
{
  "proxies": [{"name": "节点1", "type": "ss", "server": "a.example.com"}],
  "proxy-groups": [
    {"name": "自动选择", "type": "url-test", "proxies": ["节点1", "DIRECT"]}
  ],
  "rules": ["MATCH,自动选择"]
}
''') as Map<String, dynamic>;

Script _script(String content) => Script(id: 's1', label: 's', content: content);

Profile _profile({bool useScriptOverride = true}) => Profile(
  id: 'p1',
  label: 'p1',
  autoUpdateDuration: defaultUpdateDuration,
  useScriptOverride: useScriptOverride,
  groupSwitches: const {'自动选择': false},
);

Config _config(Script? script) => Config(
  themeProps: defaultThemeProps,
  patchClashConfig: defaultClashConfig,
  overrideDns: true,
  scriptProps: script == null
      ? const ScriptProps()
      : ScriptProps(currentId: script.id, scripts: [script]),
);

void main() {
  final available = BettboxConfig.isAvailable;
  final skipReason = available
      ? null
      : '未找到 bettbox_native 动态库，先构建：cd rust && cargo build --release';

  late _TestGlobalState state;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppLocalizations.load(const Locale('zh', 'CN'));
    PathProviderPlatform.instance = _FakePathProvider();
    state = _TestGlobalState(_rawConfig());
  });

  group('patchRawConfig 合并入口接线', () {
    test('两个开关都开且脚本适用时走合并入口，不再走两段式', () async {
      final config = _config(
        _script("function main(c){ c['mergedMarker'] = 'yes'; return c; }"),
      );
      state.config = config;
      final uiPath = await appPath.uiPath;

      final result = await state.patchRawConfig(
        patchConfig: config.patchClashConfig,
        profile: _profile(),
      );

      expect(state.twoStageReached, isFalse, reason: '走了合并入口就不该再走两段式');
      expect(result['mergedMarker'], 'yes', reason: '脚本必须真的在 Rust 内跑过');
      expect(result['external-ui'], uiPath, reason: 'patch 管道必须真的跑过');
    });

    test('脚本抛错时 patch 仍产出，但不回退两段式', () async {
      final config = _config(
        _script("function main(c){ throw new Error('boom'); }"),
      );
      state.config = config;
      final uiPath = await appPath.uiPath;

      final result = await state.patchRawConfig(
        patchConfig: config.patchClashConfig,
        profile: _profile(),
      );

      expect(state.twoStageReached, isFalse);
      expect(result['external-ui'], uiPath);
    });

    test('profile 未启用脚本覆写时跳过合并入口，走两段式', () async {
      final config = _config(
        _script("function main(c){ c['mergedMarker'] = 'yes'; return c; }"),
      );
      state.config = config;

      await state.patchRawConfig(
        patchConfig: config.patchClashConfig,
        profile: _profile(useScriptOverride: false),
      );

      expect(state.twoStageReached, isTrue);
    });
  }, skip: skipReason);
}
