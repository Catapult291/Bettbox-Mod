import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/common/theme.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/dashboard/widgets/memory_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 侧栏配色与 `quick_controls_power_button_test.dart` 一致：默认主色 + `content` 变体。
ColorScheme _scheme(Brightness brightness) {
  return ColorScheme.fromSeed(
    seedColor: const Color(defaultPrimaryColor),
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.content,
  );
}

/// 渲染内存卡片；两个读数经构造参数注入，不碰 clashCore 与 Win32 FFI。
Future<void> _pumpCard(
  WidgetTester tester, {
  required Future<int> Function() kernel,
  required int Function() app,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: _scheme(Brightness.light)),
      home: Builder(
        builder: (context) {
          globalState.theme = CommonTheme.of(context, 1);
          globalState.measure = Measure.of(context, 1.0);
          return Material(
            color: _scheme(Brightness.light).surfaceContainerHigh,
            child: Align(
              alignment: Alignment.topLeft,
              child: MemoryInfo(
                kernelMemoryBytes: kernel,
                appMemoryBytes: app,
              ),
            ),
          );
        },
      ),
    ),
  );
  // 冲掉 initState 里首轮 _updateMemory 的微任务。
  await tester.pump();
}

/// 手动拨一次 2s tick 并等刷新落地。
///
/// `pump()` 的微任务刷新在帧检查之后：首轮冲掉 `_updateMemory` 的 await 链
/// （setState 此时才标记需要重建），第二轮才把新帧画出来。
Future<void> _tick2s(WidgetTester tester) async {
  dashboardRefreshManager.tick2s.value++;
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppLocalizations.load(const Locale('zh', 'CN'));
    globalState.config = Config(
      themeProps: defaultThemeProps,
      patchClashConfig: defaultClashConfig,
    );
    globalState.appState = AppState(
      viewSize: const Size(360, 800),
      brightness: Brightness.light,
      requests: FixedList(maxLength),
      version: 1,
      logs: FixedList(maxLength),
      traffics: FixedList(30),
      totalTraffic: Traffic(),
      systemUiOverlayStyle: const SystemUiOverlayStyle(),
    );
    MemoryInfo.debugResetCache();
  });

  testWidgets('内核读数恒为 0（已停止）时，应用读数仍随每次刷新更新（A⑥ 冻结修复）', (
    tester,
  ) async {
    var appReads = 0;
    await _pumpCard(
      tester,
      kernel: () async => 0,
      // 每次 +1 MiB 且从 2 MiB 起：1 MiB 恰好落在 KB/MB 分界（严格大于）上，避开显示歧义。
      app: () {
        appReads++;
        return (appReads + 1) * 1024 * 1024;
      },
    );

    // 内核恒 0 → initState 重试打满 5 轮（每 500ms 一轮），应用每轮都前进：
    // 第 5 轮 = (5+1) MiB。
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('应用 6.0 MB'), findsOneWidget);
    // 内核从未有过有效读数 → 保持初始 0，不闪动。
    expect(find.text('内核 0.0 B'), findsOneWidget);

    // 2s 刷新 tick：内核仍为 0，应用必须继续推进（修复前被外层 if 锁死在旧值）。
    await _tick2s(tester);
    expect(find.text('应用 7.0 MB'), findsOneWidget);
    expect(find.text('内核 0.0 B'), findsOneWidget);
  });

  testWidgets('内核从有值降到 0：内核保留上次有效值，应用读数继续推进', (tester) async {
    var kernelReads = 0;
    var appReads = 0;
    await _pumpCard(
      tester,
      kernel: () async {
        kernelReads++;
        // 第 3 次读数起模拟内核已停止。
        return kernelReads >= 3 ? 0 : 100 * 1024 * 1024;
      },
      app: () {
        appReads++;
        return (appReads + 1) * 1024 * 1024;
      },
    );

    // 首轮：内核 100 MB > 0 → 重试立即结束；应用 = 2 MiB。
    expect(find.text('内核 100.0 MB'), findsOneWidget);
    expect(find.text('应用 2.0 MB'), findsOneWidget);

    // 第 2 轮（tick）：内核仍有值；应用推进到 3 MiB。
    await _tick2s(tester);
    expect(find.text('内核 100.0 MB'), findsOneWidget);
    expect(find.text('应用 3.0 MB'), findsOneWidget);

    // 第 3 轮（tick）：内核停止读 0 → 「内核」保留上次有效值不归零；
    // 「应用」照常推进（修复前整段被跳过、两个数一起冻结）。
    await _tick2s(tester);
    expect(find.text('内核 100.0 MB'), findsOneWidget);
    expect(find.text('应用 4.0 MB'), findsOneWidget);
  });

  testWidgets('内核读数挂死（invoke 无回包）：应用读数不受拖累，1.5s 限时后照常刷新', (
    tester,
  ) async {
    var appReads = 0;
    final hang = Completer<int>();
    addTearDown(() {
      if (!hang.isCompleted) hang.complete(0);
    });
    await _pumpCard(
      tester,
      kernel: () => hang.future,
      app: () {
        appReads++;
        return (appReads + 1) * 1024 * 1024;
      },
    );

    // 首轮：应用读数已上屏，内核 await 挂死中（修复前整卡卡在这里）。
    expect(find.text('应用 2.0 MB'), findsOneWidget);
    expect(find.text('内核 0.0 B'), findsOneWidget);

    // 推过 1.5s 超时：_isUpdating 放开 → 重试循环下一轮，应用继续前进。
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('应用 3.0 MB'), findsOneWidget);
    expect(find.text('内核 0.0 B'), findsOneWidget);

    // 内核“复活”回包：限时内的 await 拿到值，重试循环据此结束。
    // 两轮 pump：首轮冲微任务（setState），次轮出帧。
    hang.complete(42 * 1024 * 1024);
    await tester.pump();
    await tester.pump();
    expect(find.text('内核 42.0 MB'), findsOneWidget);
    expect(find.text('应用 3.0 MB'), findsOneWidget);
  });
}
