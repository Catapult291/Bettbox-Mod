import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 推入一页「扫码页」，并把它自己的 context 交给 [onReady]
void _pushScanPage(
  GlobalKey<NavigatorState> navigatorKey,
  void Function(BuildContext context) onReady,
) {
  unawaited(
    BaseNavigator.push(
      navigatorKey.currentContext!,
      Builder(
        builder: (context) {
          onReady(context);
          return const Scaffold(body: Text('scan'));
        },
      ),
    ),
  );
}

void main() {
  setUp(() {
    // 手机宽度：showExtend / BaseNavigator 走整页路由分支
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

  testWidgets('showExtend(replace: true) 换成新页面并丢掉被替换的那页', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('add')),
      ),
    );

    // 模拟扫码页
    late BuildContext scanContext;
    _pushScanPage(navigatorKey, (context) => scanContext = context);
    await tester.pumpAndSettle();
    expect(find.text('scan'), findsOneWidget);
    expect(find.text('add'), findsNothing);

    // 扫码识别成功：用导入页替换扫码页
    unawaited(
      showExtend(
        scanContext,
        replace: true,
        builder: (context, type) => const Scaffold(body: Text('import')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('import'), findsOneWidget);
    expect(find.text('scan'), findsNothing);

    // 返回回到「添加配置页」，而不是扫码页
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('add'), findsOneWidget);
  });

  testWidgets('默认 replace: false 仍是压栈，返回回到扫码页', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('add')),
      ),
    );

    late BuildContext scanContext;
    _pushScanPage(navigatorKey, (context) => scanContext = context);
    await tester.pumpAndSettle();

    unawaited(
      showExtend(
        scanContext,
        builder: (context, type) => const Scaffold(body: Text('import')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('import'), findsOneWidget);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('scan'), findsOneWidget);
  });
}
