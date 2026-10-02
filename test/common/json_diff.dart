import 'dart:convert';

import 'package:collection/collection.dart';

/// 只报第一处差异（带路径），避免整份配置打进失败信息。
///
/// 数值会额外比较「是否为 double」，因为 `300` 与 `300.0` 在 `==` 下相等，
/// 但两者混用说明两端的序列化不一致。
String? firstJsonDifference(Object? dart, Object? rust, String path) {
  if (dart is Map && rust is Map) {
    for (final key in {...dart.keys, ...rust.keys}) {
      if (!dart.containsKey(key)) return '$path.$key：Dart 侧缺失';
      if (!rust.containsKey(key)) return '$path.$key：Rust 侧缺失';
      final difference = firstJsonDifference(
        dart[key],
        rust[key],
        '$path.$key',
      );
      if (difference != null) return difference;
    }
    return null;
  }
  if (dart is List && rust is List) {
    if (dart.length != rust.length) {
      return '$path：长度 Dart=${dart.length} Rust=${rust.length}';
    }
    for (var index = 0; index < dart.length; index++) {
      final difference = firstJsonDifference(
        dart[index],
        rust[index],
        '$path[$index]',
      );
      if (difference != null) return difference;
    }
    return null;
  }
  if (dart is num && rust is num && (dart is double) != (rust is double)) {
    return '$path：数值类型 Dart=${dart.runtimeType}($dart) Rust=${rust.runtimeType}($rust)';
  }
  if (!const DeepCollectionEquality().equals(dart, rust)) {
    return '$path：Dart=${dart.runtimeType}(${_short(dart)}) '
        'Rust=${rust.runtimeType}(${_short(rust)})';
  }
  return null;
}

String _short(Object? value) {
  final text = jsonEncode(value);
  return text.length > 160 ? '${text.substring(0, 160)}…' : text;
}
