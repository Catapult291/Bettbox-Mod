import 'dart:convert';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/controller.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Config _config() {
  return Config(
    themeProps: defaultThemeProps,
    patchClashConfig: defaultClashConfig,
    windowProps: const WindowProps(width: 910, height: 620),
    scriptProps: ScriptProps(
      currentId: 's1',
      scripts: [Script(id: 's1', label: 'main', content: 'x' * 20000)],
    ),
  );
}

/// 从偏好设置里读回整包配置（与 [preferences.getConfig] 同一口径）。
Config? _persisted(SharedPreferences prefs) {
  final raw = prefs.getString(configKey);
  if (raw == null) return null;
  return Config.fromJson(json.decode(raw) as Map<String, dynamic>);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // 单例的 completer 只完成一次，整个文件共用同一个实例。
    prefs = (await preferences.sharedPreferencesCompleter.future)!;
  });

  setUp(() async {
    await prefs.clear();
    preferences.clearConfigSliceCache();
    globalState.config = _config();
    globalState.takeDirtyConfigSlices();
  });

  ProviderContainer container() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  test('设置写入只标脏自己那一片（没有界面监听也生效）', () {
    final c = container();
    c.read(themeSettingProvider.notifier).updateState(
      (state) => state.copyWith(pureBlack: true),
    );

    expect(globalState.takeDirtyConfigSlices(), {ConfigSlice.themeProps});
    expect(globalState.config.themeProps.pureBlack, isTrue);
  });

  test('设置写入拨动 configRevision（AppStateManager 的保存触发面）', () {
    final before = globalState.configRevision.value;
    final c = container();
    c.read(themeSettingProvider.notifier).updateState(
      (state) => state.copyWith(pureBlack: true),
    );

    expect(globalState.configRevision.value, before + 1);
  });

  test('连续改窗口尺寸只累计 windowProps 一个脏分片', () {
    final c = container();
    final notifier = c.read(windowSettingProvider.notifier);
    for (var i = 0; i < 5; i++) {
      notifier.updateState((state) => state.copyWith(width: 900 + i.toDouble()));
    }

    expect(globalState.takeDirtyConfigSlices(), {ConfigSlice.windowProps});
    expect(globalState.config.windowProps.width, 904);
  });

  test('进程分流写入会标脏 processAccess（§159 回归）', () {
    final c = container();
    c.read(processAccessStateProvider.notifier).updateState(
      (state) => state.copyWith(
        mode: ProcessAccessMode.blacklist,
        paths: const [r'C:\apps\a.exe'],
      ),
    );

    expect(globalState.takeDirtyConfigSlices(), {ConfigSlice.processAccess});
    expect(
      globalState.config.processAccess.paths,
      [r'C:\apps\a.exe'],
    );
  });

  test('整包替换配置标脏全部分片并清空编码缓存', () {
    preferences.clearConfigSliceCache();
    globalState.config = _config().copyWith(nodeExcludeFilter: 'x');

    expect(
      globalState.takeDirtyConfigSlices(),
      ConfigSlice.values.toSet(),
      reason: '整包替换无法判断改了哪一片，下次落盘写全',
    );
    expect(globalState.takeDirtyConfigSlices(), isEmpty, reason: '取走即清空');
  });

  /// 挂一个最小 `ProviderScope`，拿到 `WidgetRef` 并装好 `AppController`
  /// （`savePreferences` 只用到 `preferences` 与 `globalState`）。
  Future<WidgetRef> pumpController(WidgetTester tester) async {
    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (context, widgetRef, _) {
            ref = widgetRef;
            return const SizedBox();
          },
        ),
      ),
    );
    globalState.appController = AppController(
      tester.element(find.byType(SizedBox)),
      ref,
    );
    return ref;
  }

  testWidgets('落盘只重编码脏分片，但写入的仍是完整配置', (tester) async {
    final ref = await pumpController(tester);

    await tester.runAsync(() async {
      ref.read(themeSettingProvider.notifier).updateState(
        (state) => state.copyWith(pureBlack: true),
      );

      await globalState.appController.savePreferences();

      expect(globalState.takeDirtyConfigSlices(), isEmpty);
      final persisted = _persisted(prefs);
      expect(persisted, globalState.config, reason: '落盘内容应是一份完整配置');
      expect(persisted?.themeProps.pureBlack, isTrue);
      expect(persisted?.scriptProps.scripts.single.content.length, 20000);
      // 走一遍真实读取路径：分片拼出的 JSON 要能被 `getConfig` 解析。
      expect(await preferences.getConfig(), globalState.config);
    });
  });

  testWidgets('第二次只改另一片：上一片的改动不会被旧片段盖回去', (tester) async {
    final ref = await pumpController(tester);

    await tester.runAsync(() async {
      ref.read(themeSettingProvider.notifier).updateState(
        (state) => state.copyWith(pureBlack: true),
      );
      await globalState.appController.savePreferences();

      ref.read(windowSettingProvider.notifier).updateState(
        (state) => state.copyWith(width: 1234),
      );
      await globalState.appController.savePreferences();

      final persisted = _persisted(prefs);
      expect(persisted, globalState.config);
      expect(persisted?.themeProps.pureBlack, isTrue, reason: '第一片仍是新值');
      expect(persisted?.windowProps.width, 1234);
    });
  });

  testWidgets('没有脏分片时不写盘', (tester) async {
    await pumpController(tester);

    await tester.runAsync(() async {
      await prefs.setString(configKey, '{"sentinel":true}');
      await globalState.appController.savePreferences();
      expect(prefs.getString(configKey), '{"sentinel":true}');
    });
  });
}
