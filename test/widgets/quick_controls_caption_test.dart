import 'package:bett_box/common/common.dart';
import 'package:bett_box/common/theme.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/quick_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 侧栏底色是 `surfaceContainerHigh`；配色用默认主色 + `content` 变体，即应用的默认配置。
/// `content` 变体下 `onPrimaryContainer` / `onTertiaryContainer` 接近白色，相对侧栏底色只有约
/// 1.2:1——控件标签一旦错用这类「配方块自身底色」的前景色就会几乎看不见，这正是这条用例要守住的回归点。
ColorScheme _scheme(Brightness brightness) {
  return ColorScheme.fromSeed(
    seedColor: const Color(defaultPrimaryColor),
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.content,
  );
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final high = la > lb ? la : lb;
  final low = la > lb ? lb : la;
  return (high + 0.05) / (low + 0.05);
}

/// 按 `QuickSidebar` 的摆法渲染快捷控制：`surfaceContainerHigh` 底、带文字标签。
/// [scriptSelected] 为 true 时脚本覆写生效；右栏脚本按钮不随该状态高亮（已改为
/// 开关式弹出/收回脚本页），两种配置仅用于覆盖按钮普通态下的标签可读性。
Future<ColorScheme> _pumpSidebar(
  WidgetTester tester,
  Brightness brightness, {
  bool scriptSelected = false,
}) async {
  final scheme = _scheme(brightness);
  globalState.config = Config(
    themeProps: defaultThemeProps,
    patchClashConfig: defaultClashConfig,
    scriptProps: scriptSelected
        ? ScriptProps(
            currentId: 's1',
            scripts: [Script(id: 's1', label: 'test', content: '')],
          )
        : const ScriptProps(),
  );
  await tester.pumpWidget(
    ProviderScope(
      // 同一个测试里连续渲染多个状态时必须换 key，否则 ProviderScope 的
      // state 被复用、provider 不会按新配置重新 build
      key: ValueKey('${brightness.name}-$scriptSelected'),
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

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppLocalizations.load(const Locale('zh', 'CN'));
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

  for (final brightness in Brightness.values) {
    for (final scriptSelected in [false, true]) {
      testWidgets(
        '快捷控制下方的标签可读(${brightness.name}/scriptSelected=$scriptSelected)',
        (tester) async {
          final scheme = await _pumpSidebar(
            tester,
            brightness,
            scriptSelected: scriptSelected,
          );
          for (final caption in [
            appLocalizations.powerSwitch,
            appLocalizations.systemProxy,
            appLocalizations.tun,
            appLocalizations.script,
          ]) {
            final text = tester.widget<Text>(find.text(caption));
            final color = text.style?.color;
            expect(color, isNotNull, reason: '缺少标签：$caption');
            // 标签是 labelSmall 小字，按 WCAG AA 小字门槛要求 4.5:1
            expect(
              _contrast(color!, scheme.surfaceContainerHigh),
              greaterThan(4.5),
              reason: '标签对比度不足：$caption',
            );
          }
        },
      );
    }
  }
}
