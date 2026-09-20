import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bett_box/common/utils.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('订阅名自动获取（profile-title 响应头）', () {
    test('base64: 前缀按 base64（UTF-8）解码', () {
      final encoded = base64.encode(utf8.encode('机场订阅'));
      expect(utils.getProfileNameForTitle('base64:$encoded'), '机场订阅');
    });

    test('百分号编码解码后再取名', () {
      expect(utils.getProfileNameForTitle('%E6%9C%BA%E5%9C%BA'), '机场');
    });

    test('纯文本原样返回并去掉首尾空白', () {
      expect(utils.getProfileNameForTitle('  My Sub  '), 'My Sub');
    });

    test('空值 / 解不出内容的 base64 返回 null', () {
      expect(utils.getProfileNameForTitle(null), isNull);
      expect(utils.getProfileNameForTitle('   '), isNull);
      expect(utils.getProfileNameForTitle('base64:***'), isNull);
    });
  });

  group('订阅名自动获取（URL 末段路径）', () {
    test('带查询串时取末段路径', () {
      expect(
        utils.getProfileNameForUrl(
          'https://sub.example.com/api/v1/client/subscribe?token=abc',
        ),
        'subscribe',
      );
    });

    test('末段为空时退回主机名', () {
      expect(
        utils.getProfileNameForUrl('https://sub.example.com/'),
        'sub.example.com',
      );
    });

    test('百分号编码的末段解码为原文', () {
      expect(
        utils.getProfileNameForUrl(
          'https://example.com/%E6%9C%BA%E5%9C%BA.yaml',
        ),
        '机场.yaml',
      );
    });

    test('空值返回 null', () {
      expect(utils.getProfileNameForUrl(null), isNull);
      expect(utils.getProfileNameForUrl(''), isNull);
    });
  });

  group('订阅名来源优先级', () {
    const url = 'https://sub.example.com/api/v1/client/subscribe?token=abc';
    const disposition = 'attachment; filename="sub.yaml"';

    test('profile-title 优先于 content-disposition 与 URL', () {
      expect(
        utils.getProfileName(
          profileTitle: '机场 A',
          disposition: disposition,
          url: url,
        ),
        '机场 A',
      );
    });

    test('无 profile-title 时用 content-disposition 文件名', () {
      expect(
        utils.getProfileName(disposition: disposition, url: url),
        'sub.yaml',
      );
    });

    test('两个响应头都没有时用 URL 末段', () {
      expect(utils.getProfileName(url: url), 'subscribe');
    });

    test('都取不到时返回 null', () {
      expect(utils.getProfileName(), isNull);
    });
  });

  // 走真实 HTTP + dio：确认生产代码用的响应头键名能命中（面板可能用任意大小写发送），
  // 且「响应头 → 名称」这条链路端到端可用。
  group('响应头取名（HTTP 端到端）', () {
    late HttpServer server;
    late String origin;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        req.response.headers.set(
          'Profile-Title',
          'base64:${base64.encode(utf8.encode('机场订阅'))}',
        );
        req.response.headers.set(
          'Content-Disposition',
          'attachment; filename="sub.yaml"',
        );
        req.response.write('proxies: []');
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('profile-title 优先，且小写键名可命中', () async {
      final res = await Dio().get<Uint8List>(
        '$origin/api/v1/client/subscribe?token=abc',
        options: Options(responseType: ResponseType.bytes),
      );
      expect(
        utils.getProfileName(
          profileTitle: res.headers['profile-title']?.firstOrNull,
          disposition: res.headers['content-disposition']?.firstOrNull,
          url: res.requestOptions.uri.toString(),
        ),
        '机场订阅',
      );
    });
  });
}
