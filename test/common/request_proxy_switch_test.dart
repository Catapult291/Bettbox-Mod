import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「代理更新」开关的两条出站路径。
///
/// 假的本机内核代理（一个 HTTP 服务）充当 mixed-port：请求真的递到它手上，说明走的是
/// 代理；关掉开关后请求不再到达它、而是直接解析目标域名，说明走的是直连。两条用例用
/// 同一个 URL、只改 `proxy` 参数，把变量隔离开。
void main() {
  late HttpServer fakeMixedPort;
  late List<String> reached;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // flutter_test 默认把 HttpOverrides 换成「一律回 400、不真发请求」的假客户端；
    // 这两条用例恰恰要观察请求发去了哪里，所以换回真实客户端（只打本机回环地址）。
    HttpOverrides.global = null;
    reached = [];
    fakeMixedPort = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fakeMixedPort.listen((req) async {
      reached.add(req.uri.toString());
      req.response
        ..statusCode = 200
        ..write('via-mixed-port');
      await req.response.close();
    });
    globalState.appState = AppState(
      viewSize: const Size(360, 800),
      brightness: Brightness.light,
      // runTime 非空即视为内核已启动，handleFindProxy 才会给出 PROXY 而不是 DIRECT。
      runTime: DateTime.now().millisecondsSinceEpoch,
      requests: FixedList(maxLength),
      version: 1,
      logs: FixedList(maxLength),
      traffics: FixedList(30),
      totalTraffic: Traffic(),
      systemUiOverlayStyle: const SystemUiOverlayStyle(),
    );
    globalState.config = Config(
      themeProps: defaultThemeProps,
      patchClashConfig: defaultClashConfig.copyWith(
        mixedPort: fakeMixedPort.port,
        // 适配器建连时会取 globalState.ua，而它回落到 packageInfo（测试里没初始化）；
        // 指定显式 UA 即可绕开。
        globalUa: 'bettbox-test',
      ),
    );
  });

  tearDown(() async {
    await fakeMixedPort.close(force: true);
  });

  test('proxy=true：订阅请求递到本机 mixed-port', () async {
    final res = await request.getTextResponseForUrl(
      'http://proxy-switch.invalid/sub.yaml',
    );

    expect(res.statusCode, 200);
    expect(res.data, 'via-mixed-port');
    expect(reached, hasLength(1));
    expect(reached.single, contains('proxy-switch.invalid'));
  });

  test('proxy=false：不再经过 mixed-port，改为直连目标', () async {
    // `proxy-switch.invalid` 不解析（RFC 2606 保留域），直连必然失败；
    // 关键是它**没有**落到那个假的 mixed-port 上。
    await expectLater(
      request.getTextResponseForUrl(
        'http://proxy-switch.invalid/sub.yaml',
        proxy: false,
      ),
      throwsA(isA<Exception>()),
    );

    expect(reached, isEmpty);
  });
}
