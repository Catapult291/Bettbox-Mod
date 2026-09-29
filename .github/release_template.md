# Bettbox-Mod VERSION

本仓库是 [appshubcc/Bettbox](https://github.com/appshubcc/Bettbox) 的衍生版本（GPL-3.0）。
本次构建包含的改动见 [CHANGES-vs-upstream.md](https://github.com/Catapult291/Bettbox-Mod/blob/main/CHANGES-vs-upstream.md)，
主要集中在这几处：

- 首页网络检测的 IP 来源：国外 HTTPS 源优先，全部失败回退国内源，不再跨源合并结果
- 脚本页「规则」区块：可在应用内直接添加规则，按「覆盖全局规则」前置生效
- 脚本页添加规则时的目标分组：只列顶层分组（GLOBAL 成员），隐藏分组跟随「显示隐藏项」开关
- 配置更新控制：新增「跟随更新」开关，「全部同步」只更新订阅型且开启该开关的配置；编辑页右上角可单独更新当前配置
- 桌面端右侧快捷控制栏（仅 Windows / macOS / Linux）：总开关 / 系统代理 / 虚拟网卡 / 出站模式常驻，Android 不显示
- 从 URL 导入不填名称时自动获取配置名称
- 桌面端二维码图片导入修复（Windows / Linux 原先必失败）；扫码识别成功直接进入「从 URL 导入」页
- 首页总开关与内核状态脱节修复（显示已停止、内核仍在跑且点不动）与界面挂起：新增每 5 秒一次的内核状态对账，
  启停动作与 IPC / 订阅请求补上超时，提权对话框不再阻塞界面
- 内核"半死"（进程在、IPC 不应答）自动恢复：后台分组刷新不再与启停抢锁；启动前先探测内核，不应答就自动
  重启内核并提示；恢复全程（含等待）总开关转圈并禁用，不再只是一个灰着的开关
- 修掉挂死启动链的旧 socket：内核崩溃 / 被强杀后旧连接上的 `close()` 会一直等发送缓冲区，整条启动链卡在
  这一步，现加 2 秒上界并强制断开、重建 IPC 连接
- 启动成功判据改为 `mixed-port` 真的在监听：内核只回报"指令被接受"，客户端原先直接丢弃返回值，指令被丢或
- 吸收上游 9/10～9/28 的健壮性补丁：内核 panic 恢复、运行配置写入原子化（时间戳临时文件 + 重试，不再出现「重试前先删掉目标配置」）、助手托管下重启前先停旧内核、`_initCore` 去重、换节点后关连接改为等待、内核返回值按类型收敛
- 平台专项：Windows 安装器改 `sc config` 就地改指向（升级不再先删助手服务）；内置编辑器修 Windows 中文输入错位；脚本引擎健壮化 + 空闲归还内存；Android 17 兼容（网络权限、文件 `mode` 收敛、`flclash://` 导入）
  端口没起来时开关会停在"运行中"的假状态；现在失败会重试一次，仍失败就拨回已停止并提示

## 下载

| 平台 | 文件 |
| --- | --- |
| Android (arm64-v8a) | [Bettbox-VERSION-android-arm64-v8a.apk](https://github.com/Catapult291/Bettbox-Mod/releases/download/vVERSION/Bettbox-VERSION-android-arm64-v8a.apk) |
| Android (universal) | [Bettbox-VERSION-android-universal.apk](https://github.com/Catapult291/Bettbox-Mod/releases/download/vVERSION/Bettbox-VERSION-android-universal.apk) |
| Windows (x64) | [Bettbox-VERSION-windows-amd64-setup.exe](https://github.com/Catapult291/Bettbox-Mod/releases/download/vVERSION/Bettbox-VERSION-windows-amd64-setup.exe) |

## 说明

- 构建与改动明细：仓库根目录 `CHANGES-vs-upstream.md`；反馈请开 Issue。
