import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/controller.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/process_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 测试环境没有 `path_provider_windows`，`AppPath` 构造期取下载目录会抛
/// `UnsupportedError`（未接住的异步错误会直接判用例失败），与编辑页测试同款桩。
class _FakePathProvider extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async => Directory.systemTemp.path;

  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;

  @override
  Future<String?> getDownloadsPath() async => Directory.systemTemp.path;
}

/// `ProcessAccessView`（进程分流页）的 widget 测试。
///
/// 页面 `_apply` 会调 `globalState.appController.setupClashConfigDebounce()`——
/// 测试里换成空实现：真链路是 600ms 防抖 + 全量 setup（依赖 FFI 内核库），
/// 放进来会残留 Timer / dispose 后回调，把用例打断。
class _QuietAppController extends AppController {
  _QuietAppController(super.context, super.ref);

  @override
  void setupClashConfigDebounce() {}
}

Config _config({ProcessAccessProps access = const ProcessAccessProps()}) {
  return Config(
    themeProps: defaultThemeProps,
    patchClashConfig: defaultClashConfig,
    processAccess: access,
  );
}

/// 渲染页面；把 `appController` 换成静默实现，并记下容器供断言读取。
Future<void> _pumpPage(WidgetTester tester, Config config) async {
  globalState.config = config;
  await tester.pumpWidget(
    ProviderScope(
      key: ValueKey(config.processAccess),
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            globalState.appController = _QuietAppController(context, ref);
            return const Scaffold(body: ProcessAccessView());
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 当前 ProviderScope 里页面正在用的 processAccess 状态。
ProcessAccessProps _access(WidgetTester tester) {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(ProcessAccessView)),
    listen: false,
  );
  return container.read(processAccessStateProvider);
}

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppLocalizations.load(const Locale('zh', 'CN'));
    PathProviderPlatform.instance = _FakePathProvider();
    globalState.config = _config();
  });

  testWidgets('渲染三种模式行，黑名单选中，空名单显示空态', (tester) async {
    await _pumpPage(
      tester,
      _config(
        access: const ProcessAccessProps(mode: ProcessAccessMode.blacklist),
      ),
    );

    expect(find.text(appLocalizations.processAccessOff), findsOneWidget);
    expect(find.text(appLocalizations.processAccessBlacklist), findsOneWidget);
    expect(find.text(appLocalizations.processAccessWhitelist), findsOneWidget);

    expect(find.text(appLocalizations.processAccessEmpty), findsOneWidget);
    expect(
      find.text(appLocalizations.processAccessSelectedCount(0)),
      findsOneWidget,
    );
    expect(
      find.text(appLocalizations.processAccessFindProcessHint),
      findsOneWidget,
    );
  });

  testWidgets('名单非空：计数、含 .exe 的文件名与完整路径都显示', (tester) async {
    const axon = r'C:\Users\me\AppData\Local\AxonHub\axonhub.exe';
    const pix = r'C:\Users\me\Documents\PixPin\PixPin.exe';
    await _pumpPage(
      tester,
      _config(
        access: const ProcessAccessProps(
          mode: ProcessAccessMode.whitelist,
          paths: [axon, pix],
        ),
      ),
    );

    expect(
      find.text(appLocalizations.processAccessSelectedCount(2)),
      findsOneWidget,
    );
    // 已选列表保留 .exe（§158：只在选择器标题去后缀）。
    expect(find.text('axonhub.exe'), findsOneWidget);
    expect(find.text('PixPin.exe'), findsOneWidget);
    expect(find.text(axon), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNWidgets(2));
    expect(find.text(appLocalizations.processAccessEmpty), findsNothing);
  });

  testWidgets('点白名单：模式落 provider，find-process-mode 强制 always',
      (tester) async {
    await _pumpPage(
      tester,
      _config(
        access: const ProcessAccessProps(
          mode: ProcessAccessMode.blacklist,
          paths: [r'C:\apps\a.exe'],
        ),
      ),
    );
    expect(
      globalState.config.patchClashConfig.findProcessMode,
      FindProcessMode.off,
    );

    await tester.tap(find.text(appLocalizations.processAccessWhitelist));
    await tester.pumpAndSettle();

    final access = _access(tester);
    expect(access.mode, ProcessAccessMode.whitelist);
    expect(access.paths, [r'C:\apps\a.exe']);
    expect(
      globalState.config.patchClashConfig.findProcessMode,
      FindProcessMode.always,
    );
  });

  testWidgets('空名单点模式回落 off（不产生无名单的规则模式）', (tester) async {
    await _pumpPage(tester, _config());

    await tester.tap(find.text(appLocalizations.processAccessBlacklist));
    await tester.pumpAndSettle();

    expect(_access(tester).mode, ProcessAccessMode.off);
  });

  testWidgets('点移除按钮：名单少一项并回写 config', (tester) async {
    const keep = r'C:\apps\keep.exe';
    const drop = r'C:\apps\drop.exe';
    await _pumpPage(
      tester,
      _config(
        access: const ProcessAccessProps(
          mode: ProcessAccessMode.blacklist,
          paths: [drop, keep],
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();

    expect(_access(tester).paths, [keep]);
    expect(globalState.config.processAccess.paths, [keep]);
    expect(
      find.text(appLocalizations.processAccessSelectedCount(1)),
      findsOneWidget,
    );
  });
}
