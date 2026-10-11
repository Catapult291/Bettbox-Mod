import 'dart:io';

import 'package:flutter_app_builder/src/build_config.dart';
import 'package:flutter_app_builder/src/build_error.dart';
import 'package:flutter_app_builder/src/build_result.dart';
import 'package:flutter_app_builder/src/commands/flutter.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:pubspec_parse/pubspec_parse.dart';

abstract class AppBuilder {
  String get platform => throw UnimplementedError();
  bool get isSupportedOnCurrentPlatform => throw UnimplementedError();
  BuildResultResolver get resultResolver;
  String get buildSubcommand => platform;

  String get appName => pubspec.name;
  Version get appVersion => pubspec.version!;
  String get appBuildName => appVersion.toString().split('+').first;
  String get appBuildNumber => appVersion.toString().split('+').last;

  Pubspec? _pubspec;

  Pubspec get pubspec {
    if (_pubspec == null) {
      final yamlString = File('pubspec.yaml').readAsStringSync();
      _pubspec = Pubspec.parse(yamlString);
    }
    return _pubspec!;
  }

  bool match(String platform, [String? target]) {
    return this.platform == platform;
  }

  Future<BuildResult> build({
    required Map<String, dynamic> arguments,
    Map<String, String>? environment,
  }) async {
    final time = Stopwatch()..start();

    BuildConfig config = BuildConfig(arguments: arguments);
    List<String> buildArguments = [];
    for (String key in config.arguments.keys) {
      dynamic value = config.arguments[key];
      if (value == null || value is bool) {
        buildArguments.add('--$key');
      } else if (value is Map) {
        for (String subKey in value.keys) {
          if(key == "dart-define"){
            buildArguments.add('--$key=$subKey=${value[subKey]}');
          }else{
            buildArguments.addAll(['--$key', '$subKey=${value[subKey]}']);
          }
        }
      } else {
        buildArguments.addAll(['--$key', value]);
      }
    }

    // 版本号不能走 `--dart-define FLUTTER_BUILD_NAME` / `FLUTTER_BUILD_NUMBER`：这两个名字被
    // Flutter 当保留名（`FlutterCommand._ensureReservedDartDefineIsUnset`），较新版本会直接报错
    // （本机 3.47.2 实测 `BuildError: FLUTTER_BUILD_NAME is used by the framework and cannot be set
    // using --dart-define`）。`--build-name` / `--build-number` 才是框架的正式入口，同名 dart-define
    // 由框架自己按这两个值注入。
    buildArguments.addAll([
      '--build-name=$appBuildName',
      '--build-number=$appBuildNumber',
    ]);

    ProcessResult processResult = await flutter.withEnv(environment).build(
      [buildSubcommand, ...buildArguments],
    );

    if (processResult.exitCode != 0) {
      throw BuildError('${processResult.stderr}');
    }

    return resultResolver.resolve(config)..duration = time.elapsed;
  }
}
