import 'package:bett_box/common/preferences.dart';
import 'package:bett_box/common/proxy_guard.dart';
import 'package:bett_box/common/system_proxy.dart';
import 'package:bett_box/manager/proxy_manager.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/rust/system_proxy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 记录调用、返回固定快照的原生层替身。
class _FakeNative implements SystemProxyNative {
  int? enabledPort;
  List<String>? enabledBypass;
  final restored = <String>[];
  final claimedPorts = <int>[];

  @override
  RustSystemProxyEnableResult enable(int port, List<String> bypass) {
    enabledPort = port;
    enabledBypass = bypass;
    return const RustSystemProxyEnableResult(
      snapshotJson: '{"version":1,"applied":"127.0.0.1:7890","connections":[]}',
      warnings: [],
    );
  }

  @override
  RustSystemProxyRestoreReport restore(String snapshotJson) {
    restored.add(snapshotJson);
    return const RustSystemProxyRestoreReport(
      restored: 1,
      skipped: 0,
      warnings: [],
    );
  }

  @override
  RustSystemProxyClaimReport claimResidual(int port) {
    claimedPorts.add(port);
    return const RustSystemProxyClaimReport(
      claimed: 0,
      listening: false,
      warnings: [],
    );
  }
}

/// 替身看门狗：只记录是否被拉起。
class _FakeGuard implements ProxyGuard {
  int startCount = 0;

  @override
  Future<void> start() async {
    startCount++;
  }

  @override
  Future<void> writePayload(String snapshotJson) async {}

  @override
  Future<void> clearPayload() async {}
}

const _running = ProxyState(
  isStart: true,
  systemProxy: true,
  bypassDomain: ['localhost'],
  port: 7890,
);
const _stopped = ProxyState(
  isStart: false,
  systemProxy: false,
  bypassDomain: [],
  port: 7890,
);

Future<void> _pumpManager(WidgetTester tester, ProxyState state) async {
  await tester.pumpWidget(
    ProviderScope(
      key: ValueKey('$state'),
      overrides: [proxyStateProvider.overrideWithValue(state)],
      child: const ProxyManager(child: SizedBox()),
    ),
  );
  // 门面里的启停链在 fake-async 区只随 pump 推进（prefs 往返 + 认领残留 +
  // 看门狗快照），真实事件循环那侧则要 runAsync 才会转；两边各冲几轮到链静默。
  for (var i = 0; i < 3; i++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  await tester.pumpAndSettle();
}

void main() {
  late _FakeNative native;
  late _FakeGuard guard;
  // 在 setUp（真实事件循环）里拿到实例：testWidgets 的 fake-async 区里 await
  // `sharedPreferencesCompleter.future` 不会推进，测试会挂住。
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = (await preferences.sharedPreferencesCompleter.future)!;
    await prefs.remove(SystemProxy.snapshotKey);
    native = _FakeNative();
    SystemProxy.native = native;
    guard = _FakeGuard();
    SystemProxy.guard = guard;
  });

  testWidgets('挂载时拉起系统代理看门狗', (tester) async {
    await _pumpManager(tester, _stopped);

    expect(guard.startCount, 1);
  });

  testWidgets('内核运行 + 系统代理开启时按状态打开系统代理', (tester) async {
    await _pumpManager(tester, _running);

    expect(native.enabledPort, 7890);
    expect(native.enabledBypass, ['localhost']);
    // 没有快照（新会话）时 enable 先按端口认领残留。
    expect(native.claimedPorts, [7890]);
  });

  testWidgets('内核停止时还原（此处没有快照，只按端口认领残留）', (tester) async {
    await _pumpManager(tester, _stopped);

    expect(native.enabledPort, isNull);
    expect(native.restored, isEmpty);
    expect(native.claimedPorts, [7890]);
  });

  testWidgets('先开后关：关的时候把快照还原掉', (tester) async {
    await _pumpManager(tester, _running);
    await _pumpManager(tester, _stopped);

    expect(native.restored, hasLength(1));
    expect(prefs.getString(SystemProxy.snapshotKey), isNull);
    // 有快照走还原，第二轮不再认领。
    expect(native.claimedPorts, hasLength(1));
  });
}
