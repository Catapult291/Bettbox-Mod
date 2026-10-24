import 'dart:convert';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VpnProps 托盘点击行为', () {
    test('默认保留托盘增强关闭，左键显示面板、右键显示菜单', () {
      const props = VpnProps();

      expect(props.trayEnhancement, isFalse);
      expect(props.trayLeftClickBehavior, TrayClickBehavior.showPanel);
      expect(props.trayRightClickBehavior, TrayClickBehavior.showMenu);
    });

    test('序列化后能够独立恢复左右键设置及托盘增强设置', () {
      const props = VpnProps(
        trayEnhancement: true,
        trayLeftClickBehavior: TrayClickBehavior.showMenu,
        trayRightClickBehavior: TrayClickBehavior.showPanel,
      );

      final restored = VpnProps.fromJson(
        jsonDecode(jsonEncode(props.toJson())) as Map<String, dynamic>,
      );

      expect(restored.trayEnhancement, isTrue);
      expect(restored.trayLeftClickBehavior, TrayClickBehavior.showMenu);
      expect(restored.trayRightClickBehavior, TrayClickBehavior.showPanel);
    });
  });

  group('VpnProps 绕过 VPN', () {
    test('默认允许绕过 VPN', () {
      const props = VpnProps();

      expect(props.allowBypass, isTrue);
      expect(VpnProps.fromJson(const <String, dynamic>{}).allowBypass, isTrue);
    });

    test('序列化后保留用户关闭的绕过 VPN 设置', () {
      const props = VpnProps(allowBypass: false);

      final restored = VpnProps.fromJson(
        jsonDecode(jsonEncode(props.toJson())) as Map<String, dynamic>,
      );

      expect(restored.allowBypass, isFalse);
    });
  });
}
