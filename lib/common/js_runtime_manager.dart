import 'dart:convert';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/rust/bettbox_script.dart';
import 'package:synchronized/synchronized.dart';

class _ScriptOptionsCache {
  static final _entries = <String, Map<String, dynamic>>{};
  static const _maxEntries = 16;

  static Map<String, dynamic>? get(String content) {
    final key = _key(content);
    final v = _entries[key];
    if (v != null) {
      // Move to end (most recently used)
      _entries.remove(key);
      _entries[key] = v;
    }
    return v;
  }

  static void put(String content, Map<String, dynamic> value) {
    final key = _key(content);
    _entries[key] = value;
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  static void remove(String content) {
    _entries.remove(_key(content));
  }

  static String _key(String content) {
    final bytes = utf8.encode(content);
    return '${bytes.length}_${bytes.fold<int>(0, (p, b) => (p * 31 + b) & 0x7fffffff)}';
  }
}

/// 覆写脚本求值的唯一入口（转发到 Rust 引擎 `rust/bettbox-native`）。
///
/// 原先这里有第二条 qjs 实现（`IsolateQjs` 模板拼接）作为回退，阶段 5 第 3 步
/// 已删除：动态库缺失或 ABI 级失败现在抛错，不再静默换一套实现
/// （失败策略见 `.grok/Rust 迁移与 Windows 推进路线.md` §1.5 第 4 步）。
class JavaScriptRuntimeManager {
  /// 执行覆写脚本，返回脚本产出的配置。
  ///
  /// 脚本自身错误抛 `JS Script Error: …`；动态库/ABI 级失败抛 [StateError]。
  static Future<Map<String, dynamic>> evaluateScript(
    String scriptContent,
    Map<String, dynamic> config, {
    Map<String, bool>? customOptions,
  }) {
    return BettboxScript.evaluateScript(
      scriptContent,
      config,
      customOptions: customOptions,
    );
  }

  static final Lock _engineLock = Lock();

  /// 抽取脚本声明的选项与图标（脚本页的 options/icons）。
  ///
  /// 脚本自身的错误只记日志并返回空表（且**不缓存**这个空表）；动态库/ABI 级失败
  /// 直接抛错——那是必须让用户看见的基础设施故障，不再静默返回空表。
  static Future<Map<String, dynamic>> extractScriptOptions(
    String scriptContent,
  ) async {
    final cached = _ScriptOptionsCache.get(scriptContent);
    if (cached != null) return cached;

    return _engineLock.synchronized(() async {
      // Double-check after acquiring lock
      final recached = _ScriptOptionsCache.get(scriptContent);
      if (recached != null) return recached;

      try {
        final result = await BettboxScript.extractScriptOptions(scriptContent);
        _ScriptOptionsCache.put(scriptContent, result);
        return result;
      } on StateError {
        rethrow;
      } catch (e) {
        commonPrint.log('extractScriptOptions error: $e');
        return {};
      }
    });
  }

  static void invalidateCachedOptions(String scriptContent) {
    _ScriptOptionsCache.remove(scriptContent);
  }

  static bool hasCachedOptions(String scriptContent) {
    return _ScriptOptionsCache.get(scriptContent) != null;
  }

  static Map<String, dynamic>? getCachedOptions(String scriptContent) {
    return _ScriptOptionsCache.get(scriptContent);
  }
}
