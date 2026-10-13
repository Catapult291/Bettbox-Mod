import 'dart:io';

import 'package:bett_box/common/data_identity.dart';
import 'package:bett_box/common/identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempRoot;
  late String fakeAppData;
  late String company;
  late String legacy;
  late String pinned;

  setUp(() {
    // 模拟 %APPDATA%\Company\Product：tempRoot 充当 APPDATA。
    tempRoot = Directory.systemTemp.createTempSync('bettbox_data_id_');
    fakeAppData = tempRoot.path;
    company = p.join(fakeAppData, 'Catapult291', 'Bettbox');
    pinned = p.join(fakeAppData, 'com.appshub', 'Bettbox');
    legacy = pinned;
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  void writeUserData(String dirPath, {String config = 'mode: rule\n'}) {
    Directory(dirPath).createSync(recursive: true);
    File(p.join(dirPath, 'config.yaml')).writeAsStringSync(config);
  }

  void writeMarkerOnly(String dirPath) {
    Directory(dirPath).createSync(recursive: true);
    File(p.join(dirPath, dataDirIdentityMarker)).writeAsStringSync('x');
  }

  test('APPDATA 布局判定：标准路径 true，临时桩 false', () {
    expect(
      isWindowsAppDataLayout(company, appData: fakeAppData),
      isTrue,
    );
    final nonAppData = p.join(
      Directory.systemTemp.path,
      'bettbox_prev_cfg',
    );
    expect(isWindowsAppDataLayout(nonAppData, appData: fakeAppData), isFalse);
    expect(
      isWindowsAppDataLayout(nonAppData),
      isFalse,
      reason: 'systemTemp 的上两级不是本机 %APPDATA%',
    );
  });

  test('windows 路径解析不随 CompanyName 漂移', () {
    expect(
      windowsPinnedDataDir(company, appData: fakeAppData),
      pinned,
    );
    expect(
      windowsPinnedDataDir(company, appData: fakeAppData),
      windowsPinnedDataDir(pinned, appData: fakeAppData),
      reason: 'legacy 与钉死路径是同一条',
    );
    expect(windowsCompanyDataDir(company), company);
    expect(
      AppIdentity.windowsDataDirName.replaceAll('/', r'\'),
      r'com.appshub\Bettbox',
    );
  });

  test('非 APPDATA 布局：pinned 原样返回，不改写', () {
    final stub = p.join(Directory.systemTemp.path, 'bettbox_stub');
    expect(windowsPinnedDataDir(stub), stub);
  });

  test('hasUserData：空目录 / 仅 marker / 有 config', () {
    expect(windowsDataDirHasUserData(p.join(tempRoot.path, 'missing')), isFalse);
    writeMarkerOnly(p.join(tempRoot.path, 'empty_marker'));
    expect(
      windowsDataDirHasUserData(p.join(tempRoot.path, 'empty_marker')),
      isFalse,
    );
    writeUserData(p.join(tempRoot.path, 'with_config'));
    expect(
      windowsDataDirHasUserData(p.join(tempRoot.path, 'with_config')),
      isTrue,
    );
  });

  test('hasUserData：空 shared_preferences / 有 profiles', () {
    final spDir = p.join(tempRoot.path, 'sp');
    Directory(spDir).createSync(recursive: true);
    File(p.join(spDir, 'shared_preferences.json')).writeAsStringSync('{}');
    expect(windowsDataDirHasUserData(spDir), isFalse);

    File(p.join(spDir, 'shared_preferences.json')).writeAsStringSync(
      '{"a":1}',
    );
    expect(windowsDataDirHasUserData(spDir), isTrue);

    final profDir = p.join(tempRoot.path, 'prof');
    Directory(p.join(profDir, 'profiles')).createSync(recursive: true);
    expect(windowsDataDirHasUserData(profDir), isFalse);
    File(p.join(profDir, 'profiles', 'p1.yaml')).writeAsStringSync('x: 1');
    expect(windowsDataDirHasUserData(profDir), isTrue);
  });

  test('全新安装：不搬迁，只落哨兵', () {
    final migrated = migrateWindowsDataDirOnce(
      pinned: pinned,
      legacy: legacy,
      company: company,
    );
    expect(migrated, isFalse);
    expect(File(p.join(pinned, dataDirIdentityMarker)).existsSync(), isTrue);
    expect(windowsDataDirHasUserData(pinned), isFalse);
  });

  test('Company 有数据且钉死目录为空：搬过去并落哨兵', () {
    writeUserData(company, config: 'mode: rule\n# live\n');
    final profiles = p.join(company, 'profiles');
    Directory(profiles).createSync(recursive: true);
    File(p.join(profiles, 'sub.yaml')).writeAsStringSync('id: sub\n');

    final migrated = migrateWindowsDataDirOnce(
      pinned: pinned,
      legacy: legacy,
      company: company,
    );
    expect(migrated, isTrue);
    expect(
      File(p.join(pinned, 'config.yaml')).readAsStringSync(),
      contains('# live'),
    );
    expect(File(p.join(pinned, 'profiles', 'sub.yaml')).existsSync(), isTrue);
    expect(File(p.join(company, 'config.yaml')).existsSync(), isFalse);
    expect(File(p.join(pinned, dataDirIdentityMarker)).existsSync(), isTrue);
  });

  test('钉死目录已有用户数据：不搬、不覆盖', () {
    writeUserData(company, config: 'from: company\n');
    writeUserData(pinned, config: 'from: pinned\n');

    final migrated = migrateWindowsDataDirOnce(
      pinned: pinned,
      legacy: legacy,
      company: company,
    );
    expect(migrated, isFalse);
    expect(
      File(p.join(pinned, 'config.yaml')).readAsStringSync(),
      contains('from: pinned'),
    );
    expect(
      File(p.join(company, 'config.yaml')).readAsStringSync(),
      contains('from: company'),
    );
    expect(File(p.join(pinned, dataDirIdentityMarker)).existsSync(), isTrue);
  });

  test('哨兵已存在：二次调用直接 false', () {
    writeUserData(company);
    migrateWindowsDataDirOnce(pinned: pinned, legacy: legacy, company: company);
    File(p.join(company, 'config.yaml')).writeAsStringSync('second\n');
    final again = migrateWindowsDataDirOnce(
      pinned: pinned,
      legacy: legacy,
      company: company,
    );
    expect(again, isFalse);
  });
}
