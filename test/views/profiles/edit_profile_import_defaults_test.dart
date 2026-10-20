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

/// 同 `edit_profile_proxy_switch_test`：测试环境没有 `path_provider_windows`，
/// `AppPath` 构造时取目录会直接抛，编辑页一入场就挂，这里先换成假实现。
class _FakePathProvider extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async => Directory.systemTemp.path;

  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;

  @override
  Future<String?> getDownloadsPath() async => Directory.systemTemp.path;
}

Finder _switchOf(String label) {
  return find.descendant(
    of: find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
    matching: find.byType(Switch),
  );
}

Future<void> _pumpEdit(WidgetTester tester, Profile profile,
    {bool isNew = false}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) =>
                EditProfileView(context: context, profile: profile, isNew: isNew),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // isNew 分支里 initState 排了一个 500ms 后请求焦点的延时，测试结束前把它走完，
  // 否则 fake async 会报「Timer is still pending」。
  await tester.pump(const Duration(milliseconds: 600));
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

  test('新建/导入用的默认间隔是 720 分钟', () {
    expect(defaultUpdateDuration, const Duration(hours: 12));
    expect(defaultUpdateDuration.inMinutes, 720);
  });

  testWidgets('导入页（isNew）自动更新开关默认打开、间隔默认 720',
      (tester) async {
    final profile = Profile.normal(url: 'https://example.com/sub');
    await _pumpEdit(tester, profile, isNew: true);

    final autoSwitch = _switchOf(appLocalizations.autoUpdate);
    expect(tester.widget<Switch>(autoSwitch).value, isTrue);

    // 开关开着时间隔输入框才渲染，取其中的编辑框文本。
    final intervalField = find.descendant(
      of: find.ancestor(
        of: find.text(appLocalizations.autoUpdateInterval),
        matching: find.byType(ListTile),
      ),
      matching: find.byType(TextFormField),
    );
    expect(intervalField, findsOneWidget);
    expect(
      tester.widget<TextFormField>(intervalField).controller?.text,
      '720',
    );
  });

  testWidgets('编辑已有配置时开关与间隔仍取该配置自己的值', (tester) async {
    final profile = Profile.normal(url: 'https://example.com/sub').copyWith(
      autoUpdate: false,
      autoUpdateDuration: const Duration(minutes: 30),
    );
    await _pumpEdit(tester, profile, isNew: false);

    expect(tester.widget<Switch>(_switchOf(appLocalizations.autoUpdate)).value,
        isFalse);
  });
}
