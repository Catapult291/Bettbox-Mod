const _useDevIdentity = bool.fromEnvironment('APP_DEV');

class AppIdentity {
  static const isDev = _useDevIdentity;

  static const productName = 'Bettbox';

  /// 「关于」页展示的品牌名。可执行文件名、数据目录、助手服务名与计划任务名仍取
  /// [productName]，改这里不影响既有安装的升级路径与配置目录。
  static const brandName = 'Bettbox-mod';
  static const devSuffix = 'Dev';
  static const packageId = 'com.appshub.bettbox';

  static const compactName = isDev ? '$productName$devSuffix' : productName;
  static const displayName = isDev ? '$productName Dev' : productName;
  static const mainExecutableName = productName;
  static const coreExecutableName = '${compactName}Core';
  static const dataDirName = compactName;
  static const tunDeviceName = compactName;

  /// 上游 exe 版本资源里用过的 `CompanyName`；Windows 上 `getApplicationSupportDirectory()`
  /// 会把它拼进数据目录父路径。发布者显示可以改，这个值对应的身份目录要保留给卸载清理用。
  static const companyDirName = 'com.appshub';

  /// Windows 生产数据目录钉在 `companyDirName\productName`，不再随
  /// `Runner.rc` 的 `CompanyName` 漂移（见 `data_identity.dart`）。
  static const windowsDataDirName = '$companyDirName\\$productName';
}

class WindowsHelperIdentity {
  static const serviceName = '${AppIdentity.compactName}HelperService';
  static const pipeName = '\\\\.\\pipe\\${AppIdentity.compactName}.Helper';
}
