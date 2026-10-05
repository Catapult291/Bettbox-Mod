import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'package:bett_box/rust/generated/bettbox_script_ffi.dart';
import 'package:bett_box/rust/native_library.dart';

/// Rust 侧覆写脚本引擎（`rust/bettbox-native`）的窄 C ABI 封装。
///
/// ABI 见 `rust/bettbox-native/include/bettbox_script.h`，Dart 绑定由 ffigen 生成
/// （`ffigen.bettbox_script.yaml`）。这是脚本求值的唯一实现：动态库缺失或 ABI 级失败
/// 抛 [StateError]，不再回退到别的引擎（失败策略见
/// `.grok/Rust 迁移与 Windows 推进路线.md` §1.5 第 4 步）。
/// 脚本引擎与配置管道同在一个动态库（`bettbox_native`）。
abstract final class BettboxScript {
  static BettboxScriptFFI? _bindings;
  static Object? _loadError;

  /// 动态库是否可用。不可用时脚本求值会抛错。
  static bool get isAvailable => _tryLoad() != null;

  /// 用 Rust 引擎执行覆写脚本，返回脚本产出的配置。
  ///
  /// 动态库缺失、ABI 级失败或后台 isolate 起不来时抛 [StateError]；
  /// 脚本自身的错误抛出 `JS Script Error: …` 字符串（与原先 qjs 路径同形）。
  /// 脚本返回非对象时返回入参 [config]（同样与 qjs 路径的语义一致）。
  ///
  /// `bb_eval_script` 是同步 FFI（最坏 30 s），因此实际求值放在后台 isolate，
  /// 只在边界上传字符串。
  static Future<Map<String, dynamic>> evaluateScript(
    String scriptContent,
    Map<String, dynamic> config, {
    Map<String, bool>? customOptions,
  }) async {
    _require();
    final configJson = jsonEncode(config);
    final optionsJson = customOptions != null && customOptions.isNotEmpty
        ? jsonEncode(customOptions)
        : null;

    final String? envelopeJson;
    try {
      envelopeJson = await Isolate.run(
        () => _evalEnvelope(scriptContent, configJson, optionsJson),
      );
    } on Object catch (error) {
      throw StateError('bettbox_script 求值失败（后台 isolate 未能完成）：$error');
    }
    if (envelopeJson == null) {
      throw StateError('bettbox_script 求值失败（ABI 级失败）：$_loadError');
    }

    final envelope = jsonDecode(envelopeJson) as Map<String, dynamic>;
    if (envelope['ok'] != true) {
      throw envelope['error'];
    }
    final result = envelope['config'];
    if (result is! Map) return config;
    return result.cast<String, dynamic>();
  }

  /// 抽取脚本声明的选项与图标（脚本页的 options/icons）。
  ///
  /// 动态库缺失、ABI 级失败或后台 isolate 起不来时抛 [StateError]；
  /// 脚本抛错时抛出原始错误串（**不带** `JS Script Error: ` 前缀），
  /// 与原先 qjs 路径相同——调用方只记 `extractScriptOptions error: …` 并返回空表。
  static Future<Map<String, dynamic>> extractScriptOptions(
    String scriptContent,
  ) async {
    _require();

    final String? envelopeJson;
    try {
      envelopeJson = await Isolate.run(() => _extractEnvelope(scriptContent));
    } on Object catch (error) {
      throw StateError('bettbox_script extractScriptOptions 失败（后台 isolate 未能完成）：$error');
    }
    if (envelopeJson == null) {
      throw StateError('bettbox_script extractScriptOptions 失败（ABI 级失败）：$_loadError');
    }

    final envelope = jsonDecode(envelopeJson) as Map<String, dynamic>;
    if (envelope['ok'] != true) {
      throw envelope['error'];
    }
    final result = envelope['result'];
    if (result is! Map) return const {};
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
      return _bindings = BettboxScriptFFI(openBettboxNativeLibrary());
    } catch (error) {
      _loadError = error;
      return null;
    }
  }

  static BettboxScriptFFI _require() {
    final bindings = _tryLoad();
    if (bindings == null) {
      throw StateError('bettbox_native 动态库不可用：$_loadError');
    }
    return bindings;
  }
}
