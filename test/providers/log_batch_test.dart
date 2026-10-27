import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 合帧窗口 100ms；留两倍余量，避免计时器抖动导致偶发失败。
const _wait = Duration(milliseconds: 250);

ProviderContainer _container() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
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

  test('一个窗口内的多条日志只通知一次，并按顺序全部写入', () async {
    final container = _container();
    var notifications = 0;
    container.listen(logsProvider, (prev, next) => notifications++);

    final notifier = container.read(logsProvider.notifier);
    for (var i = 0; i < 21; i++) {
      notifier.addLog(Log.app('log $i'));
    }

    expect(container.read(logsProvider).length, 0, reason: '窗口未到时不应写出');
    expect(notifications, 0);

    await Future<void>.delayed(_wait);

    final logs = container.read(logsProvider);
    expect(logs.length, 21);
    expect(logs.list.first.payload, 'log 0');
    expect(logs.list.last.payload, 'log 20');
    expect(notifications, 1);
    expect(globalState.appState.logs.length, 21);
  });

  test('没有监听者时窗口内的日志仍然落到全局状态', () async {
    final container = _container();
    container.read(logsProvider.notifier).addLog(Log.app('no listener'));

    await Future<void>.delayed(_wait);

    expect(globalState.appState.logs.length, 1);
    expect(globalState.appState.logs.list.single.payload, 'no listener');
  });

  test('超出一窗容量时保留最新的一条，按 maxLength 截断', () async {
    final container = _container();
    final notifier = container.read(logsProvider.notifier);
    for (var i = 0; i < maxLength + 44; i++) {
      notifier.addLog(Log.app('log $i'));
    }

    await Future<void>.delayed(_wait);

    final logs = container.read(logsProvider);
    expect(logs.length, maxLength);
    expect(logs.list.first.payload, 'log 44');
    expect(logs.list.last.payload, 'log ${maxLength + 43}');
  });

  test('clearLogs 丢弃窗口内待写的日志', () async {
    final container = _container();
    var notifications = 0;
    container.listen(logsProvider, (prev, next) => notifications++);

    final notifier = container.read(logsProvider.notifier);
    notifier.addLog(Log.app('before clear'));
    notifier.clearLogs();

    await Future<void>.delayed(_wait);

    expect(container.read(logsProvider).length, 0);
    expect(globalState.appState.logs.length, 0);
    expect(notifications, 1, reason: '只有清空这一笔通知');
  });

  test('flushBatch 立即写出待处理日志', () async {
    final container = _container();
    final notifier = container.read(logsProvider.notifier);
    notifier.addLog(Log.app('flush me'));

    notifier.flushBatch();

    expect(container.read(logsProvider).length, 1);
    expect(container.read(logsProvider).list.single.payload, 'flush me');

    await Future<void>.delayed(_wait);
    expect(container.read(logsProvider).length, 1, reason: '计时器应已取消');
  });

  test('连接事件同样按窗口合并写入', () async {
    final container = _container();
    var notifications = 0;
    container.listen(requestsProvider, (prev, next) => notifications++);

    final notifier = container.read(requestsProvider.notifier);
    for (var i = 0; i < 6; i++) {
      notifier.addRequest(_tracker('conn $i'));
    }

    await Future<void>.delayed(_wait);

    expect(container.read(requestsProvider).length, 6);
    expect(notifications, 1);
    expect(globalState.appState.requests.length, 6);
    expect(globalState.appState.requests[5].id, 'conn 5');
  });

  test('clearRequests 丢弃窗口内待写的连接事件', () async {
    final container = _container();
    final notifier = container.read(requestsProvider.notifier);
    notifier.addRequest(_tracker('conn'));
    notifier.clearRequests();

    await Future<void>.delayed(_wait);

    expect(container.read(requestsProvider).length, 0);
    expect(globalState.appState.requests.length, 0);
  });
}

TrackerInfo _tracker(String id) {
  return TrackerInfo(
    id: id,
    start: DateTime(2026, 10, 26),
    metadata: const Metadata(network: 'tcp', host: 'example.com'),
    chains: const ['DIRECT'],
    rule: 'MATCH',
    rulePayload: '',
  );
}
