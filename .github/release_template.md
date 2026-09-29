# Bettbox-Mod VERSION

本仓库是 [appshubcc/Bettbox](https://github.com/appshubcc/Bettbox) 的衍生版本（GPL-3.0）。
以下为本版本相对上游累计的主要改动，逐条的问题、方案与验证见
[CHANGES-vs-upstream.md](https://github.com/Catapult291/Bettbox-Mod/blob/main/CHANGES-vs-upstream.md)。

**稳定性**

* **状态对账**：桌面端定期核对内核实际状态，界面开关随之校正并提示。
* **故障自愈**：内核停止应答时自动重启并重新下发配置，无需退出应用。
* **就绪实测**：启动后实测本地代理端口，端口未监听则显示为已停止并给出提示。
* **过程可见**：启停全程显示进行中状态，关键等待均设有时间上限。

**界面与导入**

* **快捷控制栏**：Windows 端右侧常驻总开关、系统代理、虚拟网卡与出站模式，与左侧导航栏等宽对齐，移动端不显示。
* **跟随更新**：配置可单独排除在「全部同步」之外，并可在编辑页按需更新。
* **规则直添**：脚本页可直接追加自定义规则，新规则优先于原有规则，支持编辑与批量删除。
* **扫码导入**：补齐 Windows / Linux 的图片二维码解码，识别成功后直接进入导入页。
* **名称自取**：导入订阅未填名称时，依次取订阅标题、下载文件名与网址末段。

**其他**

* **更新源**：应用内检查更新与下载入口均取自本仓库 Release。
* **出口探测**：出口 IP 优先经境外地址检测，逐源尝试、成功即停，不再混用多源结果。
* **内存占用**：内存读数分列应用与内核，大块数据不再常驻，脚本执行设有边界。
* **上游跟进**：吸收上游 2026-09-10 至 09-28 的健壮性与平台补丁——内核单条指令异常隔离、
  运行配置原子写入、Windows 升级安装保留助手服务、Android 17 兼容。

## 下载

| 平台 | 文件 |
| --- | --- |
| Android (arm64-v8a) | [Bettbox-VERSION-android-arm64-v8a.apk](https://github.com/Catapult291/Bettbox-Mod/releases/download/vVERSION/Bettbox-VERSION-android-arm64-v8a.apk) |
| Android (universal) | [Bettbox-VERSION-android-universal.apk](https://github.com/Catapult291/Bettbox-Mod/releases/download/vVERSION/Bettbox-VERSION-android-universal.apk) |
| Windows (x64) | [Bettbox-VERSION-windows-amd64-setup.exe](https://github.com/Catapult291/Bettbox-Mod/releases/download/vVERSION/Bettbox-VERSION-windows-amd64-setup.exe) |

## 说明

- 构建与改动明细：仓库根目录 `CHANGES-vs-upstream.md`；问题反馈请提交 Issue。
