import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/config_patch.dart';
import 'package:bett_box/common/js_runtime_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pipeline_cases.dart';

/// golden 生成器：用当前 Dart 镜像（`applyConfigPatch` + qjs）算出期望输出，写进
/// `fixtures/golden/`。这些期望输出就是 Rust 侧 `tests/golden.rs` 的唯一参照，
/// 目的是「删掉 Dart 镜像后，回归保护不跟着一起丢」（路线稿 §1.5 第 1 步）。
///
/// 只有显式打开时才生成，正常 `flutter test` 不会覆写期望输出：
///
///     flutter test test/rust/golden_generate_test.dart --dart-define=GOLDEN_GENERATE=true
///
/// 前提与差分测试相同：`test/build/Debug/ffiquickjs.dll` 存在（见 CI 里拷 dll 的步骤）。
/// 生成后必须复查 diff：golden 变了就等于管道行为变了，要和 Rust 侧改动一起评审。
const _generate = bool.fromEnvironment('GOLDEN_GENERATE');

const _entries = ['patch_config', 'process_profile'];

void main() {
  test('用 Dart 镜像生成 fixtures/golden', () async {
    final cases = pipelineCases();
    expect(cases, isNotEmpty);

    // 用例改名/删除时清掉旧文件，避免目录里留下没人引用的期望输出。
    for (final entry in _entries) {
      final dir = Directory('fixtures/golden/$entry');
      if (!dir.existsSync()) continue;
      for (final file in dir.listSync().whereType<File>()) {
        if (file.path.endsWith('.json')) file.deleteSync();
      }
    }

    final written = <String>[];
    for (final pipelineCase in cases) {
      final entry = pipelineCase.entry;
      final input = copyJson(pipelineCase.input) as Map<String, dynamic>;
      String? scriptError;
      Map<String, dynamic> output;

      if (entry == 'patch_config') {
        output = applyConfigPatch(copyJson(input) as Map<String, dynamic>);
      } else if (entry == 'process_profile') {
        // 与 `patchRawConfig` 的合并路径一致：跑脚本前补齐 `proxy-providers`，
        // 且这份补齐后的输入就是生产里交给 `bb_process_profile` 的那一份。
        final prepared = copyJson(input['rawConfig']) as Map<String, dynamic>;
        prepared['proxy-providers'] ??= {};
        input['rawConfig'] = prepared;

        var evaluated = prepared;
        try {
          evaluated = await JavaScriptRuntimeManager.evaluateScript(
            pipelineCase.script!,
            copyJson(prepared) as Map<String, dynamic>,
            customOptions: pipelineCase.customOptions,
          );
        } catch (error) {
          // `handleEvaluate` 的语义：脚本出错就保留原配置，错误串由调用方提示。
          scriptError = error.toString();
        }
        final patched = copyJson(input) as Map<String, dynamic>;
        patched['rawConfig'] = evaluated;
        output = applyConfigPatch(patched);
      } else {
        fail('未知的 entry：$entry');
      }

      // 防「一起空转」：管道必须真的改写过这份配置。
      expect(output['external-ui'], input['env']['uiPath'], reason: entry);
      expect(output['rules'], isNotEmpty, reason: entry);

      final document = <String, dynamic>{
        'name': pipelineCase.name,
        'entry': entry,
        'input': input,
        if (pipelineCase.script != null) 'script': pipelineCase.script,
        if (pipelineCase.customOptions != null)
          'customOptions': pipelineCase.customOptions,
        'scriptError': scriptError,
        'output': output,
      };
      final file = File('fixtures/golden/$entry/${pipelineCase.name}.json');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(document)}\n',
      );
      written.add(file.path);
    }

    expect(written.length, cases.length);
  }, skip: _generate ? null : '需要 --dart-define=GOLDEN_GENERATE=true');
}
