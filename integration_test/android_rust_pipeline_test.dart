import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/rust/bettbox_config.dart';
import 'package:bett_box/rust/bettbox_script.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 在 Android 设备/模拟器上验证「Android 已切到 Rust」这条结论本身。
///
/// 与 `rust/bettbox-native/tests/golden.rs` 不同，这里跑在设备上：`libbettbox_native.so`
/// 必须由 Android 的动态加载器按名字解析到（`lib/rust/native_library.dart`），因此
/// `isAvailable` 为真就是「Rust 库真的随包到位并加载成功」的证据。
///
/// Dart 镜像与 qjs 参照实现在阶段 5 第 3 步已删除，所以设备端不再对拍另一套实现；
/// 管道逐字段正确性由仓库内的 golden（`fixtures/golden/` + `cargo test`）负责，
/// 这里负责的是设备特性：库能加载、Android 分支真的生效、脚本在设备上真的被求值。
///
/// 运行方式（需要设备/模拟器）：
/// `flutter test integration_test/android_rust_pipeline_test.dart -d <device-id>`
///
/// 默认的 `flutter test` 只扫 `test/`，不会带上这个文件。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// 设备端用的最小输入：小配置便于断言改动落在哪。`isAndroid` 由调用方决定，
  /// 同一份输入分别以 Android / 非 Android 跑一次，用来证明平台分支真的生效。
  Map<String, dynamic> smokeInput({required bool isAndroid}) => jsonDecode('''
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
    "isAndroid": $isAndroid,
    "isLinux": false,
    "uiPath": "/data/user/0/com.appshub.bettbox/files/ui",
    "profilesPath": "/data/user/0/com.appshub.bettbox/files/profiles",
    "overrideDns": false,
    "overrideNtp": false,
    "overrideSniffer": false,
    "overrideExperimental": false,
    "nodeExcludeFilter": "",
    "healthCheckTimeout": 5000,
    "scriptAddedRules": [],
    "hasCurrentScript": false,
    "disableQuic": false,
    "excludeChina": false,
    "locale": null
  }
}
''') as Map<String, dynamic>;

  Map<String, dynamic> patchConfig(Map<String, dynamic> input) =>
      (jsonDecode(BettboxConfig.patchConfig(jsonEncode(input))) as Map)
          .cast<String, dynamic>();

  test('设备上 Rust 动态库可加载（libbettbox_native.so）', () {
    expect(Platform.isAndroid, isTrue, reason: '本用例只能在 Android 设备上跑');
    expect(
      BettboxConfig.isAvailable,
      isTrue,
      reason: 'libbettbox_native.so 未加载：配置管道会直接报错，配置无法生成',
    );
    expect(BettboxScript.isAvailable, isTrue);
  });

  test('配置管道在设备上产出配置，且 Android 分支真的生效', () {
    final android = smokeInput(isAndroid: true);
    final output = patchConfig(android);
    final env = android['env'] as Map;

    // 防「空转」：patch 管道确实跑过（external-ui 来自 env，tun 键来自 patch）。
    expect(output['external-ui'], env['uiPath']);
    expect(output['mixed-port'], 7890);
    expect(output['rules'], isNotNull);

    // Android 分支：tun 不自动路由/自动探测网卡，ntp 不写系统。
    final tun = (output['tun'] as Map).cast<String, dynamic>();
    expect(tun['auto-route'], isFalse);
    expect(tun['auto-detect-interface'], isFalse);
    expect((output['ntp'] as Map)['write-to-system'], isFalse);

    // 同一份输入在非 Android 上必须相反，否则上面的断言只是常量。
    final desktop = patchConfig(smokeInput(isAndroid: false));
    final desktopTun = (desktop['tun'] as Map).cast<String, dynamic>();
    expect(desktopTun['auto-route'], isTrue);
    expect((desktop['ntp'] as Map).containsKey('write-to-system'), isFalse);
  });

  test('脚本引擎在设备上真的求值（含 customOptions 与选项抽取）', () async {
    // `customOptions` 的合并发生在求值内部（`Object.assign(ruleOptionsEnable, …)`），
    // 不借 `main` 的返回值带出来就观察不到。
    const script =
        'var ruleOptionsEnable = {base: true};\n'
        "function main(c){ c['marker'] = 'android'; c['base'] = ruleOptionsEnable.base; return c; }";

    final merged = await JavaScriptRuntimeManager.evaluateScript(
      script,
      <String, dynamic>{'a': 1},
      customOptions: const {'base': false},
    );
    expect(merged['marker'], 'android', reason: '脚本正文没有被执行');
    expect(merged['base'], isFalse, reason: 'customOptions 没有合并进 ruleOptionsEnable');

    final declared = await JavaScriptRuntimeManager.evaluateScript(
      script,
      <String, dynamic>{'a': 1},
    );
    expect(declared['base'], isTrue, reason: 'customOptions 为空时改动了脚本声明的值');

    // 抽取只读脚本声明的选项，不参与 customOptions 合并（合并只发生在求值路径与
    // 脚本页展示层 `_processScriptData`），因此这里应是脚本里写的 true。
    final options = await JavaScriptRuntimeManager.extractScriptOptions(script);
    expect((options['options'] as Map)['base'], isTrue, reason: '抽取改动了脚本声明的值');
  });

  test('合并入口 process_profile：恒等脚本与 patchConfig 逐字段一致', () {
    final input = smokeInput(isAndroid: true);
    final reference = patchConfig(input);

    final processed = BettboxConfig.processProfile(
      jsonEncode(input),
      'function main(c){ return c; }',
    );
    expect(processed.scriptError, isNull);
    expect(processed.config, equals(reference));
  });
}
