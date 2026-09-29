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
}

class WindowsHelperIdentity {
  static const serviceName = '${AppIdentity.compactName}HelperService';
  static const pipeName = '\\\\.\\pipe\\${AppIdentity.compactName}.Helper';
}
