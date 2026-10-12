import 'package:bett_box/rust/bettbox_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// 失败路径「合并入口返回 NULL」的包装层行为：**dll 已加载**、但 `bb_process_profile`
/// 因入参非法或 patch 失败返回 NULL 时，`processProfile` 必须抛 [StateError]，
/// 而不是返回 null、也不是退回别的实现（§32 起两段式已删除）。
///
/// 分工：dll 缺失/ABI 失配由 `patch_config_unavailable_test` 覆盖；
/// Rust 侧返回 NULL 的条件由 `patch_config.rs` 的单元测试覆盖；
/// 本文件补中间一环——真实加载的 dll 返回 NULL → Dart 包装层报错。
const _script = 'function main(c){ return c; }';

/// 与 `rust/bettbox-native/src/patch_config.rs` 的 `minimal_input()` 一致。
const _minimalInput = r'''
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
    "uiPath": "C:\\demo\\ui",
    "profilesPath": "C:\\demo\\profiles",
    "nodeExcludeFilter": "",
    "healthCheckTimeout": 5000,
    "scriptAddedRules": [],
    "hasCurrentScript": false,
    "disableQuic": false,
    "excludeChina": false
  }
}
''';

Matcher _throwsNullEntrance() => throwsA(
      isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('合并入口未产出结果'),
      ),
    );

void main() {
  final available = BettboxConfig.isAvailable;
  final skipReason = available
      ? null
      : '未找到 bettbox_native 动态库，先构建：cd rust && cargo build';

  group('dll 已加载、合并入口返回 NULL → 抛 StateError（失败路径 ②）', () {
    test('rawConfig 非对象', () {
      expect(
        () => BettboxConfig.processProfile('{"rawConfig":123}', _script),
        _throwsNullEntrance(),
      );
    });

    test('input 不是合法 JSON', () {
      expect(
        () => BettboxConfig.processProfile('not json', _script),
        _throwsNullEntrance(),
      );
    });

    test('patch 缺失导致 patch 失败（脚本已跑完仍返回 NULL）', () {
      // 去掉 patch：rawConfig 是对象、脚本可求值，但 `patch_config` 报错 → NULL。
      final withoutPatch =
          _minimalInput.replaceFirst(RegExp(r'"patch": \{'), '"patchRemoved": {');
      expect(
        () => BettboxConfig.processProfile(withoutPatch, _script),
        _throwsNullEntrance(),
      );
    });

    test('customOptionsJson 非 JSON 对象', () {
      expect(
        () => BettboxConfig.processProfile(
          _minimalInput,
          _script,
          customOptionsJson: 'nope',
        ),
        _throwsNullEntrance(),
      );
    });

    test('patchConfig 输入缺必需字段同样抛错，不返回 null', () {
      expect(
        () => BettboxConfig.patchConfig('{}'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('配置管道未产出结果'),
          ),
        ),
      );
    });

    test('对照：最小合法输入正常出信封（证明不是全路径都抛错）', () {
      final processed =
          BettboxConfig.processProfile(_minimalInput, _script);
      expect(processed.config, isA<Map<String, dynamic>>());
      expect(processed.scriptError, isNull);
    });
  }, skip: skipReason);
}
