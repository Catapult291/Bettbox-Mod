import 'package:bett_box/common/system.dart';
import 'package:proxy/proxy.dart';

/// 系统代理的 macOS / Linux 实现（`plugins/proxy` 的纯 Dart 路径）。
///
/// Windows 改走 Rust 侧 `bettbox_native`（见 `lib/common/system_proxy.dart`），
/// 那里带快照与「只还原自己改过的连接」的语义；这里只服务另外两个桌面平台。
final proxy = (system.isMacOS || system.isLinux) ? Proxy() : null;
