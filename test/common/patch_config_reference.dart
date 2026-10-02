// 由 `git show HEAD:lib/state.dart` 的 `patchRawConfig` 主体机械生成，只做三类替换：
//   1. 宿主职责参数化（appPath / system / globalState.config / targetProfile / config.scriptProps），
//      为避免与主体内同名局部变量冲突，带 `env` 前缀；
//   2. 变量改名（realPatchConfig -> patch）；
//   3. 去掉三处 `await`（路径解析改成同步传入）。
// 除这三类外不碰任何逻辑，用于验证 `applyConfigPatch` 的抽取没有走样：
// 见 test/common/patch_config_reference_test.dart。
import 'dart:convert';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

Map<String, dynamic> referencePatchConfig({
  required Map<String, dynamic> rawConfig,
  required ClashConfig patch,
  required Profile profile,
  required String profileId,
  required bool isAndroid,
  required bool isLinux,
  required String uiPath,
  required String profilesPath,
  required bool envOverrideDns,
  required bool envOverrideNtp,
  required bool envOverrideSniffer,
  required bool envOverrideExperimental,
  required String envNodeExcludeFilter,
  required int envHealthCheckTimeout,
  required List<String> scriptAddedRules,
  required bool hasCurrentScript,
  required bool disableQuic,
  required bool excludeChina,
  required String? locale,
}) {
  String providersFilePath(String id, String type, String url) => p.join(
    profilesPath,
    'providers',
    id,
    type,
    md5.convert(utf8.encode(url)).toString(),
  );

  final originalProxyGroups = rawConfig['proxy-groups'];

  rawConfig['external-controller'] = patch.allowLan
      ? patch.externalController.value.replaceAll('127.0.0.1', '0.0.0.0')
      : patch.externalController.value;
  if (patch.externalController == ExternalControllerStatus.open) {
    final secret = patch.secret;
    if (secret != null && secret.isNotEmpty) {
      rawConfig['secret'] = secret;
    }
  }
  rawConfig['external-ui'] = uiPath;
  rawConfig['external-ui-url'] =
      'https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip';
  rawConfig.remove('external-ui-name');
  if (rawConfig['interface-name'] == null) {
    rawConfig['interface-name'] = '';
  }
  rawConfig['tcp-concurrent'] = patch.tcpConcurrent;
  rawConfig['unified-delay'] = patch.unifiedDelay;
  rawConfig['ipv6'] = patch.ipv6;
  rawConfig['log-level'] = patch.logLevel.name;
  rawConfig['port'] = 0;
  rawConfig['socks-port'] = 0;
  rawConfig['keep-alive-interval'] = patch.keepAliveInterval;
  rawConfig['mixed-port'] = patch.mixedPort;
  rawConfig['port'] = patch.port;
  rawConfig['socks-port'] = patch.socksPort;
  rawConfig['redir-port'] = patch.redirPort;
  rawConfig['tproxy-port'] = patch.tproxyPort;
  rawConfig['find-process-mode'] = patch.findProcessMode.name;
  rawConfig['allow-lan'] = patch.allowLan;
  rawConfig['mode'] = patch.mode.name;
  if (rawConfig['tun'] == null) {
    rawConfig['tun'] = {};
  }
  rawConfig['tun']['enable'] = patch.tun.enable;
  rawConfig['tun']['device'] = patch.tun.device;
  final dnsHijack = patch.tun.dnsHijack;
  rawConfig['tun']['dns-hijack'] = dnsHijack.isEmpty
      ? const ['any:53']
      : dnsHijack;
  rawConfig['tun']['stack'] = patch.tun.stack.name;
  rawConfig['tun']['route-address'] = patch.tun.routeAddress;
  rawConfig['tun']['route-exclude-address'] = patch.tun.routeExcludeAddress;
  rawConfig['tun']['auto-route'] = !isAndroid;
  rawConfig['tun']['auto-detect-interface'] = !isAndroid;
  rawConfig['tun']['auto-redirect'] = isLinux;
  rawConfig['tun']['strict-route'] = patch.tun.strictRoute;
  rawConfig['tun']['endpoint-independent-nat'] =
      patch.tun.endpointIndependentNat;
  rawConfig['tun']['disable-icmp-forwarding'] = patch.tun.disableIcmpForwarding;
  rawConfig['tun']['mtu'] = patch.tun.mtu;
  rawConfig['geodata-loader'] = patch.geodataLoader.name;
  rawConfig['geodata-mode'] = false;
  if (rawConfig['sniffer']?['sniff'] != null) {
    for (final value in (rawConfig['sniffer']?['sniff'] as Map).values) {
      if (value['ports'] != null && value['ports'] is List) {
        value['ports'] =
            value['ports']?.map((item) => item.toString()).toList() ?? [];
      }
    }
  }
  if (rawConfig['profile'] == null) {
    rawConfig['profile'] = {};
  }
  if (rawConfig['proxy-providers'] != null) {
    final proxyProviders = rawConfig['proxy-providers'] as Map;
    for (final key in proxyProviders.keys) {
      final proxyProvider = proxyProviders[key];
      if (proxyProvider['type'] != 'http') {
        continue;
      }
      if (proxyProvider['url'] != null) {
        proxyProvider['path'] = providersFilePath(
          profileId,
          'proxies',
          proxyProvider['url'],
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
        ruleProvider['path'] = providersFilePath(
          profileId,
          'rules',
          ruleProvider['url'],
        );
      }
    }
  }

  if (rawConfig['profile']['store-selected'] == null) {
    rawConfig['profile']['store-selected'] = true;
  }
  if (rawConfig['profile']['store-fake-ip'] == null) {
    rawConfig['profile']['store-fake-ip'] = true;
  }
  rawConfig['geox-url'] = patch.geoXUrl.toJson();
  rawConfig['global-ua'] = patch.globalUa;
  if (rawConfig['hosts'] == null) {
    rawConfig['hosts'] = {};
  }
  for (final host in patch.hosts.entries) {
    rawConfig['hosts'][host.key] = host.value.splitByMultipleSeparators;
  }

  rawConfig['hosts']['dns.msftncsi.com'] = [
    '131.107.255.255',
    'fd3e:4f5a:5b81::1',
  ];

  if (rawConfig['dns'] == null) {
    rawConfig['dns'] = {};
  }
  final isEnableDns = rawConfig['dns']['enable'] == true;
  final overrideDns = envOverrideDns;
  if (overrideDns || !isEnableDns) {
    final originalDns = rawConfig['dns'] is Map
        ? (rawConfig['dns'] as Map).cast<String, dynamic>()
        : null;
    final originalHosts = rawConfig['hosts'] is Map
        ? (rawConfig['hosts'] as Map).cast<String, dynamic>()
        : null;
    final dns = switch (!isEnableDns) {
      true => patch.dns.copyWith(
        nameserver: [...patch.dns.nameserver, 'system://'],
      ),
      false => patch.dns,
    };
    rawConfig['dns'] = dns.toJson();
    rawConfig['dns']['nameserver-policy'] = {};
    for (final entry in dns.nameserverPolicy.entries) {
      rawConfig['dns']['nameserver-policy'][entry.key] =
          entry.value.splitByMultipleSeparators;
    }
    applyDnsNodeOverride(
      rawConfig,
      originalDns: originalDns,
      originalHosts: originalHosts,
    );
  }

  if (rawConfig['dns'] != null && rawConfig['dns']['fallback-filter'] != null) {
    if (rawConfig['dns']['fallback-filter'] is Map) {
      (rawConfig['dns']['fallback-filter'] as Map).remove('geosite');
    }
  }

  if (isAndroid && rawConfig['dns']['listen'] != null) {
    final listen = rawConfig['dns']['listen'] as String;
    if (listen.endsWith(':53')) {
      rawConfig['dns']['listen'] = listen.replaceAll(':53', ':10053');
    }
    final noProviders =
        rawConfig['proxy-providers'] == null &&
        rawConfig['rule-providers'] == null;
    final proxyServerNameserver = rawConfig['dns']['proxy-server-nameserver'];
    final hasLocalProxyServerNameserver = switch (proxyServerNameserver) {
      List list => list.any((e) => e.toString().startsWith('127.0.0.1')),
      String str => str.startsWith('127.0.0.1'),
      _ => false,
    };
    if (noProviders &&
        hasLocalProxyServerNameserver &&
        listen.startsWith('0.0.0.0')) {
      rawConfig['dns']['listen'] =
          '127.0.0.1${listen.substring('0.0.0.0'.length)}';
    }
  }

  if (rawConfig['ntp'] == null) {
    rawConfig['ntp'] = {};
  }
  final overrideNtp = envOverrideNtp;
  if (overrideNtp) {
    final ntp = patch.ntp;
    rawConfig['ntp'] = ntp.toJson();
  }
  if (isAndroid) {
    rawConfig['ntp']['write-to-system'] = false;
  }
  if (rawConfig['sniffer'] == null) {
    rawConfig['sniffer'] = {};
  }
  final overrideSniffer = envOverrideSniffer;
  if (overrideSniffer) {
    final sniffer = patch.sniffer;
    rawConfig['sniffer'] = sniffer.toJson();
  }
  final guiTunnels = patch.tunnels;
  if (guiTunnels.isNotEmpty) {
    final existingTunnels = rawConfig['tunnels'] as List? ?? [];
    final allTunnels = [
      ...existingTunnels,
      ...guiTunnels.map((t) => t.toClashJson()),
    ];
    rawConfig['tunnels'] = allTunnels;
  }
  if (rawConfig['experimental'] == null) {
    rawConfig['experimental'] = {};
  }
  final overrideExperimental = envOverrideExperimental;
  if (overrideExperimental) {
    final experimental = patch.experimental;
    rawConfig['experimental'] = experimental.toJson();
  }

  final nodeExcludeFilter = envNodeExcludeFilter;
  final healthCheckTimeout = envHealthCheckTimeout;
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
                (group['use'] is List && group['use'].isEmpty))) {
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
    final proxyGroups = rawConfig['proxy-groups'] as List;
    for (final group in proxyGroups) {
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

  var rules = [];
  if (rawConfig['rules'] != null) {
    rules = rawConfig['rules'];
    rawConfig.remove('rules');
  } else if (rawConfig['rule'] != null) {
    rules = rawConfig['rule'];
    rawConfig.remove('rule');
  }

  final scriptOverride = profile.useScriptOverride;
  final addedRules = scriptAddedRules;
  final scriptActive =
      (hasCurrentScript || addedRules.isNotEmpty) && scriptOverride;

  final overrideData = profile.overrideData;
  if (overrideData.enable && !scriptActive) {
    if (overrideData.rule.type == OverrideRuleType.override) {
      rules = overrideData.runningRule;
    } else {
      rules = [...overrideData.runningRule, ...rules];
    }
  }

  // UI-added rules act as a global override: once script override is
  // enabled for the profile, prepend them so they take precedence over
  // every rule of the effective config.
  if (scriptOverride && addedRules.isNotEmpty) {
    rules = [...addedRules, ...rules];
  }

  if (disableQuic) {
    final isRussian = locale?.toLowerCase().startsWith('ru') ?? false;
    final quicRules = excludeChina && !isRussian
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
    final proxiesList = rawConfig['proxies'] as List;
    for (final proxy in proxiesList) {
      if (proxy is! Map) continue;

      final type = proxy['type']?.toString().toLowerCase();
      final isTls = proxy['tls'] == true;

      bool supportClientFingerprint = false;
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
    groupSwitches: profile.groupSwitches,
    scriptActive: scriptActive,
  );

  rawConfig.remove('rule');
  rawConfig['rules'] = rules;
  return rawConfig;
}
