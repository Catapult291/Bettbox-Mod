import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 更新探测：GitHub 返回 gzip + ETag/304，解析失败时曾把「没有缓存结果」
/// 当成「没有新版本」，导致同一进程内后续检查全部误报「已是最新」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test 默认的 HttpOverrides 不真发请求，这里换回真实客户端（只打回环地址）。
  HttpOverrides.global = null;

  late HttpServer server;
  late String baseUrl;
  late Future<void> Function(HttpRequest request) handle;
  late List<String?> ifNoneMatch;
  late List<String> apiPaths;

  setUp(() async {
    globalState.packageInfo = PackageInfo(
      appName: 'Bettbox',
      packageName: 'com.appshub.bettbox',
      version: '1.19.28',
      buildNumber: '2026110101',
    );
    ifNoneMatch = [];
    apiPaths = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      if (request.uri.path.contains('/repos/')) {
        apiPaths.add(request.uri.path);
        ifNoneMatch.add(request.headers.value('if-none-match'));
      }
      await handle(request);
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  Request newRequest() =>
      Request(updateApiBaseUrl: baseUrl, updateWebBaseUrl: baseUrl);

  Future<void> sendGzipJson(
    HttpResponse response,
    Map<String, dynamic> body, {
    String? etag,
  }) async {
    final bytes = gzip.encode(utf8.encode(jsonEncode(body)));
    response.headers.set('content-encoding', 'gzip');
    if (etag != null) response.headers.set('etag', etag);
    response.headers.contentType = ContentType.json;
    response.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }

  Future<void> redirectToRelease(HttpResponse response, String tag) async {
    response.statusCode = HttpStatus.found;
    response.headers.set(
      'location',
      '/Catapult291/Bettbox-Mod/releases/tag/$tag',
    );
    await response.close();
  }

  test('gzip 响应体可解析，304 复用上次判定结果', () async {
    const etag = '"release-1"';
    handle = (request) async {
      if (request.uri.path.contains('/repos/')) {
        if (request.headers.value('if-none-match') == etag) {
          request.response.statusCode = HttpStatus.notModified;
          await request.response.close();
          return;
        }
        await sendGzipJson(
          request.response,
          {
            'tag_name': 'v1.19.29',
            'html_url': 'https://github.com/Catapult291/Bettbox-Mod/releases',
            'body': '- 第一条更新\n- 第二条更新',
          },
          etag: etag,
        );
        return;
      }
      await redirectToRelease(request.response, 'v1.19.29');
    };

    final request = newRequest();
    final first = await request.checkForUpdate();
    expect(first.hasUpdate, isTrue);
    expect(first.data?['tag_name'], 'v1.19.29');
    expect(first.data?['body'], '- 第一条更新\n- 第二条更新');

    final second = await request.checkForUpdate();
    expect(second.hasUpdate, isTrue);
    expect(second.data?['tag_name'], 'v1.19.29');
    expect(ifNoneMatch, [null, etag]);
  });

  test('API 响应体解析失败时不记 ETag，后续检查不会误报已是最新', () async {
    const etag = '"broken-release"';
    handle = (request) async {
      if (request.uri.path.contains('/repos/')) {
        if (request.headers.value('if-none-match') != null) {
          request.response.statusCode = HttpStatus.notModified;
          await request.response.close();
          return;
        }
        // 结构合法的 HTTP 响应、内容却不是 JSON：模拟解压/解码失败那一类故障。
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('etag', etag);
        request.response.write('not-a-json-payload');
        await request.response.close();
        return;
      }
      await redirectToRelease(request.response, 'v1.19.29');
    };

    final request = newRequest();
    final first = await request.checkForUpdate();
    expect(first.hasUpdate, isTrue, reason: '应回退网页端点拿到更新');

    final second = await request.checkForUpdate();
    expect(second.hasUpdate, isTrue, reason: '第二次检查不能变成「已是最新」');
    // 解析失败的 200 不应落 ETag，因此第二次仍是不带条件的完整请求。
    expect(ifNoneMatch, [null, null]);
    expect(apiPaths.length, 2);
  });

  test('无条件请求收到 304 时回退网页端点，而不是报已是最新', () async {
    handle = (request) async {
      if (request.uri.path.contains('/repos/')) {
        request.response.statusCode = HttpStatus.notModified;
        await request.response.close();
        return;
      }
      await redirectToRelease(request.response, 'v1.19.29');
    };

    final result = await newRequest().checkForUpdate();
    expect(result.hasUpdate, isTrue);
    expect(result.data?['tag_name'], 'v1.19.29');
  });

  test('两条探测路径都失败时返回 failed，而不是「已是最新」', () async {
    handle = (request) async {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    };

    final result = await newRequest().checkForUpdate();
    expect(result.isFailed, isTrue);
    expect(result.hasUpdate, isFalse);
  });

  test('本地已是最新时返回 upToDate，304 后仍为 upToDate', () async {
    const etag = '"release-latest"';
    handle = (request) async {
      if (request.uri.path.contains('/repos/')) {
        if (request.headers.value('if-none-match') == etag) {
          request.response.statusCode = HttpStatus.notModified;
          await request.response.close();
          return;
        }
        await sendGzipJson(
          request.response,
          {'tag_name': 'v1.19.28'},
          etag: etag,
        );
        return;
      }
      await redirectToRelease(request.response, 'v1.19.28');
    };

    final request = newRequest();
    expect((await request.checkForUpdate()).status, UpdateCheckStatus.upToDate);
    expect((await request.checkForUpdate()).status, UpdateCheckStatus.upToDate);
    expect(ifNoneMatch, [null, etag]);
  });
}
