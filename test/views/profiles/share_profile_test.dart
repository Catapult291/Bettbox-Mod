import 'package:bett_box/common/common.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/profiles/share_profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

Profile _profile() {
  return Profile.normal(
    label: '测试机场',
    url: 'https://example.com/sub?token=abc123',
  );
}

Future<void> _pumpDialog(WidgetTester tester, Profile profile) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: ProfileShareDialog(profile: profile)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await AppLocalizations.load(const Locale('zh', 'CN'));
    globalState.appState = AppState(
      viewSize: const Size(400, 800),
      brightness: Brightness.light,
      requests: FixedList(maxLength),
      version: 1,
      logs: FixedList(maxLength),
      traffics: FixedList(30),
      totalTraffic: Traffic(),
      systemUiOverlayStyle: const SystemUiOverlayStyle(),
    );
  });

  testWidgets('分享弹窗展示配置名、机场链接与二维码', (tester) async {
    final profile = _profile();
    await _pumpDialog(tester, profile);

    expect(find.text('分享'), findsOneWidget);
    expect(find.text('测试机场'), findsOneWidget);
    expect(find.text('机场链接'), findsOneWidget);
    expect(find.text(profile.url), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
  });

  testWidgets('点击链接写入剪贴板', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    final profile = _profile();
    await _pumpDialog(tester, profile);
    await tester.tap(find.text(profile.url));
    await tester.pump();

    final clipboardCalls = calls
        .where((call) => call.method == 'Clipboard.setData')
        .toList();
    expect(clipboardCalls, hasLength(1));
    expect((clipboardCalls.single.arguments as Map)['text'], profile.url);

    // 覆盖复制后 2 秒的勾选态复位计时器。
    await tester.pump(const Duration(seconds: 2));
  });
}
