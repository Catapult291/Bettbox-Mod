import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'package:bett_box/rust/generated/bettbox_config_ffi.dart';
import 'package:bett_box/rust/native_library.dart';

/// Rust 侧配置管道（`rust/bettbox-native`）的窄 C ABI 封装。
///
/// ABI 见 `rust/bettbox-native/include/bettbox_config.h`，Dart 绑定由 ffigen 生成
/// （`ffigen.bettbox_config.yaml`）。本文件只负责动态库加载、内存管理与 JSON 解码。
/// 配置管道与脚本引擎已合并进同一个动态库（`bettbox_native`）。
///
/// 这是配置改写的唯一实现：动态库缺失或 ABI 级失败会抛 [StateError]，不再回退到
/// Dart 镜像（失败策略与保留上一份可用运行配置的做法见
/// `.grok/Rust 迁移与 Windows 推进路线.md` §1.5 第 4 步）。
abstract final class BettboxConfig {
  static BettboxConfigFFI? _bindings;
  static Object? _loadError;

  /// 动态库是否可用。不可用时所有入口都会抛错。
  static bool get isAvailable => _tryLoad() != null;

  /// 解析一条 Clash 规则。动态库缺失时抛错；输入非法时返回 null。
  static RustParsedRule? parseRule(String rule) {
    final json = _call(_require().bb_rule_parse, rule);
    if (json == null) return null;
    final map = jsonDecode(json) as Map<String, dynamic>;
    return RustParsedRule(
      action: map['action'] as String,
      content: map['content'] as String?,
      target: map['target'] as String?,
      ruleProvider: map['ruleProvider'] as String?,
      subRule: map['subRule'] as String?,
      noResolve: map['noResolve'] as bool? ?? false,
      src: map['src'] as bool? ?? false,
    );
  }

  /// 解析后再序列化回配置字符串。动态库缺失时抛错；输入非法时返回 null。
  static String? roundTripRule(String rule) {
    return _call(_require().bb_rule_round_trip, rule);
  }

  /// 节点过滤用的正则匹配（QuickJS libregexp 语义）：命中返回 true，未命中返回
  /// false，模式语法错误返回 null（配置管道遇到语法错误时跳过过滤，与 Dart 侧
  /// `try { RegExp(...) } catch (_) {}` 一致）。
  static bool? nodeFilterMatch(String pattern, String text) {
    final bindings = _require();
    final patternPtr = pattern.toNativeUtf8();
    final textPtr = text.toNativeUtf8();
    try {
      final result = bindings.bb_node_filter_match(
        patternPtr.cast<Char>(),
        textPtr.cast<Char>(),
      );
      return switch (result) { 1 => true, 0 => false, _ => null };
    } finally {
      malloc.free(patternPtr);
      malloc.free(textPtr);
    }
  }

  /// 跑完整条配置改写管道，返回改写后的配置 JSON 文本。
  ///
  /// 动态库不可用，或 Rust 侧未产出结果（输入结构非法、内部出错）时抛
  /// [StateError]。该管道是唯一实现，失败必须让调用方看见（会保留上一份可用的
  /// 运行配置，见 `GlobalState.getSetupParams`）。
  static String patchConfig(String inputJson) {
    final output = _call(_require().bb_patch_config, inputJson);
    if (output == null) {
      throw StateError('Rust 配置管道未产出结果（输入结构非法或内部出错）');
    }
    return output;
  }

  /// 合并入口：对 [inputJson] 里的 `rawConfig` 跑覆写脚本，再跑整条配置改写管道，
  /// 整份配置只跨一次 FFI（对应 `patchRawConfig` 原先「handleEvaluate + patch」两步）。
  ///
  /// 动态库不可用或 Rust 侧未产出结果时抛 [StateError]；脚本自身失败不阻断 patch，
  /// 错误放在结果的 `scriptError` 里由调用方提示。
  static RustProcessedProfile processProfile(
    String inputJson,
    String script, {
    String? customOptionsJson,
  }) {
    final bindings = _tryLoad();
    if (bindings == null) {
      throw StateError('bettbox_native 动态库不可用：$_loadError');
    }
    final inputPtr = inputJson.toNativeUtf8();
    final scriptPtr = script.toNativeUtf8();
    final optionsPtr = customOptionsJson?.toNativeUtf8();
    try {
      final outputPtr = bindings.bb_process_profile(
        inputPtr.cast<Char>(),
        scriptPtr.cast<Char>(),
        optionsPtr?.cast<Char>() ?? nullptr,
      );
      if (outputPtr == nullptr) {
        throw StateError('Rust 合并入口未产出结果（输入结构非法或内部出错）');
      }
      try {
        final map = jsonDecode(outputPtr.cast<Utf8>().toDartString())
            as Map<String, dynamic>;
        final config = map['config'];
        if (config is! Map) {
          throw StateError('Rust 合并入口返回的信封里没有 config');
        }
        return RustProcessedProfile(
          config: config.cast<String, dynamic>(),
          scriptError: map['scriptError'] as String?,
        );
      } finally {
        bindings.bb_string_free(outputPtr);
      }
    } finally {
      malloc.free(inputPtr);
      malloc.free(scriptPtr);
      if (optionsPtr != null) malloc.free(optionsPtr);
    }
  }

  /// 解析 provider 列表原文，返回元数据数组 JSON（已剥掉全节点列表）。
  static String? parseProviderMeta(String rawProvidersJson) {
    return _call(_require().bb_parse_provider_meta, rawProvidersJson);
  }

  /// 由内核代理表 + provider 原文构建分组，返回分组数组 JSON。
  ///
  /// [rawProviders] 传 null 或空串表示没有 provider 数据。
  static String? buildProxiesGroups(String proxiesJson, {String? rawProviders}) {
    final bindings = _require();
    final proxiesPtr = proxiesJson.toNativeUtf8();
    final providersPtr = rawProviders?.toNativeUtf8();
    try {
      final outputPtr = bindings.bb_build_proxies_groups(
        proxiesPtr.cast<Char>(),
        providersPtr?.cast<Char>() ?? nullptr,
      );
      if (outputPtr == nullptr) return null;
      try {
        return outputPtr.cast<Utf8>().toDartString();
      } finally {
        bindings.bb_string_free(outputPtr);
      }
    } finally {
      malloc.free(proxiesPtr);
      if (providersPtr != null) malloc.free(providersPtr);
    }
  }

  /// 应用分组开关，返回 `{"proxy-groups": [...], "rules": [...]}` JSON 文本。
  ///
  /// [groupSwitchesJson] 是 `{分组名: 是否启用}`；[scriptActive] 为真时不处理
  /// （与配置管道内部的调用口径一致）。
  static String? applyGroupSwitches(
    String proxyGroupsJson,
    String rulesJson,
    String groupSwitchesJson, {
    required bool scriptActive,
  }) {
    final bindings = _require();
    final groupsPtr = proxyGroupsJson.toNativeUtf8();
    final rulesPtr = rulesJson.toNativeUtf8();
    final switchesPtr = groupSwitchesJson.toNativeUtf8();
    try {
      final outputPtr = bindings.bb_apply_group_switches(
        groupsPtr.cast<Char>(),
        rulesPtr.cast<Char>(),
        switchesPtr.cast<Char>(),
        scriptActive,
      );
      if (outputPtr == nullptr) return null;
      try {
        return outputPtr.cast<Utf8>().toDartString();
      } finally {
        bindings.bb_string_free(outputPtr);
      }
    } finally {
      malloc.free(groupsPtr);
      malloc.free(rulesPtr);
      malloc.free(switchesPtr);
    }
  }

  /// 就地应用 DNS 节点覆写，返回改写后的配置 JSON 文本。
  ///
  /// [originalDnsJson] / [originalHostsJson] 传 null 表示没有对应数据。
  static String? applyDnsNodeOverride(
    String rawConfigJson, {
    String? originalDnsJson,
    String? originalHostsJson,
  }) {
    final bindings = _require();
    final rawPtr = rawConfigJson.toNativeUtf8();
    final dnsPtr = originalDnsJson?.toNativeUtf8();
    final hostsPtr = originalHostsJson?.toNativeUtf8();
    try {
      final outputPtr = bindings.bb_apply_dns_node_override(
        rawPtr.cast<Char>(),
        dnsPtr?.cast<Char>() ?? nullptr,
        hostsPtr?.cast<Char>() ?? nullptr,
      );
      if (outputPtr == nullptr) return null;
      try {
        return outputPtr.cast<Utf8>().toDartString();
      } finally {
        bindings.bb_string_free(outputPtr);
      }
    } finally {
      malloc.free(rawPtr);
      if (dnsPtr != null) malloc.free(dnsPtr);
      if (hostsPtr != null) malloc.free(hostsPtr);
    }
  }

  static String? _call(
    Pointer<Char> Function(Pointer<Char>) function,
    String input,
  ) {
    final bindings = _require();
    final inputPtr = input.toNativeUtf8();
    try {
      final outputPtr = function(inputPtr.cast<Char>());
      if (outputPtr == nullptr) return null;
      try {
        return outputPtr.cast<Utf8>().toDartString();
      } finally {
        bindings.bb_string_free(outputPtr);
      }
    } finally {
      malloc.free(inputPtr);
    }
  }

  static BettboxConfigFFI? _tryLoad() {
    final cached = _bindings;
    if (cached != null) return cached;
    if (_loadError != null) return null;
    try {
      return _bindings = BettboxConfigFFI(openBettboxNativeLibrary());
    } catch (error) {
      _loadError = error;
      return null;
    }
  }

  static BettboxConfigFFI _require() {
    final bindings = _tryLoad();
    if (bindings == null) {
      throw StateError('bettbox_config 动态库不可用：$_loadError');
    }
    return bindings;
  }

}

/// [BettboxConfig.processProfile] 的结果。
class RustProcessedProfile {
  const RustProcessedProfile({required this.config, this.scriptError});

  /// 已跑完脚本与配置改写的配置。
  final Map<String, dynamic> config;

  /// 脚本自身失败时的错误串（`JS Script Error: …`）；成功时为 null。
  /// 脚本失败不阻断 patch，[config] 仍然可用。
  final String? scriptError;
}

/// [BettboxConfig.parseRule] 的返回结构，字段与 Dart 侧 `ParsedRule` 一一对应。
class RustParsedRule {
  const RustParsedRule({
    required this.action,
    this.content,
    this.target,
    this.ruleProvider,
    this.subRule,
    this.noResolve = false,
    this.src = false,
  });

  /// 规则关键字，如 `DOMAIN`；对应 Dart 侧 `RuleAction.value`。
  final String action;
  final String? content;
  final String? target;
  final String? ruleProvider;
  final String? subRule;
  final bool noResolve;
  final bool src;
}
