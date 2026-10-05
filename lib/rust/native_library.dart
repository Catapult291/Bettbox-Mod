import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 打开 `bettbox_native` 动态库（配置管道 + 覆写脚本引擎）。
///
/// 打包后 Windows/macOS 取与可执行文件同目录的绝对路径（CMake install 的结果）；
/// Android/iOS 交给平台动态加载器按名字解析——APK/IPA 里的库不在 dart:io 能看到的
/// 路径上，先做文件预检必然失败。按名字解析要求库的文件名与 `jniLibs/<abi>/` 下的
/// 一致（`libbettbox_native.so`）。
///
/// 开发/测试时另试仓库根的 cargo 产物（debug 在前：开发迭代跑 `cargo build`，
/// 若 release 产物更旧会被它挡住）。
DynamicLibrary openBettboxNativeLibrary() {
  final tried = <String>[];
  for (final path in _candidates()) {
    if (!_isPlatformResolved(path) && !File(path).existsSync()) {
      tried.add('$path（不存在）');
      continue;
    }
    try {
      return DynamicLibrary.open(path);
    } catch (error) {
      tried.add('$path（$error）');
    }
  }
  throw StateError('未找到 $_libraryFileName，已尝试：\n${tried.join('\n')}');
}

/// Android/iOS 的库随包分发，只能靠加载器的默认搜索路径找，不能按文件路径探测。
bool get _usesPlatformSearchPath => Platform.isAndroid || Platform.isIOS;

bool _isPlatformResolved(String path) =>
    _usesPlatformSearchPath && path == _libraryFileName;

List<String> _candidates() {
  final fileName = _libraryFileName;
  return [
    if (_usesPlatformSearchPath) fileName,
    p.join(p.dirname(Platform.resolvedExecutable), fileName),
    for (final profile in ['debug', 'release'])
      p.join(Directory.current.path, 'rust', 'target', profile, fileName),
  ];
}

String get _libraryFileName {
  if (Platform.isWindows) return 'bettbox_native.dll';
  if (Platform.isMacOS) return 'libbettbox_native.dylib';
  return 'libbettbox_native.so';
}
