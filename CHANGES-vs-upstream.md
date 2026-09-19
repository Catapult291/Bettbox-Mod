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
  只弹上述 `updateFailed` 提示；原始错误仍写进应用日志（`commonPrint.log` → 日志页），便于排查。
- `AppController.updateProfile` 改为返回 `bool`（同一配置已有更新在途时返回 false），使上面的成功提示
  只在真正完成更新时出现。
- UI（配置页）：右上角「全部同步」改为只更新订阅型且开启「跟随更新」的配置（`getSyncAllTargets`）；
  「自动更新」（定时/启动补更）与卡片菜单里的单条「同步」不受该开关影响。
- 多语言：7 个 `arb` 与对应的 `lib/l10n/intl/messages_*.dart`、`lib/l10n/l10n.dart` 新增 `followUpdate`、
  `updateSuccess`、`updateFailed`。

---

## 5. 其他

- `analysis_options.yaml`：analyzer 排除 `build/**`、`android/**`、`windows/**`、`macos/**`、`linux/**`，
  避免 `flutter analyze` 被平台侧生成代码与构建产物淹没。

---

## 附：上游已自行实现、本仓库不再单列的改动

- **访问控制列表排序稳定性**：原 `lib/models/selector.dart` 中「链式两次排序 + Dart 不稳定排序」问题，
  上游已在提交 `79cf06e`（Optimize android access control list sorting）中修复，实现与本仓库此前的
  修法等价（单次复合比较器 + 兜底包名比较）。本仓库直接采用上游实现。
