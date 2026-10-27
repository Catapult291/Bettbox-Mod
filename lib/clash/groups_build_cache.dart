import 'package:bett_box/models/models.dart';

/// 构组输入的指纹（代理表 + provider 原文）。
///
/// 逐字段遍历而不是只挑几个字段：内核以后往代理表里加字段，指纹会自动跟着变，
/// 不会出现「字段没进指纹、内容变了却跳过重建」的陈旧界面。
int groupsSourceDigest(Map proxies, String rawProvidersContent) {
  var hash = 0x811c9dc5;

  void mix(int value) {
    hash = ((hash ^ (value & 0xffffffff)) * 0x01000193) & 0xffffffff;
  }

  void mixValue(Object? value) {
    if (value == null) {
      mix(0x7fffffff);
    } else if (value is String) {
      mix(value.length);
      mix(value.hashCode);
    } else if (value is Map) {
      mix(value.length);
      for (final entry in value.entries) {
        mixValue(entry.key);
        mixValue(entry.value);
      }
    } else if (value is List) {
      mix(value.length);
      for (final item in value) {
        mixValue(item);
      }
    } else {
      mix(value.hashCode);
    }
  }

  mix(proxies.length);
  for (final entry in proxies.entries) {
    mixValue(entry.key);
    mixValue(entry.value);
  }
  mix(rawProvidersContent.length);
  mix(rawProvidersContent.hashCode);
  return hash;
}

/// 上一次构组的输入指纹与结果。
///
/// 输入没变时复用上一次结果，跳过 `Isolate.run` 与 `Group.fromJson`。复用同一个
/// List 实例还有第二层作用：`groupsProvider` 的 `updateShouldNotify` 按 identical
/// 判定，内容没变时不会通知任何界面重建。
class GroupsBuildCache {
  int? _digest;
  List<Group>? _groups;

  /// 指纹一致时返回上一次结果，否则返回 null。
  List<Group>? lookup(int digest) {
    if (_digest != digest) return null;
    return _groups;
  }

  void store(int digest, List<Group> groups) {
    _digest = digest;
    _groups = groups;
  }

  /// 内核重启、换配置后作废：旧结果可能来自另一个内核实例。
  void clear() {
    _digest = null;
    _groups = null;
  }
}
