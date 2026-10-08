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

// 自定义节点过滤：命中的节点从所有节点组里剔除（节点本身仍留在 proxies）。正则字面量
// （/官网|剩余/i）和字符串（"官网|剩余"，按不区分大小写编译）都接受；null = 不过滤任何节点。
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

  // 不钉 timeout：写死 1 秒会把跨境节点里 TLS 握手偏慢（常见 0.8~2.5 s）的那些判死，而实时
  // 故障切换靠 max-failed-times 已经能保证（连续失败即触发一次健康检查）。不写 timeout 时
  // Bettbox 会按应用内「健康检查超时」写入（patch_config 只在组没有 timeout 时才写），
  // 其它内核用默认 5000。
  URL_TEST_EXTRA: {
    hidden: true,
    url: "https://example.com/generate_204",
    interval: 900,
    tolerance: 100,
    lazy: true,
    "max-failed-times": 1,
  },

  // 同上：不钉 timeout，交给应用设置 / 内核默认
  FALLBACK_TEST_EXTRA: {
    url: "https://example.com/generate_204",
    interval: 900,
    lazy: true,
    "max-failed-times": 1,
  },

  // `tg` 是短代号，必须带字母/数字边界：旧写法会把「HKTG-01」「SG-TG01」这类真实节点当成
  // 信息节点，判成信息节点后它就不进任何节点组。带分隔符的 TG / Telegram 仍按信息节点处理
  // ——公告节点远比「专为 TG 优化的节点」常见，宁可贵一点。若订阅里真有叫 TG-01 的节点，
  // 把这一项里的 `(?:^|[^a-z0-9])tg(?:[^a-z0-9]|$)|` 整段删掉即可。
  INFO_FILTER: /(?:^|[^a-z0-9])tg(?:[^a-z0-9]|$)|telegram|倒卖|到期|电报|订阅|发布|防止|返利|购买|官方|官网|工单|过期|规则|建议|客服|联系|流量|剩余|失联|网址|邮箱|续费|邀请|重置|梯子|群/i
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

// provider 模式的地区筛选用：正则跑在内核（regexp2，默认区分大小写）里、匹配的是原始
// 节点名，所以要用内联 (?i)；2~3 个字母的地区代号要加字母边界，否则 HK 会命中「HKTG」。
const buildRegionFilter = (arr = []) =>
  "(?i)" +
  arr
    .map((raw) => {
      const token = String(raw).trim();
      const escaped = escapeRegex(token);
      return /^[A-Za-z]{2,3}$/.test(token)
        ? `(?:^|[^A-Za-z])${escaped}(?:[^A-Za-z]|$)`
        : escaped;
    })
    .join("|");

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
  ]).map((r) => ({ ...r, regex: buildRegex(r.pattern), filter: buildRegionFilter(r.pattern) }));

const REGIONS = buildRegions();
const REGION_META = new Map(REGIONS.map((r) => [r.name, r]));

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

// 订阅自带的直连规则要插在「第一条泛化代理规则」之前：旧做法插在 MATCH 之前，它们排在
// RULE-SET,gfw,main 与 ai/tg 分类规则之后，对 gfw 域名根本轮不到生效（等于白留）。
// 锚点选 gfw 而不是所有指向代理组的规则，有两处有意保留的优先级：
//   * FORCE_PROXY_DOMAINS 那几条是网络检测的锚点，要保持脚本可控；
//   * ai / tg 的分类优先（AI 走独立出口降风控、Telegram 直连在部分网络不通）。
// 想让订阅规则连这两类也盖过去，把锚点换成 /,(?:main|ai|tg)$/ 即可。
const EXTRA_RULES_ANCHOR = /^RULE-SET,gfw,main$/i;

const mergeRules = (baseRules = [], extraRules = []) => {
  const extra = Array.isArray(extraRules) ? extraRules.filter(Boolean) : [];
  if (!extra.length) return baseRules.slice();

  let insertIndex = baseRules.findIndex((rule) => EXTRA_RULES_ANCHOR.test(String(rule).trim()));
  if (insertIndex === -1) {
    insertIndex = baseRules.findIndex(
      // 注意：左侧已 toUpperCase，右侧也必须是全大写——旧写法的 "MATCH,main" 永远不相等，
      // 于是保留下来的 profile 直连规则被追加到 MATCH 之后，成为永不生效的死规则。
      (rule) => String(rule).trim().toUpperCase() === "MATCH,FINAL"
    );
  }

  if (insertIndex === -1) return uniq([...baseRules, ...extra]);

  return uniq([
    ...baseRules.slice(0, insertIndex),
    ...extra,
    ...baseRules.slice(insertIndex)
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

// 无可用节点（既无内联 proxies 也无 proxy-providers）时用的规则：与 STATIC_RULES 同序，
// 只把指向代理组的那几条降级成 DIRECT。内核 parseRules 对不存在的规则目标直接报
// "rules[N] [RULE-SET,gfw,main] error: proxy [main] not found" 并拒绝整份配置（连 DNS
// 都不生效），不是回退直连，所以这不是美观问题。
const STATIC_RULES_NO_NODES = STATIC_RULES.map((rule) =>
  /^(?:RULE-SET|DOMAIN|DOMAIN-SUFFIX),[^,]+,(?:main|ai|tg)$/.test(rule)
    ? rule.replace(/,(?:main|ai|tg)$/, ",DIRECT")
    : rule
);

const STATIC_FAKE_IP_FILTER = buildFakeIpFilter(BYPASS_DOMAINS);

// ====================
// 4. 节点处理
// ====================
const ensureConfigObject = (input) =>
  input && typeof input === "object" ? input : {};

const getOriginalProxies = (input) =>
  Array.isArray(input.proxies) ? input.proxies : [];

// proxy-providers 的键：这类订阅的节点不在 config.proxies 里，只在运行期由 provider 提供。
// 旧版只看 proxies，于是 provider 型订阅会走进「无节点」分支。
const getProxyProviders = (input) => {
  const providers = input && input["proxy-providers"];
  return providers && typeof providers === "object" ? Object.keys(providers) : [];
};

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

// 过滤器统一成 RegExp：字符串按不区分大小写编译（旧注释写「用 | 分割」，直接传字符串会
// 在 .test 上抛 TypeError，脚本整体失败并回退上一份配置）。正则非法只警告一次并退化为
// 「不过滤」——留一个笔误就废掉整份配置的代价更大。
const toFilterRegex = (filter) => {
  if (!filter) return null;
  if (filter instanceof RegExp) return filter;
  try {
    return new RegExp(String(filter), "i");
  } catch (err) {
    console.warn(`CUSTOM_FILTER 不是合法正则，已忽略：${String(filter)}（${err}）`);
    return null;
  }
};

const filterCustomProxies = (proxies = [], customFilter) => {
  const filter = toFilterRegex(customFilter);
  if (!filter) return proxies.slice();   // 未配置过滤器：全保留
  return proxies.filter((proxy) => {
    if (!proxy || !proxy.name) return false;
    return !filter.test(proxy.name);
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

// 排除 HK 的节点名单。旧版在「无非 HK 节点」时退回全量（含 HK），于是只有 HK 节点的订阅
// 里 AI 仍然走 HK；这里返回空，由 buildProxyGroups 把 ai 组指向 main（AI 跟随主组）。
const buildAllAiProxyList = (activeRegions = [], otherProxyNames = []) =>
  uniq([
    ...activeRegions.filter((r) => r.name !== "HK").flatMap((r) => r.proxies),
    ...otherProxyNames
  ]);

// ====================
// 5. 策略组
// ====================
// 节点来源有两种，可同时存在：
//   * 内联节点（config.proxies）→ 显式名单建组，能按名字做地区/AI 分类；
//   * proxy-providers → `use` + `filter`/`exclude-filter` 建组，节点名运行期才知道，
//     分类交给内核正则在组内筛。filter 只作用于 provider 带来的节点，显式名单始终保留
//     （内核 groupbase.GetProxies 只对 provider 节点套 filterRegs）。
// 代价：provider 型订阅在组之前拿不到节点名，INFO_FILTER 与「地区内具体有哪些节点」都
// 只能交给内核正则，公告类节点会照规则留在地区组里。
const buildProxyGroups = ({
  allNames,
  allAiNames,
  activeRegionMap,
  activeRegionNameSet,
  otherProxyNames,
  infoNames,
  providers
}) => {
  const groups = [];
  const hasNodes = allNames.length > 0 || providers.length > 0;
  const hasProvider = providers.length > 0;
  const hasAllAi = allAiNames.length > 0 || hasProvider;

  const add = (name, type, proxies = [], icon = "Available.png", extra = {}) => {
    const list = uniq(Array.isArray(proxies) ? proxies : []);
    const use = uniq(extra.use || []);
    // 显式名单与 use 都空才算空组：只靠 use 的组（provider 模式）不能按名单长度判空
    if (!name || (!list.length && !use.length)) return;
    groups.push({
      name,
      type,
      ...(use.length ? { use } : {}),
      proxies: list,
      icon: SETTINGS.ICON_BASE + icon,
      ...extra
    });
  };

  // provider 模式下给叶子组补 use（地区筛选交给 filter）
  const withProviders = (extra = {}) => (hasProvider ? { ...extra, use: providers } : extra);

  // 这里原本还有一个 hidden 的 `fcm` 组（["DIRECT"]），但没有任何规则或分组引用它，
  // 而 FCM 已由 STATIC_RULES 的 RULE-SET,googlefcm,DIRECT 直接判直连，故删除。
  // 想要「FCM 从哪个出口走」的手动开关：把那条规则的 DIRECT 换成 fcm，并去掉 hidden。

  // 有哪些地区组：内联侧出现过的地区；provider 模式下三个地区组都建（内容运行期筛）
  const regionEntries = SETTINGS.REGION_ORDER.filter((rName) => {
    const meta = REGION_META.get(rName);
    return meta && (activeRegionNameSet.has(rName) || hasProvider);
  });

  // main 组
  if (hasNodes) {
    const mainEntries = ["All", ...regionEntries];
    if (otherProxyNames.length) mainEntries.push("Other");
    add("main", "select", mainEntries, "Available.png");
  }

  // final 组：规则全部落空后的兜底出口（MATCH,final）。可选「前面各策略组」+ DIRECT，
  // 想改兜底走向时不用动规则；默认第一项是 main，与旧版 MATCH,main 行为一致。
  // 该组永远存在（至少含 DIRECT），因此无可用节点时也不会出现悬空的 MATCH 目标。
  const finalEntries = [
    ...(hasNodes ? ["main", "ai", "tg"] : []),
    ...regionEntries,
    ...(otherProxyNames.length ? ["Other"] : []),
    "DIRECT"
  ];
  add("final", "select", finalEntries, "Final.png");

  // All 组
  if (hasNodes) {
    add("URL Test - All", "url-test", allNames, "Auto.png", withProviders({ ...SETTINGS.URL_TEST_EXTRA }));
    add("All", "select", ["URL Test - All", ...allNames], "Auto.png");
  }

  // ai 组（含地区子分组，排除 HK）与它的全量组
  if (hasNodes) {
    const aiRegionEntries = SETTINGS.REGION_ORDER.filter(
      (rName) => rName !== "HK" && regionEntries.includes(rName)
    );
    const aiEntries = [
      ...(hasAllAi ? ["All-ai"] : []),
      ...aiRegionEntries,
      ...(otherProxyNames.length ? ["Other"] : [])
    ];
    // 只有 HK 节点（无非 HK 节点、也无 provider）时不能退回「含 HK 的全量」——旧版会在
    // 只有 HK 的订阅上把 AI 交给 HK。改成指向 main：语义是「AI 跟随主组」，且不生成悬空组。
    if (!aiEntries.length) aiEntries.push("main");
    add("ai", "select", aiEntries, "ChatGPT.png");

    if (hasAllAi) {
      add(
        "URL Test - All-ai",
        "url-test",
        allAiNames,
        "ChatGPT.png",
        withProviders({
          ...SETTINGS.URL_TEST_EXTRA,
          // provider 侧的排除 HK 只能靠 exclude-filter（名单里没有 provider 节点名）
          ...(hasProvider ? { "exclude-filter": REGION_META.get("HK").filter } : {})
        })
      );
      add("All-ai", "select", ["URL Test - All-ai", ...allAiNames], "ChatGPT.png");
    }
  }

  // tg 组（原优先 SG，SG 已并入 TW_SG_JP_KR，改为优先合并组）
  if (hasNodes) {
    const hasAsia4 = activeRegionNameSet.has("TW_SG_JP_KR") || hasProvider;

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
    const meta = REGION_META.get(rName);
    if (!meta) return;
    const inline = activeRegionMap.get(rName);
    const inlineNames = inline ? inline.proxies : [];
    if (!inline && !hasProvider) return;

    add(
      `URL Test - ${rName}`,
      "url-test",
      inlineNames,
      meta.icon,
      withProviders({ ...SETTINGS.URL_TEST_EXTRA, ...(hasProvider ? { filter: meta.filter } : {}) })
    );
    add(rName, "select", [`URL Test - ${rName}`, ...inlineNames], meta.icon);
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
      ...(hasNodes ? ["main", "All"] : []),
      ...(hasNodes ? ["ai"] : []),
      ...(hasAllAi ? ["All-ai"] : []),
      ...(hasNodes ? ["tg"] : []),
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

// 注：这一整段在 Bettbox 里基本被应用侧补丁覆盖（enable / device / stack / dns-hijack /
// auto-route / auto-detect-interface / auto-redirect / strict-route 都由应用写入，见
// rust/bettbox-native/src/patch_config.rs），这里主要是给其它 mihomo 客户端的默认值；
// 在 Bettbox 里真正由脚本决定的是规则、DNS 与分组。
const applyTun = (cfg) => {
  cfg.tun = {
    ...(cfg.tun || {}),
    enable: true,
    stack: "system",
    "auto-route": true,
    "auto-detect-interface": true,
    "strict-route": true,
    // 只留 any:53：内核会把 `tcp://any:53` 的前缀裁掉、any 换成 0.0.0.0，与 any:53 完全相同
    // （listener/sing_tun/server.go），而 TUN 的 dns-hijack 本来就同时接管 UDP/TCP。
    "dns-hijack": ["any:53"]
  };
};

// hasProxyGroups=false 表示这份配置没有任何节点（无 main/ai 组），DNS 里就不能再引用它们。
const applyDns = (cfg, { hasProxyGroups = true } = {}) => {
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

  // 没有代理组时不能再用 `#main`：内核找不到这个名字时会把它当**网卡名**去绑定
  // （tunnel/dns_dialer.go: Proxies()[name] 未命中就 dialer.WithInterface(name)），
  // 结果是这些 nameserver 的查询直接失败，而不是回落直连。
  const directForeignDNS = foreignDNS.map((s) => s.replace(/#main$/, "#DIRECT"));

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
    // 订阅自带的 nameserver-policy 合并进来，脚本点名的键以脚本为准。内核的 policy 键按最长
    // 匹配生效、没有真正的全捕获键（`*` 只匹配单标签域名），故订阅里宽泛的键最多影响它点名的
    // 那部分域名；真遇到塞了 `+.com` 这类宽泛键的订阅，把下面第一行展开去掉即可。
    "nameserver-policy": {
      ...(dns["nameserver-policy"] || {}),
      ...(hasProxyGroups ? { "rule-set:category-ai-!cn": aiDNS } : {}),
      ...criticalNameserverPolicy
    },
    nameserver: hasProxyGroups ? foreignDNS : directForeignDNS,
    "proxy-server-nameserver": [
      "https://doh.pub/dns-query#DIRECT",
      "https://dns.alidns.com/dns-query#DIRECT"
    ],
    "direct-nameserver": chinaDNS
  };

  // 合并而不是整段覆盖：订阅自带的 hosts 条目保留下来，同名的以脚本为准（脚本这几条分别是
  // DoH 引导与定向屏蔽，必须由脚本说了算）。
  cfg.hosts = {
    ...(cfg.hosts || {}),
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
  const providers = getProxyProviders(config);
  const existingRules = Array.isArray(config.rules) ? config.rules : [];

  config["rule-providers"] = {
    ...(config["rule-providers"] || {}),
    ...buildRuleProviders()
  };

  makeProxyNamesUnique(originalProxies);

  // 1. 先用 CUSTOM_FILTER 过滤掉不想要的节点
  const filteredProxies = filterCustomProxies(originalProxies, CUSTOM_FILTER);

  // 2. 再用 INFO_FILTER 分离信息节点和正常节点
  const { infoProxies, normalProxies } = splitInfoAndNormalProxies(
    filteredProxies,
    SETTINGS.INFO_FILTER
  );

  const allNames = uniq(normalProxies.map((p) => p.name));
  const infoNames = uniq(infoProxies.map((p) => p.name));

  const {
    activeRegions,
    activeRegionNameSet,
    activeRegionMap,
    otherProxyNames
  } = classifyProxiesByRegion(normalProxies, REGIONS);

  // 排除 HK 的名单；无非 HK 节点时为空，由分组逻辑把 ai 指向 main
  const allAiNames = buildAllAiProxyList(activeRegions, otherProxyNames);

  // 有节点 = 内联节点或 proxy-providers 任一非空；规则的组目标只有在这时才合法
  const hasNodes = allNames.length > 0 || providers.length > 0;

  // 无节点时把指向 main/ai/tg 的规则降级成 DIRECT：内核 parseRules 对不存在的目标直接
  // 报 "proxy [main] not found" 并拒绝整份配置，不会回退直连。
  config.rules = mergeRules(
    hasNodes ? STATIC_RULES : STATIC_RULES_NO_NODES,
    pickDirectRules(existingRules)
  );

  // 保留所有原始节点（包括被 CUSTOM_FILTER 过滤的）
  config.proxies = originalProxies;
  config["proxy-groups"] = buildProxyGroups({
    allNames,
    allAiNames,
    activeRegionMap,
    activeRegionNameSet,
    otherProxyNames,
    infoNames,
    providers
  });

  removeGeoDataConfig(config);
  applyRuntime(config);
  applyIPv6(config);
  applySniffer(config);
  applyTun(config);
  applyDns(config, { hasProxyGroups: hasNodes });
  applyProfile(config);

  return config;
}
