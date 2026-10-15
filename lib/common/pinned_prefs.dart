import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'common.dart';

/// Windows 偏好设置钉死到 [AppPath] 数据目录的平台存储。
///
/// 插件自带的 Windows 实现把 `shared_preferences.json` 写在
/// `getApplicationSupportDirectory()`（随 exe 版本资源 `CompanyName` 漂移，见
/// `data_identity.dart`）；本类改写到 [file]，文件格式与插件一致（JSON 对象、
/// `flutter.` 前缀键原样存盘），既有文件可直接续用。
///
/// 只覆写经典 `SharedPreferences` 用到的四个入口；Async 通道不走这里。
class PinnedPreferencesStore extends SharedPreferencesStorePlatform {
  PinnedPreferencesStore(this.file);

  /// 偏好文件完整路径：`<数据目录>/shared_preferences.json`。
  final File file;

  Map<String, Object>? _cache;

  @override
  Future<Map<String, Object>> getAll() async {
    return Map<String, Object>.from(await _read());
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final prefs = await _read();
    prefs[key] = value;
    return _write(prefs);
  }

  @override
  Future<bool> remove(String key) async {
    final prefs = await _read();
    prefs.remove(key);
    return _write(prefs);
  }

  @override
  Future<bool> clear() async {
    final prefs = await _read();
    prefs.removeWhere((key, _) => key.startsWith('flutter.'));
    return _write(prefs);
  }

  Future<Map<String, Object>> _read() async {
    final cached = _cache;
    if (cached != null) return cached;
    var prefs = <String, Object>{};
    if (file.existsSync()) {
      final raw = file.readAsStringSync();
      if (raw.isNotEmpty) {
        try {
          final data = json.decode(raw);
          if (data is Map) prefs = data.cast<String, Object>();
        } catch (_) {
          // 损坏内容按空表处理，首次写盘会覆盖。
        }
      }
    }
    _cache = prefs;
    return prefs;
  }

  Future<bool> _write(Map<String, Object> prefs) async {
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(json.encode(prefs));
      _cache = prefs;
      return true;
    } catch (e) {
      commonPrint.log('PinnedPreferencesStore: write failed: $e');
      return false;
    }
  }
}

/// 把旧身份目录里仍更新的偏好文件回拷进钉死目录（一次性、按 mtime 判新）。
///
/// v1.19.19 起 prefs 读写已钉死，但现网存在分裂态：活跃文件留在
/// `<APPDATA>\<CompanyName>\<Product>\`，钉死目录里那份可能是陈旧残留。
/// 规则：钉死侧缺失，或旧侧 mtime 更新时，把旧侧**复制**过来（不删旧文件，
/// 留给降级路径）；此后钉死侧持续被写、mtime 恒新，不会被再次覆盖。
/// 无哨兵——降级到旧版本改了设置再升回来时，较新的旧侧文件仍能被采纳。
bool migrateLegacyPreferencesFile({
  required String legacyDir,
  required String pinnedDir,
  String fileName = 'shared_preferences.json',
}) {
  if (p.equals(legacyDir, pinnedDir)) return false;
  final legacyFile = File(p.join(legacyDir, fileName));
  final pinnedFile = File(p.join(pinnedDir, fileName));
  if (!legacyFile.existsSync()) return false;
  final legacyStat = legacyFile.statSync();
  if (legacyStat.size == 0) return false;
  if (pinnedFile.existsSync()) {
    final pinnedStat = pinnedFile.statSync();
    if (pinnedStat.modified.millisecondsSinceEpoch >=
        legacyStat.modified.millisecondsSinceEpoch) {
      return false;
    }
  }
  pinnedFile.parent.createSync(recursive: true);
  legacyFile.copySync(pinnedFile.path);
  commonPrint.log(
    'AppPath: copied legacy preferences $legacyFile -> $pinnedFile',
  );
  return true;
}

/// 把偏好存储接到 [AppPath] 钉死数据目录（仅 Windows；其他平台保持插件默认）。
///
/// 必须在任何 `SharedPreferences.getInstance()`（含顶层 `preferences` 首次
/// 访问）之前调用：`main` / `_service` 在 `WidgetsFlutterBinding.ensureInitialized()`
/// 之后各调一次。
Future<void> installPinnedPreferencesStore() async {
  if (!system.isWindows) return;
  final pinnedDir = await appPath.homeDirPath;
  try {
    final legacyDir = (await getApplicationSupportDirectory()).path;
    migrateLegacyPreferencesFile(legacyDir: legacyDir, pinnedDir: pinnedDir);
  } catch (e) {
    commonPrint.log('AppPath: preferences migration skipped: $e');
  }
  SharedPreferencesStorePlatform.instance = PinnedPreferencesStore(
    File(p.join(pinnedDir, 'shared_preferences.json')),
  );
}

