import 'dart:convert';

import 'package:bett_box/rust/bettbox_config.dart';
import 'package:flutter_test/flutter_test.dart';

import '../common/json_diff.dart';

/// 合并入口 `bb_process_profile`（`patchRawConfig` 里「跑脚本 + patch」两步合一的
/// Rust 实现）的验证。输入用与 `rust/bettbox-native/src/patch_config.rs` 测试里
/// `minimal_input()` 同形的最小配置。
Map<String, dynamic> _minimalInput() => jsonDecode('''
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

dynamic _copy(Object? value) => jsonDecode(jsonEncode(value));

void main() {
  final available = BettboxConfig.isAvailable;
  final skipReason = available
      ? null
      : '未找到 bettbox_native 动态库，先构建：cd rust && cargo build --release';

  group('bb_process_profile 合并入口', () {
    test('恒等脚本时与 patchConfig 结果一致', () {
      final input = _minimalInput();
      final referenceJson = BettboxConfig.patchConfig(jsonEncode(input));
      expect(referenceJson, isNotNull, reason: 'patchConfig 应接管');
      final reference = jsonDecode(referenceJson!);

      final processed = BettboxConfig.processProfile(
        jsonEncode(input),
        'function main(c){ return c; }',
      );
      expect(processed, isNotNull, reason: 'processProfile 应接管');
      expect(processed!.scriptError, isNull);

      // 防「两边一起空转」。
      expect(reference['external-ui'], input['env']['uiPath']);
      expect(processed.config['external-ui'], input['env']['uiPath']);

      final difference = firstJsonDifference(
        reference,
        processed.config,
        '',
      );
      expect(difference, isNull, reason: '$difference');
    });

    test('脚本真的跑过：脚本加的键出现在 patch 结果里', () {
      final processed = BettboxConfig.processProfile(
        jsonEncode(_minimalInput()),
        "function main(c){ c['scriptMarker'] = 'yes'; return c; }",
      );
      expect(processed, isNotNull);
      expect(processed!.config['scriptMarker'], 'yes');
      expect(processed.scriptError, isNull);
    });

    test('customOptions 合并进 ruleOptionsEnable', () {
      // 选项只合并进**已定义**的 `ruleOptionsEnable`（与 Dart 侧一致），
      // 所以脚本正文要先声明它。
      final processed = BettboxConfig.processProfile(
        jsonEncode(_minimalInput()),
        'var ruleOptionsEnable = {base: true};\n'
            "function main(c){ c['opt'] = ruleOptionsEnable; return c; }",
        customOptionsJson: jsonEncode({'add-quic': true}),
      );
      expect(processed, isNotNull);
      expect(processed!.config['opt'], {'base': true, 'add-quic': true});
    });

    test('脚本失败时回传 scriptError，且 patch 仍然产出', () {
      final processed = BettboxConfig.processProfile(
        jsonEncode(_minimalInput()),
        "function main(c){ throw new Error('boom'); }",
      );
      expect(processed, isNotNull);
      final error = processed!.scriptError;
      expect(error, isNotNull);
      expect(error, startsWith('JS Script Error: '));
      expect(error, contains('boom'));
      expect(processed.config['external-controller'], '127.0.0.1:9090');
    });

    test('rawConfig 不是对象时返回 null（ABI 级失败）', () {
      final input = _copy(_minimalInput()) as Map<String, dynamic>;
      input['rawConfig'] = 'not an object';
      expect(
        BettboxConfig.processProfile(
          jsonEncode(input),
          'function main(c){ return c; }',
        ),
        isNull,
      );
    });

    test('入参非法 JSON 返回 null', () {
      expect(
        BettboxConfig.processProfile(
          '{not json',
          'function main(c){ return c; }',
        ),
        isNull,
      );
    });
  }, skip: skipReason);
}
