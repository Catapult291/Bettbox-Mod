// 脚本链接：https://example.com/Catapult291/scripts/main/sing-mix_twjpkr.ps1

// ====================
// 0. 特殊处理
// ====================

// 强制直连（按需填域名，留空即不启用）
const BYPASS_DOMAINS = [];

// 强制代理（按需填域名，留空即不启用）
// 默认带上 Bettbox 首页「网络检测」的探测域名（api.ip.sb / Cloudflare trace / api.ipify.org /
// api.ipinfo.io）：这些域名既不在 gfw 也不在 cn，规则落空后走 MATCH,final；final 一旦选 DIRECT，
// 检测请求就直连、显示国内出口 IP，看着像代理没生效。钉到 main 后检测结果与 final 的取值解耦：
// final 选什么都仍从 main 出站。main 是 select 组且不含 DIRECT，做锚点不会被选成直连。
// 一律用精确域名（DOMAIN），不用 DOMAIN-SUFFIX：后者会把
// challenges.example.com 一并拽进代理，而它本来由 RULE-SET,cloudflare 判直连。
const FORCE_PROXY_DOMAINS = [
  "api.ip.sb",
  "example.com",
  "www.example.com",
  "example.com",
  "api.ipify.org",
  "api.ipinfo.io"
];

// 自定义节点过滤（用 | 分割；null = 不过滤任何节点）
const CUSTOM_FILTER = null;

// IPv6 支持。内核里 AAAA 放行条件是 dns.ipv6 与顶层 ipv6 同时为真（ipv6 := dns.ipv6 && general.ipv6），
// 所以客户端整体没开 IPv6 时，这里打开也不会带来任何变化。
// Bettbox 中顶层 ipv6 由应用内「IPv6」开关在脚本之后强制覆写，脚本管不到它；
// 脚本能决定的是 DNS 侧：不打开这里，即使应用开了 IPv6，域名也永远解析不到 AAAA。
const ENABLE_IPV6 = true;

// IPv6 fake-ip 池。fake-ip 模式下 v6 池要单独给出，缺失时 AAAA 一律回空应答。
// 与 Bettbox 的 fakeIpRangeV6 默认值保持一致。
const FAKE_IP_RANGE6 = "2001:2::1/48";

// 关键链路域名：本机中转链路的入口（cline 渠道 + commandcode 渠道）。
// 解析必须与代理组可用性解耦，且不能拿 fake-ip：境外 nameserver 是 `#main`（经代理组出站），
// 节点全挂时会把全机境外解析一起拖死，而这两个域名默认走 MATCH,final、仍在 main 上，正是受害面。
// 实测它们不是污染目标（系统 DNS 与 223.5.5.5 给出的都是同一个真实 IP），走直连公共 DoH
// 既不被污染也不依赖节点。
const CRITICAL_DOMAINS = ["+.cline.bot", "+.commandcode.ai"];
const CRITICAL_DIRECT_DNS = [
  "https://dns.alidns.com/dns-query#DIRECT",
  "https://doh.pub/dns-query#DIRECT"
];

// ====================
// 1. 常量配置
// ====================
const SETTINGS = {
  ICON_BASE: "https://example.com/gh/Koolson/Qure@master/IconSet/Color/",
  RULE_PROVIDER_URL_BASE: "https://example.com/gh/MetaCubeX/meta-rules-dat@meta/geo",

  // TW/SG/JP/KR 合并为 TW_SG_JP_KR 单一分组；原 AS 分组（东南亚）已移除
  REGION_ORDER: ["HK", "TW_SG_JP_KR", "US"],

  URL_TEST_EXTRA: {
    hidden: true,
    url: "https://example.com/generate_204",
    interval: 900,
    tolerance: 100,
    lazy: true,
    timeout: 1000,
    "max-failed-times": 1,
  },

  FALLBACK_TEST_EXTRA: {
    url: "https://example.com/generate_204",
    interval: 900,
    lazy: true,
    timeout: 1000,
    "max-failed-times": 1,
  },

  INFO_FILTER: /tg|telegram|倒卖|到期|电报|订阅|发布|防止|返利|购买|官方|官网|工单|过期|规则|建议|客服|联系|流量|剩余|失联|网址|邮箱|续费|邀请|重置|梯子|群/i
};

// ====================
// 2. 基础工具
// ====================
const uniq = (arr = []) => [...new Set(arr.filter(Boolean))];

const escapeRegex = (s = "") =>
  String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

const normalizeName = (name = "") =>
  String(name)
    .replace(/(IEPL|IPLC|BGP|RELAY|PRO|V\d+)/ig, " $1 ")
    .replace(/[【】\[\]（）()|_\-.,/:~]/g, " ")
    .replace(/🇭🇰/g, " HK ")
    .replace(/🇹🇼/g, " TW ")
    .replace(/🇸🇬/g, " SG ")
    .replace(/🇯🇵/g, " JP ")
    .replace(/🇰🇷/g, " KR ")
    .replace(/🇺🇸/g, " US ")
    .toUpperCase()
    .replace(/\s+/g, " ")
    .trim();

const buildRegex = (arr = []) =>
  new RegExp(
    arr
      .map((raw) => {
        const token = String(raw).trim().toUpperCase();
        const escaped = escapeRegex(token);
        return /^[A-Z]{2,3}$/.test(token)
          ? `(?:^|[^A-Z])${escaped}(?:[^A-Z]|$)`
          : escaped;
      })
      .join("|"),
    "i"
  );

const buildRegions = () =>
  ([
    { name: "HK", pattern: ["香港", "HK", "HKG", "HONGKONG", "HONG KONG"], icon: "Hong_Kong.png" },
    // 合并组：台湾/新加坡/日本/韩国四地关键词合入同一 pattern
    {
      name: "TW_SG_JP_KR",
      pattern: [
        "台湾", "台北", "新北", "TW", "TWN", "TAIWAN", "TAIPEI",
        "新加坡", "狮城", "SG", "SGP", "SINGAPORE",
        "日本", "东京", "大阪", "JP", "JPN", "JAPAN", "TOKYO", "OSAKA",
        "韩国", "首尔", "KR", "KOR", "KOREA", "SEOUL"
      ],
      icon: "Asia_Map.png"
    },
    {
      name: "US",
      pattern: [
        "美国", "纽约", "旧金山", "洛杉矶", "西雅图", "芝加哥",
        "US", "USA",
        "NEWYORK", "NEW YORK",
        "SANFRANCISCO", "SAN FRANCISCO",
        "LOSANGELES", "LOS ANGELES",
        "SEATTLE", "CHICAGO"
      ],
      icon: "United_States.png"
    }
  ]).map((r) => ({ ...r, regex: buildRegex(r.pattern) }));

const REGIONS = buildRegions();

const buildFakeIpFilter = (bypass = []) =>
  uniq([
    "rule-set:private",
    "rule-set:google-cn",
    "rule-set:synology",
    "rule-set:cn",
    ...uniq(
      bypass.flatMap((domain) => {
        const d = String(domain || "").trim();
        if (!d) return [];
        return d.includes("*") || d.startsWith("+.") ? [d] : [`+.${d}`];
      })
    )
  ]);

const mergeRules = (baseRules = [], extraRules = []) => {
  const extra = Array.isArray(extraRules) ? extraRules.filter(Boolean) : [];
  if (!extra.length) return baseRules.slice();

  const matchIndex = baseRules.findIndex(
    // 注意：左侧已 toUpperCase，右侧也必须是全大写——旧写法的 "MATCH,main" 永远不相等，
    // 于是保留下来的 profile 直连规则被追加到 MATCH 之后，成为永不生效的死规则。
    (rule) => String(rule).trim().toUpperCase() === "MATCH,FINAL"
  );

  if (matchIndex === -1) return uniq([...baseRules, ...extra]);

  return uniq([
    ...baseRules.slice(0, matchIndex),
    ...extra,
    ...baseRules.slice(matchIndex)
  ]);
};

const pickDirectRules = (rules = []) =>
  rules.filter((rule) => {
    const r = String(rule || "").trim();
    if (!r || r.startsWith("#")) return false;
    return /,DIRECT(?:,|$)/i.test(r);
  });

// ====================
// 3. 规则集与固定规则
// ====================
const RULE_PROVIDERS_DOMAINS = [
  "category-ads-all", "private", "google-cn", "synology", "microsoft@cn",
  "category-game-platforms-download@cn", "category-ai-!cn", "telegram", "gfw", "cn",
  "googlefcm", "epicgames", "nvidia@cn", "cloudflare@cn", "steam@cn",
  "category-ntp", "connectivity-check", "apple", "spotify", "microsoft"
];

const RULE_PROVIDERS_IPS = [
  "private", "cn"
];

const buildRuleProviders = () => {
  const providers = {};

  RULE_PROVIDERS_DOMAINS.forEach(name => {
    providers[name] = {
      type: "http",
      behavior: "domain",
      format: "mrs",
      path: `./rules/${name}.mrs`,
      url: `${SETTINGS.RULE_PROVIDER_URL_BASE}/geosite/${name}.mrs`,
      interval: 86400
    };
  });

  RULE_PROVIDERS_IPS.forEach(name => {
    providers[`${name}-ip`] = {
      type: "http",
      behavior: "ipcidr",
      format: "mrs",
      path: `./rules/${name}-ip.mrs`,
      url: `${SETTINGS.RULE_PROVIDER_URL_BASE}/geoip/${name}.mrs`,
      interval: 86400
    };
  });

  // Cloudflare 人机验证规则集
  providers.cloudflare = {
    type: "inline",
    behavior: "classical",
    payload: [
      "DOMAIN,challenges.example.com",
      "DOMAIN-SUFFIX,cloudflarechallenge.com"
    ]
  };

  return providers;
};

const STATIC_RULES = [
  "RULE-SET,category-ads-all,REJECT",

  ...uniq(BYPASS_DOMAINS).map((d) => `DOMAIN-SUFFIX,${d},DIRECT`),
  ...uniq(FORCE_PROXY_DOMAINS).map((d) => `DOMAIN,${d},main`),

  "RULE-SET,cloudflare,DIRECT",
  "RULE-SET,private,DIRECT",
  "RULE-SET,private-ip,DIRECT,no-resolve",
  "RULE-SET,googlefcm,DIRECT",
  "RULE-SET,google-cn,DIRECT",
  "RULE-SET,synology,DIRECT",
  "DOMAIN-SUFFIX,sharepoint.com,DIRECT",
  "RULE-SET,microsoft@cn,DIRECT",
  "RULE-SET,category-game-platforms-download@cn,DIRECT",
  "RULE-SET,category-ai-!cn,ai",
  "RULE-SET,telegram,tg",
  "RULE-SET,gfw,main",
  "RULE-SET,cn,DIRECT",
  "RULE-SET,cn-ip,DIRECT,no-resolve",
  "MATCH,final"
];

const STATIC_FAKE_IP_FILTER = buildFakeIpFilter(BYPASS_DOMAINS);

// ====================
// 4. 节点处理
// ====================
const ensureConfigObject = (input) =>
  input && typeof input === "object" ? input : {};

const getOriginalProxies = (input) =>
  Array.isArray(input.proxies) ? input.proxies : [];

const makeProxyNamesUnique = (proxies = []) => {
  const used = new Set();
  const nextIdx = new Map();

  proxies.forEach((p) => {
    if (!p || !p.name) return;

    const base = String(p.name);

    if (!used.has(base)) {
      used.add(base);
      nextIdx.set(base, 1);
      return;
    }

    let idx = nextIdx.get(base) ?? 1;
    let candidate = `${base}_${idx}`;

    while (used.has(candidate)) candidate = `${base}_${++idx}`;

    p.name = candidate;
    used.add(candidate);
    nextIdx.set(base, idx + 1);
  });
};

const filterCustomProxies = (proxies = [], customFilter) => {
  if (!customFilter) return proxies.slice();   // 未配置过滤器：全保留
  return proxies.filter((proxy) => {
    if (!proxy || !proxy.name) return false;
    return !customFilter.test(proxy.name);
  });
};

const splitInfoAndNormalProxies = (proxies = [], infoFilter) =>
  proxies.reduce(
    (acc, proxy) => {
      if (!proxy || !proxy.name) return acc;
      (infoFilter.test(proxy.name) ? acc.infoProxies : acc.normalProxies).push(proxy);
      return acc;
    },
    { infoProxies: [], normalProxies: [] }
  );

const classifyProxiesByRegion = (normalProxies = [], regions = []) => {
  const regionGroupsData = regions.map((r) => ({ name: r.name, icon: r.icon, proxies: [] }));
  const regionGroupMap = new Map(regionGroupsData.map((r) => [r.name, r]));
  const regionSeen = new Map(regionGroupsData.map((r) => [r.name, new Set()]));
  const otherProxyNames = [];
  const otherSeen = new Set();

  normalProxies.forEach((proxy) => {
    const proxyName = proxy.name;
    const normName = normalizeName(proxyName);
    const matchedRegion = regions.find((r) => r.regex.test(normName));

    if (matchedRegion) {
      const group = regionGroupMap.get(matchedRegion.name);
      const seen = regionSeen.get(matchedRegion.name);
      if (group && seen && !seen.has(proxyName)) {
        group.proxies.push(proxyName);
        seen.add(proxyName);
      }
    } else if (!otherSeen.has(proxyName)) {
      otherProxyNames.push(proxyName);
      otherSeen.add(proxyName);
    }
  });

  const activeRegions = regionGroupsData
    .map((r) => ({ ...r, proxies: uniq(r.proxies) }))
    .filter((r) => r.proxies.length > 0);

  const activeRegionNameSet = new Set(activeRegions.map((r) => r.name));
  const activeRegionMap = new Map(activeRegions.map((r) => [r.name, r]));

  return {
    activeRegions,
    activeRegionNameSet,
    activeRegionMap,
    otherProxyNames: uniq(otherProxyNames)
  };
};

const buildAllAiProxyList = (activeRegions = [], otherProxyNames = [], allNames = []) => {
  const nonHk = uniq([
    ...activeRegions.filter((r) => r.name !== "HK").flatMap((r) => r.proxies),
    ...otherProxyNames
  ]);
  return nonHk.length ? nonHk : allNames;
};

// ====================
// 5. 策略组
// ====================
const buildProxyGroups = ({
  allNames,
  allAiNames,
  activeRegionMap,
  activeRegionNameSet,
  otherProxyNames,
  infoNames
}) => {
  const groups = [];

  const add = (name, type, proxies, icon = "Available.png", extra = {}) => {
    proxies = uniq(proxies);
    if (name && proxies.length) {
      groups.push({
        name,
        type,
        proxies,
        icon: SETTINGS.ICON_BASE + icon,
        ...extra
      });
    }
  };

  add("fcm", "select", ["DIRECT"], "Google_Search.png", { hidden: true });

  const regionEntries = SETTINGS.REGION_ORDER.filter((rName) => activeRegionNameSet.has(rName));

  // main 组
  if (allNames.length) {
    const mainEntries = ["All", ...regionEntries];
    if (otherProxyNames.length) mainEntries.push("Other");
    add("main", "select", mainEntries, "Available.png");
  }

  // final 组：规则全部落空后的兜底出口（MATCH,final）。可选「前面各策略组」+ DIRECT，
  // 想改兜底走向时不用动规则；默认第一项是 main，与旧版 MATCH,main 行为一致。
  // 该组永远存在（至少含 DIRECT），因此无可用节点时也不会出现悬空的 MATCH 目标。
  const finalEntries = [
    ...(allNames.length ? ["main"] : []),
    ...(allAiNames.length ? ["ai"] : []),
    ...(allNames.length ? ["tg"] : []),
    ...regionEntries,
    ...(otherProxyNames.length ? ["Other"] : []),
    "DIRECT"
  ];
  add("final", "select", finalEntries, "Final.png");

  // All 组
  if (allNames.length) {
    add("URL Test - All", "url-test", allNames, "Auto.png", SETTINGS.URL_TEST_EXTRA);
    add("All", "select", ["URL Test - All", ...allNames], "Auto.png");
  }

  // ai 组（包含地区子分组，排除 HK）
  if (allAiNames.length) {
    const aiRegionEntries = SETTINGS.REGION_ORDER.filter(
      (rName) => rName !== "HK" && activeRegionNameSet.has(rName)
    );
    const aiEntries = ["All-ai", ...aiRegionEntries];
    if (otherProxyNames.length) aiEntries.push("Other");
    add("ai", "select", aiEntries, "ChatGPT.png");
  }

  // All-ai 组（排除 HK 的所有节点）
  if (allAiNames.length) {
    add("URL Test - All-ai", "url-test", allAiNames, "ChatGPT.png", SETTINGS.URL_TEST_EXTRA);
    add("All-ai", "select", ["URL Test - All-ai", ...allAiNames], "ChatGPT.png");
  }

  // tg 组（原优先 SG，SG 已并入 TW_SG_JP_KR，改为优先合并组）
  if (allNames.length) {
    const hasAsia4 = activeRegionNameSet.has("TW_SG_JP_KR");

    add(
      "tg - Fallback",
      "fallback",
      hasAsia4 ? ["TW_SG_JP_KR", "main"] : ["main"],
      "Telegram.png",
      SETTINGS.FALLBACK_TEST_EXTRA
    );

    add(
      "tg",
      "select",
      ["tg - Fallback", ...(hasAsia4 ? ["TW_SG_JP_KR"] : []), "main"],
      "Telegram.png"
    );
  }

  // 地区分组
  SETTINGS.REGION_ORDER.forEach((rName) => {
    const region = activeRegionMap.get(rName);
    if (!region) return;

    add(`URL Test - ${region.name}`, "url-test", region.proxies, region.icon, SETTINGS.URL_TEST_EXTRA);
    add(region.name, "select", [`URL Test - ${region.name}`, ...region.proxies], region.icon);
  });

  // Other 组（未匹配任何地区的节点，含原 AS 组的东南亚节点）
  if (otherProxyNames.length) {
    add("URL Test - Other", "url-test", otherProxyNames, "Available.png", SETTINGS.URL_TEST_EXTRA);
    add("Other", "select", ["URL Test - Other", ...otherProxyNames], "Available.png");
  }

  // info 组
  if (infoNames.length) {
    add("info", "select", infoNames, "Available.png");
  }

  // GLOBAL 组
  add(
    "GLOBAL",
    "select",
    [
      ...(allNames.length ? ["main", "All"] : []),
      ...(allAiNames.length ? ["ai", "All-ai"] : []),
      ...(allNames.length ? ["tg"] : []),
      ...regionEntries,
      ...(otherProxyNames.length ? ["Other"] : []),
      ...(infoNames.length ? ["info"] : []),
      "final"
    ],
    "Global.png"
  );

  return groups;
};

// ====================
// 6. 网络配置
// ====================
const removeGeoDataConfig = (cfg) => {
  delete cfg["geodata-mode"];
  delete cfg["geo-auto-update"];
  delete cfg["geo-update-interval"];
  delete cfg["geox-url"];
};

const applySniffer = (cfg) => {
  cfg.sniffer = {
    ...(cfg.sniffer || {}),
    enable: true,
    "force-dns-mapping": true,
    "parse-pure-ip": true,
    "override-destination": true,
    sniff: {
      HTTP: { ports: [80, "8080-8880"], "override-destination": true },
      TLS: { ports: [443, 8443] },
      QUIC: { ports: [443, 8443] }
    }
  };
};

const applyTun = (cfg) => {
  cfg.tun = {
    ...(cfg.tun || {}),
    enable: true,
    stack: "system",
    "auto-route": true,
    "auto-detect-interface": true,
    "strict-route": true,
    "dns-hijack": ["any:53", "tcp://any:53"]
  };
};

const applyDns = (cfg) => {
  const dns = cfg.dns || {};
  const fakeIpFilterFromCfg = Array.isArray(dns["fake-ip-filter"]) ? dns["fake-ip-filter"] : [];

  // 直连出口域名解析：国内公共 DoH，保留 system 作兜底
  const chinaDNS = [
    "system",
    "https://dns.alidns.com/dns-query",
    "https://doh.pub/dns-query"
  ];

  // 境外域名解析：双 DoH 并发互为冗余（任一故障不影响解析），
  // 均为 IP 直连形式无需引导解析，且锁定 main 组经代理出站，防泄漏防污染
  const foreignDNS = [
    "https://1.1.1.1/dns-query#main",
    "https://8.8.8.8/dns-query#main"
  ];

  // AI 域名 DNS 锁定 ai 组出口，保证解析出口与实际流量出口地理位置一致，降低风控
  const aiDNS = [
    "https://1.1.1.1/dns-query#ai",
    "https://8.8.8.8/dns-query#ai"
  ];

  // 关键链路域名的 nameserver-policy：走直连公共 DoH，不经代理组、不参与 fake-ip
  const criticalNameserverPolicy = CRITICAL_DOMAINS.reduce((acc, domain) => {
    acc[domain] = CRITICAL_DIRECT_DNS;
    return acc;
  }, {});

  const directRuleSetsForChinaDNS = [
    "rule-set:cn",
    "rule-set:google-cn",
    "rule-set:synology",
    "rule-set:googlefcm",
    "rule-set:epicgames",
    "rule-set:nvidia@cn",
    "rule-set:microsoft@cn",
    "rule-set:cloudflare@cn",
    "rule-set:steam@cn",
    "rule-set:category-game-platforms-download@cn",
    "rule-set:category-ntp",
    "rule-set:connectivity-check",
    "rule-set:apple",
    "rule-set:spotify",
    "rule-set:microsoft"
  ];

  const fullFakeIpFilter = uniq([
    "+.cn",
    "rule-set:cloudflare",
    "rule-set:private",

    ...directRuleSetsForChinaDNS,
    ...STATIC_FAKE_IP_FILTER,
    ...fakeIpFilterFromCfg
  ]);

  cfg.dns = {
    ...dns,
    enable: true,
    // 只服务本机的 DNS 模块（TUN dns-hijack 走内核内部转发，不依赖对外监听）
    listen: "127.0.0.1:1053",
    // 顶层 ipv6 为假时，内核会把 AAAA 查询回成空应答（withResolver），
    // 顶层为真而这一项为假时，域名解析同样拿不到 AAAA——只有 IPv6 字面量流量能走通。
    ipv6: ENABLE_IPV6,
    // fake-ip 模式下 AAAA 由独立的 v6 池分配，池为空时内核只回空应答（withFakeIP）。
    "fake-ip-range6": ENABLE_IPV6 ? FAKE_IP_RANGE6 : "",
    "cache-algorithm": "arc",
    "prefer-h3": false,
    "use-hosts": true,
    "use-system-hosts": true,
    "respect-rules": true,
    "enhanced-mode": "fake-ip",
    "fake-ip-filter-mode": "blacklist",
    // 关键链路域名必须拿真实 IP：fake-ip 映射不落盘（store-fake-ip=false），
    // 内核重启后旧 fake-ip 失配会让客户端连到失效地址（表现为超时/重置）
    "fake-ip-filter": uniq([...fullFakeIpFilter, ...CRITICAL_DOMAINS]),
    "default-nameserver": ["223.5.5.5", "119.29.29.29"],
    "nameserver-policy": {
      "rule-set:category-ai-!cn": aiDNS,
      ...criticalNameserverPolicy
    },
    nameserver: foreignDNS,
    "proxy-server-nameserver": [
      "https://doh.pub/dns-query#DIRECT",
      "https://dns.alidns.com/dns-query#DIRECT"
    ],
    "direct-nameserver": chinaDNS
  };

  cfg.hosts = {
    "dns.alidns.com": ["223.5.5.5", "223.6.6.6"],
    "doh.pub": ["1.12.12.12", "120.53.53.53"],
    "services.googleapis.cn": ["services.googleapis.com"],
    "+.mcdn.bilivideo.com": ["0.0.0.0"],
    "+.mcdn.bilivideo.cn": ["0.0.0.0"]
  };
};

const applyProfile = (cfg) => {
  cfg.profile = {
    ...(cfg.profile || {}),
    "store-selected": true,
    "store-fake-ip": false
  };
};

const applyIPv6 = (cfg) => {
  // 顶层开关。Bettbox 会在脚本跑完之后用应用内「IPv6」开关覆写这一项，
  // 所以这里主要是给其它 mihomo 客户端的默认值，也是本脚本 dns.ipv6 生效的前提。
  cfg.ipv6 = ENABLE_IPV6;
};

const applyRuntime = (cfg) => {
  cfg.mode = "rule";
  cfg["log-level"] = "warning";
};

// ====================
// 7. 主流程
// ====================
function main(config) {
  config = ensureConfigObject(config);

  const originalProxies = getOriginalProxies(config);
  const existingRules = Array.isArray(config.rules) ? config.rules : [];

  config["rule-providers"] = {
    ...(config["rule-providers"] || {}),
    ...buildRuleProviders()
  };

  config.rules = mergeRules(STATIC_RULES, pickDirectRules(existingRules));

  if (originalProxies.length) {
    makeProxyNamesUnique(originalProxies);

    // 1. 先用 CUSTOM_FILTER 过滤掉不想要的节点
    const filteredProxies = filterCustomProxies(originalProxies, CUSTOM_FILTER);

    // 2. 再用 INFO_FILTER 分离信息节点和正常节点
    const { infoProxies, normalProxies } = splitInfoAndNormalProxies(
      filteredProxies,
      SETTINGS.INFO_FILTER
    );

    const baseProxies = normalProxies;
    const allNames = uniq(baseProxies.map((p) => p.name));
    const infoNames = uniq(infoProxies.map((p) => p.name));

    const {
      activeRegions,
      activeRegionNameSet,
      activeRegionMap,
      otherProxyNames
    } = classifyProxiesByRegion(baseProxies, REGIONS);

    const allAiNames = buildAllAiProxyList(activeRegions, otherProxyNames, allNames);

    config["proxy-groups"] = buildProxyGroups({
      allNames,
      allAiNames,
      activeRegionMap,
      activeRegionNameSet,
      otherProxyNames,
      infoNames
    });

    // 保留所有原始节点（包括被 CUSTOM_FILTER 过滤的）
    config.proxies = originalProxies;
  } else {
    config["proxy-groups"] = buildProxyGroups({
      allNames: [],
      allAiNames: [],
      activeRegionMap: new Map(),
      activeRegionNameSet: new Set(),
      otherProxyNames: [],
      infoNames: []
    });
  }

  removeGeoDataConfig(config);
  applyRuntime(config);
  applyIPv6(config);
  applySniffer(config);
  applyTun(config);
  applyDns(config);
  applyProfile(config);

  return config;
}
