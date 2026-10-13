import 'dart:io';

import 'package:path/path.dart' as p;

import 'identity.dart';

/// Windows 数据目录身份标记：钉死身份后写入目标目录，避免每次启动都重扫迁移。
const dataDirIdentityMarker = '.bettbox-data-dir';

/// v1.19.7 起 `Runner.rc` 的 `CompanyName` 变成 `Catapult291` 时，
/// `getApplicationSupportDirectory()` 落在的那份「公司名\Product」目录。
///
/// 迁移用；应用运行时**不再**把这个路径当数据目录。
String windowsCompanyDataDir(String appSupportPath) {
  return appSupportPath;
}

/// 改 `CompanyName` 之前、上游身份下的数据目录，与钉死后的生产目录是同一条路径。
String windowsLegacyDataDir(String appSupportPath) {
  return windowsPinnedDataDir(appSupportPath);
}

/// [appSupportPath] 是否是 Windows 生产 `path_provider` 的标准布局
/// `%APPDATA%\Company\Product`。
///
/// 测试桩把 applicationSupport 指到临时目录时这里为 false——那些路径上层不是
/// `%APPDATA%`，不得钉死或回迁（否则会把桩目录里的 fixture 当用户数据搬走）。
/// [appData] 供测试注入，缺省读环境变量。
bool isWindowsAppDataLayout(String appSupportPath, {String? appData}) {
  final root = appData ?? Platform.environment['APPDATA'];
  if (root == null || root.isEmpty) return false;
  final parent = p.dirname(p.dirname(appSupportPath));
  return p.equals(parent, p.normalize(root));
}

/// 钉死后的生产数据目录：不再随 exe 版本资源的 `CompanyName` 漂移。
///
/// [appSupportPath] 是 `%APPDATA%\Company\Product`；钉死路径取其上两级（`%APPDATA%`）
/// 再拼 `com.appshub\Bettbox`。非标准布局原样返回，由调用方跳过钉死。
String windowsPinnedDataDir(String appSupportPath, {String? appData}) {
  if (!isWindowsAppDataLayout(appSupportPath, appData: appData)) {
    return appSupportPath;
  }
  final appDataRoot = p.dirname(p.dirname(appSupportPath));
  return p.join(
    appDataRoot,
    AppIdentity.companyDirName,
    AppIdentity.productName,
  );
}

/// 目录是否含可识别的用户数据（升级迁移的判据）。
bool windowsDataDirHasUserData(String dirPath) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return false;
  if (File(p.join(dirPath, 'config.yaml')).existsSync()) return true;
  final prefs = File(p.join(dirPath, 'shared_preferences.json'));
  if (prefs.existsSync() && prefs.lengthSync() > 2) return true;
  final profiles = Directory(p.join(dirPath, 'profiles'));
  if (profiles.existsSync() && profiles.listSync().isNotEmpty) return true;
  return false;
}

/// 一次性把 v1.19.7+ 的 `Company\Product` 数据目录搬回钉死身份。
///
/// 仅当「钉死目录还没有用户数据、上游身份目录也没有、而 Company 目录有」时搬迁；
/// 其余情况（全新安装、用户已在旧身份重配、两边都有数据）只落哨兵、不搬。
/// 哨兵写在钉死目录内；搬迁失败会抛出且不写哨兵，下次启动可重试。
bool migrateWindowsDataDirOnce({
  required String pinned,
  required String legacy,
  required String company,
}) {
  final sentinel = File(p.join(pinned, dataDirIdentityMarker));
  if (sentinel.existsSync()) return false;

  final companyHasUserData = windowsDataDirHasUserData(company);
  final legacyHasUserData = windowsDataDirHasUserData(legacy);
  final pinnedHasUserData = windowsDataDirHasUserData(pinned);

  Directory(pinned).createSync(recursive: true);

  var migrated = false;
  if (!pinnedHasUserData && !legacyHasUserData && companyHasUserData) {
    for (final item in Directory(company).listSync()) {
      final name = p.basename(item.path);
      final target = p.join(pinned, name);
      if (item is Directory) {
        item.renameSync(target);
      } else if (item is File) {
        item.renameSync(target);
      } else if (item is Link) {
        item.renameSync(target);
      }
    }
    migrated = true;
  }

  sentinel.writeAsStringSync('pinned=${AppIdentity.windowsDataDirName}\n');
  return migrated;
}
