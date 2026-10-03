import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/js_runtime_manager.dart';
import 'package:bett_box/rust/bettbox_script.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../common/json_diff.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

/// 与 `GlobalState.handleEvaluate` 一致：脚本求值前补上 `proxy-providers`。
Map<String, dynamic> _configFor(String profileFixture) {
  final config = _fixture('config/$profileFixture.json');
  config['proxy-providers'] ??= {};
  return config;
}

String get _realScript => File('fixtures/scripts/dns.js').readAsStringSync();

/// 逐字段比对 Rust 输出与 qjs 输出，返回第一处差异（无差异为 null）。
Future<String?> _firstDifference(
  String script,
  Map<String, dynamic> config, {
  Map<String, bool>? customOptions,
  bool expectRustTakesOver = true,
}) async {
  final rust = await BettboxScript.evaluateScript(
    script,
    config,
    customOptions: customOptions,
  );
  if (expectRustTakesOver) {
    expect(rust, isNotNull, reason: 'Rust 引擎未接管（返回 null）');
  }
  final qjs = await JavaScriptRuntimeManager.evaluateScript(
    script,
    config,
    customOptions: customOptions,
  );
  if (rust == null) return null;
  return firstJsonDifference(qjs, rust, '');
}

/// 抽取选项这条路径的逐字段比对：Rust 与 qjs 参考实现。
Future<String?> _firstExtractDifference(String script) async {
  final rust = await BettboxScript.extractScriptOptions(script);
  expect(rust, isNotNull, reason: 'Rust 引擎未接管 extractScriptOptions');
  final qjs = await JavaScriptRuntimeManager.extractOptionsViaQjs(script);
  return firstJsonDifference(qjs, rust, '');
}

/// 抽取路径出错时两侧的错误串（都抛原始错误，不带 `JS Script Error: ` 前缀）。
Future<String> _extractErrorFromRust(String script) async {
  final error = await BettboxScript.extractScriptOptions(
    script,
  ).then<Object?>((value) => value, onError: (Object error) => error);
  expect(error, isA<String>(), reason: script);
  return error.toString();
}

Future<String> _extractErrorFromQjs(String script) async {
  // qjs 侧抛的是 JSError（`toString()` 同样是 `message\nstack`），Rust 侧抛的是
  // 原始错误串——两边对外的文本一致，所以只比 `toString()`。
  final error = await JavaScriptRuntimeManager.extractOptionsViaQjs(
    script,
  ).then<Object?>((value) => value, onError: (Object error) => error);
  return error.toString();
}

void main() {
  // qjs 参考实现只在 flutter test 下从 `test/build/Debug/ffiquickjs.dll` 加载
  // （见 `plugins/flutter_qjs/lib/src/ffi.dart`），且该 dll 依赖 flutter_windows.dll。
  final qjsDll = File(p.join('test', 'build', 'Debug', 'ffiquickjs.dll'));
  final skipReason = !BettboxScript.isAvailable
      ? '未找到 bettbox_script 动态库，先构建：cd rust && cargo build --release'
      : !Platform.isWindows
      ? 'qjs 参考实现的测试库路径只在 Windows 上确认过'
      : !qjsDll.existsSync()
      ? '未找到 qjs 参考实现 ${qjsDll.path}：拷一份 '
            'build/windows/x64/runner/Release/flutter_qjs_plugin.dll 过去，'
            '并让 PATH 包含同目录（flutter_windows.dll 与它同目录）'
      : null;

  group('Rust 脚本引擎 vs qjs 的逐字段差分', () {
    test('真实脚本 × profile-a', () async {
      final difference = await _firstDifference(
        _realScript,
        _configFor('profile-a'),
      );
      expect(difference, isNull, reason: 'profile-a\n$difference');
    });

    test('真实脚本 × profile-b（3486 条规则）', () async {
      final difference = await _firstDifference(
        _realScript,
        _configFor('profile-b'),
      );
      expect(difference, isNull, reason: 'profile-b\n$difference');
    });

    test('evaluateScriptPreferRust 确实走 Rust，且与 qjs 同结果', () async {
      final config = _configFor('profile-a');
      final preferRust = await JavaScriptRuntimeManager.evaluateScriptPreferRust(
        _realScript,
        config,
      );
      final viaRustWrapper = await BettboxScript.evaluateScript(
        _realScript,
        config,
      );
      expect(
        firstJsonDifference(viaRustWrapper, preferRust, ''),
        isNull,
        reason: 'evaluateScriptPreferRust 没有走 Rust 引擎',
      );
      final qjs = await JavaScriptRuntimeManager.evaluateScript(
        _realScript,
        config,
      );
      expect(firstJsonDifference(qjs, preferRust, ''), isNull);
    });

    test('customOptions 合并进 ruleOptionsEnable', () async {
      const script = '''
var ruleOptionsEnable = { flag: false, other: true };
function main(c) { return { flag: ruleOptionsEnable.flag, other: ruleOptionsEnable.other }; }
''';
      final config = <String, dynamic>{'a': 1};
      expect(await _firstDifference(script, config), isNull);
      expect(
        await _firstDifference(
          script,
          config,
          customOptions: const {'flag': true},
        ),
        isNull,
      );
      // 脚本未定义 ruleOptionsEnable 时，两侧都应忽略 options。
      const noOptionsScript = 'function main(c) { c.ok = true; return c; }';
      expect(
        await _firstDifference(
          noOptionsScript,
          config,
          customOptions: const {'flag': true},
        ),
        isNull,
      );
    });

    test('返回值不是对象时保留原配置', () async {
      final config = <String, dynamic>{
        'a': <String, dynamic>{'b': [1, 2, 3]},
      };
      for (final script in [
        'function main(c) { return 42; }',
        'function main(c) { return [1, 2]; }',
        'function main(c) { return null; }',
        'function main(c) { return undefined; }',
      ]) {
        final difference = await _firstDifference(script, config);
        expect(difference, isNull, reason: script);
      }
      final rust = await BettboxScript.evaluateScript(
        'function main(c) { return 42; }',
        config,
      );
      expect(rust, config, reason: '非对象返回值应原样保留原配置');
    });

    test('UTF-8 键值与中文内容', () async {
      final config = <String, dynamic>{
        '名称': '香港',
        'rules': <String>['DOMAIN-SUFFIX,例子.中国,DIRECT'],
      };
      const script = "function main(c){ c.备注 = '中文节点'; return c; }";
      expect(await _firstDifference(script, config), isNull);
    });

    test('错误串与 qjs 一致（含栈与语法错误）', () async {
      for (final script in [
        // 抛 Error：栈里带 <eval>:<行号>，两侧程序的行结构必须一致。
        "function main(c){ throw new Error('boom'); }",
        // 多行脚本 + 抛错，覆盖脚本自身行号参与栈帧的情况。
        "function main(c){\n  var x = 1;\n  throw new Error('boom2');\n}",
        // 抛非 Error 值：不起栈，只比消息。
        "function main(c){ throw 'plain'; }",
        // 语法错误：在解析期报出，行号也对齐。
        'function main(c){ return c; ',
        'function main(c){ return c; } oops',
        // 缺少 main。
        'var x = 1;',
      ]) {
        final qjsError = await JavaScriptRuntimeManager.evaluateScript(
          script,
          <String, dynamic>{},
        ).then<Object?>((value) => value, onError: (Object error) => error);
        final rustError = await BettboxScript.evaluateScript(
          script,
          <String, dynamic>{},
        ).then<Object?>((value) => value, onError: (Object error) => error);
        expect(rustError, isA<String>(), reason: script);
        expect(rustError.toString(), qjsError.toString(), reason: script);
      }
    });
  }, skip: skipReason);

  group('extractScriptOptions：Rust vs qjs 的逐字段差分', () {
    test('选项与图标（含该跳过的条目）', () async {
      const script = '''
var ruleOptionsEnable = { enableIPv6: false, fixBug: true };
var serviceConfigs = [
  { name: 'OpenAI', icon: 'https://example.com/openai.png' },
  { name: 'NoIcon' },
  { icon: 'https://example.com/orphan.png' },
  'not-an-object',
];
function main(c) { return c; }
''';
      final difference = await _firstExtractDifference(script);
      expect(difference, isNull, reason: '$difference');
      final rust = await BettboxScript.extractScriptOptions(script);
      expect((rust!['options'] as Map)['enableIPv6'], isFalse);
      // 只收「有 name 且 icon 是字符串」的项。
      expect((rust['icons'] as Map).keys.toList(), ['OpenAI']);
    });

    test('什么都没声明 / 声明形状不对都退化成空表', () async {
      for (final script in [
        'function main(c) { return c; }',
        "var ruleOptionsEnable = 'nope'; function main(c) { return c; }",
        "var serviceConfigs = { name: 'x', icon: 'y' }; function main(c) { return c; }",
        'var ruleOptionsEnable = null; var serviceConfigs = []; function main(c) { return c; }',
      ]) {
        final difference = await _firstExtractDifference(script);
        expect(difference, isNull, reason: script);
      }
    });

    test('真实脚本（未声明选项）两侧一致', () async {
      final difference = await _firstExtractDifference(_realScript);
      expect(difference, isNull, reason: '$difference');
    });

    test('顶层抛错与语法错误的错误串一致', () async {
      for (final script in [
        "var x = 1;\nthrow new Error('boom');",
        "throw 'plain';",
        'var ruleOptionsEnable = { ;',
      ]) {
        expect(
          await _extractErrorFromRust(script),
          await _extractErrorFromQjs(script),
          reason: script,
        );
      }
    });

    test('公共入口走 Rust 且结果进缓存', () async {
      const script = '''
var ruleOptionsEnable = { cached: true };
function main(c) { return c; }
''';
      expect(JavaScriptRuntimeManager.hasCachedOptions(script), isFalse);
      final result = await JavaScriptRuntimeManager.extractScriptOptions(
        script,
      );
      expect((result['options'] as Map)['cached'], isTrue);
      expect(JavaScriptRuntimeManager.hasCachedOptions(script), isTrue);
      expect(
        JavaScriptRuntimeManager.getCachedOptions(script),
        result,
        reason: '缓存里应是 Rust 路径的同一份结果',
      );
    });
  }, skip: skipReason);
}
