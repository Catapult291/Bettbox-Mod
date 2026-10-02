import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/config_patch.dart';
import 'package:bett_box/rust/bettbox_config.dart';

import '../common/json_diff.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

dynamic _copy(Object? value) => jsonDecode(jsonEncode(value));

final _app = _fixture('config/app-config.json');

/// 脱敏脚本把 `hosts` 的值写成了列表，但 `ClashConfig.hosts` 是 `Map<String, String>`；
/// 这里换成应用里真实会出现的字符串形状，并留一条多值以覆盖分隔符切分。
Map<String, dynamic> _patchBase() {
  final patch = _copy(_app['patchClashConfig']) as Map<String, dynamic>;
  patch['hosts'] = <String, dynamic>{
    'example.com': '203.0.113.10',
    'cdn.example.net': '203.0.113.11, 203.0.113.12',
  };
  return patch;
}

/// 把 `Profile` 里 `patchRawConfig` 会读到的字段摊成平结构。
///
/// `overrideData.rules` 是 `OverrideRule.rules`（按 type 选 overrideRules / addedRules）
/// 映射出的 `value` 列表，对应 Dart 侧的 `OverrideDataExt.runningRule`。
Map<String, dynamic> _profileMeta(String id) {
  final entry = (_app['profiles'] as List).cast<Map>().firstWhere(
    (profile) => profile['id'] == id,
  );
  final overrideData = (entry['overrideData'] as Map).cast<String, dynamic>();
  final rule = (overrideData['rule'] as Map).cast<String, dynamic>();
  final rules =
      (rule['type'] == 'override' ? rule['overrideRules'] : rule['addedRules'])
          as List;
  return <String, dynamic>{
    'id': entry['id'],
    'useScriptOverride': entry['useScriptOverride'],
    'groupSwitches': entry['group-switches'],
    'overrideData': <String, dynamic>{
      'enable': overrideData['enable'],
      'type': rule['type'],
      'rules': rules.map((rule) => (rule as Map)['value']).toList(),
    },
  };
}

Map<String, dynamic> _envBase() => <String, dynamic>{
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

Map<String, dynamic> _build({
  required String profileFixture,
  required String profileId,
  Map<String, dynamic>? env,
  Map<String, dynamic>? profile,
  void Function(Map<String, dynamic> raw)? mutateRaw,
  void Function(Map<String, dynamic> patch)? mutatePatch,
}) {
  final raw =
      _copy(_fixture('config/$profileFixture.json')) as Map<String, dynamic>;
  mutateRaw?.call(raw);
  // 注入用的 Dart 字面量会推断出窄类型，过一次 JSON 归一化以匹配真实解码结果。
  final normalizedRaw = _copy(raw) as Map<String, dynamic>;
  final patch = _patchBase();
  mutatePatch?.call(patch);
  return <String, dynamic>{
    'rawConfig': normalizedRaw,
    'patch': patch,
    'profile': profile ?? _profileMeta(profileId),
    'env': <String, dynamic>{..._envBase(), ...?env},
  };
}

void _expectSame(Map<String, dynamic> input, String where) {
  final dartOutput = applyConfigPatch(_copy(input) as Map<String, dynamic>);

  final rustJson = BettboxConfig.patchConfig(jsonEncode(input));
  expect(rustJson, isNotNull, reason: where);
  final rustOutput = jsonDecode(rustJson!);

  // 防「两边一起空转」：输出必须真的是一份改写过的配置。
  expect(
    dartOutput['external-ui'],
    input['env']['uiPath'],
    reason: '$where：external-ui',
  );
  expect(dartOutput['rules'], isNotEmpty, reason: '$where：rules 为空');
  expect(
    (dartOutput['hosts'] as Map)['dns.msftncsi.com'],
    isNotNull,
    reason: '$where：hosts 未写入 dns.msftncsi.com',
  );
  expect(rustOutput['rules'], isNotEmpty, reason: '$where：Rust 侧 rules 为空');

  final difference = firstJsonDifference(dartOutput, rustOutput, '');
  expect(difference, isNull, reason: '$where\n$difference');
}

void main() {
  final available = BettboxConfig.isAvailable;
  final skipReason = available
      ? null
      : '未找到 bettbox_config 动态库，先构建：cd rust && cargo build';

  const profileA = '1790933713761';
  const profileB = '1790933895907';

  group('Rust vs Dart 的整管道差分', () {
    test('两份真实 profile 的默认开关', () {
      _expectSame(
        _build(profileFixture: 'profile-a', profileId: profileA),
        'profile-a 默认',
      );
      _expectSame(
        _build(profileFixture: 'profile-b', profileId: profileB),
        'profile-b 默认',
      );
    });

    test('DNS / NTP / Sniffer / Experimental 全覆盖打开', () {
      _expectSame(
        _build(
          profileFixture: 'profile-a',
          profileId: profileA,
          env: {
            'overrideDns': true,
            'overrideNtp': true,
            'overrideSniffer': true,
            'overrideExperimental': true,
          },
        ),
        'override 全开',
      );
    });

    test('Android 分支（tun / dns listen / ntp）', () {
      _expectSame(
        _build(
          profileFixture: 'profile-a',
          profileId: profileA,
          env: {'isAndroid': true},
        ),
        'Android',
      );
      _expectSame(
        _build(
          profileFixture: 'profile-b',
          profileId: profileB,
          env: {'isAndroid': true, 'isLinux': true},
        ),
        'Android + Linux',
      );
    });

    test('节点过滤与 tolerance 归一化', () {
      for (final filter in ['过期|剩余|官网', '^test-', '中文\\d+']) {
        _expectSame(
          _build(
            profileFixture: 'profile-a',
            profileId: profileA,
            env: {'nodeExcludeFilter': filter, 'healthCheckTimeout': 3000},
          ),
          'nodeExcludeFilter=$filter',
        );
      }
      _expectSame(
        _build(
          profileFixture: 'profile-b',
          profileId: profileB,
          env: {'nodeExcludeFilter': '过期', 'healthCheckTimeout': 8000},
        ),
        'profile-b 节点过滤',
      );
      _expectSame(
        _build(
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
        ),
        'tolerance 归一化',
      );
    });

    test('disableQuic 的三种分支', () {
      for (final entry in {
        '默认': {'disableQuic': true},
        '排除中国': {'disableQuic': true, 'excludeChina': true},
        '俄语环境': {'disableQuic': true, 'excludeChina': true, 'locale': 'ru-RU'},
      }.entries) {
        _expectSame(
          _build(
            profileFixture: 'profile-a',
            profileId: profileA,
            env: entry.value,
          ),
          'disableQuic ${entry.key}',
        );
      }
    });

    test('overrideData 与追加规则', () {
      for (final type in ['override', 'added']) {
        _expectSame(
          _build(
            profileFixture: 'profile-a',
            profileId: profileA,
            profile: {
              ..._profileMeta(profileA),
              'overrideData': {
                'enable': true,
                'type': type,
                'rules': [
                  'DOMAIN,override.example.com,OpenAI',
                  'MATCH,Telegram',
                ],
              },
            },
          ),
          'overrideData type=$type',
        );
      }
      _expectSame(
        _build(
          profileFixture: 'profile-a',
          profileId: profileA,
          env: {
            'scriptAddedRules': ['DOMAIN-SUFFIX,ui.example.com,fixture-a'],
          },
        ),
        '脚本追加规则',
      );
      _expectSame(
        _build(
          profileFixture: 'profile-a',
          profileId: profileA,
          env: {'hasCurrentScript': true},
          profile: {
            ..._profileMeta(profileA),
            'overrideData': {
              'enable': true,
              'type': 'override',
              'rules': ['MATCH,OpenAI'],
            },
          },
        ),
        '脚本覆写生效（跳过 overrideData 与分组开关）',
      );
    });

    test('分组开关', () {
      _expectSame(
        _build(
          profileFixture: 'profile-a',
          profileId: profileA,
          profile: {
            ..._profileMeta(profileA),
            'groupSwitches': {
              'OpenAI': false,
              'Telegram': false,
              'fixture-a': true,
            },
          },
        ),
        '禁用两个分组',
      );
      _expectSame(
        _build(
          profileFixture: 'profile-b',
          profileId: profileB,
          mutateRaw: (raw) {
            final groups = raw['proxy-groups'] as List;
            raw['proxy-groups'] = groups;
          },
          profile: {
            ..._profileMeta(profileB),
            'groupSwitches': {
              for (final (index, group)
                  in ((_copy(_fixture('config/profile-b.json'))
                              as Map)['proxy-groups']
                          as List)
                      .indexed)
                if (group is Map && group['name'] is String)
                  group['name'] as String: index.isEven,
            },
          },
        ),
        'profile-b 禁用一半分组',
      );
    });

    test('provider 路径改写与 provider 级 exclude-filter', () {
      _expectSame(
        _build(
          profileFixture: 'profile-a',
          profileId: profileA,
          env: {'nodeExcludeFilter': '过期'},
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
        ),
        'provider 路径改写',
      );
    });

    test('tun / sniffer 端口 / tunnels / 代理字段补丁', () {
      _expectSame(
        _build(
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
                'network': 'tcp',
                'address': '198.51.100.0/24',
                'target': '203.0.113.9:443',
                'proxy': 'DIRECT',
              },
            ];
          },
        ),
        'tun/sniffer/tunnels/代理补丁',
      );
    });
  }, skip: skipReason);
}
