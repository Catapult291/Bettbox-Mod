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

## 5. 右侧快捷控制栏（总开关 / 系统代理 / 虚拟网卡 / 出站模式）

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
- 方块下方那行模式名的文字色取同色族的 `secondary` / `primary` / `tertiary`，不用方块图标的前景色 `on*Container`：后者是为方块自身的 `*Container` 底色挑的，`content` 配色下 `onPrimaryContainer` / `onTertiaryContainer` 接近白色，放到浅色侧栏底上对比度只有约 1.2:1（全局 / 直连模式下模式名几乎看不见，深色主题下同样偏低）。改后各配色变体、深浅两套相对侧栏底色 `surfaceContainerHigh` 都在 5:1 以上，规则模式的观感基本不变。
- 核心未启动（`runTimeProvider == null`）时两个开关禁用并降到 38% 不透明度，与托盘菜单「核心运行时才给这两个开关」
  的口径一致；出站模式始终可切（改的是配置）。
- 系统代理 / 虚拟网卡仅在桌面渲染，与首页 `DashboardWidget` 的 `desktopPlatforms` 限定一致。
- 右侧栏本身只在**桌面平台**（Windows / macOS / Linux）渲染：Android 平板等设备同样是「非移动布局」、也会走到
  `AppSidebarContainer` 的非移动分支，所以 `showQuickRail = system.isDesktop` 是必需的平台判断——不加它移动端会多出
  一条栏（页面内容的 `Padding(right:)` 随之在非桌面下归零，不占宽度）。窗口拉窄到手机布局时与左侧栏一起消失。
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
按钮组仍在右上角。截图：`archive/screenshots/sidebar/31-windows-topbar-extend-window.png`（窗口）、`32-…-max.png`（最大化）、
`33-…-laptop.png`（宽 800 的 laptop 布局）、`34-…-mobile.png`（手机布局）、`35-…-showlabel.png`（扩展左栏）。

**模式名可读性（2026-09-20）**：新增 `test/widgets/quick_controls_caption_test.dart`，按 `QuickSidebar` 的摆法渲染三种模式 × 深浅两套，
断言模式名文字相对侧栏底色 `surfaceContainerHigh` 的对比度 > 4.5:1（改前浅色下全局 / 直连只有 1.20:1，用例会红）；并把控件渲染成
PNG 目视核对（浅色下三个模式名都是深色字，深色下都是浅色字）。`flutter analyze lib test` 仍只剩 `lib/clash/core.dart` 的基线告警，
`flutter test` 65/65。

**总开关 + 控件顺序（2026-09-20）**：右栏新增总开关 `_PowerButton` 并排到最上，自上而下改为
**总开关 / 系统代理 / 虚拟网卡 / 出站模式**；对齐基准随之从出站模式方块改为总开关（用户不再要求模式方块与「首页」对齐）。

- 总开关与首页「电源开关」卡片、首页顶栏那个开关、托盘菜单共用 `appController.updateStatus()`（开 = 重新下发配置 + 起核心，
  关 = 停核心 + 收掉系统代理/TUN，见第 13 节的答疑记录）。它是右栏唯一能启动核心的入口：核心没跑时下面两个开关都是禁用的，
  所以它同时充当「核心在跑没跑」的常驻指示——运行中为 `primary` 20%（浅色）/ 26%（深色）底色 + `primary` 图标，
  与右栏两个开关的开启态同一表达式。
- 可点条件与首页两处同口径（`isInit && hasProfile && !isRestarting && !isSmartStopped`）：无配置 / 未初始化 / 智能停机挂起时
  不可点并降到 38% 灰。点按期间的乐观态保持运行中的配色，避免启动中闪过一次灰。
- **不开「添加配置」弹层**：右栏在 `MaterialApp.builder` 之上、没有 Navigator 祖先，首页卡片那套 `showExtend` 在这里会挂；
  无配置时就是禁用态。
- 对齐量法未改（`_syncRailMetrics` 量的仍是左栏「首页」图标中心，`topOffset = 图标中心 - quickControlSize / 2`）：
  首个控件换成同规格 44px 方块后自动生效，无需改 `app_manager.dart` 的测量逻辑。
- 矮窗口：`QuickSidebar` 的 `Column` 外套 `SingleChildScrollView`——四个控件加标签在最小窗口高度（400 逻辑px）下已贴底，
  英文标签折行时改动前的写法会溢出（实测 `RenderFlex overflowed by 0.7 pixels`）；内容不超高时滚动视图与原来的 `Column` 无差别。

**验证**：新增 `test/widgets/quick_controls_power_button_test.dart`（7 例）：控件自上而下的顺序、首控件是 44px 方块且顶边为 0
（右栏「中心对齐」契约的前提）、核心未启动时仍可点且图标为 `onSurfaceVariant`、运行中为 `primary` 图标 + 20% 底色、
无配置时不可点且 38% 灰、zh/en 两种语言在 400 逻辑px 高下都不溢出（en 那例在改动前会红）。`flutter test` 72/72、
`flutter analyze lib test` 仅剩基线告警。Windows 真机（探针实跑，1365×930 物理、150% 缩放）：右栏首个控件（电源图标）墨迹中心
y=135.5，左栏「首页」图标墨迹中心 y=135.5，**差 0.0 px**；右栏四行自上而下确为 电源 / 系统代理 / 虚拟网卡 / 出站模式（后三者的
图标在核心未启动时都是 38% 灰，与配置一致）。产物 `Bettbox-1.19.1-windows-x64-sidebar-power/`（129.1MB，`Bettbox.exe` SHA256
`4317A533…EBCC5794`，与第 6/7 节同一份 exe——只有 Dart AOT 变了）。

**右栏限定为桌面平台（2026-09-20）**：Android 平板这类设备同样会走「非移动布局」，右栏原本也会出现。改为
`showQuickRail = system.isDesktop`（非桌面时页面内容的 `Padding(right:)` 同时归零），移动端不再渲染右栏。

**验证（Android A/B 实跑）**：同一台 x86_64 模拟器（`nnhanman_test`，`wm size 1600x900` + `wm density 160`，即非移动布局）上
依次安装改动前的 debug 包（`Bettbox-1.19.1-qr-import-debug.apk`，Sep 19 23:58）与本次新包：改动前右边缘有一条常驻栏，
「出站模式 / 规则」可见（系统代理与虚拟网卡因非桌面本就隐藏）；改动后右栏消失、首页卡片区吃满整宽，左侧导航栏与页面布局不变。
截图 `archive/screenshots/android-wide-before-2.png`、`android-wide-after-2.png`。`flutter test` 72/72、
`flutter analyze lib test` 仅剩 `lib/clash/core.dart:197` 基线告警（新包构建命令：
`flutter build apk --debug --target-platform android-x64 --android-skip-build-dependency-validation`）。

---

## 6. 从 URL 导入：不填名称时自动获取配置名称

**文件**：`lib/common/utils.dart`、`lib/models/profile.dart`、`lib/views/profiles/edit_profile.dart`、
`arb/intl_*.arb`、`lib/l10n/*`　**测试**：`test/models/profile_name_resolve_test.dart`

**需求**：导入订阅只填 URL、不填名称，应用自动取到该订阅的名称（与 Pandora-Box 一致）。

**问题**：取名只认 `content-disposition` 响应头，而多数订阅面板不返回该头，于是回落到配置 id
（毫秒时间戳），配置页里显示的是一串数字。

**改动**：

- 新增 `utils.getProfileName()`：取名优先级 `profile-title` 响应头 → `content-disposition` 文件名 →
  URL 末段路径（去查询串、百分号解码；末段为空时退回主机名）。都取不到返回 null，由调用方兜底。
- 新增 `utils.getProfileNameForTitle()`：`profile-title` 兼容 `base64:` 前缀（base64 编码的 UTF-8，
  多数订阅面板的写法）与百分号编码两种写法，解不出内容返回 null。
- `Profile.update()`：名称改用上述优先级链推导，用户填写的名称仍最优先；名称为空（含历史数据里的
  空串）时才回填，最终兜底仍是配置 id。
- UI（导入页）：名称输入框在新建配置时提示「留空则自动获取名称」；编辑已有配置时不出该提示
  （编辑页名称必填）。
- 多语言：7 个 `arb` 与对应的 `lib/l10n/intl/messages_*.dart`、`lib/l10n/l10n.dart` 新增 `autoGetNameTip`。

**验证**：`flutter analyze lib test` 仅剩基线告警（`lib/clash/core.dart:197`），`flutter test` 全部通过
（新增 13 例：取名来源优先级、`profile-title` 的 base64/百分号编码、URL 末段与主机名兜底，以及一例
真实 HTTP + dio 的端到端用例，确认服务端以 `Profile-Title` 混合大小写发送时生产代码的小写键名可取到值）。
未在应用内跑通一次真实订阅导入（本机会被动接管系统代理 / TUN，故未启动应用）。

---

## 7. 二维码导入：桌面端补上纯 Dart 解码

**文件**：`lib/common/qr_reader.dart`（新增）、`lib/common/picker.dart`、`lib/pages/scan.dart`、
`pubspec.yaml`　**测试**：`test/common/qr_import_test.dart`

**问题**：Windows（以及 Linux）上「导入 → 二维码 → 选图片」永远失败，提示信息是一串插件异常。
`mobile_scanner` 的 `pubspec.yaml` 只声明了 android / ios / macos / web 四个平台，它的
`analyzeImage` 直接走 `MethodChannel('dev.steenbakker.mobile_scanner/scanner/method')`，桌面端没有对应
的原生实现，调用即抛 `MissingPluginException`。上游原版是同一份代码，同样失败，属于上游缺陷，
非本仓库改动引入。

**改动**：

- 新增 `QrReader`：用 `zxing2`（ZXing 的 Dart 移植）+ `image` 做纯 Dart 解码（`qrcode.dart` 的
  `QRCodeReader` + `HybridBinarizer`）。长边超过 2000px 的图先等比缩小，避免大图产生几百 MB 的像素缓冲；
  图片损坏、非图片、无二维码、无二维码可识别等情况都返回 null，不抛异常。
- `Picker.decodeProfileUrlFromQrImage()`：解码 + 校验为 URL，失败抛 `pleaseUploadValidQrcode`；
  `pickerConfigQRCode()` 只负责选图后转调它，便于脱离文件对话框做测试。
- 平台策略：Android / iOS / macOS 仍优先用 `mobile_scanner` 原生识别，原生报错或没识别出内容时再退回
  Dart 解码；Windows / Linux 直接走 Dart。
- `lib/pages/scan.dart` 相机扫码：原来要求 `barcode.type == BarcodeType.url` 才回传，而该类型由各平台
  自行推断（Apple 端是插件里的启发式判断），类型判错就会静默什么都不导入；改为按内容判断
  （`rawValue` 是 URL 即回传），并加 `_handled` 防止一次扫码重复 pop。

**验证**：`flutter analyze lib test` 仅剩基线告警（`lib/clash/core.dart:197`）；`flutter test` 全部通过
（新增 9 例：合成截图、合成二维码、非 URL 内容、超长边大图缩放、无码图片、坏文件，以及 picker 入口的
URL 校验与失败提示）。

- 用户提供的失败截图（`PixPin_2026-09-19_21-54-16.png`）在本机通过 `picker.decodeProfileUrlFromQrImage()`
  解出 `https://niva.fyi/s/34e9c0655bd7305e4994d123a04b5d96`，即用户遇到的那张二维码现已可导入。
- 该截图带用户的订阅令牌，**未入库**；测试夹具改为测试内生成的合成图片（灰底 + 白卡片 + 二维码）。
- 未在运行中的应用里点完「二维码 → 选图 → 导入」：应用启动会接管系统代理 / TUN，且当前已有一个实例在运行
  （Windows runner 的 `activate_existing` 会让新实例只去激活旧窗口），故验证停在「picker 入口 + 解码」这一层。
  构建产物已复制到工作区根目录 `Bettbox-1.19.1-windows-x64-qr/`。

---

## 8. 扫码成功后的转场：识别成功 → 直接换成「从 URL 导入」页

**文件**：`lib/pages/scan.dart`、`lib/common/navigator.dart`、`lib/widgets/sheet.dart`、
`lib/views/profiles/add_profile.dart`　**测试**：`test/common/base_navigator_replace_test.dart`

**问题**（两轮反馈）：相机扫码识别成功后跳到「从 URL 导入」页太快、像瞬间跳页；随后用户明确要求**不要**先退回
「添加配置」页再进导入页。原因有两层：① 识别到就立刻 pop，没有「已识别」的落点；② `Navigator.push` 的 future
在退出动画**开始**时就完成（`Route.didComplete` 在 pop 时即被调用），调用方紧接着 push 导入页，于是「扫码页滑出」
与「导入页滑入」两个转场同时进行、互相穿越；而若改成「先等它退完再推」，中间那一页（添加配置页）就会明显闪一下。

**改动**：

- `ScanPage`：识别成功后进入 `_success` 状态显示对勾（绿色圆形 + 白色对勾，`easeOutBack` 缩放淡入），停留
  500ms（`_successHold`）作为「已识别」的落点。
- `ScanPage.onRecognized`：新增可选回调，识别成功后的去处交给调用方；不传时维持原行为（带 URL pop 回上一页，
  并有 `ModalRoute.isCurrent` 兜底：停顿期间用户已自行关掉扫码页时不再多退一层）。
- `BaseNavigator.replaceWith()`：新增，用 `pushReplacement` 把当前路由换成新页面，被替换的页面不再留在返回栈里；
  与 `push` 共用 `_buildRoute`。
- `showExtend(..., replace: true)`：`lib/widgets/sheet.dart` 新增可选参数，移动端整页分支改用 `replaceWith`
  （桌面端是侧边 sheet，不涉及）。
- `AddProfileView`：`_toScan()` 传 `onRecognized: _toImportAfterScan`；`_handleAddProfileFormURL` 新增
  `replaceContext`，扫码路径用它 + `replace: true` 打开导入页。剪贴板 / URL 项两条路径不变（仍是压栈）。
- 上一版「等退出动画播完再 push」（`awaitPopTransition`）已移除：它解决了转场重叠，但会露出中间页。
- 横屏 / 宽窗口（`viewMode != mobile`）下导入页是侧边 sheet、没有整页可替换：这时先 `pop` 掉扫码页再打开
  sheet，避免扫码页留在返回栈里（这是改动前横屏的原有行为，不做会变成回归）。

**验证**：`flutter test` 59/59 通过（新增 2 例：`showExtend(replace: true)` 之后返回落在添加配置页、扫码页已不在
栈里；默认 `replace: false` 仍是压栈）；`flutter analyze lib test` 仅剩基线告警 `lib/clash/core.dart:197`。

Android 模拟器（`nnhanman_test`，x86_64，1080×2340）实跑新包：`配置 → 添加配置 → 二维码` 正常打
开扫码页（相机预览、扫码框、相册按钮齐全，无崩溃），说明 `ScanPage(onRecognized:)` 与整页路由在真实运行
时没问题。**识别成功那一步没能在模拟器上触发**：虚拟场景的墙上海报 656×656、不在扫码框范围内，虚拟相机也无法
用 `adb emu`（`virtualscene-image` 只能换海报、`rotate` 只能转设备）摆到海报墙前，所以「对勾 → 替换成导入页」
的实际观感仍需真机确认（见未决问题）。

**未决问题**：

- 若还嫌导入页滑入太快，可以单独为这次替换调长转场时长（现在沿用 `CupertinoPageRoute` 的 500ms）。
- 顺带查清、**未改**：`ScannerOverlay` 的暗色遮罩看不到，但扫描框白框是能画出来的（模拟器实机已确认）。
  遮罩用 `BlendMode.dstOut` 擦除画布，而相机预览是 `Texture`（由合成器绘制），canvas 的 dstOut 擦不掉它，
  于是只剩白色边框可见。要遮罩生效需要在自绘层里 `saveLayer` 后再 dstOut，或直接用不透明遮罩——不影响功能，没动。

---

## 9. 其他

- `analysis_options.yaml`：analyzer 排除 `build/**`、`android/**`、`windows/**`、`macos/**`、`linux/**`，
  避免 `flutter analyze` 被平台侧生成代码与构建产物淹没。

---

## 附：上游已自行实现、本仓库不再单列的改动

- **访问控制列表排序稳定性**：原 `lib/models/selector.dart` 中「链式两次排序 + Dart 不稳定排序」问题，
  上游已在提交 `79cf06e`（Optimize android access control list sorting）中修复，实现与本仓库此前的
  修法等价（单次复合比较器 + 兜底包名比较）。本仓库直接采用上游实现。
