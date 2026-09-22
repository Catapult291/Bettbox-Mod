# Bettbox-Mod VERSION

本仓库是 [appshubcc/Bettbox](https://github.com/appshubcc/Bettbox) 的衍生版本（GPL-3.0）。
本次构建包含的改动见 [CHANGES-vs-upstream.md](https://github.com/Catapult291/Bettbox-Mod/blob/main/CHANGES-vs-upstream.md)，
主要集中在这几处：

- 首页网络检测的 IP 来源：国外 HTTPS 源优先，全部失败回退国内源，不再跨源合并结果
- 脚本页「规则」区块：可在应用内直接添加规则，按「覆盖全局规则」前置生效
- 覆写页添加规则时的目标分组：只列顶层分组（GLOBAL 成员），隐藏分组跟随「显示隐藏项」开关
- 配置更新控制：新增「跟随更新」开关，「全部同步」只更新订阅型且开启该开关的配置；编辑页右上角可单独更新当前配置
- 桌面端右侧快捷控制栏（仅 Windows / macOS / Linux）：总开关 / 系统代理 / 虚拟网卡 / 出站模式常驻，Android 不显示
- 从 URL 导入不填名称时自动获取配置名称
- 桌面端二维码图片导入修复（Windows / Linux 原先必失败）；扫码识别成功直接进入「从 URL 导入」页
- 首页总开关与内核状态脱节修复（显示已停止、内核仍在跑且点不动）与界面挂起：新增每 5 秒一次的内核状态对账，
  启停动作与 IPC / 订阅请求补上超时，提权对话框不再阻塞界面

## 下载

| 平台 | 文件 |
| --- | --- |
| Android (arm64-v8a) | [Bettbox-VERSION-android-arm64-v8a.apk](https://github.com/Catapult291/Bettbox-Mod/releases/download/vVERSION/Bettbox-VERSION-android-arm64-v8a.apk) |
| Android (universal) | [Bettbox-VERSION-android-universal.apk](https://github.com/Catapult291/Bettbox-Mod/releases/download/vVERSION/Bettbox-VERSION-android-universal.apk) |
| Windows (x64) | [Bettbox-VERSION-windows-amd64-setup.exe](https://github.com/Catapult291/Bettbox-Mod/releases/download/vVERSION/Bettbox-VERSION-windows-amd64-setup.exe) |

## 说明

- 本构建使用本仓库自有证书签名，与官方 Bettbox 不同（包名相同）：Windows 安装程序可直接覆盖升级官方版；
  Android 未装签名校验豁免模块时需先卸载官方版再安装（会清除应用数据），装核心破解 / CorePatch 等模块的设备可直接覆盖且数据保留。
  此后本仓库各版本之间可正常覆盖升级。
- Windows 安装包未做代码签名，SmartScreen 可能提示“未知发布者”，选择“仍要运行”即可。
- 构建与改动明细：仓库根目录 `CHANGES-vs-upstream.md`；反馈请开 Issue。
- 感谢 [linux.do](https://linux.do) 社区。
