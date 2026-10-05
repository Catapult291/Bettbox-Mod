import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'dns_override.dart';
import 'group_switch.dart';
import 'string.dart';

/// 配置改写的整管道，输入输出都是 JSON 结构（无 IO、无全局状态）。
///
/// 这是 `state.dart` 的 `patchRawConfig` 方法体的机械抽取：把「读 profile 配置、
/// 跑脚本、算路径、读全局开关」这些宿主职责留给调用方（见 `GlobalState.patchRawConfig`），
/// 只保留对配置 map 的手术。抽出来是为了能与 Rust 侧
/// `rust/bettbox-native/src/patch_config.rs` 逐字段差分（见
/// `test/rust/patch_config_diff_test.dart`）。
///
/// 输入结构：
/// ```
/// {
///   "rawConfig": {...},   // 已跑完脚本的 profile 配置（rules 已从 rule 改名）
///   "patch": {...},       // 解析后的 realPatchConfig（见 patchClashConfigToJson）
///   "profile": {"id", "useScriptOverride", "groupSwitches", "overrideData"},
///   "env": {...},         // 平台标志、路径、各类 override 开关、规则相关全局项
/// }
/// ```
Map<String, dynamic> applyConfigPatch(Map<String, dynamic> input) {
  final rawConfig = (input['rawConfig'] as Map).cast<String, dynamic>();
  final patch = (input['patch'] as Map).cast<String, dynamic>();
  final profile = (input['profile'] as Map).cast<String, dynamic>();
  final env = (input['env'] as Map).cast<String, dynamic>();

  final isAndroid = env['isAndroid'] == true;
  final isLinux = env['isLinux'] == true;
  final profileId = profile['id'] as String;

  final originalProxyGroups = rawConfig['proxy-groups'];

  rawConfig['external-controller'] = patch['allow-lan'] == true
      ? (patch['external-controller'] as String).replaceAll(
          '127.0.0.1',
          '0.0.0.0',
        )
      : patch['external-controller'];
  if (patch['external-controller'] == '127.0.0.1:9090') {
    final secret = patch['secret'];
    if (secret is String && secret.isNotEmpty) {
      rawConfig['secret'] = secret;
    }
  }
  rawConfig['external-ui'] = env['uiPath'];
  rawConfig['external-ui-url'] =
      'https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip';
  rawConfig.remove('external-ui-name');
  if (rawConfig['interface-name'] == null) {
    rawConfig['interface-name'] = '';
  }
  rawConfig['tcp-concurrent'] = patch['tcp-concurrent'];
  rawConfig['unified-delay'] = patch['unified-delay'];
  rawConfig['ipv6'] = patch['ipv6'];
  rawConfig['log-level'] = patch['log-level'];
  rawConfig['port'] = 0;
  rawConfig['socks-port'] = 0;
  rawConfig['keep-alive-interval'] = patch['keep-alive-interval'];
  rawConfig['mixed-port'] = patch['mixed-port'];
  rawConfig['port'] = patch['port'];
  rawConfig['socks-port'] = patch['socks-port'];
  rawConfig['redir-port'] = patch['redir-port'];
  rawConfig['tproxy-port'] = patch['tproxy-port'];
  rawConfig['find-process-mode'] = patch['find-process-mode'];
  rawConfig['allow-lan'] = patch['allow-lan'];
  rawConfig['mode'] = patch['mode'];

  final patchTun = (patch['tun'] as Map).cast<String, dynamic>();
  if (rawConfig['tun'] == null) {
    rawConfig['tun'] = <String, dynamic>{};
  }
  final tun = (rawConfig['tun'] as Map).cast<String, dynamic>();
  tun['enable'] = patchTun['enable'];
  tun['device'] = patchTun['device'];
  final dnsHijack = patchTun['dns-hijack'] as List? ?? const [];
  tun['dns-hijack'] = dnsHijack.isEmpty ? const ['any:53'] : dnsHijack;
  tun['stack'] = patchTun['stack'];
  tun['route-address'] = patchTun['route-address'];
  tun['route-exclude-address'] = patchTun['route-exclude-address'];
  tun['auto-route'] = !isAndroid;
  tun['auto-detect-interface'] = !isAndroid;
  tun['auto-redirect'] = isLinux;
  tun['strict-route'] = patchTun['strict-route'];
  tun['endpoint-independent-nat'] = patchTun['endpoint-independent-nat'];
  tun['disable-icmp-forwarding'] = patchTun['disable-icmp-forwarding'];
  tun['mtu'] = patchTun['mtu'];

  rawConfig['geodata-loader'] = patch['geodata-loader'];
  rawConfig['geodata-mode'] = false;

  if (rawConfig['sniffer'] != null && rawConfig['sniffer']['sniff'] != null) {
    for (final value in (rawConfig['sniffer']['sniff'] as Map).values) {
      if (value['ports'] != null && value['ports'] is List) {
        value['ports'] =
            (value['ports'] as List).map((item) => item.toString()).toList();
      }
    }
  }

  if (rawConfig['profile'] == null) {
    rawConfig['profile'] = <String, dynamic>{};
  }
  if (rawConfig['proxy-providers'] != null) {
    final proxyProviders = rawConfig['proxy-providers'] as Map;
    for (final key in proxyProviders.keys) {
      final proxyProvider = proxyProviders[key];
      if (proxyProvider['type'] != 'http') {
        continue;
      }
      if (proxyProvider['url'] != null) {
        proxyProvider['path'] = _providersFilePath(
          env['profilesPath'] as String,
          profileId,
          'proxies',
          proxyProvider['url'] as String,
        );
      }
    }
  }
  if (rawConfig['rule-providers'] != null) {
    final ruleProviders = rawConfig['rule-providers'] as Map;
    for (final key in ruleProviders.keys) {
      final ruleProvider = ruleProviders[key];
      if (ruleProvider['type'] != 'http') {
        continue;
      }
      if (ruleProvider['url'] != null) {
        ruleProvider['path'] = _providersFilePath(
          env['profilesPath'] as String,
          profileId,
          'rules',
          ruleProvider['url'] as String,
        );
      }
    }
  }

  final rawProfile = (rawConfig['profile'] as Map).cast<String, dynamic>();
  rawProfile['store-selected'] ??= true;
  rawProfile['store-fake-ip'] ??= true;

  rawConfig['geox-url'] = patch['geox-url'];
  rawConfig['global-ua'] = patch['global-ua'];
  if (rawConfig['hosts'] == null) {
    rawConfig['hosts'] = <String, dynamic>{};
  }
  final hosts = (rawConfig['hosts'] as Map).cast<String, dynamic>();
  for (final host in (patch['hosts'] as Map).entries) {
    hosts[host.key as String] = (host.value as String).splitByMultipleSeparators;
  }
  hosts['dns.msftncsi.com'] = ['131.107.255.255', 'fd3e:4f5a:5b81::1'];

  if (rawConfig['dns'] == null) {
    rawConfig['dns'] = <String, dynamic>{};
  }
  final isEnableDns = rawConfig['dns']['enable'] == true;
  if (env['overrideDns'] == true || !isEnableDns) {
    final originalDns = rawConfig['dns'] is Map
        ? Map<String, dynamic>.from(rawConfig['dns'] as Map)
        : null;
    final originalHosts = Map<String, dynamic>.from(hosts);
    final patchDns = (patch['dns'] as Map).cast<String, dynamic>();
    final dns = !isEnableDns
        ? {
            ...patchDns,
            'nameserver': [
              ...(patchDns['nameserver'] as List? ?? const []),
              'system://',
            ],
          }
        : patchDns;
    final dnsMap = Map<String, dynamic>.from(dns);
    dnsMap['nameserver-policy'] = <String, dynamic>{};
    for (final entry
        in (dns['nameserver-policy'] as Map? ?? const {}).entries) {
      dnsMap['nameserver-policy'][entry.key] = (entry.value as String)
          .splitByMultipleSeparators;
    }
    rawConfig['dns'] = dnsMap;
    applyDnsNodeOverride(
      rawConfig,
      originalDns: originalDns,
      originalHosts: originalHosts,
    );
  }

  final rawDns = rawConfig['dns'];
  if (rawDns is Map && rawDns['fallback-filter'] is Map) {
    (rawDns['fallback-filter'] as Map).remove('geosite');
  }

  if (isAndroid && rawDns is Map && rawDns['listen'] != null) {
    final listen = rawDns['listen'] as String;
    if (listen.endsWith(':53')) {
      rawDns['listen'] = listen.replaceAll(':53', ':10053');
    }
    final noProviders =
        rawConfig['proxy-providers'] == null &&
        rawConfig['rule-providers'] == null;
    final proxyServerNameserver = rawDns['proxy-server-nameserver'];
    final hasLocalProxyServerNameserver = switch (proxyServerNameserver) {
      List list => list.any((e) => e.toString().startsWith('127.0.0.1')),
      String str => str.startsWith('127.0.0.1'),
      _ => false,
    };
    if (noProviders &&
        hasLocalProxyServerNameserver &&
        listen.startsWith('0.0.0.0')) {
      rawDns['listen'] = '127.0.0.1${listen.substring('0.0.0.0'.length)}';
    }
  }

  if (rawConfig['ntp'] == null) {
    rawConfig['ntp'] = <String, dynamic>{};
  }
  if (env['overrideNtp'] == true) {
    rawConfig['ntp'] = Map<String, dynamic>.from(patch['ntp'] as Map);
  }
  if (isAndroid) {
    (rawConfig['ntp'] as Map)['write-to-system'] = false;
  }

  if (rawConfig['sniffer'] == null) {
    rawConfig['sniffer'] = <String, dynamic>{};
  }
  if (env['overrideSniffer'] == true) {
    rawConfig['sniffer'] = Map<String, dynamic>.from(patch['sniffer'] as Map);
  }

  final guiTunnels = patch['tunnels'] as List? ?? const [];
  if (guiTunnels.isNotEmpty) {
    final existingTunnels = rawConfig['tunnels'] as List? ?? const [];
    rawConfig['tunnels'] = [
      ...existingTunnels,
      ...guiTunnels.map((t) => Map<String, dynamic>.from(t as Map)),
    ];
  }

  if (rawConfig['experimental'] == null) {
    rawConfig['experimental'] = <String, dynamic>{};
  }
  if (env['overrideExperimental'] == true) {
    rawConfig['experimental'] = Map<String, dynamic>.from(
      patch['experimental'] as Map,
    );
  }

  final nodeExcludeFilter = env['nodeExcludeFilter'] as String;
  final healthCheckTimeout = env['healthCheckTimeout'] as int;
  if ((nodeExcludeFilter.isNotEmpty || healthCheckTimeout != 5000) &&
      rawConfig['proxy-groups'] is List) {
    RegExp? filterRegex;
    if (nodeExcludeFilter.isNotEmpty) {
      try {
        filterRegex = RegExp(nodeExcludeFilter);
      } catch (_) {}
    }

    final proxyGroups = rawConfig['proxy-groups'] as List;
    final Set<String> protectedNames = {
      'DIRECT',
      'REJECT',
      'REJECT-DROP',
      'COMPATIBLE',
      'PASS',
    };
    for (final g in proxyGroups) {
      if (g is Map && g['name'] is String) {
        protectedNames.add(g['name'] as String);
      }
    }

    for (final group in proxyGroups) {
      if (group is! Map) continue;

      if (filterRegex != null && group['use'] != null) {
        final existing = group['exclude-filter'];
        if (existing is String && existing.isNotEmpty) {
          group['exclude-filter'] = '$existing|$nodeExcludeFilter';
        } else {
          group['exclude-filter'] = nodeExcludeFilter;
        }
      }

      if (filterRegex != null && group['proxies'] is List) {
        final proxiesList = group['proxies'] as List;
        final filtered = proxiesList.where((item) {
          if (item is! String || protectedNames.contains(item)) return true;
          return !filterRegex!.hasMatch(item);
        }).toList();

        if (filtered.isEmpty &&
            (group['use'] == null ||
                (group['use'] is List && (group['use'] as List).isEmpty))) {
          filtered.add('DIRECT');
        }
        group['proxies'] = filtered;
      }

      if (healthCheckTimeout != 5000) {
        group['timeout'] ??= healthCheckTimeout;
      }
    }

    if (filterRegex != null && rawConfig['proxy-providers'] is Map) {
      final proxyProviders = rawConfig['proxy-providers'] as Map;
      for (final provider in proxyProviders.values) {
        if (provider is! Map) continue;
        final existing = provider['exclude-filter'];
        if (existing is String && existing.isNotEmpty) {
          provider['exclude-filter'] = '$existing|$nodeExcludeFilter';
        } else {
          provider['exclude-filter'] = nodeExcludeFilter;
        }
      }
    }
  }

  if (rawConfig['proxy-groups'] is List) {
    for (final group in rawConfig['proxy-groups'] as List) {
      if (group is! Map) continue;
      final tolerance = group['tolerance'];
      if (tolerance != null) {
        if (tolerance is double) {
          group['tolerance'] = tolerance.toInt();
        } else if (tolerance is String) {
          group['tolerance'] = int.tryParse(tolerance) ?? tolerance;
        }
      }
    }
  }

  List<dynamic> rules = [];
  if (rawConfig['rules'] != null) {
    rules = rawConfig['rules'] as List;
    rawConfig.remove('rules');
  } else if (rawConfig['rule'] != null) {
    rules = rawConfig['rule'] as List;
    rawConfig.remove('rule');
  }

  final scriptOverride = profile['useScriptOverride'] == true;
  final addedRules = (env['scriptAddedRules'] as List?) ?? const [];
  final scriptActive =
      (env['hasCurrentScript'] == true || addedRules.isNotEmpty) &&
      scriptOverride;

  final overrideData = (profile['overrideData'] as Map).cast<String, dynamic>();
  if (overrideData['enable'] == true && !scriptActive) {
    final runningRule = overrideData['enable'] == true
        ? (overrideData['rules'] as List)
        : const [];
    if (overrideData['type'] == 'override') {
      rules = List<dynamic>.from(runningRule);
    } else {
      rules = [...runningRule, ...rules];
    }
  }

  if (scriptOverride && addedRules.isNotEmpty) {
    rules = [...addedRules, ...rules];
  }

  if (env['disableQuic'] == true) {
    final isRussian =
        (env['locale'] as String?)?.toLowerCase().startsWith('ru') ?? false;
    final quicRules = env['excludeChina'] == true && !isRussian
        ? [
            'AND,((NETWORK,UDP),(DST-PORT,443),(NOT,((OR,((GEOSITE,geolocation-cn),(GEOIP,CN,no-resolve)))))),REJECT',
          ]
        : ['AND,((NETWORK,UDP),(DST-PORT,443)),REJECT'];
    rules = [...quicRules, ...rules];
  }

  if (rawConfig['proxy-groups'] == null && originalProxyGroups != null) {
    rawConfig['proxy-groups'] = originalProxyGroups;
  }

  final globalClientFingerprint = rawConfig['global-client-fingerprint'];
  if (rawConfig['proxies'] is List) {
    for (final proxy in rawConfig['proxies'] as List) {
      if (proxy is! Map) continue;

      final type = proxy['type']?.toString().toLowerCase();
      final isTls = proxy['tls'] == true;

      var supportClientFingerprint = false;
      if (type == 'trojan' || type == 'anytls') {
        supportClientFingerprint = true;
      } else if ((type == 'vmess' || type == 'vless') && isTls) {
        supportClientFingerprint = true;
      }

      if (supportClientFingerprint) {
        if (globalClientFingerprint != null &&
            proxy['client-fingerprint'] == null) {
          proxy['client-fingerprint'] = globalClientFingerprint;
        }
      }

      final realityOpts = proxy['reality-opts'];
      if (realityOpts is Map) {
        final shortId = realityOpts['short-id'];
        if (shortId is num) {
          realityOpts['short-id'] = shortId.toString();
        }
      }
    }
  }

  applyGroupSwitches(
    rawConfig,
    rules,
    groupSwitches: (profile['groupSwitches'] as Map? ?? const {})
        .cast<String, bool>(),
    scriptActive: scriptActive,
  );

  rawConfig.remove('rule');
  rawConfig['rules'] = rules;
  return rawConfig;
}

/// `AppPath.getProvidersFilePath` 的纯函数形态（见 `lib/common/path.dart:143`）。
String _providersFilePath(String profilesPath, String id, String type, String url) {
  return p.join(profilesPath, 'providers', id, type, _md5(url));
}

String _md5(String value) => md5.convert(utf8.encode(value)).toString();
