import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/controller.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
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

/// 渲染编辑页。传 [withController] 时挂一个真实 `AppController`，供需要写回
/// 配置的用例使用（`setProfile` 要经 Riverpod 的 profiles provider）。
Future<void> _pumpEdit(
  WidgetTester tester,
  Profile profile, {
  bool withController = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              if (withController) {
                return Consumer(
                  builder: (context, ref, _) {
                    globalState.appController = AppController(context, ref);
                    return EditProfileView(context: context, profile: profile);
                  },
                );
              }
              return EditProfileView(context: context, profile: profile);
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 当前 ProviderScope 里的 profiles 列表。
List<Profile> _profiles(WidgetTester tester) {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(EditProfileView)),
    listen: false,
  );
  return container.read(profilesProvider);
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

  // 回归：后台补更/自动更新读的是配置里的 proxyUpdate。开关只改表单内存态、
  // 要等 FAB 保存才生效时，内核在跑的这段窗口里更新仍经内核 mixed-port 出站，
  // 订阅域名被判走代理或代理链路不通就失败，用户只能关掉启动开关才能更新。
  testWidgets('点开关即写回配置的 proxyUpdate，不等 FAB 保存', (tester) async {
    final profile = _profile(proxyUpdate: true);
    globalState.config = Config(
      themeProps: defaultThemeProps,
      patchClashConfig: defaultClashConfig,
      profiles: [profile],
    );
    await _pumpEdit(tester, profile, withController: true);

    await tester.tap(_switchOf(appLocalizations.proxyUpdate));
    await tester.pumpAndSettle();

    expect(_profiles(tester).getProfile('p1')?.proxyUpdate, isFalse);
  });
}
