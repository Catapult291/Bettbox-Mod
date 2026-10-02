import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/config_patch_input.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// `buildConfigPatchInput` 是 Dart 与 Rust 两条路径唯一的共同入口，
/// 这里把它对模型的映射钉住：枚举取 `.name`、`external-controller` 取 `.value`、
/// `tunnels` 用 `toClashJson()` 而不是 `toJson()`。
void main() {
  final app =
      jsonDecode(File('fixtures/config/app-config.json').readAsStringSync())
          as Map<String, dynamic>;
  final patchJson = Map<String, dynamic>.from(app['patchClashConfig'] as Map)
    ..['hosts'] = <String, dynamic>{'example.com': '203.0.113.10'};
  patchJson['tunnels'] = [
    {
      'id': 'tunnel-1',
      'network': ['tcp'],
      'address': '198.51.100.0/24',
      'target': '203.0.113.9:443',
      'proxyName': 'DIRECT',
    },
  ];

  final patch = ClashConfig.fromJson(patchJson);
  final profile = Profile.fromJson({
    'id': 'profile-1',
    'autoUpdateDuration': 86400000000,
    'group-switches': {'OpenAI': false, 'Telegram': true},
    'overrideData': {
      'enable': true,
      'rule': {
        'type': 'added',
        'overrideRules': [],
        'addedRules': [
          {'id': 'r1', 'value': 'DOMAIN,a.example.com,OpenAI'},
        ],
      },
    },
  });

  final input = buildConfigPatchInput(
    rawConfig: {'rules': <dynamic>[]},
    patch: patch,
    profile: profile,
    isAndroid: false,
    isLinux: true,
    uiPath: r'C:\demo\ui',
    profilesPath: r'C:\demo\profiles',
    overrideDns: true,
    overrideNtp: false,
    overrideSniffer: true,
    overrideExperimental: false,
    nodeExcludeFilter: '过期',
    healthCheckTimeout: 3000,
    scriptAddedRules: const ['MATCH,DIRECT'],
    hasCurrentScript: false,
    disableQuic: true,
    excludeChina: true,
    locale: 'ru-RU',
  );

  final patchOut = input['patch'] as Map<String, dynamic>;
  final profileOut = input['profile'] as Map<String, dynamic>;
  final envOut = input['env'] as Map<String, dynamic>;

  test('rawConfig 原样带上，不复制', () {
    final raw = {'rules': <dynamic>[]};
    final built = buildConfigPatchInput(
      rawConfig: raw,
      patch: patch,
      profile: profile,
      isAndroid: false,
      isLinux: false,
      uiPath: 'u',
      profilesPath: 'p',
      overrideDns: false,
      overrideNtp: false,
      overrideSniffer: false,
      overrideExperimental: false,
      nodeExcludeFilter: '',
      healthCheckTimeout: 5000,
      scriptAddedRules: const [],
      hasCurrentScript: false,
      disableQuic: false,
      excludeChina: false,
      locale: null,
    );
    expect(identical(built['rawConfig'], raw), isTrue);
  });

  test('枚举与 external-controller 取对了取值', () {
    expect(patchOut['log-level'], patch.logLevel.name);
    expect(patchOut['mode'], patch.mode.name);
    expect(patchOut['find-process-mode'], patch.findProcessMode.name);
    expect(patchOut['geodata-loader'], patch.geodataLoader.name);
    expect(patchOut['tun']['stack'], patch.tun.stack.name);
    expect(patchOut['external-controller'], patch.externalController.value);
    expect(patchOut['geox-url'].keys.toSet(), {'mmdb', 'asn', 'geosite'});
  });

  test('tunnels 用 toClashJson（proxy 而不是 proxyName，且不含 id）', () {
    expect(patchOut['tunnels'], [
      {
        'network': ['tcp'],
        'address': '198.51.100.0/24',
        'target': '203.0.113.9:443',
        'proxy': 'DIRECT',
      },
    ]);
  });

  test('tun 只带管道需要读的字段', () {
    expect(patchOut['tun'].keys.toSet(), {
      'enable',
      'device',
      'stack',
      'dns-hijack',
      'route-address',
      'route-exclude-address',
      'strict-route',
      'endpoint-independent-nat',
      'disable-icmp-forwarding',
      'mtu',
    });
  });

  test('hosts 与 dns 按模型序列化', () {
    expect(patchOut['hosts'], {'example.com': '203.0.113.10'});
    expect(patchOut['dns']['fake-ip-range6'], patch.dns.fakeIpRangeV6);
    expect(patchOut['dns']['nameserver-policy'], patch.dns.nameserverPolicy);
  });

  test('profile 的 overrideData 摊成 type + rules', () {
    expect(profileOut['groupSwitches'], {'OpenAI': false, 'Telegram': true});
    expect(profileOut['overrideData'], {
      'enable': true,
      'type': 'added',
      'rules': ['DOMAIN,a.example.com,OpenAI'],
    });
  });

  test('env 原样透传', () {
    expect(envOut, {
      'isAndroid': false,
      'isLinux': true,
      'uiPath': r'C:\demo\ui',
      'profilesPath': r'C:\demo\profiles',
      'overrideDns': true,
      'overrideNtp': false,
      'overrideSniffer': true,
      'overrideExperimental': false,
      'nodeExcludeFilter': '过期',
      'healthCheckTimeout': 3000,
      'scriptAddedRules': ['MATCH,DIRECT'],
      'hasCurrentScript': false,
      'disableQuic': true,
      'excludeChina': true,
      'locale': 'ru-RU',
    });
  });
}
