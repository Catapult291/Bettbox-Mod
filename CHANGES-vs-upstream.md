# 相对上游 Bettbox 的改动清单

- 基线：`appshubcc/Bettbox` `main` @ `70b6077`（2026-09-10）；上游补丁跟进至 `31893466`（2026-09-28）
- 范围：导入提交 `19d5e118` 之后的全部本地提交（含文档与构建配置类提交，归入第 9 节）
- 查看完整差异：`git diff 19d5e118 HEAD`
- 本仓库当前版本：`1.19.7`（tag `v1.19.7` 已发布 Release）

各节「验证」里的 `flutter test` 计数为编写当时的实测值，随用例增加依次变大（34 → 65 → 72 → 85）。
文中提到的截图与构建产物均为本机验证留存，**未入库**，仅作为该步骤已执行的记录。

## 目录与发布版本对照

| 节 | 领域 | 改动 | 首个包含它的版本 |
| --- | --- | --- | --- |
| 1 | 首页 | 首页网络检测：IP 来源与探测策略 | v1.19.1 |
| 2 | 界面 | 脚本页「规则」区块（UI 添加规则） | v1.19.1 |
| 3 | 界面 | 「添加规则」的目标分组与代理页一致 | v1.19.1 |
| 4 | 界面 | 配置「跟随更新」开关与编辑页单配置更新 | v1.19.2 |
| 5 | 界面 | 右侧快捷控制栏（总开关 / 系统代理 / 虚拟网卡 / 出站模式） | v1.19.2 |
| 6 | 导入 | 从 URL 导入：不填名称时自动获取配置名称 | v1.19.2 |
| 7 | 导入 | 二维码导入：桌面端补上图片解码 | v1.19.2（解码改引擎优先：v1.19.3） |
| 8 | 导入 | 扫码成功后的转场 | v1.19.2 |
| 9 | 仓库工程 | 其他（CI、忽略规则、对外文案） | v1.19.1 起持续 |
| 10 | 内存 | 内存占用：数据层与展示口径调整 | v1.19.3 |
| 11 | 稳定性 | 首页总开关与内核状态脱节、界面挂起 | v1.19.3 |
| 12 | 稳定性 | 总开关被「半死内核」锁死：后台刷新不抢锁 + 启动前自动重启 | v1.19.4 |
| 13 | 稳定性 | 恢复过程看得见 + 关闭旧 socket 挂死整条启动链 | v1.19.4 |
| 14 | 稳定性 | 启动判据改为 mixed-port 真的在监听 | v1.19.4 |
| 15 | 上游跟进 | 吸收上游 09-10～09-28 的健壮性补丁（A1–A6 / B1–B4） | v1.19.5 |
| 16 | 更新 | 应用内「检查更新」指向本仓库 | v1.19.1 |
| 17 | 更新 | 「更多」页入口与 Windows 安装包发布者链接指向本仓库 | v1.19.6 |
| 18 | 界面 | 「关于」页去上游内容、名称改 Bettbox-mod、发布者字段改本仓库作者 | v1.19.7 |

---

## 1. 首页网络检测：IP 来源与探测策略

**文件**：`lib/common/request.dart`　**测试**：`test/models/ip_geoip_parse_test.dart`

**问题**：代理运行时首页仍显示国内 IP。原因是探测源以国内服务为主，而国内域名在常见规则集里常被判
`GEOIP,CN,DIRECT` 直连，返回的是本机真实 IP 而不是代理出口；同时原实现把所有源并发结果合并，不同源
返回不同 IP 时会拼接出「中国 · United States」这类 IP 与国家错配的脏数据。

**改动**：

- 新增 `_getOverseasIpSources()`：`https://api.ip.sb/geoip` → `www.cloudflare.com` / `cp.cloudflare.com` /
  `cloudflare.com` 的 `/cdn-cgi/trace` → `https://api.ipify.org?format=json`（配置了 token 时附
  `api.ipinfo.io`）。这些均为境外域名，代理运行时经本地代理端口出站，能反映真实出口。
- `_getPrimaryIpSources()` 精简为国内回退源 `api.myip.la`（按语言中/英）。
- 新增 `_probeIpSourcesSequential()` 取代原并发的 `_checkIpFromSources()`：逐源探测、**成功即返回、不做跨源合并**；
  整体超时预算（默认 5s）均摊到各源，避免多源串行时累计超时过长；支持取消。
- 删除从未被引用的死代码 `checkIpCloudflare()` / `checkIpDomesticCloudflare()` 及其来源列表。
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

**需求**：无需编写脚本即可在应用内为当前配置追加规则，且这些规则优先级最高（覆盖全局规则）。

**改动**：

- 数据层：`ScriptProps` 新增 `List<String> addedRules`（JSON 键 `added-rules`，默认空列表）与
  `hasAddedRules`；`ScriptState` 新增 `addAddedRule`（插入队首）、`updateAddedRule`（原位替换）、
  `deleteAddedRules`（批量删除）。生成文件 `config.freezed.dart` / `config.g.dart` 已手工同步。
- 运行时注入：`state.dart` 的 `patchRawConfig` 中，`scriptActive` 判定改为
  「有生效脚本 **或** 有 UI 规则」且开启脚本覆写；开启覆写且存在 UI 规则时，把规则前置到规则列表顶部，
  即「覆盖全局规则」语义（没有脚本、只开覆写时同样生效）。
- UI：脚本页列表末尾新增「规则」区块——标题 + 副标题（`scriptRuleTip`，中文为「覆盖全局规则」）+
  「添加」按钮；规则行支持长按进入多选，顶栏出现编辑 / 删除按钮，编辑态隐藏设置按钮与新增悬浮按钮；
  空列表显示空态提示。添加规则时取当前配置的最终分组作为目标（脚本覆写开启且有生效脚本时，
  先执行一次脚本取结果）。
- 多语言：7 个 `arb` 文件与对应 `lib/l10n/intl/messages_*.dart`、`lib/l10n/l10n.dart` 新增 `scriptRuleTip`。
- 兼容迁移：双脚本角色方案回退后，历史配置里残留的 `rule-script-id` 会在 `Config.compatibleFromJson`
  中提升为 `currentId`，保证这批用户的规则脚本继续生效。

---

## 3. 脚本页「添加规则」的目标分组与代理页一致

**文件**：`lib/views/profiles/override_profile.dart`　**测试**：`test/views/profiles/rule_target_groups_test.dart`

**问题**：添加规则时的目标分组下拉中混入了内核内部使用的子分组（如 fallback 子组）与隐藏分组，
与代理页展示的分组范围不一致。

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

**需求**：配置页右上角的「全部同步」需支持排除部分配置；被排除的配置仅能在其编辑页内手动更新。

**改动**：

- 数据层：`Profile` 新增 `followUpdate`（JSON 键 `follow-update`，默认 **开启**）。默认开启以保证既有
  配置升级后仍保持原「全部同步」行为。
- UI（编辑页）：`自动更新` 下方新增「跟随更新」开关，与 URL / 自动更新等一起随保存写入。
- UI（编辑页）：右上角新增更新按钮（仅订阅型配置出现），点击后按当前表单内容更新该配置，
  不受「跟随更新」开关影响，也无需先保存退出。更新成功弹短提示 `updateSuccess`、失败弹 `updateFailed`，
  两者均约 1.6s 自动消失、点击穿透、不使列表产生位移。提示占位在「跟随更新」与「配置」两行之间的分隔槽内
  （与列表分隔等高的 24px 槽位 + `OverflowBox` 溢出绘制），因此出现与消失都不改变列表布局；提示本身
  水平居中于该留白带，底色取自主题色彩（成功 `primary`/`onPrimary`，失败 `error`/`onError`），随「主题色彩」
  设置与明暗模式变化。
- UI（编辑页）：更新失败不再使用全局错误弹框（原来是标题为「提示」、正文为「配置导入失败…」的对话框），
  只弹上述 `updateFailed` 提示。提示第二行附一句简短原因（HTTP 错误只报状态码，如 `HTTP 404`；其它错误取
  原始错误文本，压缩为一行、最多两行超出省略），原始错误仍写入应用日志（`commonPrint.log` → 日志页）。
- `AppController.updateProfile` 改为返回 `bool`（同一配置已有更新在途时返回 false），使上面的成功提示
  只在确实完成更新时出现。
- UI（配置页）：右上角「全部同步」改为只更新订阅型且开启「跟随更新」的配置（`getSyncAllTargets`）；
  「自动更新」（定时/启动补更）与卡片菜单中的单条「同步」不受该开关影响。
- 多语言：7 个 `arb` 与对应的 `lib/l10n/intl/messages_*.dart`、`lib/l10n/l10n.dart` 新增 `followUpdate`、
  `updateSuccess`、`updateFailed`。

---

## 5. 右侧快捷控制栏（总开关 / 系统代理 / 虚拟网卡 / 出站模式）

**文件**：`lib/widgets/quick_controls.dart`（新增）、`lib/manager/app_manager.dart`、`lib/widgets/widgets.dart`

**需求**：切换「出站模式 / 系统代理 / 虚拟网卡」无需回到首页；左侧导航栏放不下这三项（窄栏容不下带文字的三项）。

**改动**：

- 新增 `QuickSidebar`（`app_manager.dart`）与 `QuickControls`（`lib/widgets/quick_controls.dart`）：页面**右侧**常驻一条
  与左侧导航栏**等宽**的快捷栏，自上而下是出站模式 / 系统代理 / 虚拟网卡，每个控件下方有一行四字小字标签
  （`labelSmall`；英文标签允许折两行）。出站模式方块下方再补一行当前模式名，避免只依赖底色表示状态。
- 出站模式是 44×44 圆角方块，
  底色随当前模式变化（与首页 `OutboundModeV2` 同一套语义色：规则 `secondaryContainer`、全局
  `darken3PrimaryContainer`、直连 `tertiaryContainer`），点击按枚举顺序循环切换；其下是系统代理、虚拟网卡两个同规格
 开关，开启态用 `primary` 20%（浅色）/ 26%（深色）底色 + `primary` 图标，与导航栏选中项一致。
- 方块下方那行模式名的文字色取同色族的 `secondary` / `primary` / `tertiary`，不用方块图标的前景色 `on*Container`。后者是为方块自身的 `*Container` 底色配置的，`content` 配色下 `onPrimaryContainer` / `onTertiaryContainer` 接近白色，放到浅色侧栏底上对比度只有约 1.2:1（全局 / 直连模式下模式名难以辨认，深色主题下同样偏低）。改后各配色变体、深浅两套相对侧栏底色 `surfaceContainerHigh` 都在 5:1 以上，规则模式的观感基本不变。
- 核心未启动（`runTimeProvider == null`）时两个开关禁用并降到 38% 不透明度，与托盘菜单「核心运行时才启用这两个开关」
  的口径一致；出站模式始终可切换（修改的是配置）。
- 系统代理 / 虚拟网卡仅在桌面渲染，与首页 `DashboardWidget` 的 `desktopPlatforms` 限定一致。
- 右侧栏本身只在**桌面平台**（Windows / macOS / Linux）渲染：Android 平板等设备同样是「非移动布局」、也会走到
  `AppSidebarContainer` 的非移动分支，所以 `showQuickRail = system.isDesktop` 是必需的平台判断——不加它移动端会多出
  一条栏（页面内容的 `Padding(right:)` 随之在非桌面下归零，不占宽度）。窗口收窄到手机布局时与左侧栏同时消失。
- 宽度对齐：`AppSidebarContainer` 改为 `ConsumerStatefulWidget`，用 `GlobalKey` 测得左栏实际宽度（含其 1px 右边框），
  post-frame 回写后传给 `QuickSidebar(width: 实测 - 1)`；左栏宽度随标签长度（语言）变化，采用固定值会错位。
- 与左侧导航项对齐：右栏第一个控件（出站模式方块）的中心与左栏第一个导航项（首页）的图标中心齐平。左栏图标的纵向位置
  随平台（macOS 多 22px 的窗口按钮带）与标签长度变化，因此不做硬编码：`AppSidebarContainer` 在第一个导航项的图标上挂
  `GlobalKey`，post-frame 测得它相对左栏顶部的中心偏移，减去控件半高后传给 `QuickSidebar(topOffset:)`；测量失败时
  退回原先跟随页面标题栏的位置（`kToolbarHeight / 2 - quickControlSize / 2`）。
- 窗口按钮组（图钉 / 最小化 / 最大化 / 关闭）落回窗口右边缘：自绘顶栏（色带 + 按钮）由 `AppSidebarContainer` 渲染，
  横跨「页面内容 + 右侧快捷栏」，色带因此从左侧导航栏右边框一直延伸到**窗口右边缘**，按钮组贴在色带右端。
  为此把右侧快捷栏从 `Row` 的直接子项改成内容区 `Stack` 里 `right: 0` 的一层，页面内容则加 `Padding(right: 左栏实测宽度)`
  让出同样宽度，页面自身的布局与改动前逐像素一致。`WindowHeaderContainer` 仅保留「给顶栏留高度」的留白。
- 切换统一走 `appController.updateMode / updateSystemProxy / updateTun`，与托盘菜单、全局快捷键同一入口。
- 该位置在 `MaterialApp.builder` 内、Navigator 之上，**没有 `Overlay`**，因此不能使用 `Tooltip`；无障碍标签改用
  `Semantics`，悬停反馈依赖 `Material`/`InkWell` 自带的高亮。

**验证**：Android x86_64 模拟器宽屏布局（`wm size 1600x900` + `wm density 160`）实测：右栏三行（中文四字标签一行排下）、
任意页面常驻、点击模式方块后底色与模式名、首页「出站模式」滑块同步变化；像素级实测左右两栏等宽（中英文下均为 81px）。
`flutter analyze lib test` 仅剩基线告警，`flutter test` 34/34（当时本机尚无法产出 Windows 包，桌面实测见下一段）。

**Windows 桌面实测（同一节，后一版）**：出站模式方块中心与左栏「首页」图标中心逐像素重合（135.5 对 135.5，1365×930 窗口；
137.5 对 137.5，1920×1140 最大化；扩展栏 `showLabel` 下 144.5 对 144.5），方块顶部均位于 40px 顶栏色带之下；顶栏色带宽度实测
= 从左侧导航栏右边框（含扩展栏时是其实际宽度）一直延伸至窗口右边缘（右侧余量 0~1.3 逻辑px），关闭按钮墨迹距窗口右边缘
约 13~15 逻辑px（按钮盒子贴边，与 Windows 标题栏按钮的观感一致）。手机布局（宽 467 逻辑px）下两条侧栏同时消失、色带铺满整宽、
按钮组仍在右上角。以上五种形态（窗口、最大化、宽 800 的 laptop 布局、手机布局、扩展左栏）均有截图核对。

**模式名可读性（2026-09-20）**：新增 `test/widgets/quick_controls_caption_test.dart`，按 `QuickSidebar` 的摆放方式渲染三种模式 × 深浅两套，
断言模式名文字相对侧栏底色 `surfaceContainerHigh` 的对比度 > 4.5:1（改前浅色下全局 / 直连只有 1.20:1，该用例会失败）；并把控件渲染成
PNG 人工核对（浅色下三个模式名都是深色字，深色下都是浅色字）。`flutter analyze lib test` 仍只剩 `lib/clash/core.dart` 的基线告警，
`flutter test` 65/65。

**总开关 + 控件顺序（2026-09-20）**：右栏新增总开关 `_PowerButton` 并排列到最上方，自上而下改为
**总开关 / 系统代理 / 虚拟网卡 / 出站模式**；对齐基准随之从出站模式方块改为总开关（用户不再要求模式方块与「首页」对齐）。

- 总开关与首页「电源开关」卡片、首页顶栏的开关、托盘菜单共用 `appController.updateStatus()`。它是右栏唯一能启动核心的入口：
  核心未运行时下方两个开关均为禁用，所以它同时充当「核心是否运行」的常驻指示——运行中为 `primary` 20%（浅色）/
  26%（深色）底色 + `primary` 图标，与右栏两个开关的开启态同一表达式。
- 可点条件与首页两处同口径（`isInit && hasProfile && !isRestarting && !isSmartStopped`）：无配置 / 未初始化 / 智能停机挂起时
  无法点击且不透明度降到 38%。点按期间的乐观态保持运行中的配色，避免启动过程中出现一次灰显。
- **不开「添加配置」弹层**：右栏在 `MaterialApp.builder` 之上、没有 Navigator 祖先，首页卡片那套 `showExtend` 在这里不可用；
  无配置时保持禁用。
- 对齐测量方式未改（`_syncRailMetrics` 的测量目标仍是左栏「首页」图标中心，`topOffset = 图标中心 - quickControlSize / 2`）：
  首个控件换成同规格 44px 方块后自动生效，无需改 `app_manager.dart` 的测量逻辑。
- 小尺寸窗口：`QuickSidebar` 的 `Column` 外增加 `SingleChildScrollView`。四个控件加标签在最小窗口高度（400 逻辑px）下已接近底部，
  英文标签折行时改动前的写法会溢出（实测 `RenderFlex overflowed by 0.7 pixels`）；内容不超高时滚动视图与原来的 `Column` 无差别。

**验证**：新增 `test/widgets/quick_controls_power_button_test.dart`（7 例）：控件自上而下的顺序、首控件是 44px 方块且顶边为 0
（右栏「中心对齐」契约的前提）、核心未启动时仍可点击且图标为 `onSurfaceVariant`、运行中为 `primary` 图标 + 20% 底色、
无配置时无法点击且为 38% 不透明度灰显、zh/en 两种语言在 400 逻辑px 高下都不溢出（en 用例在改动前会失败）。`flutter test` 72/72、
`flutter analyze lib test` 仅剩基线告警。Windows 真机（探针实测，1365×930 物理、150% 缩放）：右栏首个控件（电源图标）墨迹中心
y=135.5，左栏「首页」图标墨迹中心 y=135.5，**差 0.0 px**；右栏四行自上而下确为 电源 / 系统代理 / 虚拟网卡 / 出站模式（后三者的
图标在核心未启动时均为 38% 不透明度灰显，与配置一致）。本次验证用的 Windows 包与第 6/7 节是同一份 exe（只有 Dart AOT 变化）。

**右栏限定为桌面平台（2026-09-20）**：Android 平板这类设备同样会走「非移动布局」，改动前右栏也会出现。改为
`showQuickRail = system.isDesktop`（非桌面时页面内容的 `Padding(right:)` 同时归零），移动端不再渲染右栏。

**验证（Android A/B 真机验证）**：同一台 x86_64 模拟器（`nnhanman_test`，`wm size 1600x900` + `wm density 160`，即非移动布局）上
依次安装改动前的 debug 包与本次新包：改动前右边缘有一条常驻栏，
「出站模式 / 规则」可见（系统代理与虚拟网卡因非桌面本就隐藏）；改动后右栏消失、首页卡片区占满整宽，左侧导航栏与页面布局不变
（改动前后各保留一张截图核对）。`flutter test` 72/72、
`flutter analyze lib test` 仅剩 `lib/clash/core.dart:197` 基线告警（新包构建命令：
`flutter build apk --debug --target-platform android-x64 --android-skip-build-dependency-validation`）。

---

## 6. 从 URL 导入：不填名称时自动获取配置名称

**文件**：`lib/common/utils.dart`、`lib/models/profile.dart`、`lib/views/profiles/edit_profile.dart`、
`arb/intl_*.arb`、`lib/l10n/*`　**测试**：`test/models/profile_name_resolve_test.dart`

**需求**：导入订阅时只填 URL、不填名称，应用自动获取该订阅的名称（与 Pandora-Box 一致）。

**问题**：名称获取只识别 `content-disposition` 响应头，而多数订阅面板不返回该头，于是回落到配置 id
（毫秒时间戳），配置页中显示的是一串数字。

**改动**：

- 新增 `utils.getProfileName()`：名称优先级 `profile-title` 响应头 → `content-disposition` 文件名 →
  URL 末段路径（去查询串、百分号解码；末段为空时退回主机名）。均取不到时返回 null，由调用方兜底。
- 新增 `utils.getProfileNameForTitle()`：`profile-title` 兼容 `base64:` 前缀（base64 编码的 UTF-8，
  多数订阅面板的写法）与百分号编码两种写法，无法解码出内容时返回 null。
- `Profile.update()`：名称改用上述优先级链推导，用户填写的名称仍最优先；名称为空（含历史数据中的
  空串）时才回填，最终兜底仍是配置 id。
- UI（导入页）：名称输入框在新建配置时提示「留空则自动获取名称」；编辑已有配置时不显示该提示
  （编辑页名称必填）。
- 多语言：7 个 `arb` 与对应的 `lib/l10n/intl/messages_*.dart`、`lib/l10n/l10n.dart` 新增 `autoGetNameTip`。

**验证**：`flutter analyze lib test` 仅剩基线告警（`lib/clash/core.dart:197`），`flutter test` 全部通过
（新增 13 例：名称来源优先级、`profile-title` 的 base64/百分号编码、URL 末段与主机名兜底，以及一例
真实 HTTP + dio 的端到端用例，确认服务端以 `Profile-Title` 混合大小写发送时生产代码的小写键名可取到值）。
未在应用内按预期完成一次真实订阅导入（本机会被动接管系统代理 / TUN，故未启动应用）。

---

## 7. 二维码导入：桌面端补上图片解码（引擎优先，纯 Dart 兜底）

**文件**：`lib/common/qr_reader.dart`（新增）、`lib/common/picker.dart`、`lib/pages/scan.dart`、
`pubspec.yaml`　**测试**：`test/common/qr_import_test.dart`

**问题**：Windows（以及 Linux）上「导入 → 二维码 → 选图片」总是失败，提示信息为一串插件异常。
`mobile_scanner` 的 `pubspec.yaml` 只声明了 android / ios / macos / web 四个平台，它的
`analyzeImage` 直接走 `MethodChannel('dev.steenbakker.mobile_scanner/scanner/method')`，桌面端没有对应
的原生实现，调用即抛 `MissingPluginException`。上游原版是同一份代码，同样失败，属于上游缺陷，
非本仓库改动引入。

**改动**：

- 新增 `QrReader`：**首选 Flutter 引擎自带的图片解码器**（`dart:ui` 的 `ImmutableBuffer` → `ImageDescriptor`
  → `instantiateCodec`），按目标尺寸采样解码、在引擎工作线程上执行，速度比纯 Dart 快数倍（实测 12MP 照片 97ms 对
  636ms）且不占 isolate；引擎报错或无法解码的格式（TIFF 等）退回纯 Dart 解码（`image` 解码 + `zxing2` 的
  `QRCodeReader` + `HybridBinarizer`，全部在后台 isolate 里执行，12MP 照片 0.6~0.8s）。解码前把长边压到
  2000px（`maxDecodeSide`）以内，避免大图产生几百 MB 的像素缓冲；缩放后未解出时会用原图再尝试一次（小二维码
  可能因缩放丢失细节）。图片损坏、非图片、无二维码、无二维码可识别等情况均返回 null，不抛异常。
  `useEngineCodec: false` 可关闭引擎路径只走纯 Dart，测试用它比对两条路径的结果。
- `Picker.decodeProfileUrlFromQrImage()`：解码 + 校验为 URL，失败抛 `pleaseUploadValidQrcode`；
  `pickerConfigQRCode()` 只负责选图后转调它，以便脱离文件对话框进行测试。
- 平台策略：Android / iOS / macOS 仍优先用 `mobile_scanner` 原生识别，原生报错或未识别出内容时再退回
  `QrReader`；Windows / Linux 直接走 `QrReader`。
- `lib/pages/scan.dart` 相机扫码：原来要求 `barcode.type == BarcodeType.url` 才回传，而该类型由各平台
  自行推断（Apple 端是插件里的启发式判断），类型判错时会静默地不导入任何内容；改为按内容判断
  （`rawValue` 是 URL 即回传），并加 `_handled` 防止一次扫码重复 pop。
- 后续（`42cfd30e`，v1.19.3）将上面第一段的解码顺序改成引擎优先、纯 Dart 兜底，与上游 PR #489
  （`perf(qr): decode qr code images with the engine codec first`，未合并）内容相同；因为该 PR 不在上游
  `main` 的历史中，§15 的吸收清单不重复计入。

**验证**：`flutter analyze lib test` 仅剩基线告警（`lib/clash/core.dart:197`）；`flutter test` 全部通过
（`test/common/qr_import_test.dart` 现有 13 例：合成截图、合成二维码、非 URL 内容、超长边大图、大图里小二维码
退回原图、无码图片、坏文件、灰度与调色板图、引擎与纯 Dart 结果一致、引擎无法解码的文件退回纯 Dart，以及 picker 入口的
URL 校验与两条失败提示）。

- 用户提供的失败截图（`PixPin_2026-09-19_21-54-16.png`）在本机通过 `picker.decodeProfileUrlFromQrImage()`
  解出 `https://niva.fyi/s/34e9c0655bd7305e4994d123a04b5d96`，即用户提供的那张二维码现已可导入。
- 该截图含用户的订阅令牌，**未入库**；测试夹具改为测试内生成的合成图片（灰底 + 白卡片 + 二维码）。
- 未在运行中的应用里完成「二维码 → 选图 → 导入」的整条操作：应用启动会接管系统代理 / TUN，且当前已有一个实例在运行
  （Windows runner 的 `activate_existing` 会让新实例只激活旧窗口），故验证止于「picker 入口 + 解码」这一层。
  构建产物已复制到工作区根目录，属本地产物不入库。

---

## 8. 扫码成功后的转场：识别成功 → 直接换成「从 URL 导入」页

**文件**：`lib/pages/scan.dart`、`lib/common/navigator.dart`、`lib/widgets/sheet.dart`、
`lib/views/profiles/add_profile.dart`　**测试**：`test/common/base_navigator_replace_test.dart`

**问题**（两轮反馈）：相机扫码识别成功后跳到「从 URL 导入」页太快，观感类似瞬间跳页；随后用户明确要求**不要**先退回
「添加配置」页再进导入页。原因有两层：① 识别成功后立刻 pop，没有「已识别」的落点；② `Navigator.push` 的 future
在退出动画**开始**时就完成（`Route.didComplete` 在 pop 时即被调用），调用方紧接着 push 导入页，于是「扫码页滑出」
与「导入页滑入」两个转场同时进行、互相穿越；若改成「先等退出动画结束再 push」，中间那一页（添加配置页）就会明显闪现。

**改动**：

- `ScanPage`：识别成功后进入 `_success` 状态显示对勾（绿色圆形 + 白色对勾，`easeOutBack` 缩放淡入），停留
  500ms（`_successHold`）作为「已识别」的落点。
- `ScanPage.onRecognized`：新增可选回调，识别成功后的去向交给调用方；不传时维持原行为（带 URL pop 回上一页，
  并有 `ModalRoute.isCurrent` 兜底：停顿期间用户已自行关闭扫码页时不再多退一层）。
- `BaseNavigator.replaceWith()`：新增，用 `pushReplacement` 把当前路由替换为新页面，被替换的页面不再留在返回栈里；
  与 `push` 共用 `_buildRoute`。
- `showExtend(..., replace: true)`：`lib/widgets/sheet.dart` 新增可选参数，移动端整页分支改用 `replaceWith`
  （桌面端是侧边 sheet，不涉及）。
- `AddProfileView`：`_toScan()` 传 `onRecognized: _toImportAfterScan`；`_handleAddProfileFormURL` 新增
  `replaceContext`，扫码路径用它 + `replace: true` 打开导入页。剪贴板 / URL 项两条路径不变（仍是压栈）。
- 上一版「等退出动画播完再 push」（`awaitPopTransition`）已移除：它解决了转场重叠，但会显露中间页。
- 横屏 / 宽窗口（`viewMode != mobile`）下导入页是侧边 sheet、没有整页可替换：此时先 `pop` 关闭扫码页再打开
  sheet，避免扫码页留在返回栈中（这是改动前横屏的原有行为，不做会构成回归）。

**验证**：`flutter test` 59/59 通过（新增 2 例：`showExtend(replace: true)` 之后返回仍落在添加配置页、扫码页已不在
栈中；默认 `replace: false` 仍是压栈）；`flutter analyze lib test` 仅剩基线告警 `lib/clash/core.dart:197`。

Android 模拟器（`nnhanman_test`，x86_64，1080×2340）真机验证新包：`配置 → 添加配置 → 二维码` 正常打
开扫码页（相机预览、扫码框、相册按钮齐全，无崩溃），说明 `ScanPage(onRecognized:)` 与整页路由在真实运行时正常。
**识别成功那一步未能在模拟器上触发**：虚拟场景的墙上海报 656×656、不在扫码框范围内，也无法用 `adb emu`
（`virtualscene-image` 只能换海报、`rotate` 只能转设备）把虚拟相机移到海报墙前，因此「对勾 → 替换成导入页」
的实际观感仍需真机确认（见未决问题）。

**未决问题**：

- 若仍认为导入页滑入过快，可以单独为这次替换调长转场时长（现在沿用 `CupertinoPageRoute` 的 500ms）。
- 同时查清、**本次未改**：`ScannerOverlay` 的暗色遮罩不可见，但扫描框的白色边框可以正常绘制（模拟器已确认）。
  遮罩用 `BlendMode.dstOut` 擦除画布，而相机预览是 `Texture`（由合成器绘制），canvas 的 dstOut 无法擦除它，
  于是只剩白色边框可见。要让遮罩生效需要在自绘层里 `saveLayer` 后再 dstOut，或直接使用不透明遮罩；
  不影响功能，本次未改动。

---

## 9. 其他（仓库工程性改动）

- `analysis_options.yaml`：analyzer 排除 `build/**`、`android/**`、`windows/**`、`macos/**`、`linux/**`，
  避免 `flutter analyze` 的输出被平台侧生成代码与构建产物淹没。
- `.github/workflows/build.yaml`：重写为只构建本仓库要发布的三个目标——Android `arm64`、Android `universal`、
  Windows `amd64`（上游原版的矩阵另含 macOS / Linux / 其余 Android ABI）。推送 `v*` 标签时构建并创建 Release
  （标题 `Bettbox-Mod <tag>`，标签名含 `pre` 时标记为预发布）；`workflow_dispatch` 手动触发只上传构建产物、
  不创建 Release。构建时注入 `CORE_SHA256`、`APP_ENV`（stable / pre）与 `APP_ASSET_SUFFIX`，后两者决定
  应用内检查更新拼出的下载地址（见第 16 节）。
- `.gitignore`：补充位于仓库根目录的 Windows 安装包（`21cd5ec1`）——构建产物按约定复制到根目录方便取用，
  与已有的 apk / zip 忽略规则口径一致。
- 对外文案：`README.md` 的衍生仓库说明、`.github/release_template.md`、Issue 模板与仓库 About 描述统一口径
  （致谢仅保留在 README、「覆写页」改称「脚本页」；`94088230`、`2880581a`、`d4b304ef`）。同时删除
  `SIGNING-POLICY.md` 与 `.github/ISSUE_TEMPLATE/config.yml`（后者仅剩一项指向外部论坛的联系配置）；
  `SIGNING-POLICY.md` 的要点一度并入 README 的「下载注意事项」（与本仓库签名不同时的覆盖安装行为），
  现按维护者决定整体删除，本仓库不再说明签名差异。

---

## 10. 内存占用：数据层与展示口径调整

只做应用侧（Dart）的结构调整，不改代理行为、不改磁盘数据契约。

- **首页「内存信息」卡片改为显示两个数**：`应用 <值>` 是本应用自身的内存
  （`ProcessInfo.currentRss`），`内核 <值>` 仍是代理内核进程的运行堆（`clashCore.getMemory()`）。
  此前只有内核一个数，应用自身内存没有任何读数，无法观察优化效果。两者含义不同故分列显示，
  卡片下方说明文案已按此改写（7 种语言）。
- **provider 的全节点列表不再进常驻状态**：内核返回的每个 provider 都带一份完整节点字段列表，
  此前它会随 provider 一起进 `providersProvider` 单例并一直驻留。现在常驻状态只保留元数据
  （名字/类型/条目数/订阅信息/更新时间），全节点列表改为「原文进 isolate、在 isolate 内解码、
  构组完即随 isolate 释放」，主 isolate 不再物化它。分组与代理列表的内容不变，
  `test/clash/build_proxies_groups_test.dart` 覆盖「provider 节点仍会并入分组」这条行为。
- **连接页快照在窗口隐藏/后台时释放**：连接表随连接数增长，此前页面不可见时也持续保留；
  现在窗口隐藏或进入后台模式时清空，恢复窗口时页面本身就会重新拉取。
- **脚本引擎补上执行上下界**：`flutter_qjs` 的 `timeout` 与 `memoryLimit` 此前都是 0（无边界），
  现在分别为 30 秒与 256MB。正常配置脚本远达不到这两个值，用于防止失控脚本耗尽进程内存。
- **代理卡片的表情缓存加上界**（512 条，超出整体丢弃），避免大订阅下只增不减。

---

## 11. 首页总开关与内核状态脱节、界面挂起

**文件**：`lib/clash/service.dart`、`lib/clash/core.dart`、`lib/controller.dart`、`lib/state.dart`、
`lib/views/dashboard/dashboard.dart`、`lib/views/dashboard/widgets/start_button.dart`、
`lib/widgets/quick_controls.dart`、`lib/common/system.dart`、`lib/common/request.dart`、
`lib/common/constant.dart`、`arb/intl_*.arb`、`lib/l10n/*`

**问题**（官方 Windows 版同样可复现）：长时间使用后，首页总开关显示为关闭且无法点击，而系统代理
开关仍是打开——此时监听已经停止、代理并不通，走系统代理的请求全部失败；整个程序无响应，需退出并重新启动应用才恢复。

**证据**：本机 Windows 事件日志确认过真实挂起——`Application Hang`（Event ID 1002）
`Bettbox.exe 1.19.1`，`HangType = Top level window is idle`（2026-09-19 20:56，UTC+8），
同时留下 WER `AppHangB1` 报告（dump 已被系统清理）。`Top level window is idle` 的判定对象是
消息泵线程，而 Flutter Windows 的 platform thread 就是 Dart 根 isolate 所在线程：只有同步阻塞
该线程才会得到这个结果。

**定位**（两条独立成因，都属于上游共有逻辑）：

1. **启停状态与内核真实状态没有任何对账渠道**。桌面端没有内核退出通知（内核由帮助服务托管时连进程句柄都没有），
   `ClashService.checkCoreHealth()` 定义后从未被调用（改动后由状态对账调用，见下方 `reconcileCoreState`），
   socket 断开只写日志。UI 的运行状态 `runTimeProvider` 是纯内存状态，一旦停止指令没被内核应答
   （IPC 超时被 `invoke` 收敛为 `false` 后调用方丢弃），界面就停在「已关闭」，而系统代理开关读的是持久化配置位、
   仍显示打开，于是「开关关闭 + 系统代理打开」同时成立——实际监听已经停止、代理不通。`updateRunTime()` 每秒把 `startTime == null` 传播成开关关闭，
   使该错误状态每秒被固化一次。首页电源卡片又只在 `dashboardRefreshManager.tick1s` 触发时重建
   （`ref.read`），后台时 tick 停止，卡片文案会停留在旧值。
2. **启停链路上存在会阻塞消息泵的同步调用**。`Windows.runas()` 直接在根 isolate 上调用
   `ShellExecuteW(..., "runas", ...)`，会一直阻塞到用户在 UAC 对话框上作出选择；而
   `ClashService._doRestart()` 每次启动内核都会走 `registerService()`，帮助服务不健康（ping 失败）
   时就进入 `_configureHelperService()` 的提权路径。此外 `serverCompleter.future`、
   `sendMessage` 里的 `socketCompleter.future`、重启链的 `await previous.future`、
   `_restartCompleter` 以及 `_clashDio`（无任何超时）都没有上界：任一环节无限等待就会长期占用
   `_coreLifecycleLock`，此后所有启停/应用配置动作排队等待，按钮停在禁用或加载指示状态。

**改动**：

- **新增内核状态对账**（`AppController.reconcileCoreState`）：桌面端每 5 秒用一次 IPC 探测
  （`getIsInit`，2 秒超时）比对「UI 的运行状态」与「内核是否仍在」，连续两次同向才执行动作，避免开关来回跳变；
  启停动作刚结束、内核异常断开、窗口回到前台时各立即对账一次。判定「应恢复为运行中」的依据是新增的
  持久化意图 `core_listener_running`（`handleStart` / `handleStop` 维护），所以「内核进程在、监听已停」
  这种常态不会被误判为需要启动代理；该意图**在每次启动时清空**（上一次会话留下的值不能代表这次的
  期望，否则 `autoRun` 关闭时也会被它触发启动），正常退出时同样清空。
  恢复为运行中时会补一次 `startListener()`、恢复 1 秒刷新循环并提示 `coreStateResynced`；
  判定内核已退出则清空运行状态并提示 `coreExited`。
- **停止不再返回虚假成功**：`handleStop` 返回内核是否应答了停止指令，未应答时不再清空 `startTime`；
  启动动作执行完成但内核未起来（静默中止或内核没就绪）时立即对账一次。
- **启停控件超时后恢复可用**：三处总开关（首页卡片、顶栏开关、右栏快捷开关）给 `updateStatus`
  加了 120 秒上界（`updateStatusTimeout`），超时后放开按钮，状态由对账纠正；首页电源卡片改用
  `ref.watch(runTimeProvider)`，不再依赖 `tick1s`。
- **补上缺失的上界**：`ClashService` 的 `serverCompleter`、`socketCompleter`、重启链前驱、
  `destroy()` / `preload()` 各自加上超时，绑定失败时抛错而不是永久等待；IPC 断开或内核进程
  退出时回调 `onCoreDisconnected` 触发对账；`sendMessage` 在非过渡态下写失败不再 rethrow 为无人处理的异步错误。
  `_clashDio` 补 `connectTimeout: 15s` / `receiveTimeout: 30s`（后者是两次数据之间的间隔，不影响大文件下载），
  订阅地址黑洞时不再无限期占用生命周期锁。
- **`runas()` 移出 platform thread**：`ShellExecuteW` 提权改在独立 isolate 里执行，等待用户响应 UAC
  期间界面照常刷新（`NetworkFix` 的逐条提权改为串行 `await`，保持逐条弹出提权对话框的原有顺序）。

**验证**：`flutter analyze` 无问题；`flutter test` 85/85 通过；Windows release 包
（Flutter 3.44.9 + `--dart-define=APP_ENV=stable`）构建成功，
并在 `data/app.so` 中确认新代码与新文案都已编译进去（`core_listener_running`、
`Core did not acknowledge the stop request`、`Core state reconcile failed`、`coreExited`/`coreStateResynced`
的中英文案均可检索到）。该包已完成一轮真机验证：

- 启动正常（UIA 控件树可用）。点击右键栏总开关 → 内核与监听启动（`127.0.0.1:7890` 可连）、
  卡片显示运行时长、`core_listener_running` 写入为 true；再次点击 → 监听关闭、意图转 false、
  内核进程保留（内核进程存活但监听已停止，下称内核暖态）；再次点击又能启动，启停可重复执行。
- **内核暖态 + UI 已停止**的组合下，看门狗没有误把开关恢复为运行中（意图判定生效，这是本次改动最
  容易出现的假阳性）；**上一次会话被强杀留下的意图 true + 重启后自动出现的内核暖态**也没有让应用在
  `autoRun=false` 时自动启动监听（启动清空意图生效）。
- 未能在实机触发的分支：内核被强杀（`BettboxCore.exe` 由 SYSTEM 下的帮助服务托管，非提权
  `taskkill` 报「拒绝访问」）。「内核已退出 → 开关恢复为已停止 + `coreExited` 提示」这条仅在逻辑上
  成立，没有实机证据。验证时另观察到：应用在「内核未运行 + 自身 systemProxy 关闭」时会调
  `proxy.stopProxy()`，会同时清除**其他程序**设置的系统代理（`ProxyEnable` 被置 0，`ProxyServer`
  保留）——这是上游既有行为，不属于本次问题，验证后恢复原值（`ProxyEnable=1`）。

**未决问题**：

- 上述改动能在「状态脱节」这一层自愈，但**没有复现出那次真实挂起**：导致 `Top level window is idle`
  的同步阻塞点仍仅由代码审计推断（`runas` 提权与无超时的 IPC 等待是仅有的候选）。要确证需在挂起时
  获取线程调用栈：可临时开启 WER LocalDumps（`HKLM\SOFTWARE\Microsoft\Windows\Windows
  Error Reporting\LocalDumps\Bettbox.exe`，`DumpType=2`）后复现一次，再分析主线程调用栈。
- 该对账是桌面端行为；Android 端原本就有原生 `runStateChanged` 回调与 VPN 状态同步，本次未改动。

---

## 12. 总开关仍会被「半死内核」锁死：后台刷新不再抢锁 + 启动前自动重启内核

**文件**：`lib/controller.dart`、`lib/clash/service.dart`、`lib/clash/interface.dart`、
`lib/clash/core.dart`、`lib/clash/lib.dart`、`lib/state.dart`、`lib/common/constant.dart`、
`arb/intl_*.arb`、`lib/l10n/*`

**问题**：第 11 节的修复上线（v1.19.3）后用户仍在报告同一现象：总开关无明确诱因地被置为关闭并锁定，需退出并重新启动应用才能恢复。
本轮在本机用独立命名实例（`APP_DEV=true` 的 `BettboxDev` 身份，独立数据目录 / 窗口类 / 内核名）**完整复现**：
对 dev 内核进程调用 `NtSuspendProcess` 将其挂起（内核进程仍在、IPC 完全不应答）后，界面被对账恢复为「已停止」（与
用户截图一致）；此时点击右栏总开关：

```
18:48:21.801  updateStatus(start)#9 waiting (holder=updateGroups#8)   ← 用户点了开关
18:48:41.476  updateGroups#8 released (held 20615ms)                  ← 后台刷新占了 20.6 秒
18:48:41.477  updateStatus(start)#9 acquired after 19675ms            ← 开关等了 19.7 秒才拿到锁
18:48:41.479  _updateStatus(isStart=true) enter
18:50:21.803  updateStatus did not return in time                     ← 动作本身又耗 120 秒（IPC 超时）
18:50:41.502  _updateStatus(isStart=true) leave
18:50:41.504  updateGroups#10 acquired after 80644ms                  ← 排队的后台刷新等了 80 秒
```

**根因（三条，都已实测）**：

1. **后台分组刷新和启停争用同一把生命周期锁**。刷新是 60 秒一次的后台任务，但内核 IPC 不应答时
   `getProxies` 会等待至 `invoke` 的默认超时（30 秒）再乘以内部重试，于是后台刷新独占该锁 20 秒甚至
   100 秒，用户点击开关的动作排在其后。
2. **启动链路对「半死内核」没有任何恢复路径**：`setupConfig`（60 秒）与 `startListener`（30 秒）只会静默
   等到超时，没有任何一步会重启内核。「退出并重新启动应用」之所以有效，是因为退出时内核被杀掉、
   下次启动重新拉起；这一步此前只能由用户手动完成。
3. **IPC 未连接时调用方等待至超时**：`sendMessage` 在没有 socket 时丢弃消息就返回，而 `invoke` 仍会
   等待完整的 30/60 秒；`ClashService._doRestart` 中途抛错还会把 `isStarting` 永久留在 `true`，
   使健康探测与状态对账此后全部跳过。

**改动**：

- **后台刷新改用独立的 `_coreRefreshLock`**（不再占用生命周期锁），并给刷新加两层上界：单次向内核
  请求代理表 5 秒（`_groupsIpcTimeout`）、整轮刷新 15 秒（`_groupsRefreshTimeout`）。刷新内部原本就有
  `_isUpdatingGroups` 与 generation 兜底，且从不反向获取生命周期锁，因此单独使用一把锁是安全的。
- **生命周期锁加「持有过久」告警**：`_withCoreLock` 把 `updateStatus` / `restartCore` / `applyProfile` /
  `updateClashConfig` / `setupClashConfig` / `handleChangeProfile` 这些动作具名化，持锁超过 20 秒就写日志
  （`[Core] lifecycle action "xxx" has been holding the lock for Ns`），下次出现时可直接定位阻塞来源。
- **启动前先确认内核仍在应答**（`_ensureCoreReachable`）：探测失败则走控制器级重启
  （`_restartCore` = `reStart()` + 重新 `initClash`，缺少后者时新内核会被 `getIsInit` 判定为仍然不可达），
  重启成功后提示新增文案 `coreRestarted`（内核无响应，已自动重启内核），再继续下发配置、启动监听。
- **启动动作结束后的自检**：开关已显示运行中但内核仍不应答时，立即对账并恢复为已停止（`Start request left the
  core unreachable`），不再让开关停留在虚假的运行状态。
- **IPC 无连接时不再空等**：`sendMessage` 改为返回 `bool`（`interface.dart` / `service.dart` / `lib.dart`），
  `invoke` 收到 `false` 后立即按「无应答」返回默认值并清理等待者，不再空等 30/60 秒。
  `_socketReadyTimeout` 随之删除，`_waitForCoreReady` 的上界改用 `_coreReadyTimeout`。
- **`_doRestart` 拆出 `_startCore` 并补 try/finally**：任何一步抛错都不会再将 `isStarting` 留在 `true`。
- 启停链路显式上界：`startListener` 15 秒（`coreStartIpcTimeout`）、`setupConfig` 30 秒（`coreSetupIpcTimeout`），
  通过新增的可选 `timeout` 参数传入，`invoke` 默认值不变。

**验证**（`flutter analyze` 无问题、`flutter test` 85/85）：同一套「挂起 dev 内核」故障注入下，
修复后点击开关的日志为

```
19:11:48  （点总开关）
19:11:51  [Core] Core is not reachable before start, restarting it
19:11:51  restart core / Socket connection closed / Core process exited with code -1   ← 挂死的旧内核被杀
19:12:24  127.0.0.1:7891 LISTENING                                                    ← 监听恢复、内核换新
```

即「点击开关 → 自动重启内核 → 监听恢复」在有界时间内完成，不再需要退出应用；修复前的同一场景是
「开关等待 19.7 秒 + 动作耗时 120 秒 + 界面回到已停止 + 监听始终无法启动」。基线路径无回归：
内核健康时点击开关 30 余毫秒完成、`127.0.0.1:7891` 正常监听。

**未决问题**：

- 故障注入测的是 `Process.start` 回落路径（诊断构建跳过 Windows 助手服务）：用户机上内核由帮助服务
  托管（`helperClient.startCore`），`reStart` 的杀进程/拉起由帮助服务完成，恢复路径是同一套代码，但未在
  实机帮助服务模式下验证过；恢复耗时为数十秒（探测 2 秒 + 重启 + 重新下发配置），仍有压缩空间。
  （「数十秒」的实际来源与后续修复见第 13 节。）
- 诊断用的 dev 身份实例在本机偶发「启动 1~2 分钟后静默退出」（无日志、无崩溃转储），原因未定位；用户正式
  实例（`Documents\Bettbox`，自 18:04 起持续运行）不受影响，与本问题无关。
- 另记一条上游既有行为（非本轮改动）：应用启动/退出时会调 `proxy.stopProxy()`，会同时清除**其他程序**
  设置的 Windows 系统代理（`ProxyEnable` 置 0、`ProxyServer` 保留）。诊断期间已多次核对并保持用户
  `ProxyEnable=1 / 127.0.0.1:7890` 原值不变。

---

## 13. 恢复过程看得见 + 找齐「锁死」根因：关闭旧 socket 会挂死整条启动链

第 12 节已将「半死内核」的处理改为自动重启，但恢复期间界面没有任何反馈——用户只看到一个灰显的开关，
等不下去就退出应用，自动恢复失去意义。本轮补充可见性，并沿「恢复到底阻塞在哪一步」定位到真正的卡死点。

**改动**

- **整个启停过程都有进行中指示**（新增 `isCoreBusyProvider`，`lib/providers/state.dart`）：从点击起
  （含等待内核锁的时间）到动作结束，右栏总开关显示加载指示并禁用，首页启动卡片显示加载指示，顶栏开关禁用。
  此前只有「检测到内核不应答、正在重启」那一段显示加载指示，等待与下发配置的十几秒里仍是灰显状态。
- **恢复时真正关闭旧 socket**（`ClashService._destroySocket`）：内核崩溃 / 被强杀 / 卡死之后，旧连接上的
  `close()` 会一直等待发送缓冲区写完。整条启动链都阻塞在这里——实测停滞 17 秒以上不再前进，之后
  `socketCompleter` 也没有被重置，后续所有 IPC 都写入已失效的连接（日志里持续输出
  `Ignored message send on closed socket`）。现在给 `close()` 加 2 秒上界，超时后改用 `destroy()` 强制断开，
  且无论成败都重建 `socketCompleter`。
- **恢复重启改为带配置重启**（`_ensureCoreReachable` → `_restartCore(setupConfig: true)`）：只启动进程
  而不下发配置时，新内核不会监听端口。
- 新增 `coreRestarting` 文案（7 种语言），恢复期间提示「内核无响应，正在重启内核…」。

**验证**（`flutter analyze` 无问题、`flutter test` 85/85）

- **可见性**：dev 实例点击开关后快速连拍（每帧约 0.44 秒）：点击后 0.55 秒，右栏总开关与首页启动卡片
  即出现加载指示，顶栏与其他按钮同步禁用，并保持到动作结束。
- **卡死根因**：注入「强杀内核」后点击开关，修复前日志停在 `startCore: begin` 之后不再前进（20 秒后出现
  `lifecycle action "start" has been holding the lock for 20s`，界面持续显示「重启内核」）；修复后同一注入：

```
[Core] Core is not reachable before start, restarting it
restart core
[Core] Failed to close previous socket: SocketException: Write failed (OS Error 10054)
[Core] startCore: previous socket destroyed      ← 修复前永远到不了这一行
[Core] startCore: ipc server ready
[Core] startCore: spawned pid=3080
```

  从 `begin` 到 `spawned` 共 8 毫秒。
- **助手服务模式（补验）**：dev 助手服务 `BettboxDevHelperService` 运行后启动内核，新内核
  `ParentProcessId` 即该服务 PID，启动耗时 1.04 秒（同路径直接 spawn 为 6.6 秒）；助手侧 `start_core`
  在校验 SHA256 之后先 `stop_core()` 再 spawn，即卡死的旧内核由服务强制清理。

**未决问题**

- 验证走的是**进程内直接 spawn**路径（诊断构建用编译开关跳过助手服务，避免装服务触发 UAC）。
  助手托管路径下「卡死后恢复」的端到端未复现：内核由服务托管时运行在 Session 0，普通权限既不能挂起
  也不能终止，无法注入「半死」状态；该路径目前只有代码证据（助手 `start_core` 先 `stop_core`）与
  生产实例的观察（UI 不在时内核仍在运行）。
- 「强杀内核」注入下恢复流程不再卡死，但新内核**没有监听 mixed-port**（进程在、端口未监听），原因尚未查明。
  该注入会留下「对端已死」的旧 socket，与内核自然崩溃未必等价，需进一步复验。
- 诊断实例偶发「启动 1~2 分钟后静默退出」仍未定位（与第 12 节同一条）。

---

## 14. 启动判据改为 mixed-port 真的在监听：不再停在「运行中」的假状态

**文件**：`lib/clash/core.dart`、`lib/common/network.dart`、`lib/state.dart`

**问题**：第 13 节遗留的「强杀内核后新内核没有监听 mixed-port」（进程在、端口未监听）不是独立故障，而是
启动判据本身的缺陷：内核的 `handleStartListener` 无条件返回成功（内部只置一个运行标志，建立监听失败
也只写日志），客户端又丢弃了它的返回值。因此指令被丢弃、IPC 超时或端口未建立，任意一种情况发生时开关照样停在
「运行中」——此时内核可能只剩一个进程、`mixed-port` 无监听者、代理实际不通。将本轮修复临时回退，
同一套注入立刻复现：「`close start` 之后 60 秒没有进展、端口起不来、IPC 全部报 `StreamSink is closed`」。

**改动**：

- `ClashCore.startListener` 改为返回 `bool`（`lib/clash/core.dart`）：使调用方能够看到内核是否接受了指令；
  异常时返回 `false` 并写日志。
- 新增 `isLoopbackPortListening(port)`（`lib/common/network.dart`）：实际连接一次回环端口以判断是否存在监听者
  ——「监听是否真的建立」内核并不回报，只能从客户端侧实测。
- `GlobalState.handleStart` 改走 `_startListenerChecked()`（`lib/state.dart`）：内核已不应答（且不在
  重启过渡中）时 2 秒内直接判失败，无需等待至整段 IPC 超时；`startListener` 超时收紧到 5 秒；随后实际连接
  `mixed-port`，失败则等待 500 毫秒再重试一次（新内核刚启动时监听可能仍在建立）。
- 重试仍失败：`startTime` 置空、`_applyStoppedState()` 把开关恢复为已停止、不写运行意图，并提示
  `coreExited`——不再停留在虚假的运行状态。

**验证**（`flutter analyze` 无问题、`flutter test` 85/85）：

- 故障注入（在 `startListener` 之前杀掉内核）：**2.3 秒**内判失败，开关回到已停止，
  `core_listener_running` 保持 `false`（没有写入「曾启动」的意图）。
- 「正常启动」与「强杀内核后点击开关」两条路径都无回归：`mixed-port` 持续监听。
- 助手托管路径（正式身份实机）：提权 + `SeDebugPrivilege` 挂起 Session 0 的内核后点击开关，**5 秒内**
  新内核接管、`7890` 由新 PID 监听、经代理 `curl --proxy 127.0.0.1:7890 http://cp.cloudflare.com/generate_204`
  返回 204（0.22 秒），阻塞的旧内核由帮助服务清理。

**未决问题**：

- 用户报告的「点击开关**首次**失败、第二次才成功」，6 次启停均未复现（正常路径 0.86 秒就绪、停止 27 毫秒）。
  剩下的可能是：点击时内核正处在重启过渡窗口（`isStarting` 期间 `sendMessage` 静默丢弃，重试间隔固定
  500 毫秒，两次都可能落在该窗口内），或那次点击实际命中的是「停止」。是否按前者增加「重试前先等内核脱离
  `isStarting`」的加固，待定。
- 同时确认的一条真实路径：`handleStop` 在停止指令未获应答时走 `reconcileCoreState(force: true)`，最终
  进入 `_resyncCoreStopped()`，而它**只清界面状态、完全不操作内核**——「界面显示已停止、内核仍在运行」仍可能
  出现（`core_listener_running` 也仍是 `true`，下次启动会尝试拉起）。实测系统代理会被正确关闭
  （对账在 +10 秒把 `ProxyEnable` 置 0），不存在「界面已停止而系统代理仍开启」。是否让停止失败也真正停止内核，
  待定。

---

## 15. 吸收上游 2026-09-10～09-28 的健壮性补丁（A1–A6 内核与进程 + B1–B4 平台专项）

本仓库基线是上游 `70b6077`（2026-09-10）。到上游 `31893466`（v1.19.4-pre1，2026-09-28）之间的 91 个提交中，
排除 macOS/Linux 专属、mips/Android TV、解锁检测新模块与纯风格改名后，选取 10 条对本仓库有实际价值的补丁
整批吸收，共 22 个文件；除下文明确说明的例外，实现与上游一致。编号按 **A = 内核与进程健壮性**、
**B = 平台专项**，本节之后的验证与未决项中出现的「A3」等编号即指这些条目。

**内核与进程健壮性**：

- **A1** `handleAction` 加 `defer recover()`：单个 action 内的 panic 不再导致整条指令通道失效，而是按失败应答（`core/action.go`）。
- **A2** `_writeRunningConfig` 改为「时间戳临时文件名 + 最多 3 次 rename/copy 重试 + `finally` 清理」。旧实现 rename
  失败会**先把目标配置删掉**再重试，第二次仍失败时运行配置被清空（`lib/state.dart`）。
- **A3** `_startCore()` 在 `_destroySocket()` 之后、`process?.kill()` 之前补 Windows 的 `helperClient.stopCore()`：
  助手托管时 `process` 为 `null`，此前该调用无法作用于旧内核（`lib/clash/service.dart`）。
- **A4** `_initCore` 用 `_initCoreFuture` 去重：启动 / 重载配置 / 状态对账并发走到这里时只实际初始化一次（`lib/controller.dart`）。
- **A5** 换节点后的 `closeConnections()` 改为 `await`；内核侧单条连接关闭失败不再中断整轮（原来 `return false` 会
  跳过后续全部连接的关闭）（`lib/controller.dart`、`core/hub.go`）。
- **A6** 内核返回值不再直接强转：`getConfig` 与分组构建按 `is Map` 收敛类型，内核返回意外类型时不再抛错中断启动链
  （`lib/clash/core.dart`）。

**平台专项**：

- **B1** Windows 安装器注册助手服务改为 `sc config binPath=` 就地改指向，失败（服务不存在）才 `create`，
  升级安装不再采用「先删服务再创建」的方式（`windows/packaging/exe/inno_setup.iss`）。
- **B2** 内置代码编辑器取上游修复，含 Windows 上中文输入错位（上游 issue #498）（`plugins/code_forge`）。
- **B3** 脚本引擎取上游健壮化（JS 返回 `null` 不再导致崩溃等）；控制器接上空闲 GC：界面空闲 2 秒后才
  `requestGc(forceFreeOSMemory: true)`，后台加载收尾那次也改为真正归还内存（`plugins/flutter_qjs`、`lib/controller.dart`）。
- **B4** Android 17 兼容：manifest 补 `ACCESS_LOCAL_NETWORK` / `INTERACT_ACROSS_USERS`，`FilesProvider.openDocument`
  收敛 `mode`，三处 intent-filter 与 Windows 侧协议注册补 `flclash://` 导入（`AndroidManifest.xml`、
  `FilesProvider.kt`、`lib/common/window.dart`）。

**有意未吸收的**：

- `107468a3` 夹带的 `libclash.so → libmeta.so` 整组重命名：本仓库发布的产物是 `libclash.so`（`jniLibs`、ffigen
  头、`setup.dart` 均以此命名），只取 Dart 部分会直接导致 Android 构建失败。
- `b6b07a78` 同笔给 `_setupCoreConfig()` / `_updateClashConfig()` 加的两处 `await _initCore()`：本仓库的
  `_initCore()` 先 `waitForSocket(10 秒)`，放在配置更新路径上会在「内核已停止」时使该路径额外等待 10 秒，因此只做去重。
- 两个插件的 `macos/` 文件（本仓库不发布 macOS）。
- 上游的内存详情面板（`f3773739` / `ed31901a` / `66c48587`：点击内存卡片弹出「内核负载详情」，含已分配 / 可回收
  环形图、Goroutines、Heap Objects、Geodata 用途等，并把内核读数口径改为含 Go 保留空闲堆）：属于新功能，
  且会替换第 10 节「应用 / 内核」双读数的口径，与本仓库既定取向冲突，本轮未吸收。

**验证**：`flutter analyze` 无问题、`flutter test` 85/85、内核按项目设置（`CGO_ENABLED=0 -tags=with_gvisor`）
编译通过、Windows release 构建通过。实机（正式身份、助手托管路径）：总开关停止 → `7890` 立即不监听、系统代理关闭；
启动 → `7890` 重新监听、经代理 `generate_204` 返回 204；内置编辑器打开用户脚本，渲染与中文输入正常（未保存）。

**A3 真机复验（2026-09-29，正式身份 + 助手托管）**：用 `Bettbox.exe --restart`（外部控制通道 → `restart_app`
插件）触发一次完整的应用重启，使新实例在旧内核仍存活时执行 `_startCore()`；另用 `taskkill /F` 强杀应用作为对照。
采样精度 2ms 的进程 / 端口记录：

| 事件 | 时刻 | 说明 |
|---|---|---|
| 新实例进程出现 | 14:35:22.604 | 插件按 `CREATE_SUSPENDED` 创建，`Sleep(150)` 后才 `ResumeThread` |
| `7890` 关闭 | 14:35:22.831 | 旧内核 PID 16332（父进程 = 助手服务）开始退出 |
| 旧内核消失 / 旧实例退出 | 14:35:22.877 | 旧实例走 `ExitProcess(0)`，不做任何 Dart 清理 |
| 新内核诞生 | 14:35:22.938 | PID 32448，父进程 = `BettboxHelperService.exe`，助手托管路径确认 |
| 对照组：强杀应用 | 14:38:30.664 → 30.820 / 30.850 | 全程无任何 RPC：`7890` 在 +156ms 关闭、内核在 +186ms 消失 |

`_startCore()` 在真机助手托管形态下完整执行成功（`stopCore()` → `_awaitServerSocket()` → `registerService()` →
`core.start` → 新内核由助手拉起），A3 那一行必然执行过：它在同一函数内无条件调用，其下游 `core.start` 已观测成功。
应用重启后按设计不自动恢复运行（「本应在运行」的意图只对当次进程有效），重新打开总开关后 `7890` 立即重新监听、
经代理 `generate_204` 返回 204、`ProxyEnable` 恢复为 `0x1`。

**但旧内核的退出原因不能归给这一行**：`core/server.go` 的 `startServer()` 在 `readFrame` 读到 EOF 时直接返回、
进程随之退出，所以应用一旦退出（正常 `ExitProcess` 与被强杀都一样）内核就自行退出，对照组实测 156~186ms 且不经任何
RPC。`stopCore()` 的实际作用是让助手 `kill()`+`wait()` 回收它记录的那个子进程，并在 `core.start` 之前确保
`7890` 已经释放——属于兜底，不是这条路径上唯一可行的停止手段。

**未决问题**：

- 助手托管下「旧内核还活着、但应用侧 `process` 为 `null` 且其 IPC 也未断」这一 A3 要覆盖的场景，本机**无法构造**，
  有两个相互独立的原因。其一，内核随 IPC 断开自行退出（`core/server.go` 读循环遇 EOF 即 return）。其二，Windows 侧的
  单实例逻辑在 C++ runner 里：`Win32Window::Create` 先走 `SendAppLinkToInstance`，`FindWindow` 命中既有窗口就把
  app link 交给它、`SW_RESTORE` + `SetForegroundWindow` 将其拉起，本进程随即以退出码 1 结束，Dart 侧不会启动
  （`main.dart` 中的 `singleInstanceLock` 只是 macOS 分支，易被误判为 Windows 无单实例）。dev 身份另有独立的
  服务名 / 命名管道 / 内核名，也无法命中同一个助手服务实例。因此该调用的独立效果仍只有代码级证据；路径本身已按上文复验通过。
- 上游的内存详情面板未吸收，第 10 节的读数口径保持不变。

---

## 16. 应用内「检查更新」指向本仓库

**文件**：`lib/common/constant.dart`（`47d964f0`，v1.19.1）、`lib/common/request.dart`、`lib/controller.dart`

**问题**：上游原版把 `repository` 常量硬编码为 `appshubcc/Bettbox`，应用内的「检查更新」与「去下载」拼出的链接
都取自该常量指向的仓库。衍生仓库若不修改，用户在本仓库的构建中点击检查更新，得到的是**官方版**的版本号与安装包：
Android 上因签名不同无法安装（或提示签名冲突），Windows 上安装器会指回官方包，本地改动被静默覆盖。

**改动**：`repository` 改为 `Catapult291/Bettbox-Mod`，取更新的两处都由这一个常量驱动：

- `Request.checkForUpdate()`：请求 `https://github.com/$repository/releases/latest`，以 `followRedirects: false`
  取得 302 的 `location` 头并解析出最新 tag，再与本地版本号比较，不解析页面 HTML。
- 更新弹窗的「去下载」：构建时注入了 `--dart-define=APP_ASSET_SUFFIX=<平台-架构-扩展名>` 时，直接拼接
  `https://github.com/$repository/releases/download/<tag>/Bettbox-<版本>-<assetSuffix>`；未注入（如本地调试构建）
  时退回 Release 列表页。CI 按矩阵注入该值，Windows 侧为 `windows-amd64-setup.exe`（见第 9 节）。

**未决问题**：

- `releases/latest` 只返回 GitHub 标记为 Latest 的正式版，**预发布（标签含 `pre`）不会被检出**，所以本仓库发布
  `-pre` 版时应用内不会提示更新，需手动前往 Release 页获取。要覆盖预发布需改走 `/releases` 列表或 API。
- 更新弹窗只比较版本号，不校验下载物的签名与来源；本仓库与上游版本号同为 `1.19.x` 递增，若上游先发布更高版本，
  用户在本仓库的构建中也不会收到提示。

## 17. 「更多」页入口与 Windows 安装包发布者链接指向本仓库

**文件**：`lib/views/about.dart`、`windows/packaging/exe/make_config.yaml`、`windows/packaging/exe/package_windows.dart`（v1.19.6）

**问题**：第 16 节只改了更新检查与「去下载」共用的 `repository` 常量，界面上另有两处仍是上游地址：

- 「更多」页的 `Github Releases` 磁贴硬编码 `https://github.com/appshubcc/Bettbox`，点开是官方版 Releases。
- Windows 安装包的 `publisher_url` 取自 `make_config.yaml` 的上游地址，安装界面与卸载项里的支持链接因此指向官方仓库。

**改动**：

- `lib/views/about.dart` 的该入口改为 `https://github.com/$repository/releases`，与更新检查共用同一常量，后续换源只需改一处。
- `make_config.yaml` 的 `publisher_url` 与 `package_windows.dart` 中的同名兜底值改为本仓库地址。

**验证**：`flutter analyze lib/views/about.dart` 无问题；CI run `36580355081` 产出 v1.19.6，
解包 `Bettbox-1.19.6-android-arm64-v8a.apk` 的 `lib/arm64-v8a/libapp.so` 后，`Catapult291/Bettbox-Mod` 存在、
`appshubcc/Bettbox` 已不再出现（`appshubcc/bett-rules` 仍在，那是 GeoIP 规则数据源，与本改动无关）。
Windows 安装包的 `publisher_url` 由 Inno Setup 压缩存储，新旧安装包内都搜不到 URL 明文，
因此这一项只有源码与 CI 输入层面的确认，未经安装包内的字符串复核。

## 18. 「关于」页去掉上游内容、名称改为 Bettbox-mod，发布者字段改为本仓库作者

**文件**：`lib/views/about.dart`、`lib/common/identity.dart`、`windows/packaging/exe/make_config.yaml`、
`windows/packaging/exe/package_windows.dart`、`windows/runner/Runner.rc`、`linux/packaging/deb/make_config.yaml`、
`linux/packaging/rpm/make_config.yaml`（v1.19.7）

**问题**：第 16/17 节只把链接换成自己的仓库，界面与安装包里仍是上游身份：

- 「关于」页保留上游宣传语（「Bettbox 基于强大灵活的 Mihomo…我们的愿景」）与上游「其他贡献者」头像墙，
  外加上游 Telegram 群 / 频道入口——衍生版留着这些，等于替官方版做宣传并把用户引向上游社群。
- 安装包版本信息里的 `CompanyName` 仍是 `appshub.cc`（Inno Setup 的 `VersionInfoCompany` 默认取 `AppPublisher`），
  应用本体 `Bettbox.exe` 的 `CompanyName` 仍是 `com.appshub`；Linux 包的 maintainer / packager 同样是上游。

**改动**：

- `lib/views/about.dart`：删掉简介文案与「其他贡献者」板块（连同只为它存在的 `Contributor` / `Avatar` 两个类），
  删掉 Telegram 群 / 频道一行；名称改用 `AppIdentity.brandName`；链接区新增上游 `Bettbox` 入口，与既有
  `FlClash` / `Mihomo` 同排（`_LinkGridRow` 由固定左右两格改为格数可变，故三格同排）。
- `lib/common/identity.dart`：新增 `AppIdentity.brandName = 'Bettbox-mod'`。**只影响「关于」页展示**：可执行文件名、
  数据目录（`%APPDATA%\com.appshub\Bettbox`）、助手服务名、计划任务名仍取 `productName`。
- 发布者字段改为 `Catapult291`：`make_config.yaml` 的 `publisher`、`package_windows.dart` 的同名兜底值、
  `Runner.rc` 的 `CompanyName`、Linux 两份 `make_config.yaml` 的 maintainer / packager。
- 死资源一并清掉：删掉 18 张贡献者头像（`assets/images/avatars/` 整目录）与 `pubspec.yaml` 里的同名资源目录，
  并从 7 份 `arb` 删除已无人引用的 `desc` / `otherContributors`，再用 `flutter pub run intl_utils:generate`
  重新生成 `lib/l10n/`（生成物 diff 只有这两个键，无其他格式漂移）。

**验证**：`flutter analyze lib test` 无问题、`flutter test` 85 项全过；本机
`flutter build windows --release --dart-define=APP_ENV=stable` 后，用 `GetFileVersionInfoW` 读回
`Bettbox.exe` 版本资源 `CompanyName = 'Catapult291'`（该次构建仍在升版前，`FileVersion` 为 `1.19.6+2026092903`）。
界面用 dev 身份调试版（`--debug --dart-define=APP_DEV=true`，窗口类与标题独立，可与已安装实例并存）实机渲染核对：
标题为 `Bettbox-mod`，简介与「其他贡献者」板块、Telegram 行均已消失，链接区两行分别为
`Github Releases | 检查更新`、`Bettbox | FlClash | Mihomo`，三格分隔线与右端图标正常。
清死资源后 `flutter pub run intl_utils:generate` 的生成物 diff 只含两个键的删除（`lib/l10n/` 共 −56 行），
再用 `flutter test` 复跑通过。

**未决问题**：

- 「关于」页只有这一处显示名改了：窗口标题、托盘提示、可执行文件名、数据目录、助手服务名与计划任务名仍是
  `Bettbox` / `com.appshub.bettbox`（Android `applicationId` 与 Linux `APPLICATION_ID` 同理）。改动它们会让既装用户
  变成「另一个应用」（无法覆盖升级、配置目录分裂），需要单独一轮评估。
- `Runner.rc` 的 `LegalCopyright` 保留上游署名（「Copyright (C) 2025 com.appshub」），属 GPL 归属，不随发布者字段一起改。
- 安装包（Inno `setup.exe`）的 `CompanyName` 取自 `publisher`，本机无 ISCC 打不出安装包，
  只能读 CI 产出的 v1.19.7 安装包版本资源复核。

## 附：上游已自行实现、本仓库不再单列的改动

- **访问控制列表排序稳定性**：原 `lib/models/selector.dart` 中「链式两次排序 + Dart 不稳定排序」问题，
  上游已在提交 `79cf06e`（Optimize android access control list sorting）中修复，实现与本仓库此前的
  修法等价（单次复合比较器 + 兜底包名比较）。本仓库直接采用上游实现。
