import 'package:bett_box/models/models.dart';
import 'package:bett_box/views/profiles/profiles.dart';
import 'package:flutter_test/flutter_test.dart';

Profile _profile({required String id, String url = '', bool followUpdate = true}) {
  return Profile(
    id: id,
    url: url,
    followUpdate: followUpdate,
    autoUpdateDuration: const Duration(minutes: 60),
  );
}

void main() {
  group('getSyncAllTargets 「全部同步」目标', () {
    test('只包含开启跟随更新的订阅配置', () {
      final targets = getSyncAllTargets([
        _profile(id: 'follow', url: 'https://example.com/a'),
        _profile(id: 'manual', url: 'https://example.com/b', followUpdate: false),
      ]);

      expect(targets.map((profile) => profile.id), ['follow']);
    });

    test('本地文件配置一律跳过', () {
      final targets = getSyncAllTargets([
        _profile(id: 'file', followUpdate: true),
        _profile(id: 'file-manual', followUpdate: false),
      ]);

      expect(targets, isEmpty);
    });

    test('全部关闭跟随更新时不产生任何更新目标', () {
      final targets = getSyncAllTargets([
        _profile(id: 'a', url: 'https://example.com/a', followUpdate: false),
        _profile(id: 'b', url: 'https://example.com/b', followUpdate: false),
      ]);

      expect(targets, isEmpty);
    });
  });
}
