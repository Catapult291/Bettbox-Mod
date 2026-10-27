import 'package:bett_box/common/common.dart';
import 'package:bett_box/common/theme.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/dashboard/widgets/network_speed_data.dart';
import 'package:bett_box/views/dashboard/widgets/widgets.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

ColorScheme _scheme(Brightness brightness) {
  return ColorScheme.fromSeed(
    seedColor: const Color(defaultPrimaryColor),
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.content,
  );
}

/// 三张原先跟 tick1s 重建的卡片渲染在同一个布局里，模拟首页的排布。
Future<void> _pumpCards(
  WidgetTester tester,
  ProviderContainer container,
) async {
  final scheme = _scheme(Brightness.light);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorScheme: scheme),
        home: Builder(
          builder: (context) {
            globalState.theme = CommonTheme.of(context, 1);
            globalState.measure = Measure.of(context, 1.0);
            return Material(
              color: scheme.surface,
              child: const Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 320,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      NetworkSpeed(),
                      TrafficUsage(),
                      StartButton(),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
  await tester.pump();
}

ProviderContainer _container() {
  return ProviderContainer(
    overrides: [
      startButtonSelectorStateProvider.overrideWithValue(
        const StartButtonSelectorState(isInit: true, hasProfile: true),
      ),
    ],
  );
}

void _tick(WidgetTester tester) {
  dashboardRefreshManager.tick1s.value++;
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

  testWidgets('内核已停止时，tick1s 不再重建速度/流量/电源三张卡片', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    await _pumpCards(tester, container);

    final chart = tester.widget<LineChart>(find.byType(LineChart));
    final donut = tester.widget<DonutChart>(find.byType(DonutChart));
    final power = tester.widget<FadeThroughBox>(find.byType(FadeThroughBox));

    for (var i = 0; i < 5; i++) {
      _tick(tester);
      await tester.pump();
      expect(tester.widget<LineChart>(find.byType(LineChart)), same(chart));
      expect(tester.widget<DonutChart>(find.byType(DonutChart)), same(donut));
      expect(
        tester.widget<FadeThroughBox>(find.byType(FadeThroughBox)),
        same(power),
      );
    }
  });

  testWidgets('新流量到来时速度卡片刷新文案与曲线，tick 本身不刷新', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    await _pumpCards(tester, container);

    final emptyChart = tester.widget<LineChart>(find.byType(LineChart));

    final traffic = Traffic(up: 2048, down: 4096);
    container.read(trafficsProvider.notifier).addTraffic(traffic);
    await tester.pump();

    expect(find.text(traffic.toSpeedText()), findsOneWidget);
    final chart = tester.widget<LineChart>(find.byType(LineChart));
    expect(chart, isNot(same(emptyChart)));
    expect(chart.points.last.y, traffic.speed.toDouble());

    // 数据没再变：tick 不应再重建这张卡。
    _tick(tester);
    await tester.pump();
    expect(tester.widget<LineChart>(find.byType(LineChart)), same(chart));
  });

  testWidgets('累计流量不变时流量卡片不重建，变化后数值上屏', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    await _pumpCards(tester, container);

    final donut = tester.widget<DonutChart>(find.byType(DonutChart));

    // 同一个 Traffic 数值每秒都要写一次：显示值没变就不该重建。
    for (var i = 0; i < 3; i++) {
      container.read(totalTrafficProvider.notifier).value = Traffic(
        up: 2 * 1024 * 1024,
        down: 3 * 1024 * 1024,
      );
      await tester.pump();
    }
    expect(find.text('2.00'), findsOneWidget);
    expect(find.text('3.00'), findsOneWidget);
    final updated = tester.widget<DonutChart>(find.byType(DonutChart));
    expect(updated, isNot(same(donut)));

    _tick(tester);
    await tester.pump();
    expect(tester.widget<DonutChart>(find.byType(DonutChart)), same(updated));
  });

  testWidgets('电源卡片随 runTime 变化刷新，不依赖 tick', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    await _pumpCards(tester, container);

    container.read(runTimeProvider.notifier).value = 65 * 1000;
    await tester.pump();
    expect(find.text('00:01:05'), findsOneWidget);

    // 时钟由 runTime 驱动；tick 不再参与这张卡的重建。
    final power = tester.widget<FadeThroughBox>(find.byType(FadeThroughBox));
    _tick(tester);
    await tester.pump();
    expect(
      tester.widget<FadeThroughBox>(find.byType(FadeThroughBox)),
      same(power),
    );

    container.read(runTimeProvider.notifier).value = 3600 * 1000;
    await tester.pump();
    expect(find.text('01:00:00'), findsOneWidget);
  });

  testWidgets('小号速度卡片同样只随流量数据重建', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    final scheme = _scheme(Brightness.light);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(colorScheme: scheme),
          home: Builder(
            builder: (context) {
              globalState.theme = CommonTheme.of(context, 1);
              globalState.measure = Measure.of(context, 1.0);
              return Material(
                color: scheme.surface,
                child: const Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(width: 160, child: NetworkSpeedSmall()),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    final chart = tester.widget<LineChart>(find.byType(LineChart));
    _tick(tester);
    await tester.pump();
    expect(tester.widget<LineChart>(find.byType(LineChart)), same(chart));

    final traffic = Traffic(up: 1024, down: 1024);
    container.read(trafficsProvider.notifier).addTraffic(traffic);
    await tester.pump();
    final updated = tester.widget<LineChart>(find.byType(LineChart));
    expect(updated, isNot(same(chart)));
    expect(updated.points.last.y, traffic.speed.toDouble());
  });

  test('曲线点：速率窗口内容未变时返回同一实例，变化后才换新列表', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final points = container.listen(networkSpeedPointsProvider, (_, _) {});
    var textNotifications = 0;
    container.listen(networkSpeedTextProvider, (_, _) => textNotifications++);

    final notifier = container.read(trafficsProvider.notifier);
    for (var i = 0; i < 30; i++) {
      notifier.addTraffic(Traffic(up: 0, down: 0));
    }
    await container.pump();
    final filled = points.read();
    expect(filled.length, 32);

    textNotifications = 0;
    // 窗口已满、速率全是 0：新样本不该触发重建。
    notifier.addTraffic(Traffic(up: 0, down: 0));
    await container.pump();
    expect(identical(points.read(), filled), isTrue);
    expect(textNotifications, 0);

    // 速率变了：点列表与文案都要更新。
    notifier.addTraffic(Traffic(up: 1024, down: 1024));
    await container.pump();
    expect(identical(points.read(), filled), isFalse);
    expect(textNotifications, 1);
  });

  test('速率曲线：内容相同的点列表不触发重绘', () {
    LineChartPainter painter(List<Point> points) {
      return LineChartPainter(
        prevPoints: const [],
        points: points,
        progress: 1,
        color: const Color(defaultPrimaryColor),
        gradient: true,
        hasAnimation: false,
      );
    }

    const a = [Point(0, 0), Point(1, 0), Point(2, 2048)];
    const sameAsA = [Point(0, 0), Point(1, 0), Point(2, 2048)];
    const moved = [Point(0, 0), Point(1, 2048), Point(2, 0)];

    expect(painter(sameAsA).shouldRepaint(painter(a)), isFalse);
    expect(painter(moved).shouldRepaint(painter(a)), isTrue);
  });
}
