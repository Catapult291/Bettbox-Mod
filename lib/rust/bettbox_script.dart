import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'package:bett_box/rust/generated/bettbox_script_ffi.dart';

/// 是否让 Rust 侧接管覆写脚本求值（`GlobalState.handleEvaluate`）。
///
/// 默认开启，用 `--dart-define=USE_RUST_SCRIPT_ENGINE=false` 关闭回 qjs 路径。
/// Rust 动态库缺失（如 Android）或 ABI 级失败时自动回退 qjs，不回退才是不正常。
const bool useRustScriptEngine = bool.fromEnvironment(
  'USE_RUST_SCRIPT_ENGINE',
  defaultValue: true,
);

/// Rust 侧覆写脚本引擎（`rust/bettbox-script`）的窄 C ABI 封装。
///
/// ABI 见 `rust/bettbox-script/include/bettbox_script.h`，Dart 绑定由 ffigen 生成
/// （`ffigen.bettbox_script.yaml`）。契约与 `JavaScriptRuntimeManager.evaluateScript`
/// 逐项对齐，详见该文件与 `rust/bettbox-script/src/eval.rs`。
abstract final class BettboxScript {
  static BettboxScriptFFI? _bindings;
  static Object? _loadError;

  /// 动态库是否可用。不可用时 [evaluateScript] 返回 null，调用方走 qjs 兜底。
  static bool get isAvailable => _tryLoad() != null;

  /// 用 Rust 引擎执行覆写脚本，返回脚本产出的配置。
  ///
  /// 返回 null 表示 Rust 引擎**不接管**（开关关闭、动态库缺失、或 ABI 级失败），
  /// 调用方应回退 `JavaScriptRuntimeManager.evaluateScript`。
  /// 脚本自身的错误抛出 `JS Script Error: …` 字符串，与 qjs 路径的错误形状一致。
  ///
  /// `bb_eval_script` 是同步 FFI（最坏 30 s），因此实际求值放在后台 isolate，
  /// 只在边界上传字符串。
  static Future<Map<String, dynamic>?> evaluateScript(
    String scriptContent,
    Map<String, dynamic> config, {
    Map<String, bool>? customOptions,
  }) async {
    if (!useRustScriptEngine) return null;
    if (!isAvailable) return null;
    final configJson = jsonEncode(config);
    final optionsJson = customOptions != null && customOptions.isNotEmpty
        ? jsonEncode(customOptions)
        : null;

    final String? envelopeJson;
    try {
      envelopeJson = await Isolate.run(
        () => _evalEnvelope(scriptContent, configJson, optionsJson),
      );
    } catch (_) {
      // 只在 isolate 启动/加载失败时走到这里；脚本错误走信封，不抛异常。
      return null;
    }
    if (envelopeJson == null) return null;

    final envelope = jsonDecode(envelopeJson) as Map<String, dynamic>;
    if (envelope['ok'] != true) {
      throw envelope['error'];
    }
    final result = envelope['config'];
    if (result is! Map) return null;
    return result.cast<String, dynamic>();
  }

  /// 抽取脚本声明的选项与图标（脚本页的 options/icons）。
  ///
  /// 返回 null 表示 Rust 引擎**不接管**（开关关闭、动态库缺失、或 ABI 级失败），
  /// 调用方回退 `JavaScriptRuntimeManager.extractOptionsViaQjs`。
  /// 脚本抛错时抛出原始错误串（**不带** `JS Script Error: ` 前缀），
  /// 与 qjs 路径一致——那条路径只记 `extractScriptOptions error: …` 并返回空表。
  static Future<Map<String, dynamic>?> extractScriptOptions(
    String scriptContent,
  ) async {
    if (!useRustScriptEngine) return null;
    if (!isAvailable) return null;

    final String? envelopeJson;
    try {
      envelopeJson = await Isolate.run(() => _extractEnvelope(scriptContent));
    } catch (_) {
      // 只在 isolate 启动/加载失败时走到这里；脚本错误走信封，不抛异常。
      return null;
    }
    if (envelopeJson == null) return null;

    final envelope = jsonDecode(envelopeJson) as Map<String, dynamic>;
    if (envelope['ok'] != true) {
      throw envelope['error'];
    }
    final result = envelope['result'];
    if (result is! Map) return null;
    return result.cast<String, dynamic>();
  }

  /// 在后台 isolate 内执行的同步 FFI 调用，返回信封 JSON；null 表示 ABI 级失败。
  static String? _evalEnvelope(
    String script,
    String configJson,
    String? optionsJson,
  ) {
    final bindings = _require();
    final scriptPtr = script.toNativeUtf8();
    final configPtr = configJson.toNativeUtf8();
    final optionsPtr = optionsJson?.toNativeUtf8();
    try {
      final outputPtr = bindings.bb_eval_script(
        scriptPtr.cast<Char>(),
        configPtr.cast<Char>(),
        optionsPtr?.cast<Char>() ?? nullptr,
      );
      if (outputPtr == nullptr) return null;
      try {
        return outputPtr.cast<Utf8>().toDartString();
      } finally {
        bindings.bb_string_free(outputPtr);
      }
    } finally {
      malloc.free(scriptPtr);
      malloc.free(configPtr);
      if (optionsPtr != null) malloc.free(optionsPtr);
    }
  }

  /// [`extractScriptOptions`] 在后台 isolate 内执行的那一半。
  static String? _extractEnvelope(String script) {
    final bindings = _require();
    final scriptPtr = script.toNativeUtf8();
    try {
      final outputPtr = bindings.bb_extract_script_options(
        scriptPtr.cast<Char>(),
      );
      if (outputPtr == nullptr) return null;
      try {
        return outputPtr.cast<Utf8>().toDartString();
      } finally {
        bindings.bb_string_free(outputPtr);
      }
    } finally {
      malloc.free(scriptPtr);
    }
  }

  static BettboxScriptFFI? _tryLoad() {
    final cached = _bindings;
    if (cached != null) return cached;
    if (_loadError != null) return null;
    try {
      return _bindings = BettboxScriptFFI(_openLibrary());
    } catch (error) {
      _loadError = error;
      return null;
    }
  }

  static BettboxScriptFFI _require() {
    final bindings = _tryLoad();
    if (bindings == null) {
      throw StateError('bettbox_script 动态库不可用：$_loadError');
    }
    return bindings;
  }

  static DynamicLibrary _openLibrary() {
    final tried = <String>[];
    for (final path in _candidatePaths()) {
      if (!File(path).existsSync()) {
        tried.add('$path（不存在）');
        continue;
      }
      try {
        return DynamicLibrary.open(path);
      } catch (error) {
        tried.add('$path（$error）');
      }
    }
    throw StateError('未找到 $_libraryFileName，已尝试：\n${tried.join('\n')}');
  }

  static List<String> _candidatePaths() {
    return [
      // 打包后：与 Bettbox.exe 同目录（CMake install 的结果）。
      p.join(p.dirname(Platform.resolvedExecutable), _libraryFileName),
      // 开发/测试时：仓库根的 cargo 产物（flutter test 与 flutter run 的 cwd 都是仓库根）。
      // debug 在前：开发迭代跑 `cargo build`，若 release 产物更旧会被它挡住。
      for (final profile in ['debug', 'release'])
        p.join(
          Directory.current.path,
          'rust',
          'target',
          profile,
          _libraryFileName,
        ),
    ];
  }

  static String get _libraryFileName {
    if (Platform.isWindows) return 'bettbox_script.dll';
    if (Platform.isMacOS) return 'libbettbox_script.dylib';
    return 'libbettbox_script.so';
  }
}
