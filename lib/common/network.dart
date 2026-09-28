import 'dart:io';

extension NetworkInterfaceExt on NetworkInterface {
  bool get isWifi {
    final nameLowCase = name.toLowerCase();
    if (nameLowCase.contains('wlan') ||
        nameLowCase.contains('wi-fi') ||
        nameLowCase == 'en0' ||
        nameLowCase == 'eth0') {
      return true;
    }

    return false;
  }

  bool get includesIPv4 {
    return addresses.any((addr) => addr.isIPv4);
  }
}

extension InternetAddressExt on InternetAddress {
  bool get isIPv4 {
    return type == InternetAddressType.IPv4;
  }
}

/// 真连一次回环端口，判断有没有监听者。
///
/// 内核的 `startListener` 只表示"指令被接受"（内部只置一个运行标志），监听是否
/// 真的建立它并不回报——所以"端口起没起"只能从客户端侧实测。
Future<bool> isLoopbackPortListening(
  int port, {
  Duration timeout = const Duration(milliseconds: 800),
}) async {
  if (port <= 0) return false;
  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: timeout,
    );
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}
