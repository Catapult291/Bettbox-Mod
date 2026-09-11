import 'dart:convert';

import 'package:bett_box/models/common.dart';
import 'package:flutter_test/flutter_test.dart';

// 与 lib/common/request.dart 中 _tryParseIpInfo 的归一化逻辑保持一致：
// api.ip.sb/geoip 等扁平 snake_case 全字段 JSON 先转成 ip-api 风格键，
// 再交给 IpInfo.fromJson 的 ip-api 分支映射。
Map<String, Object?> _normalizeGeoIp(Map<String, dynamic> decoded) {
  final cc = decoded['country_code']?.toString() ?? '';
  final rawAsn = decoded['asn']?.toString() ?? '';
  final asn =
      rawAsn.isNotEmpty && !rawAsn.toUpperCase().startsWith('AS')
          ? 'AS$rawAsn'
          : rawAsn;
  return {
    'ip': decoded['ip']?.toString() ?? '',
    'countryCode': cc,
    'country': decoded['country']?.toString(),
    'regionName': decoded['region']?.toString(),
    'city': decoded['city']?.toString(),
    'isp': decoded['isp']?.toString(),
    'org': decoded['organization']?.toString(),
    'as': asn,
  };
}

IpInfo? _parseBody(String body) {
  final trimmed = body.trim();
  if (trimmed.startsWith('{')) {
    final decoded = json.decode(trimmed);
    if (decoded is Map<String, dynamic>) {
      final cc = decoded['country_code']?.toString() ?? '';
      if (cc.isNotEmpty &&
          decoded['region'] is String &&
          decoded['city'] is String) {
        return IpInfo.fromJson(_normalizeGeoIp(decoded));
      }
      return IpInfo.fromJson(decoded);
    }
  }
  return IpInfo.fromCloudflareTrace(trimmed);
}

void main() {
  test('api.ip.sb/geoip 真实载荷解析出全字段', () {
    // 2026-09-08 实抓：出口为台湾，返回扁平 snake_case 全字段 JSON。
    const body =
        '{"region":"New Taipei City","organization":"Imcloud Technology",'
        '"region_code":"NWT","isp":"Imcloud Technology",'
        '"city":"Linkou District",'
        '"asn_organization":"Imcloud Technology Co., Ltd.",'
        '"postal_code":"244","asn":131151,"latitude":25.0738,'
        '"ip":"103.123.133.58","continent_code":"AS","offset":28800,'
        '"country":"Taiwan","timezone":"Asia/Taipei",'
        '"country_code":"TW","longitude":121.3935}';

    final info = _parseBody(body);
    expect(info, isNotNull);
    expect(info!.ip, '103.123.133.58');
    expect(info.countryCode, 'TW');
    expect(info.country, 'Taiwan');
    expect(info.province, 'New Taipei City');
    expect(info.city, 'Linkou District');
    expect(info.isp, 'Imcloud Technology');
    expect(info.asName, 'Imcloud Technology');
    expect(info.asn, 'AS131151');
  });

  test('cloudflare trace 文本仍走 trace 解析', () {
    const body = 'fl=80f382\nh=www.cloudflare.com\nip=103.123.133.58\n'
        'loc=TW\nwarp=off\ngateway=off\n';
    final info = _parseBody(body);
    expect(info, isNotNull);
    expect(info!.ip, '103.123.133.58');
    expect(info.countryCode, 'TW');
  });
}
