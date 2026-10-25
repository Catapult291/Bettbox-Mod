<h1 align="center">Bettbox-Mod</h1>

<p align="center">
  <a href="https://github.com/appshubcc/Bettbox">appshubcc/Bettbox</a> 的衍生版本（GPL-3.0）<br>
  在上游基线之上叠加功能改进与内核稳定性修复
</p>

<p align="center">
  <a href="https://github.com/Catapult291/Bettbox-Mod/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/Catapult291/Bettbox-Mod?style=for-the-badge&logo=github&color=238636&label=Release"></a>
  <a href="https://github.com/MetaCubeX/mihomo/releases/latest"><img alt="Mihomo" src="https://img.shields.io/github/v/release/MetaCubeX/mihomo?style=for-the-badge&logo=go&logoColor=white&color=8A2BE2&label=Mihomo"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-GPL--3.0-blue?style=for-the-badge"></a>
</p>

<p align="center">
  <img src="snapshots/home.png" alt="Bettbox-Mod 首页" />
</p>

---

## 简介

Bettbox 是一款使用 Mihomo（Clash Meta）内核、基于 FlClash 早期版本重构的多平台网络调试与规则分流客户端。
本仓库为其衍生版本，收录面向日常使用的功能改进，以及内核启动、停止与异常恢复链路的稳定性修复，
仅发布 **Android** 与 **Windows** 构建。

仓库按「上游快照 + 独立改动提交」的方式组织：首个提交为上游代码原样导入，其后均为本仓库改动，
任何一笔差异均可直接对照、审阅与回退。

- 基线：上游 `main` @ `70b6077`（2026-09-10）；上游补丁跟进至 `31893466`（2026-09-28）
- 随包内核：vendored mihomo **v1.19.33**（保留本仓库与 FlClash 的独立补丁）

## 相对上游的改动


### 稳定性

* **状态对账**：桌面端定期核对内核实际状态，界面开关随之校正并提示。
* **故障自愈**：内核停止应答时自动重启并重新下发配置，无需退出应用。
* **就绪实测**：启动后实测本地代理端口，端口未监听则显示为已停止并给出提示。
* **过程可见**：启停全程显示进行中状态，关键等待均设有时间上限。
* **真停兜底**：停止指令未被应答时按进程真停内核，避免「界面已停、内核仍在跑」。

### 界面与分流

* **快捷控制栏**：Windows 端右侧常驻总开关、系统代理、虚拟网卡与出站模式，与左侧导航栏等宽对齐；移动端不显示。
* **跟随更新**：配置可单独排除在「全部同步」之外，被排除的配置仍可在卡片菜单里单独「同步」。
* **规则直添**：脚本页可直接追加自定义规则，新规则优先于原有规则，支持编辑与批量删除。
* **配置分享**：配置卡片新增「分享」，弹窗展示订阅二维码与机场链接，点击链接复制到剪贴板。
* **进程分流**（Windows）：「更多 → 设置 → 进程分流」可把代理按应用进程设为关闭、黑名单或白名单，带进程选择器，设置即时生效并随配置保存。
* **应用访问控制**（Android）：固定白名单模式，支持已选/未选筛选与搜索；勾选在退出页面时统一生效，无需重启 VPN 提示。

### 导入与更新

* **扫码导入**：补齐 Windows / Linux 的图片二维码解码，识别成功后直接进入导入页。
* **名称自取**：导入订阅未填名称时，依次取订阅标题、下载文件名与网址末段。
* **自动更新**：新建与从 URL 导入的配置默认开启自动更新，间隔默认 720 分钟。
* **应用内更新**：每 2 分钟向 GitHub 做一次条件请求（ETag/304），新版本发布后通常在 1~2 分钟内提示；同一版本只提示一次。API 不可达时回退网页端点。

### 其他

* **粘贴兼容**：以管理员模式运行时，剪贴板历史、输入法等通过 `WM_PASTE` 插入文本的来源不再被系统过滤丢弃。
* **配置改写**：Windows 与 Android 端的配置改写、覆写脚本求值均由随包的原生库（Rust）执行；原生库不可用或执行失败时提示错误并保留上一份可用的运行配置，不再静默换用另一套实现。
* **默认值**：内核 IPv6 默认开、休眠支持默认关；Android「允许绕过 VPN」默认开启。
* **上游与安全**：持续吸收上游健壮性补丁；内核与随包主程序用 Go 1.26.10 重编，Rust 工具链钉版 1.99.1；CI 接入 cargo-deny 许可证与安全公告审计。

## 下载

前往 **[Releases](../../releases)** 下载：

| 平台 | 产物 |
| --- | --- |
| Android | `Bettbox-<版本>-android-arm64-v8a.apk` |
| Windows | `Bettbox-<版本>-windows-amd64-setup.exe` |


## 自行构建

以 Windows 为例（需要 Git、Visual Studio、Flutter 3.44.x、Golang、Inno Setup、Rust）：

```bash
flutter pub get
dart .\setup.dart windows --arch amd64 --out app     # 产物位于 dist/
```

Android（需要 Android SDK 与 NDK `28.2.13676358`）：

```bash
flutter pub get
dart .\setup.dart android --arch arm64               # 产物位于 dist/
```

生成代码（`*.freezed.dart` / `*.g.dart`）已入库，日常构建无需运行 `build_runner`；
改动数据模型后，可用 `dart run build_runner build -d` 本地重新生成并一并提交。

CI 见 [.github/workflows/build.yaml](.github/workflows/build.yaml)：推送 `v*` 标签时构建 Android 与
Windows 产物并创建 Release；亦可在 Actions 页面手动触发，手动触发仅上传产物、不创建 Release。
Release 标题只写版本号，正文取自 [.github/release-notes/versions/](.github/release-notes/versions) 中该标签对应的
文件（逐版本撰写本版本改动与本版本跟进的上游更新，见 [.github/release-notes/README.md](.github/release-notes/README.md)）。


## 致谢

- 感谢 [Bettbox](https://github.com/appshubcc/Bettbox)、[FlClash](https://github.com/chen08209/FlClash)、[Mihomo](https://github.com/MetaCubeX/mihomo) 及其贡献者。

## 许可证

[GPL-3.0](LICENSE)。本仓库为衍生作品：原始版权归上游作者所有，本仓库的改动同样以 GPL-3.0 发布。
