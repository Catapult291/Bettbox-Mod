import 'dart:io';

import 'package:bett_box/common/preferences.dart';
import 'package:bett_box/common/system_proxy.dart';
import 'package:bett_box/rust/system_proxy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 替身原生层：记录调用，按需返回结果或抛错。
class _FakeNative implements SystemProxyNative {
  String snapshotToReturn = '{"version":1,"applied":"127.0.0.1:7890","connections":[]}';
  Object? enableError;
  Object? restoreError;

  int? enabledPort;
  List<String>? enabledBypass;
  final restored = <String>[];

  @override
  RustSystemProxyEnableResult enable(int port, List<String> bypass) {
    enabledPort = port;
    enabledBypass = bypass;
    final error = enableError;
    if (error != null) throw error;
    return RustSystemProxyEnableResult(
      snapshotJson: snapshotToReturn,
      warnings: const [],
    );
  }

  @override
  RustSystemProxyRestoreReport restore(String snapshotJson) {
    restored.add(snapshotJson);
    final error = restoreError;
    if (error != null) throw error;
    return const RustSystemProxyRestoreReport(
      restored: 1,
      skipped: 0,
      warnings: [],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeNative native;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = (await preferences.sharedPreferencesCompleter.future)!;
    await prefs.remove(SystemProxy.snapshotKey);
    native = _FakeNative();
    SystemProxy.native = native;
  });

  // 快照流程只在 Windows 分支上跑，其他平台走 plugins/proxy 的 Dart 实现。
  final skipOnOtherPlatforms = Platform.isWindows ? null : 'Windows 专属路径';

  test('enable 把启用前的设置存进偏好设置', () async {
    await SystemProxy.enable(port: 7890, bypass: const ['localhost']);

    expect(native.enabledPort, 7890);
    expect(native.enabledBypass, ['localhost']);
    expect(prefs.getString(SystemProxy.snapshotKey), native.snapshotToReturn);
  }, skip: skipOnOtherPlatforms);

  test('disable 还原快照并清掉它', () async {
    await SystemProxy.enable(port: 7890, bypass: const []);

    await SystemProxy.disable();

    expect(native.restored, [native.snapshotToReturn]);
    expect(prefs.getString(SystemProxy.snapshotKey), isNull);
  }, skip: skipOnOtherPlatforms);

  test('没有快照时 disable 不碰系统代理（保护别的程序的设置）', () async {
    await SystemProxy.disable();

    expect(native.restored, isEmpty);
  }, skip: skipOnOtherPlatforms);

  test('enable 先还原上一次残留的快照，再存新的', () async {
    await prefs.setString(SystemProxy.snapshotKey, '{"version":1,"stale":true}');

    await SystemProxy.enable(port: 7890, bypass: const []);

    expect(native.restored, ['{"version":1,"stale":true}']);
    expect(prefs.getString(SystemProxy.snapshotKey), native.snapshotToReturn);
  }, skip: skipOnOtherPlatforms);

  test('还原失败时快照保留，留给下次再试', () async {
    await SystemProxy.enable(port: 7890, bypass: const []);
    native.restoreError = StateError('原生层失败');

    await SystemProxy.disable();

    expect(prefs.getString(SystemProxy.snapshotKey), native.snapshotToReturn);
  }, skip: skipOnOtherPlatforms);

  test('开启失败时不写快照', () async {
    native.enableError = StateError('原生层失败');

    await SystemProxy.enable(port: 7890, bypass: const []);

    expect(prefs.getString(SystemProxy.snapshotKey), isNull);
  }, skip: skipOnOtherPlatforms);
}
