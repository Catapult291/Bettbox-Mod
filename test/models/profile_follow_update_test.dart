import 'dart:convert';

import 'package:bett_box/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

Profile _profile({bool followUpdate = true}) {
  return Profile(
    id: 'a',
    label: 'A',
    url: 'https://example.com/sub',
    followUpdate: followUpdate,
    autoUpdateDuration: const Duration(minutes: 60),
  );
}

void main() {
  group('Profile followUpdate (跟随更新)', () {
    test('JSON 往返保持开关，键名为 follow-update', () {
      final json = _profile(followUpdate: false).toJson();
      expect(json['follow-update'], isFalse);

      final restored = Profile.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );
      expect(restored.followUpdate, isFalse);
    });

    test('老配置缺少该字段时默认为开启', () {
      final restored = Profile.fromJson({
        'id': 'a',
        'url': 'https://example.com/sub',
        'autoUpdateDuration': 3600000000,
      });

      expect(restored.followUpdate, isTrue);
    });

    test('copyWith 切换开关且不影响其他字段', () {
      final base = _profile();
      final updated = base.copyWith(followUpdate: false);

      expect(updated.followUpdate, isFalse);
      expect(updated.id, base.id);
      expect(updated.url, base.url);
      expect(updated.autoUpdate, base.autoUpdate);
      expect(base.followUpdate, isTrue);
    });
  });
}
