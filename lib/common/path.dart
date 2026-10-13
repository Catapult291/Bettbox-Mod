import 'dart:async';
import 'dart:io';

import 'package:bett_box/common/common.dart';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

class AppPath {
  static AppPath? _instance;
  Completer<Directory> dataDir = Completer();
  Completer<Directory> downloadDir = Completer();
  Completer<Directory> tempDir = Completer();
  late String appDirPath;

  AppPath._internal() {
    appDirPath = join(dirname(Platform.resolvedExecutable));
    getApplicationSupportDirectory().then((value) {
      if (system.isWindows && AppIdentity.isDev) {
        dataDir.complete(
          Directory(join(value.parent.path, AppIdentity.dataDirName)),
        );
      } else if (system.isWindows) {
        dataDir.complete(
          Directory(_resolvePinnedWindowsDataDir(value.path)),
        );
      } else {
        dataDir.complete(value);
      }
    });
    getTemporaryDirectory().then((value) {
      tempDir.complete(value);
    });
    getDownloadsDirectory().then((value) {
      downloadDir.complete(value);
    });
  }

  factory AppPath() {
    _instance ??= AppPath._internal();
    return _instance!;
  }

  String get executableExtension {
    return system.isWindows ? '.exe' : '';
  }

  String get executableDirPath {
    final currentExecutablePath = Platform.resolvedExecutable;
    return dirname(currentExecutablePath);
  }

  String get corePath {
    return join(
      executableDirPath,
      '${AppIdentity.coreExecutableName}$executableExtension',
    );
  }

  String get helperPath {
    final devWorkspacePath = _devWorkspacePath;
    if (devWorkspacePath != null) {
      final helperPath = join(
        devWorkspacePath,
        'libclash',
        'windows',
        '$appHelperService$executableExtension',
      );
      if (File(helperPath).existsSync()) {
        return helperPath;
      }
    }

    return join(executableDirPath, '$appHelperService$executableExtension');
  }

  String? get _devWorkspacePath {
    if (!system.isWindows || !AppIdentity.isDev) return null;
    var directory = Directory(executableDirPath);
    for (var depth = 0; depth < 8; depth++) {
      final pubspecPath = join(directory.path, 'pubspec.yaml');
      if (File(pubspecPath).existsSync()) return directory.path;

      final parent = directory.parent;
      if (parent.path == directory.path) break;
      directory = parent;
    }

    return null;
  }

  Future<String> get downloadDirPath async {
    final directory = await downloadDir.future;
    return directory.path;
  }

  Future<String> get homeDirPath async {
    final directory = await dataDir.future;
    return directory.path;
  }

  Future<String> get configFilePath async {
    return join(await homeDirPath, 'config.yaml');
  }

  Future<String> get lockFilePath async {
    final directory = await dataDir.future;
    return join(directory.path, '${AppIdentity.dataDirName}.lock');
  }

  Future<String> get controlSocketPath async {
    final directory = await dataDir.future;
    return join(directory.path, '${AppIdentity.dataDirName}.control.sock');
  }

  Future<String> get controlPortFilePath async {
    final directory = await dataDir.future;
    return join(directory.path, '${AppIdentity.dataDirName}.control.port');
  }

  Future<String> get sharedPreferencesPath async {
    final directory = await dataDir.future;
    return join(directory.path, 'shared_preferences.json');
  }

  /// 系统代理看门狗可执行文件：优先取与应用同目录的那份（CMake install 的结果），
  /// 开发态再退回仓库 cargo 产物（与 `lib/rust/native_library.dart` 同一套候选）。
  String get proxyGuardPath {
    final fileName = 'BettboxProxyGuard.exe';
    final candidates = [
      join(executableDirPath, fileName),
      for (final profile in ['release', 'debug'])
        join(Directory.current.path, 'rust', 'target', profile, fileName),
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return candidates.first;
  }

  /// 看门狗的快照文件：应用在系统代理启用成功后写入，还原成功后删除；
  /// 看门狗在应用进程退出后读它决定是否还原。
  Future<String> get proxyGuardSnapshotPath async {
    final directory = await dataDir.future;
    return join(directory.path, 'system_proxy_guard.snapshot.json');
  }

  /// 看门狗日志（应用拉起前会先清掉上一轮的）。
  Future<String> get proxyGuardLogPath async {
    final directory = await dataDir.future;
    return join(directory.path, 'system_proxy_guard.log');
  }

  Future<String> get helperAuthKeyPath async {
    final directory = await dataDir.future;
    return join(directory.path, 'helper_auth.key');
  }

  /// 交给 helper（SYSTEM 身份）启动时读取的鉴权 key 文件。
  ///
  /// 与 [helperAuthKeyPath] 不同，这份必须是明文：SYSTEM 无法解密当前用户的
  /// DPAPI 数据。它放在数据目录，继承「当前用户 + SYSTEM + Administrators」的
  /// ACL，因此服务注册表里只留这个路径也不会把 key 泄露给其他本机用户。
  Future<String> get helperServiceKeyPath async {
    final directory = await dataDir.future;
    return join(directory.path, 'helper_auth_service.key');
  }

  Future<String> get profilesPath async {
    final directory = await dataDir.future;
    return join(directory.path, profilesDirectoryName);
  }

  Future<String> getProfilePath(String id) async {
    final directory = await profilesPath;
    return join(directory, '$id.yaml');
  }

  Future<String> getProvidersDirPath(String id) async {
    final directory = await profilesPath;
    return join(directory, 'providers', id);
  }

  Future<String> getProvidersFilePath(
    String id,
    String type,
    String url,
  ) async {
    final directory = await profilesPath;
    return join(directory, 'providers', id, type, url.toMd5());
  }

  Future<String> get tempPath async {
    final directory = await tempDir.future;
    return directory.path;
  }

  Future<String> get uiPath async {
    final directory = await dataDir.future;
    return join(directory.path, 'ui');
  }
}

/// Windows 生产数据目录：钉在 `com.appshub\Bettbox`，启动时做一次性回迁。
///
/// [appSupport] 是 `getApplicationSupportDirectory()` 的返回值（现网 `CompanyName`
/// 对应的目录）。dev 身份不走这里（见 `AppPath._internal`）；非 `%APPDATA%\Company\Product`
/// 布局（测试桩）原样返回，不钉死、不回迁。
String _resolvePinnedWindowsDataDir(String appSupport) {
  if (!isWindowsAppDataLayout(appSupport)) return appSupport;
  final pinned = windowsPinnedDataDir(appSupport);
  final legacy = windowsLegacyDataDir(appSupport);
  final company = windowsCompanyDataDir(appSupport);
  try {
    final migrated = migrateWindowsDataDirOnce(
      pinned: pinned,
      legacy: legacy,
      company: company,
    );
    if (migrated) {
      commonPrint.log('AppPath: migrated data dir $company -> $pinned');
    }
  } catch (e) {
    commonPrint.log('AppPath: data dir migration failed: $e');
  }
  return pinned;
}

final appPath = AppPath();
