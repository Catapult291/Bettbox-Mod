<h1 align="center">Bettbox-Mod</h1>

<p align="center">
  <a href="https://github.com/appshubcc/Bettbox">appshubcc/Bettbox</a> 的衍生版本（GPL-3.0）<br>
  在上游基线之上叠加功能改进与内核稳定性修复
</p>

---

## 简介

Bettbox 是一款使用 Mihomo(Clash Meta) 内核、基于 FlClash 早期版本重构的多平台网络调试与规则分流客户端。
本仓库为其衍生版本，收录面向日常使用的功能改进，以及内核启动、停止与异常恢复链路的稳定性修复，
仅发布 **Android** 与 **Windows** 构建。

仓库按「上游快照 + 独立改动提交」的方式组织：首个提交为上游代码原样导入，其后均为本仓库改动，
任何一笔差异均可直接对照、审阅与回退。

- 基线：上游 `main` @ `70b6077`（2026-09-10）；上游补丁跟进至 `31893466`（2026-09-28）
- 完整改动清单（逐条含问题、方案与验证）：[CHANGES-vs-upstream.md](CHANGES-vs-upstream.md)

## 相对上游的改动

以下为部分主要改动，涉及的文件与实现细节见上述改动清单。

**稳定性**

* **状态对账**：桌面端定期核对内核实际状态，界面开关随之校正并提示。
* **故障自愈**：内核停止应答时自动重启并重新下发配置，无需退出应用。
* **就绪实测**：启动后实测本地代理端口，端口未监听则显示为已停止并给出提示。
* **过程可见**：启停全程显示进行中状态，关键等待均设有时间上限。

**界面**

* **快捷控制栏**：Windows 端右侧常驻总开关、系统代理、虚拟网卡与出站模式，与左侧导航栏等宽对齐，移动端不显示。
* **跟随更新**：配置可单独排除在「全部同步」之外，并可在编辑页按需更新。
* **规则直添**：脚本页可直接追加自定义规则，新规则优先于原有规则，支持编辑与批量删除。

**导入**

* **扫码导入**：补齐 Windows / Linux 的图片二维码解码，识别成功后直接进入导入页。
* **名称自取**：导入订阅未填名称时，依次取订阅标题、下载文件名与网址末段。

**其他**

* **更新源**：应用内检查更新与下载入口均取自本仓库 Release。
* **身份信息**：「关于」页名称显示为 Bettbox-mod，只保留本项目与上游项目入口；安装包的发布者信息指向本仓库作者。
* **出口探测**：出口 IP 优先经境外地址检测，逐源尝试、成功即停，不再混用多源结果。
* **内存占用**：内存读数分列应用与内核，大块数据不再常驻，脚本执行设有边界。
* **上游跟进**：持续吸收上游健壮性补丁，已跟进至 2026-09-28。

## 下载

前往 **[Releases](../../releases)** 下载：

| 平台 | 产物 |
| --- | --- |
| Android | `Bettbox-<版本>-android-arm64-v8a.apk`（主流机型）、`Bettbox-<版本>-android-universal.apk`（通用） |
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

- 感谢 **[linux.do](https://linux.do) 社区**。
- 感谢 [Bettbox](https://github.com/appshubcc/Bettbox)、[FlClash](https://github.com/chen08209/FlClash)、[Mihomo](https://github.com/MetaCubeX/mihomo) 及其贡献者。

## 许可证

[GPL-3.0](LICENSE)。本仓库为衍生作品：原始版权归上游作者所有，本仓库的改动同样以 GPL-3.0 发布。
