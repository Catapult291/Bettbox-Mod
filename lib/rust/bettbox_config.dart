import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'package:bett_box/rust/generated/bettbox_config_ffi.dart';

/// 是否让 Rust 侧接管配置改写管道（`GlobalState.patchRawConfig`）。
///
/// 默认开启，用 `--dart-define=USE_RUST_CONFIG_PIPELINE=false` 关闭回 Dart 路径。
/// Rust 动态库缺失（如 Android）或调用失败时自动回退 Dart，不回退才是不正常。
/// 差分验证见 `test/rust/patch_config_diff_test.dart`。
const bool useRustConfigPipeline = bool.fromEnvironment(
  'USE_RUST_CONFIG_PIPELINE',
  defaultValue: true,
);

/// Rust 侧配置管道（`rust/bettbox-config`）的窄 C ABI 封装。
///
/// ABI 见 `rust/bettbox-config/include/bettbox_config.h`，Dart 绑定由 ffigen 生成
/// （`ffigen.bettbox_config.yaml`）。本文件只负责动态库加载、内存管理与 JSON 解码。
abstract final class BettboxConfig {
  static BettboxConfigFFI? _bindings;
  static Object? _loadError;

  /// 动态库是否可用。不可用时 [parseRule] / [roundTripRule] 会抛错，
  /// 调用方可以先探测再决定走 Dart 兜底路径。
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

  /// 节点过滤用的最小正则匹配：命中返回 true，未命中返回 false，
  /// 模式用了 Rust 子集之外的写法返回 null（此时配置管道会整条回退 Dart）。
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
  /// 输入结构见 `lib/common/config_patch.dart` 的 `applyConfigPatch`。
  ///
  /// 动态库不可用时返回 null 交给调用方回退 Dart，而不是抛错——该管道是可选
  /// 加速路径，缺失不算错误。
  static String? patchConfig(String inputJson) {
    final bindings = _tryLoad();
    if (bindings == null) return null;
    return _call(bindings.bb_patch_config, inputJson);
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
  /// （与 Dart 侧 `applyGroupSwitches` 一致）。
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
      return _bindings = BettboxConfigFFI(_openLibrary());
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
        p.join(Directory.current.path, 'rust', 'target', profile, _libraryFileName),
    ];
  }

  static String get _libraryFileName {
    if (Platform.isWindows) return 'bettbox_config.dll';
    if (Platform.isMacOS) return 'libbettbox_config.dylib';
    return 'libbettbox_config.so';
  }
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
