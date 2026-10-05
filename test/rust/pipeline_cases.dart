import 'dart:convert';
import 'dart:io';

/// 配置改写管道的测试输入构造器，以及 golden 用例清单。
///
/// 真实应用里这份输入由 `lib/common/config_patch_input.dart` 的
/// `buildConfigPatchInput` 摊出来（宿主是 `lib/state.dart` 的 `patchRawConfig`）；
/// 这里用脱敏 fixture 复现同一形状，供三处共用：
///   * `patch_config_diff_test.dart` / `process_profile_diff_test.dart` 做 Rust vs Dart 差分；
///   * `golden_generate_test.dart` 用 Dart 镜像生成 golden 期望输出。
/// 共用一份构造器，才能保证差分测试与 golden 喂给管道的是同一份输入。

/// app-config fixture 里两个 profile 的 id。
const profileAId = '1790933713761';
const profileBId = '1790933895907';

Map<String, dynamic> fixtureJson(String name) =>
    jsonDecode(File('fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

dynamic copyJson(Object? value) => jsonDecode(jsonEncode(value));

/// 脱敏脚本把 `hosts` 的值写成了列表，但 `ClashConfig.hosts` 是 `Map<String, String>`；
/// 这里换成应用里真实会出现的字符串形状，并留一条多值以覆盖分隔符切分。
Map<String, dynamic> patchBase() {
  final patch = copyJson(fixtureJson('config/app-config.json')['patchClashConfig'])
      as Map<String, dynamic>;
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
Map<String, dynamic> profileMeta(String id) {
  final app = fixtureJson('config/app-config.json');
  final entry = (app['profiles'] as List).cast<Map>().firstWhere(
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

Map<String, dynamic> envBase() {
  final app = fixtureJson('config/app-config.json');
  return <String, dynamic>{
    'isAndroid': false,
    'isLinux': false,
    'uiPath': r'C:\demo\Bettbox\ui',
    'profilesPath': r'C:\demo\Bettbox\profiles',
    'overrideDns': app['overrideDns'],
    'overrideNtp': app['overrideNtp'],
    'overrideSniffer': app['overrideSniffer'],
    'overrideExperimental': app['overrideExperimental'],
    'nodeExcludeFilter': app['nodeExcludeFilter'],
    'healthCheckTimeout': app['healthCheckTimeout'],
    'scriptAddedRules': (app['scriptProps'] as Map)['added-rules'],
    'hasCurrentScript': (app['scriptProps'] as Map)['currentId'] != null,
    'disableQuic': (app['vpnProps'] as Map)['disableQuic'],
    'excludeChina': (app['vpnProps'] as Map)['excludeChina'],
    'locale': (app['appSetting'] as Map)['locale'],
  };
}

/// 造一份 `applyConfigPatch` / `bb_patch_config` 的输入 JSON。
Map<String, dynamic> buildPatchInput({
  required String profileFixture,
  required String profileId,
  Map<String, dynamic>? env,
  Map<String, dynamic>? profile,
  void Function(Map<String, dynamic> raw)? mutateRaw,
  void Function(Map<String, dynamic> patch)? mutatePatch,
}) {
  final raw =
      copyJson(fixtureJson('config/$profileFixture.json')) as Map<String, dynamic>;
  mutateRaw?.call(raw);
  // 注入用的 Dart 字面量会推断出窄类型，过一次 JSON 归一化以匹配真实解码结果。
  final normalizedRaw = copyJson(raw) as Map<String, dynamic>;
  final patch = patchBase();
  mutatePatch?.call(patch);
  return <String, dynamic>{
    'rawConfig': normalizedRaw,
    'patch': patch,
    'profile': profile ?? profileMeta(profileId),
    'env': <String, dynamic>{...envBase(), ...?env},
  };
}

/// 合并入口 `bb_process_profile` 的最小输入，形状与 `patch_config.rs` 里
/// `minimal_input()` 一致（小配置便于断言脚本改动落在哪）。
Map<String, dynamic> minimalProcessInput() => jsonDecode('''
{
  "rawConfig": {
    "proxies": [
      {"name": "节点1", "type": "ss", "server": "a.example.com"},
      {"name": "节点2", "type": "ss", "server": "b.example.com"}
    ],
    "proxy-groups": [
      {"name": "自动选择", "type": "url-test", "proxies": ["节点1", "节点2"]},
      {"name": "DIRECT", "type": "select", "proxies": ["DIRECT"]}
    ],
    "rules": ["DOMAIN,a.example.com,自动选择", "MATCH,自动选择"]
  },
  "patch": {
    "dns": {"enable": true},
    "tun": {"enable": false, "device": "Bettbox", "dns-hijack": []},
    "ipv6": false,
    "allow-lan": false,
    "external-controller": "127.0.0.1:9090",
    "secret": "s3cret",
    "log-level": "error",
    "mode": "rule",
    "find-process-mode": "off",
    "geodata-loader": "memconservative",
    "mixed-port": 7890,
    "port": 7891,
    "geox-url": {"mmdb": "m", "asn": "a", "geosite": "g"},
    "hosts": {"example.com": "203.0.113.10, 203.0.113.11"},
    "tunnels": [],
    "sniffer": {},
    "ntp": {},
    "experimental": {}
  },
  "profile": {
    "id": "p1",
    "useScriptOverride": true,
    "groupSwitches": {"自动选择": false},
    "overrideData": {"enable": false, "type": "override", "rules": []}
  },
  "env": {
    "isAndroid": false,
    "isLinux": false,
    "uiPath": "C:\\\\demo\\\\ui",
    "profilesPath": "C:\\\\demo\\\\profiles",
    "nodeExcludeFilter": "",
    "healthCheckTimeout": 5000,
    "scriptAddedRules": [],
    "hasCurrentScript": false,
    "disableQuic": false,
    "excludeChina": false
  }
}
''') as Map<String, dynamic>;

/// 仓库里那份脱敏过的真实覆写脚本（`fixtures/scripts/dns.js`）。
String realScript() => File('fixtures/scripts/dns.js').readAsStringSync();

/// 一条 golden 用例：`input` 是要喂给管道的输入（process_profile 的 `input` 是**跑脚本前**
/// 的原始输入，脚本由 Rust 入口内部执行）。
class PipelineCase {
  PipelineCase({
    required this.name,
    required this.entry,
    required this.input,
    this.script,
    this.customOptions,
  });

  /// golden 文件名（同时也是用例名）。
  final String name;

  /// `patch_config` 或 `process_profile`。
  final String entry;
  final Map<String, dynamic> input;
  final String? script;
  final Map<String, bool>? customOptions;
}

/// golden 覆盖的用例集：从差分测试的用例里挑出分支覆盖面最广的一批。
///
/// 完整用例仍在 `patch_config_diff_test.dart` / `process_profile_diff_test.dart` 里跑；
/// 这里只挑进 golden 的那部分——golden 是给「Dart 镜像删除后」留的独立回归网，
/// 所以覆盖的是分支，不是全部输入组合。
List<PipelineCase> pipelineCases() {
  return <PipelineCase>[
    PipelineCase(
      name: 'profile-a-default',
      entry: 'patch_config',
      input: buildPatchInput(
        profileFixture: 'profile-a',
        profileId: profileAId,
      ),
    ),
    PipelineCase(
      name: 'profile-b-default',
      entry: 'patch_config',
      input: buildPatchInput(
        profileFixture: 'profile-b',
        profileId: profileBId,
      ),
    ),
    PipelineCase(
      name: 'profile-a-override-all',
      entry: 'patch_config',
      input: buildPatchInput(
        profileFixture: 'profile-a',
        profileId: profileAId,
        env: {
          'overrideDns': true,
          'overrideNtp': true,
          'overrideSniffer': true,
          'overrideExperimental': true,
        },
      ),
    ),
    PipelineCase(
      name: 'profile-a-android',
      entry: 'patch_config',
      input: buildPatchInput(
        profileFixture: 'profile-a',
        profileId: profileAId,
        env: {'isAndroid': true},
      ),
    ),
    PipelineCase(
      name: 'profile-a-node-filter',
      entry: 'patch_config',
      input: buildPatchInput(
        profileFixture: 'profile-a',
        profileId: profileAId,
        env: {'nodeExcludeFilter': '过期|剩余|官网', 'healthCheckTimeout': 3000},
      ),
    ),
    PipelineCase(
      name: 'profile-a-node-filter-regex',
      entry: 'patch_config',
      input: buildPatchInput(
        profileFixture: 'profile-a',
        profileId: profileAId,
        env: {'nodeExcludeFilter': '中文\\d+', 'healthCheckTimeout': 3000},
      ),
    ),
    PipelineCase(
      name: 'profile-a-tolerance',
      entry: 'patch_config',
      input: buildPatchInput(
        profileFixture: 'profile-a',
        profileId: profileAId,
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
    ),
    PipelineCase(
      name: 'profile-a-quic-exclude-china',
      entry: 'patch_config',
      input: buildPatchInput(
        profileFixture: 'profile-a',
        profileId: profileAId,
        env: {'disableQuic': true, 'excludeChina': true},
      ),
    ),
    PipelineCase(
      name: 'profile-a-override-rules',
      entry: 'patch_config',
      input: buildPatchInput(
        profileFixture: 'profile-a',
        profileId: profileAId,
        profile: {
          ...profileMeta(profileAId),
          'overrideData': {
            'enable': true,
            'type': 'override',
            'rules': ['DOMAIN,override.example.com,OpenAI', 'MATCH,Telegram'],
          },
        },
      ),
    ),
    PipelineCase(
      name: 'profile-a-group-switches',
      entry: 'patch_config',
      input: buildPatchInput(
        profileFixture: 'profile-a',
        profileId: profileAId,
        profile: {
          ...profileMeta(profileAId),
          'groupSwitches': {
            'OpenAI': false,
            'Telegram': false,
            'fixture-a': true,
          },
        },
      ),
    ),
    PipelineCase(
      name: 'profile-a-provider-paths',
      entry: 'patch_config',
      input: buildPatchInput(
        profileFixture: 'profile-a',
        profileId: profileAId,
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
    ),
    PipelineCase(
      name: 'profile-a-tun-sniffer-tunnels',
      entry: 'patch_config',
      input: buildPatchInput(
        profileFixture: 'profile-a',
        profileId: profileAId,
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
    ),
    PipelineCase(
      name: 'profile-b-half-groups',
      entry: 'patch_config',
      input: buildPatchInput(
        profileFixture: 'profile-b',
        profileId: profileBId,
        profile: {
          ...profileMeta(profileBId),
          'groupSwitches': {
            for (final (index, group)
                in ((copyJson(fixtureJson('config/profile-b.json'))
                            as Map)['proxy-groups']
                        as List)
                    .indexed)
              if (group is Map && group['name'] is String)
                group['name'] as String: index.isEven,
          },
        },
      ),
    ),
    PipelineCase(
      name: 'profile-a-real-script',
      entry: 'process_profile',
      input: buildPatchInput(
        profileFixture: 'profile-a',
        profileId: profileAId,
        env: {'hasCurrentScript': true},
      ),
      script: realScript(),
    ),
    PipelineCase(
      name: 'profile-b-real-script',
      entry: 'process_profile',
      input: buildPatchInput(
        profileFixture: 'profile-b',
        profileId: profileBId,
        env: {'hasCurrentScript': true},
      ),
      script: realScript(),
    ),
    PipelineCase(
      name: 'minimal-identity-script',
      entry: 'process_profile',
      input: minimalProcessInput(),
      script: 'function main(c){ return c; }',
    ),
    PipelineCase(
      name: 'minimal-script-error',
      entry: 'process_profile',
      input: minimalProcessInput(),
      script: "function main(c){ throw new Error('boom'); }",
    ),
    PipelineCase(
      name: 'minimal-custom-options',
      entry: 'process_profile',
      input: minimalProcessInput(),
      script: 'var ruleOptionsEnable = {base: true};\n'
          "function main(c){ c['opt'] = ruleOptionsEnable; return c; }",
      customOptions: {'add-quic': true},
    ),
  ];
}
