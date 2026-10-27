import 'dart:async';
import 'dart:convert';

import 'package:bett_box/clash/interface.dart';
import 'package:bett_box/common/constant.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只实现传输层：把发出的 action 记下来，并按需回一条应答。
class _FakeTransport extends ClashHandlerInterface {
  final sent = <Map<String, dynamic>>[];
  String Function(String data)? reply;

  @override
  Future<bool> sendMessage(String message) async {
    final action = json.decode(message) as Map<String, dynamic>;
    sent.add(action);
    final data = reply?.call(action['data'] as String) ?? '';
    if (data.isNotEmpty) {
      await handleResult(
        ActionResult(
          method: ActionMethod.asyncTestDelayBatch,
          data: data,
          id: action['id'] as String,
        ),
      );
    }
    return true;
  }

  @override
  Future<bool> preload() async => true;

  @override
  FutureOr<void> reStart() {}

  @override
  FutureOr<bool> destroy() => true;
}

void main() {
  const url = 'https://cp.cloudflare.com/generate_204';

  test('整批目标一次发出：一个 action，载荷带 proxies 与 timeout', () async {
    final transport = _FakeTransport()
      ..reply = (_) => '[{"url":"$url","name":"p1","value":42}]';

    final raw = await transport.asyncTestDelayBatch([
      {'proxy-name': 'p1', 'test-url': url},
      {'proxy-name': 'p2', 'test-url': url},
    ]);

    expect(transport.sent, hasLength(1));
    final action = transport.sent.single;
    expect(action['method'], 'asyncTestDelayBatch');

    final params = json.decode(action['data'] as String) as Map;
    expect(params['timeout'], httpTimeoutDuration.inMilliseconds);
    final proxies = params['proxies'] as List;
    expect(proxies, hasLength(2));
    expect(proxies.first, {'proxy-name': 'p1', 'test-url': url});

    // 应答原样回到调用方，由 parseDelays 负责解析。
    expect(json.decode(raw), hasLength(1));
  });

  test('空批次不发 IPC', () async {
    final transport = _FakeTransport();

    expect(await transport.asyncTestDelayBatch(const []), '[]');
    expect(transport.sent, isEmpty);
  });

  test('整批超时（内核不回包）时每个节点都落 -1，界面不会停在测速动画上', () async {
    // 50 个目标一批，就是界面在默认并发上限下会发出的最大批次。
    final transport = _FakeTransport();
    final targets = [
      for (var i = 0; i < delayTestBatchConcurrency; i++)
        {'proxy-name': 'p$i', 'test-url': url},
    ];

    final raw = await transport.asyncTestDelayBatch(targets);

    final params = json.decode(transport.sent.single['data'] as String) as Map;
    expect((params['proxies'] as List), hasLength(delayTestBatchConcurrency));

    final delays = json.decode(raw) as List;
    expect(delays, hasLength(delayTestBatchConcurrency));
    expect(delays.every((d) => d['value'] == -1), isTrue);
    expect(delays.first, {'name': 'p0', 'url': url, 'value': -1});
  });
}
