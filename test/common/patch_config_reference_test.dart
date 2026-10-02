import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/config_patch.dart';
import 'package:bett_box/common/config_patch_input.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/rust/bettbox_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'json_diff.dart';
import 'patch_config_reference.dart';

/// 用 `git show HEAD:lib/state.dart` 的原始实现（见 patch_config_reference.dart）
/// 验证抽取后的两步——`buildConfigPatchInput` + `applyConfigPatch`——没有走样。
///
/// 与 `test/rust/patch_config_diff_test.dart` 的分工：那个证明 Dart 镜像与 Rust 一致，
/// 这个证明 Dart 镜像与**改造前的生产实现**一致。
Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

dynamic _copy(Object? value) => jsonDecode(jsonEncode(value));

/// 深拷贝 fixture 后套用注入，再过一次 JSON 归一化：注入用的 Dart 字面量会推断出
/// `Map<String, List<int>>` 这类窄类型，与真实 JSON 解码（`Map<String, dynamic>` /
/// `List<dynamic>`）不同，而生产数据的类型是后者。
Map<String, dynamic> _mutate(
  Map<String, dynamic> fixture,
  void Function(Map<String, dynamic> raw)? mutate,
) {
  final raw = _copy(fixture) as Map<String, dynamic>;
  mutate?.call(raw);
  return _copy(raw) as Map<String, dynamic>;
}

final _app = _fixture('config/app-config.json');

Map<String, dynamic> _patchJson(void Function(Map<String, dynamic>)? mutate) {
  final patch = _copy(_app['patchClashConfig']) as Map<String, dynamic>;
  // 脱敏脚本把 hosts 写成列表值，但 ClashConfig.hosts 是 Map<String, String>。
  patch['hosts'] = <String, dynamic>{
    'example.com': '203.0.113.10',
    'cdn.example.net': '203.0.113.11, 203.0.113.12',
  };
  mutate?.call(patch);
  return patch;
}

Map<String, dynamic> _profileJson(
  String profileId,
  void Function(Map<String, dynamic>)? mutate,
) {
  final entry = (_app['profiles'] as List).cast<Map>().firstWhere(
    (profile) => profile['id'] == profileId,
  );
  final json = _copy(entry) as Map<String, dynamic>;
  mutate?.call(json);
  return json;
}

Map<String, dynamic> _env(void Function(Map<String, dynamic>)? mutate) {
  final env = <String, dynamic>{
    'isAndroid': false,
    'isLinux': false,
    'uiPath': r'C:\demo\Bettbox\ui',
    'profilesPath': r'C:\demo\Bettbox\profiles',
    'overrideDns': _app['overrideDns'],
    'overrideNtp': _app['overrideNtp'],
    'overrideSniffer': _app['overrideSniffer'],
    'overrideExperimental': _app['overrideExperimental'],
    'nodeExcludeFilter': _app['nodeExcludeFilter'],
    'healthCheckTimeout': _app['healthCheckTimeout'],
    'scriptAddedRules': (_app['scriptProps'] as Map)['added-rules'],
    'hasCurrentScript': (_app['scriptProps'] as Map)['currentId'] != null,
    'disableQuic': (_app['vpnProps'] as Map)['disableQuic'],
    'excludeChina': (_app['vpnProps'] as Map)['excludeChina'],
    'locale': (_app['appSetting'] as Map)['locale'],
  };
  mutate?.call(env);
  return env;
}

void _expectSame({
  required String where,
  required String profileFixture,
  required String profileId,
  void Function(Map<String, dynamic> env)? mutateEnv,
  void Function(Map<String, dynamic> profile)? mutateProfile,
  void Function(Map<String, dynamic> raw)? mutateRaw,
  void Function(Map<String, dynamic> patch)? mutatePatch,
}) {
  final patchJson = _patchJson(mutatePatch);
  final patchModel = ClashConfig.fromJson(patchJson);
  final networkProps = NetworkProps.fromJson(
    (_app['networkProps'] as Map).cast<String, dynamic>(),
  );

  // 与 patchRawConfig 里的 realPatchConfig 推导保持一致。
  final fakeIpRangeV6 = patchModel.dns.effectiveFakeIpRangeV6(
    ipv6Enabled: patchModel.ipv6,
  );
  final realPatch = patchModel.copyWith(
    dns: patchModel.dns.copyWith(fakeIpRangeV6: fakeIpRangeV6),
    tun: patchModel.tun.getRealTun(
      networkProps.bypassPrivateRoute,
      fakeIpRange: patchModel.dns.fakeIpRange,
      fakeIpRangeV6: fakeIpRangeV6,
      bypassPrivateRouteAddress: networkProps.realBypassPrivateRouteAddress,
    ),
  );

  final profileJson = _profileJson(profileId, mutateProfile);
  final profileModel = Profile.fromJson(profileJson);
  final env = _env(mutateEnv);

  final rawFixture = _fixture('config/$profileFixture.json');

  final rawForReference = _mutate(rawFixture, mutateRaw);
  final reference = referencePatchConfig(
    rawConfig: rawForReference,
    patch: realPatch,
    profile: profileModel,
    profileId: profileId,
    isAndroid: env['isAndroid'] as bool,
    isLinux: env['isLinux'] as bool,
    uiPath: env['uiPath'] as String,
    profilesPath: env['profilesPath'] as String,
    envOverrideDns: env['overrideDns'] as bool,
    envOverrideNtp: env['overrideNtp'] as bool,
    envOverrideSniffer: env['overrideSniffer'] as bool,
    envOverrideExperimental: env['overrideExperimental'] as bool,
    envNodeExcludeFilter: env['nodeExcludeFilter'] as String,
    envHealthCheckTimeout: env['healthCheckTimeout'] as int,
    scriptAddedRules: (env['scriptAddedRules'] as List).cast<String>(),
    hasCurrentScript: env['hasCurrentScript'] as bool,
    disableQuic: env['disableQuic'] as bool,
    excludeChina: env['excludeChina'] as bool,
    locale: env['locale'] as String?,
  );

  final rawForActual = _mutate(rawFixture, mutateRaw);
  final input = buildConfigPatchInput(
    rawConfig: rawForActual,
    patch: realPatch,
    profile: profileModel,
    isAndroid: env['isAndroid'] as bool,
    isLinux: env['isLinux'] as bool,
    uiPath: env['uiPath'] as String,
    profilesPath: env['profilesPath'] as String,
    overrideDns: env['overrideDns'] as bool,
    overrideNtp: env['overrideNtp'] as bool,
    overrideSniffer: env['overrideSniffer'] as bool,
    overrideExperimental: env['overrideExperimental'] as bool,
    nodeExcludeFilter: env['nodeExcludeFilter'] as String,
    healthCheckTimeout: env['healthCheckTimeout'] as int,
    scriptAddedRules: (env['scriptAddedRules'] as List).cast<String>(),
    hasCurrentScript: env['hasCurrentScript'] as bool,
    disableQuic: env['disableQuic'] as bool,
    excludeChina: env['excludeChina'] as bool,
    locale: env['locale'] as String?,
  );

  expect(reference['rules'], isNotEmpty, reason: '$where：参照实现的 rules 为空');

  // 参照实现（改造前的生产代码）会把 `Dns.toJson()` 里的 `fallback-filter` 之类的
  // 模型对象直接放进配置，靠 YAML 编码器逐层展开；这里比的就是展开后的等价形态。
  final resolvedReference = resolveJsonValue(reference) as Map<String, dynamic>;

  final actual = applyConfigPatch(_copy(input) as Map<String, dynamic>);
  expect(
    firstJsonDifference(resolvedReference, actual, ''),
    isNull,
    reason: '$where（Dart 路径）',
  );

  // 这条同时覆盖 feature flag 打开时真正走的那条路：builder → Rust 入口。
  if (BettboxConfig.isAvailable) {
    final rustJson = BettboxConfig.patchConfig(jsonEncode(input));
    expect(rustJson, isNotNull, reason: '$where：Rust 入口返回 null');
    expect(
      firstJsonDifference(resolvedReference, jsonDecode(rustJson!), ''),
      isNull,
      reason: '$where（Rust 路径）',
    );
  }
}

void main() {
  const profileA = '1790933713761';
  const profileB = '1790933895907';

  test('两份真实 profile 的默认开关', () {
    _expectSame(
      where: 'profile-a 默认',
      profileFixture: 'profile-a',
      profileId: profileA,
    );
    _expectSame(
      where: 'profile-b 默认',
      profileFixture: 'profile-b',
      profileId: profileB,
    );
  });

  test('override 全开', () {
    _expectSame(
      where: 'override 全开',
      profileFixture: 'profile-a',
      profileId: profileA,
      mutateEnv: (env) => env
        ..['overrideDns'] = true
        ..['overrideNtp'] = true
        ..['overrideSniffer'] = true
        ..['overrideExperimental'] = true,
    );
  });

  test('平台分支', () {
    _expectSame(
      where: 'Android',
      profileFixture: 'profile-a',
      profileId: profileA,
      mutateEnv: (env) => env['isAndroid'] = true,
    );
    _expectSame(
      where: 'Android + Linux',
      profileFixture: 'profile-b',
      profileId: profileB,
      mutateEnv: (env) => env
        ..['isAndroid'] = true
        ..['isLinux'] = true,
    );
  });

  test('节点过滤与 tolerance', () {
    _expectSame(
      where: '节点过滤',
      profileFixture: 'profile-a',
      profileId: profileA,
      mutateEnv: (env) => env
        ..['nodeExcludeFilter'] = '过期|剩余|官网'
        ..['healthCheckTimeout'] = 3000,
    );
    _expectSame(
      where: 'tolerance 归一化',
      profileFixture: 'profile-a',
      profileId: profileA,
      mutateRaw: (raw) {
        raw['proxy-groups'] = [
          for (final group in raw['proxy-groups'] as List)
            {...(group as Map), 'tolerance': 300.0},
          {
            'name': '带 use 的分组',
            'type': 'url-test',
            'use': ['机场A'],
            'tolerance': '150',
          },
        ];
      },
    );
  });

  test('disableQuic', () {
    for (final entry in {
      '默认': {'disableQuic': true},
      '排除中国': {'disableQuic': true, 'excludeChina': true},
      '俄语环境': {'disableQuic': true, 'excludeChina': true, 'locale': 'ru-RU'},
    }.entries) {
      _expectSame(
        where: 'disableQuic ${entry.key}',
        profileFixture: 'profile-a',
        profileId: profileA,
        mutateEnv: (env) => env.addAll(entry.value),
      );
    }
  });

  test('overrideData 与追加规则', () {
    for (final type in ['override', 'added']) {
      _expectSame(
        where: 'overrideData type=$type',
        profileFixture: 'profile-a',
        profileId: profileA,
        mutateProfile: (profile) {
          (profile['overrideData'] as Map)
            ..['enable'] = true
            ..['rule'] = {
              'type': type,
              'overrideRules': [
                {'id': 'r1', 'value': 'DOMAIN,override.example.com,OpenAI'},
              ],
              'addedRules': [
                {'id': 'r2', 'value': 'MATCH,Telegram'},
              ],
            };
        },
      );
    }
    _expectSame(
      where: '脚本追加规则',
      profileFixture: 'profile-a',
      profileId: profileA,
      mutateEnv: (env) =>
          env['scriptAddedRules'] = ['DOMAIN-SUFFIX,ui.example.com,fixture-a'],
    );
    _expectSame(
      where: '脚本覆写生效',
      profileFixture: 'profile-a',
      profileId: profileA,
      mutateEnv: (env) => env['hasCurrentScript'] = true,
      mutateProfile: (profile) {
        (profile['overrideData'] as Map)['enable'] = true;
      },
    );
  });

  test('分组开关', () {
    _expectSame(
      where: '禁用两个分组',
      profileFixture: 'profile-a',
      profileId: profileA,
      mutateProfile: (profile) {
        profile['group-switches'] = {
          'OpenAI': false,
          'Telegram': false,
          'fixture-a': true,
        };
      },
    );
  });

  test('provider 路径、tunnels、sniffer 端口、代理字段补丁', () {
    _expectSame(
      where: 'provider 路径与 exclude-filter',
      profileFixture: 'profile-a',
      profileId: profileA,
      mutateEnv: (env) => env['nodeExcludeFilter'] = '过期',
      mutateRaw: (raw) {
        raw['proxy-providers'] = {
          '机场A': {
            'type': 'http',
            'url': 'https://example.com/sub-a.yaml',
            'interval': 3600,
          },
          '本地文件': {'type': 'file', 'path': './local.yaml'},
        };
        raw['rule-providers'] = {
          '规则集': {
            'type': 'http',
            'url': 'https://example.com/rules.yaml',
            'behavior': 'domain',
          },
        };
      },
    );
    _expectSame(
      where: 'tunnels / sniffer / 代理补丁',
      profileFixture: 'profile-a',
      profileId: profileA,
      mutateRaw: (raw) {
        raw['sniffer'] = {
          'enable': true,
          'sniff': {
            'http': {
              'ports': [80, 8080],
            },
            'tls': {'ports': '443'},
          },
        };
        raw['global-client-fingerprint'] = 'chrome';
        raw['proxies'] = [
          ...(raw['proxies'] as List),
          {
            'name': 'trojan-x',
            'type': 'trojan',
            'server': 'a.example.com',
            'port': 443,
          },
          {
            'name': 'vless-y',
            'type': 'vless',
            'tls': true,
            'server': 'b.example.com',
            'port': 443,
            'reality-opts': {'short-id': 12345, 'public-key': 'PUBKEY'},
          },
          {
            'name': 'vmess-z',
            'type': 'vmess',
            'tls': false,
            'server': 'c.example.com',
            'port': 443,
          },
        ];
      },
      mutatePatch: (patch) {
        patch['tunnels'] = [
          {
            'id': 'tunnel-1',
            'network': ['tcp'],
            'address': '198.51.100.0/24',
            'target': '203.0.113.9:443',
            'proxyName': 'DIRECT',
          },
        ];
      },
    );
  });
}
