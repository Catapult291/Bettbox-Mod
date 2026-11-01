import 'package:bett_box/common/common.dart';
import 'package:bett_box/common/theme.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/profiles/scripts.dart';
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

Config _config({ScriptProps? scriptProps}) {
  return Config(
    themeProps: defaultThemeProps,
    patchClashConfig: defaultClashConfig,
    scriptProps: scriptProps ?? const ScriptProps(),
  );
}

/// 复刻 `AppSidebarContainer` 的层级：右栏经 `MaterialApp.builder` 挂在 Navigator
/// 之上，模态弹层（含遮罩）盖不住它——弹层开着时按钮仍可点，这是「再点一下收回」
/// 的物理前提。视口取桌面布局宽度（>840），`showExtend` 走侧滑弹层分支，与
/// Windows 上的实际形态一致。
Future<ColorScheme> _pumpRail(WidgetTester tester, {required Config config}) async {
  final scheme = _scheme(Brightness.light);
  globalState.config = config;
  globalState.appState = AppState(
    viewSize: const Size(1600, 900),
    brightness: Brightness.light,
    requests: FixedList(maxLength),
    version: 1,
    logs: FixedList(maxLength),
    traffics: FixedList(30),
    totalTraffic: Traffic(),
    systemUiOverlayStyle: const SystemUiOverlayStyle(),
  );
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: globalState.navigatorKey,
        theme: ThemeData(colorScheme: scheme),
        builder: (context, child) {
          globalState.theme = CommonTheme.of(context, 1);
          return Stack(
            children: [
              ?child,
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: Material(
                  color: scheme.surfaceContainerHigh,
                  child: const QuickControls(showCaption: true),
                ),
              ),
            ],
          );
        },
        home: const Scaffold(body: SizedBox.expand()),
      ),
    ),
  );
  return scheme;
}

/// 右栏四个控件各有一个 Material，深度优先遍历下最后一个即脚本按钮的方块。
Finder _scriptBlock() {
  return find
      .descendant(of: find.byType(QuickControls), matching: find.byType(Material))
      .last;
}

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppLocalizations.load(const Locale('zh', 'CN'));
  });

  testWidgets('点一下弹出脚本页，再点一下收回，再点可再次弹出', (tester) async {
    await _pumpRail(tester, config: _config());
    expect(find.byType(ScriptsView), findsNothing);

    await tester.tap(find.byIcon(Icons.functions));
    await tester.pumpAndSettle();
    expect(find.byType(ScriptsView), findsOneWidget);

    await tester.tap(find.byIcon(Icons.functions));
    await tester.pumpAndSettle();
    expect(find.byType(ScriptsView), findsNothing);

    await tester.tap(find.byIcon(Icons.functions));
    await tester.pumpAndSettle();
    expect(find.byType(ScriptsView), findsOneWidget);
  });

  testWidgets('弹层被遮罩关闭后，按钮可重新弹出', (tester) async {
    await _pumpRail(tester, config: _config());

    await tester.tap(find.byIcon(Icons.functions));
    await tester.pumpAndSettle();
    expect(find.byType(ScriptsView), findsOneWidget);

    // 点遮罩（弹层只占右缘，左侧仍是遮罩）关闭——按钮的开合状态随之复位
    await tester.tapAt(const Offset(20, 450));
    await tester.pumpAndSettle();
    expect(find.byType(ScriptsView), findsNothing);

    await tester.tap(find.byIcon(Icons.functions));
    await tester.pumpAndSettle();
    expect(find.byType(ScriptsView), findsOneWidget);
  });

  testWidgets('脚本覆写生效时按钮保持普通态（不随覆写常亮）', (tester) async {
    final scheme = await _pumpRail(
      tester,
      config: _config(
        scriptProps: ScriptProps(
          currentId: 's1',
          scripts: [Script(id: 's1', label: 'test', content: '')],
        ),
      ),
    );

    expect(
      tester.widget<Icon>(find.byIcon(Icons.functions)).color,
      scheme.onSurfaceVariant,
    );
    expect(tester.widget<Material>(_scriptBlock()).color, Colors.transparent);
  });
}
