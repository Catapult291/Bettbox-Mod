import 'dart:convert';

import 'package:bett_box/clash/core.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const url = 'https://cp.cloudflare.com/generate_204';
  final targets = [
    {'proxy-name': 'p1', 'test-url': url},
    {'proxy-name': 'p2', 'test-url': url},
    {'proxy-name': 'p3', 'test-url': url},
  ];

  test('批量测速 action 名与内核 handleAction 的分支名一致', () {
    // 内核侧是 core/constant.go 的 asyncTestDelayBatchMethod；名字对不上时
    // handleAction 不进任何分支，Dart 侧只能等满 invoke 超时。
    final raw = json.encode(
      Action(id: 'x#1', method: ActionMethod.asyncTestDelayBatch, data: '{}'),
    );
    expect(json.decode(raw)['method'], 'asyncTestDelayBatch');
  });

  test('内核应答按请求顺序落回每个节点', () {
    final delays = parseDelays(
      '[{"url":"$url","name":"p1","value":120},'
      '{"url":"$url","name":"p2","value":-1},'
      '{"url":"$url","name":"p3","value":35}]',
      targets,
    );

    expect(delays.map((d) => d.name), ['p1', 'p2', 'p3']);
    expect(delays.map((d) => d.value), [120, -1, 35]);
    expect(delays.every((d) => d.url == url), isTrue);
  });

  test('空应答（未连上内核 / 整批超时）全部落 -1，地址取请求时的值', () {
    final delays = parseDelays('', targets);

    expect(delays, hasLength(3));
    expect(delays.every((d) => d.value == -1), isTrue);
    expect(delays.map((d) => d.url), everyElement(url));
  });

  test('不可解析的应答不会把界面留在测速动画上', () {
    for (final raw in ['not json', '{"name":"p1"}', 'null']) {
      final delays = parseDelays(raw, targets);
      expect(delays, hasLength(3), reason: raw);
      expect(delays.every((d) => d.value == -1), isTrue, reason: raw);
    }
  });

  test('内核回的空 url（找不到节点）换回请求地址', () {
    // core/hub.go 对不存在的节点沿用单节点应答形态：url 为空、value 为 -1。
    final delays = parseDelays('[{"url":"","name":"p1","value":-1}]', targets);

    expect(delays[0].value, -1);
    expect(delays[0].url, url);
    // 应答缺项时其余节点同样落 -1。
    expect(delays[1].value, -1);
    expect(delays[2].value, -1);
  });

  test('超出请求数量的应答被忽略', () {
    final delays = parseDelays(
      '[{"url":"$url","name":"p1","value":10},'
      '{"url":"$url","name":"p2","value":20},'
      '{"url":"$url","name":"p3","value":30},'
      '{"url":"$url","name":"p4","value":40}]',
      targets,
    );

    expect(delays, hasLength(3));
    expect(delays.map((d) => d.value), [10, 20, 30]);
  });
}
