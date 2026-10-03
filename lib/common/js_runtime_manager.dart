import 'dart:async';
import 'dart:convert';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/rust/bettbox_script.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
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

class JavaScriptRuntimeManager {
  /// 脚本执行的上界。正常配置脚本远达不到这两个值，它们只用来挡住
  /// 失控脚本（死循环 / 无限增长）把整个进程的内存和 CPU 拖爆。
  static const int scriptTimeoutMs = 30000;
  static const int scriptMemoryLimitBytes = 256 * 1024 * 1024;

  static Future<Map<String, dynamic>> evaluateScript(
    String scriptContent,
    Map<String, dynamic> config, {
    Map<String, bool>? customOptions,
  }) async {
    final result = await _evaluateWithRetry(
      scriptContent,
      config,
      customOptions: customOptions,
    );
    if (result is Map) {
      return _deepCastMap(result);
    }
    return config;
  }

  /// 与 [evaluateScript] 同契约、同语义，但**优先走 Rust 引擎**：开关关闭、动态库
  /// 缺失或 ABI 级失败时回退 qjs。脚本自身的错误照旧抛出（两条路径的错误串同形）。
  ///
  /// [evaluateScript] 保持为纯 qjs 实现，供回退与差分测试当参照；要跑真实脚本的
  /// 调用方（配置改写、加规则取分组等）用这个入口。
  static Future<Map<String, dynamic>> evaluateScriptPreferRust(
    String scriptContent,
    Map<String, dynamic> config, {
    Map<String, bool>? customOptions,
  }) async {
    if (useRustScriptEngine && BettboxScript.isAvailable) {
      final rustResult = await BettboxScript.evaluateScript(
        scriptContent,
        config,
        customOptions: customOptions,
      );
      if (rustResult != null) return rustResult;
      commonPrint.log('Rust 脚本引擎未接管（ABI 级失败），回退 qjs 路径');
    }
    return evaluateScript(
      scriptContent,
      config,
      customOptions: customOptions,
    );
  }

  static final Lock _engineLock = Lock();

  /// 抽取脚本声明的选项与图标（脚本页的 options/icons）。
  ///
  /// 默认走 Rust 引擎（[BettboxScript.extractScriptOptions]），开关关闭 / 动态库缺失 /
  /// ABI 级失败时回退 [extractOptionsViaQjs]。两条路径的对外语义一致：脚本自身的错误
  /// 只记日志并返回空表，且**不缓存**这个空表（下次调用会重跑）。
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
        if (useRustScriptEngine && BettboxScript.isAvailable) {
          final rustResult = await BettboxScript.extractScriptOptions(
            scriptContent,
          );
          if (rustResult != null) {
            _ScriptOptionsCache.put(scriptContent, rustResult);
            return rustResult;
          }
          commonPrint.log('Rust 脚本引擎未接管 extractScriptOptions（ABI 级失败），回退 qjs');
        }
        final result = await extractOptionsViaQjs(scriptContent);
        _ScriptOptionsCache.put(scriptContent, result);
        return result;
      } catch (e) {
        commonPrint.log('extractScriptOptions error: $e');
        return {};
      }
    });
  }

  /// [extractScriptOptions] 的 qjs 参考实现：跑脚本正文，再读全局
  /// `ruleOptionsEnable` 与 `serviceConfigs`。
  ///
  /// 独立成公开入口有两个用途：Rust 库不可用时的回退路径，以及
  /// `test/rust/script_engine_diff_test.dart` 里与 Rust 输出逐字段对拍的参照。
  /// 改这里的模板必须同步改 `rust/bettbox-script/src/eval.rs` 的 `build_extract_program`
  /// （行结构也要对齐，错误串里的 `<eval>:<行号>` 才会一致）。
  static Future<Map<String, dynamic>> extractOptionsViaQjs(
    String scriptContent,
  ) async {
    final engine = IsolateQjs(
      timeout: scriptTimeoutMs,
      memoryLimit: scriptMemoryLimitBytes,
    );
    try {
      final res = await engine.evaluate('''
          var console = {
            log: function() {},
            warn: function() {},
            error: function() {},
            info: function() {},
            debug: function() {}
          };
          (function() {
            $scriptContent
            var options = typeof ruleOptionsEnable !== 'undefined' && ruleOptionsEnable && typeof ruleOptionsEnable === 'object' ? ruleOptionsEnable : {};
            var icons = {};
            if (typeof serviceConfigs !== 'undefined' && Array.isArray(serviceConfigs)) {
              for (var i = 0; i < serviceConfigs.length; i++) {
                var svc = serviceConfigs[i];
                if (svc && svc.name && typeof svc.icon === 'string') {
                  icons[svc.name] = svc.icon;
                }
              }
            }
            return JSON.stringify({ options: options, icons: icons });
          })();
        ''');

      final result = <String, dynamic>{};
      if (res is String) {
        final decoded = json.decode(res);
        if (decoded is Map) {
          result.addAll(_deepCastMap(decoded));
        }
      }
      return result;
    } finally {
      try {
        await engine.close();
      } catch (e) {
        commonPrint.log('engine.close error: $e');
      }
    }
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

  static Future<dynamic> _evaluateWithRetry(
    String scriptContent,
    Map<String, dynamic> config, {
    Map<String, bool>? customOptions,
    int maxRetries = 1,
  }) async {
    var attempt = 0;
    while (true) {
      final engine = IsolateQjs(
        timeout: scriptTimeoutMs,
        memoryLimit: scriptMemoryLimitBytes,
      );
      try {
        final configJs = json.encode(config);
        final customJs = customOptions != null && customOptions.isNotEmpty
            ? json.encode(customOptions)
            : null;
        final overrideSnippet = customJs != null
            ? 'if (typeof ruleOptionsEnable !== "undefined") { Object.assign(ruleOptionsEnable, $customJs); }'
            : '';

        return await engine.evaluate('''
          var console = {
            log: function(...args) { if (typeof print !== 'undefined') print(...args); },
            warn: function(...args) { if (typeof print !== 'undefined') print('WARN:', ...args); },
            error: function(...args) { if (typeof print !== 'undefined') print('ERROR:', ...args); },
            info: function(...args) { if (typeof print !== 'undefined') print('INFO:', ...args); },
            debug: function(...args) { if (typeof print !== 'undefined') print('DEBUG:', ...args); }
          };
          (function() {
            $scriptContent
            $overrideSnippet
            return main($configJs);
          })();
        ''');
      } catch (e) {
        if (attempt >= maxRetries) {
          throw 'JS Script Error: $e';
        }
        attempt++;
      } finally {
        try {
          await engine.close();
        } catch (e) {
          commonPrint.log('engine.close error: $e');
        }
      }
    }
  }

  static Map<String, dynamic> _deepCastMap(Map dynamicMap) {
    return dynamicMap.map<String, dynamic>((key, value) {
      return MapEntry(key.toString(), _deepCastValue(value));
    });
  }

  static dynamic _deepCastValue(dynamic value) {
    if (value is Map) {
      return _deepCastMap(value);
    } else if (value is List) {
      return value.map((e) => _deepCastValue(e)).toList();
    }
    return value;
  }
}
