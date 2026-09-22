import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:intl/intl.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/cupertino.dart';

class Request {
  late final Dio _dio;
  late final Dio _clashDio;
  String? userAgent;

  Request() {
    _dio = Dio(BaseOptions(headers: {'User-Agent': browserUa}));
    _dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.autoUncompress = false;
        return client;
      },
    );
    _clashDio = Dio(
      // 经代理出站的请求此前没有任何超时：订阅地址被黑洞（连上但不应答）时，
      // 内核启停链路会连带无限期挂住——锁一直被占，启停开关点不动，只能重启应用。
      // 这里的 receiveTimeout 是"两次数据之间的间隔"，不影响大文件下载。
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    _clashDio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.autoUncompress = false;
        client.findProxy = (Uri uri) {
          client.userAgent = globalState.ua;
          return BettboxHttpOverrides.handleFindProxy(uri);
        };
        return client;
      },
    );
  }

  Uint8List _decompressIfNeeded(Uint8List bytes, Headers headers) {
    final encodings =
        headers['content-encoding']?.map((e) => e.toLowerCase()).toList() ?? [];
    final encodingStr = encodings.join(', ');
    final wantGzip = encodingStr.contains('gzip');
    final wantDeflate = encodingStr.contains('deflate');

    var current = bytes;
    for (var i = 0; i < 4; i++) {
      final isGzipMagic =
          current.length >= 2 && current[0] == 0x1f && current[1] == 0x8b;
      if (wantGzip || isGzipMagic) {
        try {
          current = Uint8List.fromList(gzip.decode(current));
          continue;
        } catch (_) {
          break;
        }
      }
      if (wantDeflate) {
        try {
          current = Uint8List.fromList(zlib.decode(current));
          continue;
        } catch (_) {
          break;
        }
      }
      break;
    }
    return current;
  }

  Uint8List _bytesFromResponse(Response response) {
    final data = response.data;
    if (data is Uint8List) return data;
    return Uint8List.fromList((data as List).cast<int>());
  }

  Future<Response> _getResponseForUrl(
    String url,
    ResponseType responseType,
  ) async {
    String? userInfo;
    String requestUrl = url;

    if (url.startsWith('http://') || url.startsWith('https://')) {
      final schemeEnd = url.indexOf('://') + 3;
      final slashIndex = url.indexOf('/', schemeEnd);
      final questionIndex = url.indexOf('?', schemeEnd);
      final hashIndex = url.indexOf('#', schemeEnd);
      var authorityEnd = url.length;
      if (slashIndex != -1) authorityEnd = slashIndex;
      if (questionIndex != -1 && questionIndex < authorityEnd) {
        authorityEnd = questionIndex;
      }
      if (hashIndex != -1 && hashIndex < authorityEnd) {
        authorityEnd = hashIndex;
      }
      final atIndex = url.lastIndexOf('@', authorityEnd - 1);
      if (atIndex >= schemeEnd) {
        userInfo = url.substring(schemeEnd, atIndex);
        requestUrl = url.substring(0, schemeEnd) + url.substring(atIndex + 1);
      }
    }

    final headers = <String, dynamic>{'Connection': 'close'};
    if (userInfo != null && userInfo.isNotEmpty) {
      final auth = base64Encode(utf8.encode(userInfo));
      headers['Authorization'] = 'Basic $auth';
    }

    final response = await _clashDio.get(
      requestUrl,
      options: Options(responseType: ResponseType.bytes, headers: headers),
    );

    final rawBytes = _bytesFromResponse(response);
    final decompressedBytes = _decompressIfNeeded(rawBytes, response.headers);

    if (responseType == ResponseType.plain) {
      final text = utf8.decode(decompressedBytes, allowMalformed: true);
      return Response(
        requestOptions: response.requestOptions,
        data: text,
        statusCode: response.statusCode,
        statusMessage: response.statusMessage,
        isRedirect: response.isRedirect,
        redirects: response.redirects,
        extra: response.extra,
        headers: response.headers,
      );
    } else {
      return Response(
        requestOptions: response.requestOptions,
        data: decompressedBytes,
        statusCode: response.statusCode,
        statusMessage: response.statusMessage,
        isRedirect: response.isRedirect,
        redirects: response.redirects,
        extra: response.extra,
        headers: response.headers,
      );
    }
  }

  Future<Response> getFileResponseForUrl(String url) async {
    return _getResponseForUrl(url, ResponseType.bytes);
  }

  Future<Response> getTextResponseForUrl(String url) async {
    return _getResponseForUrl(url, ResponseType.plain);
  }

  Future<MemoryImage?> getImage(String url) async {
    if (url.isEmpty) return null;
    final response = await _dio.get<Uint8List>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final data = response.data;
    if (data == null) return null;
    final bytes = _decompressIfNeeded(data, response.headers);
    return MemoryImage(bytes);
  }

  Future<Map<String, dynamic>?> checkForUpdate() async {
    try {
      final t = DateTime.now().millisecondsSinceEpoch;
      final response = await _dio.get(
        'https://github.com/$repository/releases/latest?t=$t',
        options: Options(
          followRedirects: false,
          validateStatus: (status) =>
              status != null && status >= 300 && status < 400,
        ),
      );
      final location = response.headers['location']?.firstOrNull;
      if (location != null && location.contains('/releases/tag/')) {
        final remoteVersion = location.split('/').last.trim();
        if (remoteVersion.isNotEmpty) {
          final version = globalState.packageInfo.version;
          final hasUpdate =
              utils.compareVersions(
                remoteVersion.replaceAll('v', ''),
                version,
              ) >
              0;
          if (!hasUpdate) return null;
          return {
            'tag_name': remoteVersion,
            'html_url': 'https://github.com/$repository/releases/latest',
            'body': 'New version available. Please visit GitHub to download.',
          };
        }
      }
    } catch (e) {
      commonPrint.log('Check update failed: ${e.formatErrorLog}');
    }
    return null;
  }

  // 国外检测源（无需 token）：请求经本地代理端口出站时能反映真实出口 IP。
  // 顺序即优先级：首源 api.ip.sb/geoip 为全字段 HTTPS JSON（省/市/ISP/ASN 齐全，
  // 解析时归一化为 ip-api 风格键）；其后 Cloudflare 自有域名连通性最稳定（trace 文本）；
  // 全部失败才轮到 ipify 与带 token 的 ipinfo。同域名的 ip.sb trace 已被 geoip 取代不再单列。
  List<String> _getOverseasIpSources() {
    return [
      'https://api.ip.sb/geoip',
      'https://www.cloudflare.com/cdn-cgi/trace',
      'https://cp.cloudflare.com/cdn-cgi/trace',
      'https://cloudflare.com/cdn-cgi/trace',
      'https://api.ipify.org?format=json',
      if (ipInfoToken.isNotEmpty)
        'https://api.ipinfo.io/lite/me?token=$ipInfoToken',
    ];
  }

  // 国内源：作为国外源全部失败时的回退（代理未连通 / 规则限制时展示真实网络）
  List<String> _getPrimaryIpSources() {
    final locale = Intl.getCurrentLocale().toLowerCase();
    final isZh = locale.startsWith('zh');
    return [
      isZh ? 'https://api.myip.la/cn?json' : 'https://api.myip.la/en?json',
    ];
  }

  final List<String> _domesticIpSources = [
    'https://myip.ipip.net/json',
  ];

  IpInfo? _tryParseIpInfo(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('{')) {
      final decoded = json.decode(trimmed);
      if (decoded is Map<String, dynamic>) {
        // api.ip.sb/geoip 等扁平 snake_case 全字段 JSON：归一化为 ip-api 风格键，
        // 复用 IpInfo.fromJson 的 ip-api 分支做省/市/ISP/ASN 映射。
        final cc = decoded['country_code']?.toString() ?? '';
        if (cc.isNotEmpty &&
            decoded['region'] is String &&
            decoded['city'] is String) {
          final rawAsn = decoded['asn']?.toString() ?? '';
          final asn = rawAsn.isNotEmpty &&
                  !rawAsn.toUpperCase().startsWith('AS')
              ? 'AS$rawAsn'
              : rawAsn;
          return IpInfo.fromJson({
            'ip': decoded['ip']?.toString() ?? '',
            'countryCode': cc,
            'country': decoded['country']?.toString(),
            'regionName': decoded['region']?.toString(),
            'city': decoded['city']?.toString(),
            'isp': decoded['isp']?.toString(),
            'org': decoded['organization']?.toString(),
            'as': asn,
          });
        }
        return IpInfo.fromJson(decoded);
      }
    } else {
      return IpInfo.fromCloudflareTrace(trimmed);
    }
    return null;
  }

  // 依次探测各源，任一源成功即返回（成功即停，不做跨源合并），全部失败返回 null。
  // 串行而非并行：不同源可能命中不同链路（代理出口 vs 国内直连）返回不同 IP，
  // 并发合并会产生 IP 与国家错配的脏数据，故成功即返回首个可靠结果。
  Future<IpInfo?> _probeIpSourcesSequential({
    required List<String> sources,
    CancelToken? cancelToken,
    Duration? timeout,
    void Function(IpInfo info)? onUpdate,
  }) async {
    if (sources.isEmpty) return null;
    // 整体预算均摊到每个源，避免多源串行时累计超时过长
    final budget = timeout ?? const Duration(seconds: 5);
    final perSourceTimeout = Duration(
      milliseconds: (budget.inMilliseconds / sources.length).ceil(),
    );

    for (final url in sources) {
      if (cancelToken?.isCancelled ?? false) return null;
      try {
        final dio = Dio(
          BaseOptions(
            receiveTimeout: perSourceTimeout,
            connectTimeout: perSourceTimeout,
          ),
        );
        dio.httpClientAdapter = IOHttpClientAdapter(
          createHttpClient: () {
            final client = HttpClient();
            client.autoUncompress = false;
            return client;
          },
        );
        try {
          final res = await dio.get<Uint8List>(
            url,
            cancelToken: cancelToken,
            options: Options(responseType: ResponseType.bytes),
          );
          if (res.statusCode == HttpStatus.ok && res.data != null) {
            final text = utf8.decode(
              _decompressIfNeeded(_bytesFromResponse(res), res.headers),
              allowMalformed: true,
            );
            try {
              final ipInfo = _tryParseIpInfo(text);
              if (ipInfo != null) {
                onUpdate?.call(ipInfo);
                return ipInfo;
              }
            } catch (_) {}
          }
        } finally {
          dio.close(force: true);
        }
      } catch (e) {
        if (e is DioException && e.type == DioExceptionType.cancel) {
          return null;
        }
      }
    }
    return null;
  }

  Future<Result<IpInfo?>> checkIp({
    CancelToken? cancelToken,
    Duration? timeout,
    void Function(IpInfo info)? onUpdate,
  }) async {
    // 代理运行时优先使用国外源（api.ip.sb/geoip + Cloudflare trace）：这些域名在
    // 常见规则集（含 GEOIP,CN,DIRECT / 国内域名规则）下都会走代理出站，能反映真实出口；
    // api.myip.la 等国内源常被规则判 DIRECT，返回真实国内 IP 造成误判。
    final ipInfo = await _probeIpSourcesSequential(
      sources: _getOverseasIpSources(),
      cancelToken: cancelToken,
      timeout: timeout,
      onUpdate: onUpdate,
    );
    if (ipInfo != null) {
      return Result.success(ipInfo);
    }
    // 全部失败再回退国内源（代理未连通 / 规则限制时展示真实网络）
    final fallback = await _probeIpSourcesSequential(
      sources: _getPrimaryIpSources(),
      cancelToken: cancelToken,
      timeout: timeout,
      onUpdate: onUpdate,
    );
    return Result.success(fallback);
  }

  Future<Result<IpInfo?>> checkIpDomestic({
    CancelToken? cancelToken,
    Duration? timeout,
    void Function(IpInfo info)? onUpdate,
  }) async {
    return Result.success(
      await _probeIpSourcesSequential(
        sources: _domesticIpSources,
        cancelToken: cancelToken,
        timeout: timeout,
        onUpdate: onUpdate,
      ),
    );
  }

  static const _ipCacheKey = 'ip_detail_cache';
  static const _cacheDuration = Duration(days: 14);

  Future<IpInfo?> _getValidCachedIp(String cacheKey) async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      final cacheStr = prefs?.getString(_ipCacheKey);
      if (cacheStr == null || cacheStr.isEmpty) return null;

      final dynamic decoded = json.decode(cacheStr);
      if (decoded is! Map) return null;

      final rawMap = Map<String, dynamic>.from(decoded);
      final now = DateTime.now().millisecondsSinceEpoch;
      final maxAgeMs = _cacheDuration.inMilliseconds;

      bool hasExpired = false;
      final validEntries = <String, dynamic>{};
      IpInfo? matchedIpInfo;

      // 仅在用户查询时，主动检查并清理所有过期的缓存
      for (final entry in rawMap.entries) {
        final val = entry.value;
        if (val is Map) {
          final valMap = Map<String, dynamic>.from(val);
          final timestamp = valMap['timestamp'] as num?;
          if (timestamp != null && (now - timestamp) < maxAgeMs) {
            validEntries[entry.key] = valMap;
            if (entry.key == cacheKey && valMap['data'] is Map) {
              try {
                matchedIpInfo = IpInfo.fromJson(
                  Map<String, dynamic>.from(valMap['data'] as Map),
                );
              } catch (_) {}
            }
          } else {
            hasExpired = true;
          }
        }
      }

      // 如果有过期的数据被剔除，保存清理后的缓存
      if (hasExpired) {
        await prefs?.setString(_ipCacheKey, json.encode(validEntries));
      }

      return matchedIpInfo;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCachedIp(String cacheKey, IpInfo ipInfo) async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      final cacheStr = prefs?.getString(_ipCacheKey);
      final rawMap = (cacheStr != null && cacheStr.isNotEmpty)
          ? Map<String, dynamic>.from(json.decode(cacheStr) as Map)
          : <String, dynamic>{};

      final now = DateTime.now().millisecondsSinceEpoch;
      final maxAgeMs = _cacheDuration.inMilliseconds;

      // 清理已过期数据，并插入新数据
      final validEntries = <String, dynamic>{};
      for (final entry in rawMap.entries) {
        final val = entry.value;
        if (val is Map) {
          final valMap = Map<String, dynamic>.from(val);
          final timestamp = valMap['timestamp'] as num?;
          if (timestamp != null && (now - timestamp) < maxAgeMs) {
            validEntries[entry.key] = valMap;
          }
        }
      }

      validEntries[cacheKey] = {
        'timestamp': now,
        'data': ipInfo.toJson(),
      };

      await prefs?.setString(_ipCacheKey, json.encode(validEntries));
    } catch (_) {}
  }

  Future<Result<IpInfo?>> queryIpDetail(
    String ip, {
    CancelToken? cancelToken,
    Duration? timeout,
  }) async {
    final isZh = Intl.getCurrentLocale().toLowerCase().startsWith('zh');
    final cacheKey = '${ip}_${isZh ? 'zh' : 'en'}';

    // 1. 检查本地缓存并执行过期清理（有效时长7天）
    final cached = await _getValidCachedIp(cacheKey);
    if (cached != null) {
      return Result.success(cached);
    }

    final effectiveTimeout = timeout ?? const Duration(seconds: 5);
    final url = isZh
        ? 'http://ip-api.com/json/$ip?lang=zh-CN'
        : 'http://ip-api.com/json/$ip';

    try {
      final res = await _dio.get<Map<String, dynamic>>(
        url,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.json,
          receiveTimeout: effectiveTimeout,
          sendTimeout: effectiveTimeout,
        ),
      );

      if (res.statusCode == HttpStatus.ok && res.data != null) {
        final data = res.data!;
        final status = data['status']?.toString();
        if (status == 'fail') {
          final message = data['message']?.toString() ?? 'query failed';
          return Result.error(message);
        }
        final ipInfo = IpInfo.fromJson(data);
        // 2. 写入 7 天有效期的本地缓存
        await _saveCachedIp(cacheKey, ipInfo);
        return Result.success(ipInfo);
      }
      return Result.error('query failed');
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) {
        return Result.error('cancelled');
      }
      return Result.error(e.toString());
    }
  }
}

final request = Request();
