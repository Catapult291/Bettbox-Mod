import 'package:bett_box/common/common.dart';
import 'package:bett_box/common/theme.dart';
import 'package:bett_box/enum/enum.dart';
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
/// 1.2:1——这正是这条用例要守住的回归点。
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

String _modeName(Mode mode) {
  return switch (mode) {
    Mode.rule => appLocalizations.rule,
    Mode.global => appLocalizations.global,
    Mode.direct => appLocalizations.direct,
  };
}

/// 按 `QuickSidebar` 的摆法渲染快捷控制：`surfaceContainerHigh` 底、带文字标签。
Future<ColorScheme> _pumpSidebar(
  WidgetTester tester,
  Brightness brightness,
  Mode mode,
) async {
  final scheme = _scheme(brightness);
  globalState.config = Config(
    themeProps: defaultThemeProps,
    patchClashConfig: defaultClashConfig.copyWith(mode: mode),
  );
  await tester.pumpWidget(
    ProviderScope(
      // 同一个测试里连续渲染多个模式时必须换 key，否则 ProviderScope 的
      // state 被复用、`patchClashConfigProvider` 不会按新模式重新 build
      key: ValueKey('${brightness.name}-${mode.name}'),
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
    for (final mode in Mode.values) {
      testWidgets('快捷控制下方的模式名可读(${brightness.name}/${mode.name})', (
        tester,
      ) async {
        final scheme = await _pumpSidebar(tester, brightness, mode);
        final caption = tester.widget<Text>(find.text(_modeName(mode)));
        final color = caption.style?.color;
        expect(color, isNotNull);
        // 模式名是 labelSmall 加粗小字，按 WCAG AA 小字门槛要求 4.5:1
        expect(
          _contrast(color!, scheme.surfaceContainerHigh),
          greaterThan(4.5),
        );
      });
    }
  }
}
