<h1 align="center">Bettbox-Mod</h1>

<p align="center">
  基于 <a href="https://github.com/appshubcc/Bettbox">appshubcc/Bettbox</a> 的衍生版本（GPL-3.0）<br>
  只做少量针对性修补，其余功能与上游保持一致
</p>

---

## 这是什么

Bettbox 是一款使用 Mihomo(Clash Meta) 内核、基于 FlClash 早期版本重构的多平台网络调试与规则分流客户端。
本仓库是它的衍生版本，用于承载少量针对性的修补，并只发布 **Android** 与 **Windows** 构建。

仓库以“上游快照 + 独立改动提交”的方式组织：第一个提交是上游代码原样导入，后续提交是我们的改动，
因此任何一笔差异都可以直接对照、审阅与回退。

- 当前基线：上游 `main` @ `70b6077`（2026-09-10）
- 完整改动清单：[CHANGES-vs-upstream.md](CHANGES-vs-upstream.md)

## 相对上游的改动

| 改动 | 说明 |
| --- | --- |
| 首页 IP 检测来源重构 | 「国外 HTTPS 源优先（`api.ip.sb/geoip`、Cloudflare `/cdn-cgi/trace`、`ipify`、可选 `ipinfo`），全部失败再回退国内源」；串行探测、成功即停，不再跨源合并结果，避免出现“IP 与国家错配”的脏数据（`lib/common/request.dart`） |
| 脚本页「规则」区块 | 脚本页可直接添加自定义规则，按「覆盖全局规则」语义插入到配置规则最前面，支持编辑与多选删除，改动后自动重载当前配置（`lib/views/profiles/scripts.dart` 等） |
| 规则目标分组过滤 | 覆写页添加规则时的目标分组与代理页保持一致：只列顶层分组（GLOBAL 的成员），并按「显示隐藏项」开关决定是否展示隐藏分组（`lib/views/profiles/override_profile.dart`） |
| 配置更新控制 | 新增「跟随更新」开关（默认开，升上来的老配置行为不变）：配置页「全部同步」只更新订阅型且开启该开关的配置；编辑页右上角可单独更新当前配置，成功/失败以小提示反馈，不再弹全局错误对话框（`lib/models/profile.dart`、`lib/views/profiles/edit_profile.dart` 等） |
| 右侧快捷控制栏（仅桌面） | 桌面端右侧新增常驻栏：总开关 / 系统代理 / 虚拟网卡 / 出站模式，与左侧导航栏等宽、首个控件与左栏「首页」图标同高，切换动作与托盘菜单共用同一入口；Android 端不渲染（`lib/widgets/quick_controls.dart`、`lib/manager/app_manager.dart`） |
| 从 URL 导入自动取名 | 不填名称时按 `profile-title` 响应头 → `content-disposition` 文件名 → URL 末段 → 主机名的优先级取名（兼容 base64 与百分号编码），不再回落到时间戳 id（`lib/common/utils.dart`、`lib/models/profile.dart`） |
| 桌面端二维码导入 | Windows / Linux 上用纯 Dart（`zxing2` + `image`）解码二维码图片，修复上游在桌面端选图必失败（`MissingPluginException`）的问题；Android / iOS / macOS 仍优先走原生识别（`lib/common/qr_reader.dart`、`lib/common/picker.dart`） |
| 扫码成功后的转场 | 识别成功后先显示对勾停留 500ms，再用 `pushReplacement` 直接换成「从 URL 导入」页，不再闪回「添加配置」页（`lib/pages/scan.dart`、`lib/common/navigator.dart`） |
| 开发体验 | `analysis_options.yaml` 排除构建产物与平台目录，`flutter analyze` 只报应用代码问题 |
| 内存占用调整 | 首页「内存信息」同时显示「应用内存」（本应用 RSS）与「内核内存」；provider 的全节点列表不再进常驻单例，只在构组时随 isolate 瞬时使用；连接页快照在窗口隐藏/后台时释放；脚本引擎补上 30s / 256MB 执行上下界（`lib/clash/core.dart`、`lib/views/dashboard/widgets/memory_info.dart` 等） |

> 访问控制列表排序稳定性问题（原 `lib/models/selector.dart` 修复）已由上游合并（上游提交 `79cf06e`），
> 本仓库直接采用上游实现，不再单列。

## 下载

前往 **[Releases](../../releases)** 下载：

| 平台 | 产物 |
| --- | --- |
| Android | `Bettbox-<版本>-android-arm64-v8a.apk`（主流机型）、`Bettbox-<版本>-android-universal.apk`（通用） |
| Windows | `Bettbox-<版本>-windows-amd64-setup.exe` |

注意事项：

- 本仓库使用自有签名证书，与官方 Bettbox 不同（包名相同，均为 `com.appshub.bettbox`）：
  - **Windows**：安装程序可直接覆盖升级官方版，数据保留；
  - **Android（未装签名校验豁免模块）**：安装时会提示签名不一致，需要先卸载官方版再安装，应用内数据会被清除
    （建议先用应用内备份 / WebDAV 导出配置）；
  - **Android（已装核心破解 / CorePatch 等禁用 APK 签名校验的模块）**：可直接覆盖安装且数据保留，
    订阅与设置不受影响（实测）。
- 本仓库各版本之间使用同一证书，可直接覆盖升级，无需以上操作。
- Windows 安装包未做代码签名，SmartScreen 可能提示“未知发布者”，选择“仍要运行”即可。
- Android 端首次启动 TUN 需要授予 VPN 权限；如果系统限制后台，请按应用内提示放行。

## 自行构建

以 Windows 为例（需要 Git、Visual Studio、Flutter 3.44.x、Golang、Inno Setup、Rust）：

```bash
flutter pub get
dart .\setup.dart windows --arch amd64 --out app     # 产物在 dist/
```

Android（需要 Android SDK 与 NDK `28.2.13676358`）：

```bash
flutter pub get
dart .\setup.dart android --arch arm64               # 产物在 dist/
```

生成代码（`*.freezed.dart` / `*.g.dart`）已入库，日常构建无需运行 `build_runner`；若改动了数据模型，
本地可用 `dart run build_runner build -d` 重新生成后一并提交。

CI 见 [.github/workflows/build.yaml](.github/workflows/build.yaml)：推送 `v*` 标签时构建 Android 与 Windows
产物并创建 Release；也可以在 Actions 页面手动触发（手动触发只上传构建产物，不创建 Release）。

## 致谢

- 感谢 **[linux.do](https://linux.do) 社区**。
- 感谢 [Bettbox](https://github.com/appshubcc/Bettbox)、[FlClash](https://github.com/chen08209/FlClash)、[Mihomo](https://github.com/MetaCubeX/mihomo) 及其贡献者。

## 许可证

[GPL-3.0](LICENSE)。本仓库为衍生作品：原始版权归上游作者所有，本仓库的改动同样以 GPL-3.0 发布。
