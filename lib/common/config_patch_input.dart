import 'package:bett_box/models/clash_config.dart';
import 'package:bett_box/models/profile.dart';

/// 递归把模型对象展开成纯 JSON 结构：Map/List 逐层下钻，其余对象走 `toJson()`，
/// 枚举取 `.name`。
///
/// 必需的原因：`Dns.toJson()` 里 `fallback-filter`（以及 `Sniffer.toJson()` 里
/// `sniff` 的各段）是**模型对象**而不是 Map，生产链路靠 YAML 编码器
/// （`lib/common/task.dart` 的 `_resolveValue`）逐层展开才落盘。进 Rust 之前必须
/// 先展开，否则 `jsonEncode` 会直接抛错。
dynamic resolveJsonValue(Object? value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString(): resolveJsonValue(entry.value),
    };
  }
  if (value is List) {
    return value.map(resolveJsonValue).toList();
  }
  if (value is Iterable) {
    return value.map(resolveJsonValue).toList();
  }
  if (value == null || value is num || value is bool || value is String) {
    return value;
  }
  try {
    return resolveJsonValue((value as dynamic).toJson());
  } catch (_) {
    if (value is Enum) {
      return value.name;
    }
    return value;
  }
}

/// 把宿主侧已经解析好的模型/环境，摊成 [applyConfigPatch] 与 Rust 入口
/// （`rust/bettbox-config/src/patch_config.rs`）共用的输入 JSON。
///
/// 这里是两条路径唯一的共同入口，所以映射必须与模型的 `toJson()` 语义一致：
/// 枚举取 `.name`（`external-controller` 取 `ExternalControllerStatus.value`），
/// `tunnels` 用 `toClashJson()` 而不是 `toJson()`。
Map<String, dynamic> buildConfigPatchInput({
  required Map<String, dynamic> rawConfig,
  required ClashConfig patch,
  required Profile profile,
  required bool isAndroid,
  required bool isLinux,
  required String uiPath,
  required String profilesPath,
  required bool overrideDns,
  required bool overrideNtp,
  required bool overrideSniffer,
  required bool overrideExperimental,
  required String nodeExcludeFilter,
  required int healthCheckTimeout,
  required List<String> scriptAddedRules,
  required bool hasCurrentScript,
  required bool disableQuic,
  required bool excludeChina,
  required String? locale,
}) {
  return <String, dynamic>{
    'rawConfig': rawConfig,
    'patch': resolveJsonValue({
      'dns': patch.dns.toJson(),
      'tun': {
        'enable': patch.tun.enable,
        'device': patch.tun.device,
        'stack': patch.tun.stack.name,
        'dns-hijack': patch.tun.dnsHijack,
        'route-address': patch.tun.routeAddress,
        'route-exclude-address': patch.tun.routeExcludeAddress,
        'strict-route': patch.tun.strictRoute,
        'endpoint-independent-nat': patch.tun.endpointIndependentNat,
        'disable-icmp-forwarding': patch.tun.disableIcmpForwarding,
        'mtu': patch.tun.mtu,
      },
      'ipv6': patch.ipv6,
      'allow-lan': patch.allowLan,
      'external-controller': patch.externalController.value,
      'secret': patch.secret,
      'tcp-concurrent': patch.tcpConcurrent,
      'unified-delay': patch.unifiedDelay,
      'log-level': patch.logLevel.name,
      'keep-alive-interval': patch.keepAliveInterval,
      'mixed-port': patch.mixedPort,
      'port': patch.port,
      'socks-port': patch.socksPort,
      'redir-port': patch.redirPort,
      'tproxy-port': patch.tproxyPort,
      'find-process-mode': patch.findProcessMode.name,
      'mode': patch.mode.name,
      'geodata-loader': patch.geodataLoader.name,
      'geox-url': patch.geoXUrl.toJson(),
      'global-ua': patch.globalUa,
      'hosts': patch.hosts,
      'tunnels': patch.tunnels.map((tunnel) => tunnel.toClashJson()).toList(),
      'sniffer': patch.sniffer.toJson(),
      'ntp': patch.ntp.toJson(),
      'experimental': patch.experimental.toJson(),
    }),
    'profile': {
      'id': profile.id,
      'useScriptOverride': profile.useScriptOverride,
      'groupSwitches': profile.groupSwitches,
      'overrideData': {
        'enable': profile.overrideData.enable,
        'type': profile.overrideData.rule.type.name,
        'rules': profile.overrideData.rule.rules
            .map((rule) => rule.value)
            .toList(),
      },
    },
    'env': {
      'isAndroid': isAndroid,
      'isLinux': isLinux,
      'uiPath': uiPath,
      'profilesPath': profilesPath,
      'overrideDns': overrideDns,
      'overrideNtp': overrideNtp,
      'overrideSniffer': overrideSniffer,
      'overrideExperimental': overrideExperimental,
      'nodeExcludeFilter': nodeExcludeFilter,
      'healthCheckTimeout': healthCheckTimeout,
      'scriptAddedRules': scriptAddedRules,
      'hasCurrentScript': hasCurrentScript,
      'disableQuic': disableQuic,
      'excludeChina': excludeChina,
      'locale': locale,
    },
  };
}
