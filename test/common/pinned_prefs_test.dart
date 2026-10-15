import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/pinned_prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempRoot;
  late File prefsFile;
  late PinnedPreferencesStore store;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('bettbox_pinned_prefs_');
    prefsFile = File(p.join(tempRoot.path, 'shared_preferences.json'));
    store = PinnedPreferencesStore(prefsFile);
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  group('PinnedPreferencesStore', () {
    test('文件不存在时 getAll 为空', () async {
      expect(await store.getAll(), isEmpty);
    });

    test('setValue / getAll 往返，文件为 flutter. 前缀 JSON', () async {
      expect(await store.setValue('Bool', 'flutter.autoLaunch', true), isTrue);
      expect(
        await store.setValue('String', 'flutter.config', '{"a":1}'),
        isTrue,
      );
      final all = await store.getAll();
      expect(all['flutter.autoLaunch'], true);
      expect(all['flutter.config'], '{"a":1}');

      final onDisk =
          json.decode(prefsFile.readAsStringSync()) as Map<String, dynamic>;
      expect(onDisk['flutter.autoLaunch'], true);
      expect(onDisk['flutter.config'], '{"a":1}');
    });

    test('remove 删单键；clear 只删 flutter. 前缀键', () async {
      await store.setValue('Int', 'flutter.count', 3);
      await store.setValue('String', 'other.key', 'keep');
      expect(await store.remove('flutter.count'), isTrue);
      expect((await store.getAll()).containsKey('flutter.count'), isFalse);

      await store.setValue('Bool', 'flutter.flag', false);
      await store.clear();
      final all = await store.getAll();
      expect(all.containsKey('flutter.flag'), isFalse);
      expect(all['other.key'], 'keep');
    });

    test('损坏 JSON 按空表处理并不炸', () async {
      prefsFile.writeAsStringSync('{not json');
      expect(await store.getAll(), isEmpty);
      expect(await store.setValue('Bool', 'flutter.x', true), isTrue);
      expect((await store.getAll())['flutter.x'], true);
    });

    test('新实例能读到上一个实例写盘的内容', () async {
      await store.setValue('Bool', 'flutter.persist', true);
      final fresh = PinnedPreferencesStore(prefsFile);
      expect((await fresh.getAll())['flutter.persist'], true);
    });
  });

  group('migrateLegacyPreferencesFile', () {
    late String legacyDir;
    late String pinnedDir;

    setUp(() {
      legacyDir = p.join(tempRoot.path, 'Catapult291', 'Bettbox');
      pinnedDir = p.join(tempRoot.path, 'com.appshub', 'Bettbox');
    });

    void writeLegacy(String content, {Duration? age}) {
      Directory(legacyDir).createSync(recursive: true);
      final f = File(p.join(legacyDir, 'shared_preferences.json'));
      f.writeAsStringSync(content);
      if (age != null) {
        f.setLastModifiedSync(DateTime.now().subtract(age));
      }
    }

    void writePinned(String content, {Duration? age}) {
      Directory(pinnedDir).createSync(recursive: true);
      final f = File(p.join(pinnedDir, 'shared_preferences.json'));
      f.writeAsStringSync(content);
      if (age != null) {
        f.setLastModifiedSync(DateTime.now().subtract(age));
      }
    }

    test('同目录不搬', () {
      expect(
        migrateLegacyPreferencesFile(legacyDir: pinnedDir, pinnedDir: pinnedDir),
        isFalse,
      );
    });

    test('旧侧缺失不搬', () {
      writePinned('{"flutter.a":1}');
      expect(
        migrateLegacyPreferencesFile(legacyDir: legacyDir, pinnedDir: pinnedDir),
        isFalse,
      );
    });

    test('钉死侧缺失时复制旧侧', () {
      writeLegacy('{"flutter.live":true}');
      expect(
        migrateLegacyPreferencesFile(legacyDir: legacyDir, pinnedDir: pinnedDir),
        isTrue,
      );
      expect(
        File(p.join(pinnedDir, 'shared_preferences.json')).readAsStringSync(),
        '{"flutter.live":true}',
      );
      // 旧文件保留给降级路径。
      expect(File(p.join(legacyDir, 'shared_preferences.json')).existsSync(),
          isTrue);
    });

    test('旧侧更新（分裂态）时覆盖钉死侧', () {
      writePinned('{"flutter.stale":1}', age: const Duration(hours: 2));
      writeLegacy('{"flutter.live":1}', age: const Duration(minutes: 5));
      expect(
        migrateLegacyPreferencesFile(legacyDir: legacyDir, pinnedDir: pinnedDir),
        isTrue,
      );
      expect(
        File(p.join(pinnedDir, 'shared_preferences.json')).readAsStringSync(),
        '{"flutter.live":1}',
      );
    });

    test('钉死侧更新时不动', () {
      writePinned('{"flutter.newer":1}', age: const Duration(minutes: 5));
      writeLegacy('{"flutter.old":1}', age: const Duration(hours: 2));
      expect(
        migrateLegacyPreferencesFile(legacyDir: legacyDir, pinnedDir: pinnedDir),
        isFalse,
      );
      expect(
        File(p.join(pinnedDir, 'shared_preferences.json')).readAsStringSync(),
        '{"flutter.newer":1}',
      );
    });

    test('迁移后钉死侧持续更新，不再被陈旧旧侧覆盖（无哨兵自洽）', () {
      writeLegacy('{"flutter.v":1}', age: const Duration(hours: 1));
      expect(
        migrateLegacyPreferencesFile(legacyDir: legacyDir, pinnedDir: pinnedDir),
        isTrue,
      );
      // 模拟应用写盘：钉死侧 mtime 变新。
      writePinned('{"flutter.v":2,"flutter.w":3}');
      // 旧侧文件保持旧 mtime，再来一轮也不覆盖。
      expect(
        migrateLegacyPreferencesFile(legacyDir: legacyDir, pinnedDir: pinnedDir),
        isFalse,
      );
      expect(
        File(p.join(pinnedDir, 'shared_preferences.json')).readAsStringSync(),
        '{"flutter.v":2,"flutter.w":3}',
      );
    });

    test('旧侧空文件不搬', () {
      writePinned('{"flutter.keep":1}');
      writeLegacy('');
      expect(
        migrateLegacyPreferencesFile(legacyDir: legacyDir, pinnedDir: pinnedDir),
        isFalse,
      );
    });
  });
}
