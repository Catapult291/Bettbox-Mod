import 'dart:convert';

import 'package:bett_box/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

Profile _profile({bool proxyUpdate = true}) {
  return Profile(
    id: 'a',
    label: 'A',
    url: 'https://example.com/sub',
    proxyUpdate: proxyUpdate,
    autoUpdateDuration: const Duration(minutes: 60),
  );
}

void main() {
  group('Profile proxyUpdate (代理更新)', () {
    test('JSON 往返保持开关，键名为 proxy-update', () {
      final json = _profile(proxyUpdate: false).toJson();
      expect(json['proxy-update'], isFalse);

      final restored = Profile.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );
      expect(restored.proxyUpdate, isFalse);
    });

    test('老配置缺少该字段时默认为开启', () {
      final restored = Profile.fromJson({
        'id': 'a',
        'url': 'https://example.com/sub',
        'autoUpdateDuration': 3600000000,
      });

      expect(restored.proxyUpdate, isTrue);
    });

    test('copyWith 切换开关且不影响其他字段', () {
      final base = _profile();
      final updated = base.copyWith(proxyUpdate: false);

      expect(updated.proxyUpdate, isFalse);
      expect(updated.followUpdate, base.followUpdate);
      expect(updated.autoUpdate, base.autoUpdate);
      expect(base.proxyUpdate, isTrue);
    });

    test('整份 Config 序列化后开关仍在（设置落盘走的就是这条）', () {
      final config = Config(
        themeProps: defaultThemeProps,
        patchClashConfig: defaultClashConfig,
        profiles: [_profile(proxyUpdate: false)],
      );

      final restored = Config.fromJson(
        jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>,
      );

      expect(restored.profiles.single.proxyUpdate, isFalse);
    });
  });
}
