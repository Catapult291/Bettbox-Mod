import 'dart:async';
import 'dart:io';

import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/rust/bettbox_config.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.supportPath);

  final String supportPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;

  @override
  Future<String?> getTemporaryPath() async => supportPath;

  @override
  Future<String?> getDownloadsPath() async => supportPath;
}

class _TestGlobalState extends GlobalState {
  _TestGlobalState() : super.forTest();

  @override
  Future<Map<String, dynamic>> getProfileConfig(String profileId) async => {};
}

/// 动态库缺失与 ABI 失配都在加载层暴露（`_tryLoad` 失败并缓存错误），走同一条路径；
/// 这里把 `Directory.current` 挪到空目录，让 exe 同目录与仓库 cargo 产物两个候选都落空。
Future<void> _withoutNativeLibrary(FutureOr<void> Function() body) async {
  final original = Directory.current;
  final empty = Directory.systemTemp.createTempSync('bettbox_no_dll');
  Directory.current = empty.path;
  try {
    expect(BettboxConfig.isAvailable, isFalse);
    await body();
  } finally {
    Directory.current = original;
    empty.deleteSync(recursive: true);
  }
}

/// 失败策略（路线稿 §1.5 第 4 步）：Rust 管道是唯一实现，动态库不可用时**报错**，
/// 而不是换一套实现继续跑；配置没生成出来时，上一份可用的运行配置保持原样。
void main() {
  test('动态库不可用时 patchConfig / processProfile 抛错，不返回 null', () {
    return _withoutNativeLibrary(() {
      expect(() => BettboxConfig.patchConfig('{}'), throwsA(isA<StateError>()));
      expect(
        () => BettboxConfig.processProfile(
          '{}',
          'function main(c){ return c; }',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  test('配置改写失败时 patchRawConfig 报错，且不动上一份运行配置', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppLocalizations.load(const Locale('zh', 'CN'));

    await _withoutNativeLibrary(() async {
      final configDir = Directory.systemTemp.createTempSync('bettbox_prev_cfg');
      PathProviderPlatform.instance = _FakePathProvider(configDir.path);

      final configFile = File(p.join(configDir.path, 'config.yaml'));
      configFile.writeAsStringSync('previous: good\n');

      final state = _TestGlobalState();
      state.config = Config(
        themeProps: defaultThemeProps,
        patchClashConfig: defaultClashConfig,
        scriptProps: const ScriptProps(),
        profiles: [
          Profile(
            id: 'p1',
            label: 'p1',
            autoUpdateDuration: const Duration(days: 1),
          ),
        ],
        currentProfileId: 'p1',
      );

      await expectLater(
        state.getSetupParams(pathConfig: state.config.patchClashConfig),
        throwsA(isA<StateError>()),
      );
      expect(
        configFile.readAsStringSync(),
        'previous: good\n',
        reason: '配置没生成出来时不能改写上一份可用的运行配置',
      );
      configDir.deleteSync(recursive: true);
    });
  });
}
