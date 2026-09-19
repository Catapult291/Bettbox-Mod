# 相对上游 Bettbox 的改动清单

- 基线：`appshubcc/Bettbox` `main` @ `70b6077`（2026-09-10）
- 对应提交：`feat: 本地改动（IP 检测源 / 脚本页规则区块 / 规则目标分组过滤）`
- 查看完整差异：`git diff <导入提交> HEAD`

---

## 1. 首页网络检测：IP 来源与探测策略

**文件**：`lib/common/request.dart`　**测试**：`test/models/ip_geoip_parse_test.dart`

**问题**：代理运行时首页仍显示国内 IP。原因是探测源以国内服务为主，而国内域名在常见规则集里常被判
`GEOIP,CN,DIRECT` 直连，返回的是本机真实 IP 而不是代理出口；同时原实现把所有源并发结果合并，不同源
返回不同 IP 时会拼出“中国 · United States”这类 IP 与国家错配的脏数据。

**改动**：

- 新增 `_getOverseasIpSources()`：`https://api.ip.sb/geoip` → `www.cloudflare.com` / `cp.cloudflare.com` /
  `cloudflare.com` 的 `/cdn-cgi/trace` → `https://api.ipify.org?format=json`（配置了 token 时附
  `api.ipinfo.io`）。这些都是境外域名，代理运行时经本地代理端口出站，能反映真实出口。
- `_getPrimaryIpSources()` 精简为国内回退源 `api.myip.la`（按语言中/英）。
- 新增 `_probeIpSourcesSequential()` 取代原并发的 `_checkIpFromSources()`：逐源探测、**成功即返回、不做跨源合并**；
  整体超时预算（默认 5s）均摊到各源，避免多源串行时累计超时过长；支持取消。
- 删除从未接线的死代码 `checkIpCloudflare()` / `checkIpDomesticCloudflare()` 及其来源列表。
- 新增 `_tryParseIpInfo()`：把 `api.ip.sb/geoip` 的扁平 snake_case JSON 归一化为 ip-api 风格键
  （`country_code`→`countryCode`、`region`→`regionName`、`organization`→`org`、数字 `asn` 自动补 `AS` 前缀），
  复用 `IpInfo.fromJson` 的既有映射；Cloudflare trace 文本仍走 `IpInfo.fromCloudflareTrace`。
- `checkIp()`：先探测国外源，全部失败才回退国内源（代理未连通 / 规则限制时展示真实网络）；
  `checkIpDomestic()` 行为不变。

---

## 2. 脚本页「规则」区块（UI 添加规则）

**文件**：`lib/views/profiles/scripts.dart`、`lib/models/config.dart`、`lib/providers/config.dart`、
`lib/state.dart`、`arb/intl_*.arb`、`lib/l10n/*`
**测试**：`test/models/script_added_rules_test.dart`

**需求**：不写脚本也能在应用内给当前配置追加规则，且这些规则优先级最高（覆盖全局规则）。

**改动**：

- 数据层：`ScriptProps` 新增 `List<String> addedRules`（JSON 键 `added-rules`，默认空列表）与
  `hasAddedRules`；`ScriptState` 新增 `addAddedRule`（插队首）、`updateAddedRule`（原位替换）、
  `deleteAddedRules`（批量删除）。生成文件 `config.freezed.dart` / `config.g.dart` 已手工同步。
- 运行时注入：`state.dart` 的 `patchRawConfig` 中，`scriptActive` 判定改为
  「有生效脚本 **或** 有 UI 规则」且开启脚本覆写；开启覆写且存在 UI 规则时，把规则前置到规则列表顶部，
  即「覆盖全局规则」语义（没有脚本、只开覆写时同样生效）。
- UI：脚本页列表末尾新增「规则」区块——标题 + 副标题（`scriptRuleTip`，中文为「覆盖全局规则」）+
  「添加」按钮；规则行支持长按进入多选，顶栏出现编辑 / 删除按钮，编辑态隐藏设置按钮与新增悬浮按钮；
  空列表显示空态提示。添加规则时会取当前配置的最终分组作为目标（脚本覆写开启且有生效脚本时，
  先执行一次脚本取结果）。
- 多语言：7 个 `arb` 文件与对应 `lib/l10n/intl/messages_*.dart`、`lib/l10n/l10n.dart` 新增 `scriptRuleTip`。
- 兼容迁移：双脚本角色方案回退后，历史配置里残留的 `rule-script-id` 会在 `Config.compatibleFromJson`
  中提升为 `currentId`，保证这批用户的规则脚本继续生效。

---

## 3. 覆写页「添加规则」的目标分组与代理页一致

**文件**：`lib/views/profiles/override_profile.dart`　**测试**：`test/views/profiles/rule_target_groups_test.dart`

**问题**：添加规则时的目标分组下拉里会混入内核内部使用的子分组（如 fallback 子组）与隐藏分组，
和代理页展示的分组范围不一致。

**改动**：新增 `getRuleTargetGroups()`——与代理页 `getVisibleGroups` 同口径：

- 配置里显式定义了 `GLOBAL` 时，只列出 `GLOBAL` 的成员（即顶层分组）；未显式定义时不过滤成员
  （内核会自动生成包含全部分组的 `GLOBAL`）。
- 按「显示隐藏项」设置决定是否包含 `hidden` 分组；关闭时不显示。

`AddRuleDialog` 由此改为 `ConsumerStatefulWidget` 以读取该设置，下拉项使用过滤后的分组。

---

## 4. 配置「跟随更新」开关与编辑页单配置更新

**文件**：`lib/models/profile.dart`（含生成文件 `lib/models/generated/profile.freezed.dart`、`profile.g.dart`）、
`lib/views/profiles/edit_profile.dart`、`lib/views/profiles/profiles.dart`、`arb/intl_*.arb`、`lib/l10n/*`
**测试**：`test/models/profile_follow_update_test.dart`、`test/views/profiles/sync_all_targets_test.dart`

**需求**：配置页右上角的「全部同步」要能排除部分配置；被排除的配置只能在自己的编辑页里手动更新。

**改动**：

- 数据层：`Profile` 新增 `followUpdate`（JSON 键 `follow-update`，默认 **开启**）。默认开启保证老配置升级后
  仍是原来的「全部同步」行为。
- UI（编辑页）：`自动更新` 下方新增「跟随更新」开关，与 URL / 自动更新等一起随保存写入。
- UI（编辑页）：右上角新增更新按钮（仅订阅型配置出现），点击后按当前表单内容更新这一个配置——
  不受「跟随更新」开关影响，也不必先保存退出；更新成功弹短提示 `updateSuccess`、失败弹 `updateFailed`，
  都是约 1.6s 自动消失、点击穿透、不推动列表。提示占位在「跟随更新」与「配置」两行之间的分隔槽内
  （与列表分隔等高的 24px 槽位 + `OverflowBox` 溢出绘制），因此出现与消失都不改变列表布局；提示本身
  水平居中于该留白带，底色取主题色彩（成功 `primary`/`onPrimary`，失败 `error`/`onError`），随「主题色彩」
  设置与明暗模式变化。
- UI（编辑页）：更新失败不再走全局错误弹框（原来是标题为「提示」、正文为「配置导入失败…」的对话框），
  只弹上述 `updateFailed` 提示；提示第二行附一句简短原因（HTTP 错误只报状态码，如 `HTTP 404`；其它错误取
  原始错误文本，压成一行、最多两行超出省略），原始错误仍写进应用日志（`commonPrint.log` → 日志页）。
- `AppController.updateProfile` 改为返回 `bool`（同一配置已有更新在途时返回 false），使上面的成功提示
  只在真正完成更新时出现。
- UI（配置页）：右上角「全部同步」改为只更新订阅型且开启「跟随更新」的配置（`getSyncAllTargets`）；
  「自动更新」（定时/启动补更）与卡片菜单里的单条「同步」不受该开关影响。
- 多语言：7 个 `arb` 与对应的 `lib/l10n/intl/messages_*.dart`、`lib/l10n/l10n.dart` 新增 `followUpdate`、
  `updateSuccess`、`updateFailed`。

---

## 5. 右侧快捷控制栏（出站模式 / 系统代理 / 虚拟网卡）

**文件**：`lib/widgets/quick_controls.dart`（新增）、`lib/manager/app_manager.dart`、`lib/widgets/widgets.dart`

**需求**：不想为了切换「出站模式 / 系统代理 / 虚拟网卡」先回到首页；三项控件放左侧导航栏放不下（窄栏容不下带文字的三项）。

**改动**：

- 新增 `QuickSidebar`（`app_manager.dart`）与 `QuickControls`（`lib/widgets/quick_controls.dart`）：页面**右侧**常驻一条
  与左侧导航栏**等宽**的快捷栏，自上而下是出站模式 / 系统代理 / 虚拟网卡，每个控件下方带一行四字小字标签
  （`labelSmall`；英文标签允许折两行）。出站模式方块下再补一行当前模式名，避免只靠底色记状态。
- 出站模式是 44×44 圆角方块，
  底色随当前模式变化（与首页 `OutboundModeV2` 同一套语义色：规则 `secondaryContainer`、全局
  `darken3PrimaryContainer`、直连 `tertiaryContainer`），点击按枚举顺序循环切换；其下是系统代理、虚拟网卡两个同规格
 开关，开启态用 `primary` 20%（浅色）/ 26%（深色）底色 + `primary` 图标，与导航栏选中项同款。
- 核心未启动（`runTimeProvider == null`）时两个开关禁用并降到 38% 不透明度，与托盘菜单「核心运行时才给这两个开关」
  的口径一致；出站模式始终可切（改的是配置）。
- 系统代理 / 虚拟网卡仅在桌面渲染，与首页 `DashboardWidget` 的 `desktopPlatforms` 限定一致；右侧栏本身在桌面布局
  （非移动布局）下始终显示，窗口拉窄到手机布局时与左侧栏一起消失。
- 宽度对齐：`AppSidebarContainer` 改为 `ConsumerStatefulWidget`，用 `GlobalKey` 量出左栏实际宽度（含其 1px 右边框），
  post-frame 回写后传给 `QuickSidebar(width: 实测 - 1)`——左栏宽度随标签长度（语言）变化，写死会错位。
- 与左侧导航项对齐：右栏第一个控件（出站模式方块）的中心与左栏第一个导航项（首页）的图标中心齐平。左栏图标的纵向位置
  随平台（macOS 多 22px 的窗口按钮带）与标签长度变化，所以不写死：`AppSidebarContainer` 在第一个导航项的图标上挂
  `GlobalKey`，post-frame 量出它相对左栏顶部的中心偏移，减去控件半高后传给 `QuickSidebar(topOffset:)`；量不到时退回
  跟随页面标题栏的老位置（`kToolbarHeight / 2 - quickControlSize / 2`）。
- 窗口按钮组（图钉 / 最小化 / 最大化 / 关闭）落回窗口右边缘：自绘顶栏（色带 + 按钮）由 `AppSidebarContainer` 渲染，
  横跨「页面内容 + 右侧快捷栏」，色带因此从左侧导航栏右边框一直延伸到**窗口右边缘**，按钮组贴在色带右端。
  为此把右侧快捷栏从 `Row` 的直接子项改成内容区 `Stack` 里 `right: 0` 的一层，页面内容则加 `Padding(right: 左栏实测宽度)`
  让出同样宽度——页面自身的布局与改动前逐像素一致；`WindowHeaderContainer` 只保留「给顶栏留高度」的留白。
- 切换统一走 `appController.updateMode / updateSystemProxy / updateTun`，与托盘菜单、全局快捷键同一入口。
- 该位置在 `MaterialApp.builder` 内、Navigator 之上，**没有 `Overlay`**，因此不能用 `Tooltip`；无障碍标签改用
  `Semantics`，悬停反馈靠 `Material`/`InkWell` 自带高亮。

**验证**：Android x86_64 模拟器宽屏布局（`wm size 1600x900` + `wm density 160`）实测：右栏三行（中文四字标签一行排下）、
任意页面常驻、点模式方块后底色与模式名、首页「出站模式」滑块同步变化；像素级实测左右两栏等宽（中英文下均为 81px）。
`flutter analyze lib test` 仅剩基线告警，`flutter test` 34/34。详见 `.grok/stage-log.md` 第 5 节（含未验证项：本机无法出
Windows 包）。

**Windows 桌面实测（同一节，后一版）**：出站模式方块中心与左栏「首页」图标中心逐像素重合（135.5 对 135.5，1365×930 窗口；
137.5 对 137.5，1920×1140 最大化；扩展栏 `showLabel` 下 144.5 对 144.5），方块顶部都在 40px 顶栏色带之下；顶栏色带宽度实测
= 从左侧导航栏右边框（含扩展栏时是其实际宽度）一直铺到窗口右边缘（右侧余量 0~1.3 逻辑px），关闭按钮墨迹距窗口右边缘
约 13~15 逻辑px（按钮盒子贴边，与 Windows 标题栏按钮的观感一致）。手机布局（宽 467 逻辑px）下两条侧栏一起消失、色带铺满整宽、
按钮组仍在右上角。截图：`sidebar-preview/31-windows-topbar-extend-window.png`（窗口）、`32-…-max.png`（最大化）、
`33-…-laptop.png`（宽 800 的 laptop 布局）、`34-…-mobile.png`（手机布局）、`35-…-showlabel.png`（扩展左栏）。

---

## 6. 其他

- `analysis_options.yaml`：analyzer 排除 `build/**`、`android/**`、`windows/**`、`macos/**`、`linux/**`，
  避免 `flutter analyze` 被平台侧生成代码与构建产物淹没。

---

## 附：上游已自行实现、本仓库不再单列的改动

- **访问控制列表排序稳定性**：原 `lib/models/selector.dart` 中「链式两次排序 + Dart 不稳定排序」问题，
  上游已在提交 `79cf06e`（Optimize android access control list sorting）中修复，实现与本仓库此前的
  修法等价（单次复合比较器 + 兜底包名比较）。本仓库直接采用上游实现。
