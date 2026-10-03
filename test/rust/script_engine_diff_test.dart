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
}
