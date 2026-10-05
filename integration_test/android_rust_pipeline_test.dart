import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/config_patch.dart';
import 'package:bett_box/common/js_runtime_manager.dart';
import 'package:bett_box/rust/bettbox_config.dart';
import 'package:bett_box/rust/bettbox_script.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/common/json_diff.dart';
import '../test/rust/pipeline_cases.dart';

/// 在 Android 设备/模拟器上验证「Android 已切到 Rust」这条结论本身。
///
/// 与 `test/rust/*` 的差分套件不同，这里跑在设备上：`libbettbox_native.so` 必须由
/// Android 的动态加载器按名字解析到（`lib/rust/native_library.dart`），因此
/// `isAvailable` 为真就是「Rust 库真的随包到位并加载成功」的证据；
/// 再用 Dart 镜像与 qjs 在同一份输入上对拍，确认设备上的输出与参照实现一致。
///
/// 运行方式（需要设备/模拟器）：
/// `flutter test integration_test/android_rust_pipeline_test.dart -d <device-id>`
///
/// 默认的 `flutter test` 只扫 `test/`，不会带上这个文件。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// 设备端对拍用的输入：复用 Rust 侧 `process_profile` 测试用的最小输入
  /// （`minimalProcessInput()`，无 fixture 文件依赖），补上 `patch_config`
  /// 需要的 env 开关，并把 `isAndroid` 置真——这既是 Android 的真实分支，
  /// 也让上游脚本/patch 两侧都走 `isAndroid` 的路径。
  Map<String, dynamic> androidSmokeInput() {
    final data = copyJson(minimalProcessInput()) as Map<String, dynamic>;
    final env = (data['env'] as Map).cast<String, dynamic>();
    env['isAndroid'] = true;
    env['overrideDns'] = false;
    env['overrideNtp'] = false;
    env['overrideSniffer'] = false;
    env['overrideExperimental'] = false;
    env['locale'] = null;
    return data;
  }

  test('设备上 Rust 动态库可加载（libbettbox_native.so）', () {
    expect(Platform.isAndroid, isTrue, reason: '本用例只能在 Android 设备上跑');
    expect(
      BettboxConfig.isAvailable,
      isTrue,
      reason: 'libbettbox_native.so 未加载：配置管道与脚本引擎都会静默回退 Dart',
    );
    expect(BettboxScript.isAvailable, isTrue);
  });

  test('配置管道：Rust 与 Dart 镜像在设备上逐字段一致', () {
    final data = androidSmokeInput();
    // 先编码给 Rust：applyConfigPatch 会原地改写入参。
    final rustJson = BettboxConfig.patchConfig(jsonEncode(data));
    expect(rustJson, isNotNull, reason: 'Rust 配置管道未接管');
    final reference = applyConfigPatch(copyJson(data) as Map<String, dynamic>);

    // 防「两边一起空转」。
    expect(reference['external-ui'], data['env']['uiPath']);
    expect(jsonDecode(rustJson!)['external-ui'], data['env']['uiPath']);

    final difference = firstJsonDifference(
      reference,
      jsonDecode(rustJson),
      '',
    );
    expect(difference, isNull, reason: '$difference');
  });

  test('脚本引擎：Rust 与 qjs 在设备上结果一致', () async {
    const script =
        "var ruleOptionsEnable = {base: true};\n"
        "function main(c){ c['marker'] = 'android'; return c; }";
    final config = (copyJson(androidSmokeInput()['rawConfig']) as Map)
        .cast<String, dynamic>();
    const customOptions = {'base': false};

    final rust = await BettboxScript.evaluateScript(
      script,
      config,
      customOptions: customOptions,
    );
    expect(rust, isNotNull, reason: 'Rust 脚本引擎未接管');
    expect(rust!['marker'], 'android', reason: '脚本正文没有被执行');

    final qjs = await JavaScriptRuntimeManager.evaluateScript(
      script,
      copyJson(config) as Map<String, dynamic>,
      customOptions: customOptions,
    );
    final difference = firstJsonDifference(qjs, rust, '');
    expect(difference, isNull, reason: '$difference');
  });

  test('合并入口 process_profile：恒等脚本与 patchConfig 一致', () {
    final data = androidSmokeInput();
    final referenceJson = BettboxConfig.patchConfig(jsonEncode(data));
    expect(referenceJson, isNotNull);

    final processed = BettboxConfig.processProfile(
      jsonEncode(data),
      'function main(c){ return c; }',
    );
    expect(processed, isNotNull, reason: '合并入口未接管');
    expect(processed!.scriptError, isNull);

    final difference = firstJsonDifference(
      jsonDecode(referenceJson!),
      processed.config,
      '',
    );
    expect(difference, isNull, reason: '$difference');
  });
}
