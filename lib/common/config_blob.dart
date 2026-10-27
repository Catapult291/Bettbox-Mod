import 'dart:convert';

import 'package:bett_box/models/config.dart';

/// 把 [config] 编码成落盘用的 JSON 文本，只重编码 [changed] 里的分片。
///
/// [cache] 保存各分片上一次的编码结果，由调用方持有：未变更的分片直接复用缓存
/// 里的片段，于是改一个窗口尺寸只需序列化 `windowProps`，订阅配置与脚本内容
/// （真实配置里约占 80%+ 的字节）不必重新编码。缓存为空或分片缺失时该分片照常
/// 编码，所以首次落盘与换整包配置都会写全。
///
/// 输出与 `json.encode(config)` 解码后等价（字段齐全、顺序按 [ConfigSlice]），
/// 因此偏好设置里的存储格式不变，旧版本读到的仍是同一份 `config` 单键。
String encodeConfigBlob(
  Config config,
  Set<ConfigSlice> changed,
  Map<ConfigSlice, String> cache,
) {
  final buffer = StringBuffer('{');
  var first = true;
  for (final slice in ConfigSlice.values) {
    if (!first) {
      buffer.write(',');
    }
    first = false;
    var encoded = cache[slice];
    if (encoded == null || changed.contains(slice)) {
      encoded = json.encode(slice.valueOf(config));
      cache[slice] = encoded;
    }
    buffer
      ..write('"')
      ..write(slice.key)
      ..write('":')
      ..write(encoded);
  }
  buffer.write('}');
  return buffer.toString();
}
