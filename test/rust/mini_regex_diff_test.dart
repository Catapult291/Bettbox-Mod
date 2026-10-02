import 'package:bett_box/rust/bettbox_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// 手写最小匹配器（`rust/bettbox-config/src/mini_regex.rs`）与 Dart `RegExp` 的差分。
///
/// 规则：
/// - Rust 认了（返回 true/false）⇒ 必须与 Dart `RegExp.hasMatch` 逐例一致；
/// - Rust 拒绝（返回 null）⇒ 该模式必须确实在支持子集之外，且 Dart 侧要么也拒绝、
///   要么管道会整条回退 Dart（见 `patch_config.rs`），不会出现两端悄悄分叉。
///
/// 支持子集的用例与子集外的用例分开列，避免「把支持的模式误判为不支持」被漏掉。
const _supported = <String>[
  '过期',
  '剩余|官网',
  '^test-',
  r'-IEPL$',
  r'\d+',
  r'^\d+$',
  r'[0-9]+G',
  r'[a-z]+',
  '[^0-9]',
  '.*',
  'a.c',
  '(香港|台湾)',
  '^(香港|台湾)',
  '(ab|cd)+',
  'a*',
  'ab?c',
  r'\d+?',
  r'\w+',
  r'^\w+$',
  r'\s',
  r'\S+',
  r'^\D+$',
  r'[\d]+',
  r'^[\w-]+$',
  '[]',
  '[]]',
  '[^]',
  '[a-]',
  r'a\.b',
  r'\|',
  r'\\',
  r'\n',
  r'^$',
  '',
];

/// 子集之外：Rust 必须拒绝。
const _unsupported = <String>[
  r'a{2}',
  r'(?i)abc',
  r'(?:ab)',
  r'(?=a)',
  r'\bfoo',
  r'(a)\1',
  r'\p{L}',
  r'\u0041',
  r'\x41',
  '[a',
  'a**',
  '*abc',
  r'a{1,}',
  'a+*',
  r'\',
];

const _texts = <String>[
  '',
  '过期节点',
  '剩余流量',
  '节点官网',
  '正常节点',
  'test-1',
  'xtest-1',
  '香港-IEPL',
  '香港-IEPLx',
  'G123',
  '4a',
  '42',
  '10Gbps',
  'abc',
  'abbc',
  'abx',
  'xabcx',
  '台湾01',
  'abcdab',
  'bbb',
  'ac',
  '12',
  '_x1',
  '中文',
  'a b',
  'a1',
  'zzb',
  'zzz',
  'a-b_c',
  '-',
  'a',
  'x]',
  'a.b',
  'axb',
  '|',
  r'a\b',
  'a\nb',
  'a\u2028b',
  '\u00a0',
  '\ufeff',
];

void main() {
  final available = BettboxConfig.isAvailable;
  final skipReason = available
      ? null
      : '未找到 bettbox_config 动态库，先构建：cd rust && cargo build';

  group('最小匹配器 vs Dart RegExp', () {
    test('支持子集内逐例一致', () {
      for (final pattern in _supported) {
        final RegExp? dartRegex = _tryCompile(pattern);
        expect(dartRegex, isNotNull, reason: 'Dart 应该接受 `$pattern`');
        for (final text in _texts) {
          final rust = BettboxConfig.nodeFilterMatch(pattern, text);
          expect(rust, isNotNull, reason: '`$pattern` 在支持子集内，Rust 不应拒绝');
          expect(
            rust,
            dartRegex!.hasMatch(text),
            reason:
                '模式 `$pattern` 文本 `$text`：'
                'Rust=$rust Dart=${dartRegex.hasMatch(text)}',
          );
        }
      }
    });

    test('子集之外必须拒绝', () {
      for (final pattern in _unsupported) {
        expect(
          BettboxConfig.nodeFilterMatch(pattern, '任意文本'),
          isNull,
          reason: '`$pattern` 在支持子集之外，Rust 应拒绝而不是猜着匹配',
        );
      }
    });

    test('Dart 拒绝的模式，Rust 也必须拒绝', () {
      for (final pattern in [..._supported, ..._unsupported]) {
        final dartAccepts = _tryCompile(pattern) != null;
        final rustAccepts = BettboxConfig.nodeFilterMatch(pattern, 'x') != null;
        if (!dartAccepts) {
          expect(
            rustAccepts,
            isFalse,
            reason: '`$pattern` Dart 拒绝而 Rust 接受，两端会分叉',
          );
        }
      }
    });
  }, skip: skipReason);
}

RegExp? _tryCompile(String pattern) {
  try {
    return RegExp(pattern);
  } catch (_) {
    return null;
  }
}
