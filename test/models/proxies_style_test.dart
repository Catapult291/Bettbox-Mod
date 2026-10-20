import 'dart:convert';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProxiesStyle 自定义样式标记与序列化', () {
    test('默认情况下 hasCustomizedStyle 为 false', () {
      const style = ProxiesStyle();

      expect(style.type, ProxiesType.tab);
      expect(style.iconStyle, ProxiesIconStyle.none);
      expect(style.hasCustomizedStyle, isFalse);
    });

    test('排序默认选中延迟', () {
      expect(const ProxiesStyle().sortType, ProxiesSortType.delay);

      final oldJson = {'type': 'tab', 'iconStyle': 'none'};
      expect(
        ProxiesStyle.fromJson(oldJson).sortType,
        ProxiesSortType.delay,
      );
    });

    test('序列化后能够正确恢复 hasCustomizedStyle 状态', () {
      const style = ProxiesStyle(
        type: ProxiesType.list,
        iconStyle: ProxiesIconStyle.icon,
        hasCustomizedStyle: true,
      );

      final restored = ProxiesStyle.fromJson(
        jsonDecode(jsonEncode(style.toJson())) as Map<String, dynamic>,
      );

      expect(restored.type, ProxiesType.list);
      expect(restored.iconStyle, ProxiesIconStyle.icon);
      expect(restored.hasCustomizedStyle, isTrue);
    });

    test('从没有 hasCustomizedStyle 字段的旧 JSON 反序列化时默认为 false', () {
      final oldJson = {
        'type': 'tab',
        'iconStyle': 'none',
      };

      final restored = ProxiesStyle.fromJson(oldJson);

      expect(restored.hasCustomizedStyle, isFalse);
    });
  });
}
