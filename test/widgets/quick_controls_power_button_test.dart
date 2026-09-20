import 'package:bett_box/common/common.dart';
import 'package:bett_box/common/theme.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/manager/app_manager.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/quick_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 侧栏配色与 `quick_controls_caption_test.dart` 一致：默认主色 + `content` 变体。
ColorScheme _scheme(Brightness brightness) {
  return ColorScheme.fromSeed(
    seedColor: const Color(defaultPrimaryColor),
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.content,
  );
}

/// 「有配置、初始化完成」这一档；`startButtonSelectorStateProvider` 要据此判断能否点。
const _ready = StartButtonSelectorState(isInit: true, hasProfile: true);

/// 按 `QuickSidebar` 的摆法渲染快捷控制（`surfaceContainerHigh` 底、带文字标签）。
Future<ColorScheme> _pumpControls(
  WidgetTester tester, {
  required Brightness brightness,
  StartButtonSelectorState selector = _ready,
  int? runTime,
}) async {
  final scheme = _scheme(brightness);
  globalState.appState = globalState.appState.copyWith(runTime: runTime);
  await tester.pumpWidget(
    ProviderScope(
      // 同一测试里连续渲染多个状态时必须换 key，否则 ProviderScope 的 state 被复用
      key: ValueKey('$brightness-$selector-$runTime'),
      overrides: [
        startButtonSelectorStateProvider.overrideWithValue(selector),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorScheme: scheme),
        home: Builder(
          builder: (context) {
            globalState.theme = CommonTheme.of(context, 1);
            return Material(
              color: scheme.surfaceContainerHigh,
              child: const Align(
                alignment: Alignment.topLeft,
                child: QuickControls(showCaption: true),
              ),
            );
          },
        ),
      ),
    ),
  );
  return scheme;
}

/// `QuickControls` 子树里第一个 Material —— 深度优先下就是首个控件（总开关）的方块。
Finder _quickBlock() {
  return find
      .descendant(of: find.byType(QuickControls), matching: find.byType(Material))
      .first;
}

Color? _powerIconColor(WidgetTester tester) {
  return tester.widget<Icon>(find.byIcon(Icons.power_settings_new)).color;
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
  });

  testWidgets('右栏控件自上而下是 总开关 / 系统代理 / 虚拟网卡 / 出站模式', (tester) async {
    await _pumpControls(tester, brightness: Brightness.light);

    double topOf(IconData icon) =>
        tester.getTopLeft(find.byIcon(icon)).dy;

    expect(topOf(Icons.power_settings_new), lessThan(topOf(Icons.shuffle)));
    expect(topOf(Icons.shuffle), lessThan(topOf(Icons.stacked_line_chart)));
    expect(topOf(Icons.stacked_line_chart), lessThan(topOf(Icons.swap_horiz)));
  });

  testWidgets('总开关是 44px 方块且贴着栏内容顶部（右栏按它的中心对齐左栏「首页」）', (
    tester,
  ) async {
    await _pumpControls(tester, brightness: Brightness.light);

    final block = tester.getRect(_quickBlock());
    // QuickSidebar 的 topOffset = 左栏图标中心 - quickControlSize / 2，
    // 所以首控件必须是满尺寸方块、且顶边就在 topOffset 处。
    expect(block.size, const Size(quickControlSize, quickControlSize));
    expect(block.top, 0);
  });

  testWidgets('核心未启动时总开关仍可点（右栏唯一能启动核心的入口）', (tester) async {
    await _pumpControls(tester, brightness: Brightness.light, runTime: null);

    final inkWell = tester.widget<InkWell>(
      find.descendant(of: _quickBlock(), matching: find.byType(InkWell)),
    );
    expect(inkWell.onTap, isNotNull);
    expect(_powerIconColor(tester), _scheme(Brightness.light).onSurfaceVariant);
  });

  testWidgets('核心运行中总开关用 primary 图标 + 20% primary 底色', (tester) async {
    final scheme = await _pumpControls(
      tester,
      brightness: Brightness.light,
      runTime: 0,
    );

    expect(_powerIconColor(tester), scheme.primary);
    expect(tester.widget<Material>(_quickBlock()).color, scheme.primary.withValues(alpha: 0.20));
  });

  testWidgets('没有配置时总开关不可点且显示为禁用灰', (tester) async {
    const noProfile = StartButtonSelectorState(isInit: true, hasProfile: false);
    final scheme = await _pumpControls(
      tester,
      brightness: Brightness.light,
      selector: noProfile,
    );

    final inkWell = tester.widget<InkWell>(
      find.descendant(of: _quickBlock(), matching: find.byType(InkWell)),
    );
    expect(inkWell.onTap, isNull);
    expect(
      _powerIconColor(tester),
      scheme.onSurfaceVariant.withValues(alpha: 0.38),
    );
  });

  // 英文标签在这条栏宽下会折两行，「出站模式」那块最靠下；改动前（普通 Column）英文下
  // 400 逻辑px 高就会报 RenderFlex overflow。
  for (final locale in const [Locale('zh', 'CN'), Locale('en')]) {
    testWidgets('最小窗口高度（400 逻辑px）下右栏不溢出(${locale.languageCode})', (
      tester,
    ) async {
      await AppLocalizations.load(locale);
      final scheme = _scheme(Brightness.light);
      globalState.appState = globalState.appState.copyWith(runTime: null);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            startButtonSelectorStateProvider.overrideWithValue(_ready),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(colorScheme: scheme),
            home: Builder(
              builder: (context) {
                globalState.theme = CommonTheme.of(context, 1);
                return Material(
                  color: scheme.surfaceContainerHigh,
                  // 窗口最小 400 逻辑px 高，宽度取实测的右栏内宽
                  child: const Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 80,
                      height: 400,
                      child: QuickSidebar(width: 80, topOffset: 68.7),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      for (final icon in [
        Icons.power_settings_new,
        Icons.shuffle,
        Icons.stacked_line_chart,
        Icons.swap_horiz,
      ]) {
        expect(find.byIcon(icon), findsOneWidget);
      }
    });
  }
}
