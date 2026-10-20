import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/proxies/proxies.dart';
import 'package:bett_box/views/proxies/setting.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 测试环境没有 `path_provider_windows`，`AppPath` 构造期取下载目录会抛
/// `UnsupportedError`，与其它 view 测试同款桩。
class _FakePathProvider extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async => Directory.systemTemp.path;

  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;

  @override
  Future<String?> getDownloadsPath() async => Directory.systemTemp.path;
}

Config _config({ProxiesStyle? proxiesStyle}) {
  return Config(
    themeProps: defaultThemeProps,
    patchClashConfig: defaultClashConfig,
    currentProfileId: 'p1',
    profiles: [
      Profile(
        id: 'p1',
        label: 'Neverlose',
        autoUpdateDuration: const Duration(minutes: 60),
      ),
    ],
    proxiesStyle: proxiesStyle ?? defaultProxiesStyle,
  );
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppLocalizations.load(const Locale('zh', 'CN'));
    PathProviderPlatform.instance = _FakePathProvider();
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
    globalState.config = _config();
  });

  testWidgets('代理页顶栏不再出现「自定义」入口', (tester) async {
    await _pump(tester, const ProxiesView());

    // 入口原本是有当前配置时才渲染的 tune 图标按钮；这里配置齐全，
    // 若按钮回来，tooltip 即命中文案。
    expect(find.byTooltip(appLocalizations.custom), findsNothing);
    expect(find.byIcon(Icons.tune), findsNothing);
    // 顶栏其余入口不受影响。
    expect(find.byTooltip(appLocalizations.more), findsOneWidget);
  });

  testWidgets('设置里排序默认选中「延迟」', (tester) async {
    await _pump(tester, const ProxiesSetting());

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProxiesSetting)),
      listen: false,
    );
    expect(
      container.read(proxiesStyleSettingProvider).sortType,
      ProxiesSortType.delay,
    );

    final delayCard = find.ancestor(
      of: find.text(appLocalizations.delay),
      matching: find.byType(SettingInfoCard),
    );
    final defaultCard = find.ancestor(
      of: find.text(appLocalizations.defaultText),
      matching: find.byType(SettingInfoCard),
    );
    expect(
      tester.widget<SettingInfoCard>(delayCard).isSelected,
      isTrue,
    );
    expect(
      tester.widget<SettingInfoCard>(defaultCard).isSelected,
      isFalse,
    );
  });

  testWidgets('点「默认」仍可切回 none 并写回配置', (tester) async {
    await _pump(tester, const ProxiesSetting());

    await tester.tap(
      find.ancestor(
        of: find.text(appLocalizations.defaultText),
        matching: find.byType(SettingInfoCard),
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProxiesSetting)),
      listen: false,
    );
    expect(
      container.read(proxiesStyleSettingProvider).sortType,
      ProxiesSortType.none,
    );
    expect(globalState.config.proxiesStyle.sortType, ProxiesSortType.none);
  });
}
