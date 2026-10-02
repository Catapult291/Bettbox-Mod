import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/profiles/edit_profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 测试环境没有 `path_provider_windows`，默认的 MethodChannel 实现取下载目录会直接抛
/// `UnsupportedError`，而 `AppPath` 构造时就要这三个目录，于是编辑页一入场就挂。
class _FakePathProvider extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async => Directory.systemTemp.path;

  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;

  @override
  Future<String?> getDownloadsPath() async => Directory.systemTemp.path;
}

/// 「代理更新」行里的开关：整行是 ListTile，开关是它的 trailing。
Finder _switchOf(String label) {
  return find.descendant(
    of: find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
    matching: find.byType(Switch),
  );
}

Profile _profile({bool proxyUpdate = true}) {
  return Profile(
    id: 'p1',
    label: 'Neverlose',
    url: 'https://example.com/sub',
    proxyUpdate: proxyUpdate,
    autoUpdateDuration: const Duration(minutes: 60),
  );
}

Future<void> _pumpEdit(WidgetTester tester, Profile profile) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return EditProfileView(context: context, profile: profile);
            },
          ),
        ),
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
    globalState.config = Config(
      themeProps: defaultThemeProps,
      patchClashConfig: defaultClashConfig,
    );
  });

  testWidgets('开关初值取自配置的 proxyUpdate', (tester) async {
    await _pumpEdit(tester, _profile(proxyUpdate: false));

    expect(find.text(appLocalizations.proxyUpdate), findsOneWidget);
    expect(
      tester.widget<Switch>(_switchOf(appLocalizations.proxyUpdate)).value,
      isFalse,
    );
  });

  testWidgets('点开关只翻转「代理更新」，不影响同一行的其他开关', (tester) async {
    await _pumpEdit(tester, _profile(proxyUpdate: true));

    final proxySwitch = _switchOf(appLocalizations.proxyUpdate);
    final autoSwitch = _switchOf(appLocalizations.autoUpdate);
    expect(tester.widget<Switch>(proxySwitch).value, isTrue);
    expect(tester.widget<Switch>(autoSwitch).value, isTrue);

    await tester.tap(proxySwitch);
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(proxySwitch).value, isFalse);
    expect(tester.widget<Switch>(autoSwitch).value, isTrue);
  });
}
