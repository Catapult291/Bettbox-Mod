import 'package:bett_box/rust/bettbox_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// `nodeExcludeFilter` 的正则实现（`rust/bettbox-native/src/regex_matcher.rs`，
/// QuickJS 自带的 libregexp）与 Dart `RegExp` 的差分。
///
/// 规则：
/// - 两边都接受 ⇒ Rust 的 true/false 必须与 Dart `RegExp.hasMatch` 逐例一致；
/// - Dart 拒绝（FormatException）⇒ Rust 也必须拒绝（返回 null），否则两端分叉。
///
/// 截目前未发现「一边接受、另一边拒绝」的有效性分歧。
const _supported = <String>[
  // 旧 mini_regex 已支持的子集
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
  // 换 libregexp 后新支持的写法（旧 mini_regex 会整条回退）
  'a{2}',
  'a{1,}',
  '(?:ab)',
  '(?=a)',
  'a(?=b)',
  '(?<=a)b',
  '(?<name>a)',
  r'\bfoo',
  r'\b',
  r'(a)\1',
  r'\u0041',
  r'\x41',
  '节点{2}',
  r'^节点1{1}$',
  r'\p{L}',
  r'\k<name>',
];

/// Dart 拒绝 ⇒ Rust 也必须拒绝。
const _invalid = <String>[
  r'(?i)abc',
  '[a',
  'a**',
  '*abc',
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
  // 新语法相关
  'aa',
  'xaa',
  'ab',
  'cb',
  'a foo',
  'afoo',
  'foo',
  'A',
  '节点',
  '节点1',
  '节点2',
  'p{L}',
  'k<name>',
];

void main() {
  final available = BettboxConfig.isAvailable;
  final skipReason = available
      ? null
      : '未找到 bettbox_native 动态库，先构建：cd rust && cargo build --release';

  group('libregexp vs Dart RegExp', () {
    test('两边都接受时逐例一致', () {
      for (final pattern in _supported) {
        final dartRegex = _tryCompile(pattern);
        expect(dartRegex, isNotNull, reason: 'Dart 应当接受 `$pattern`');
        for (final text in _texts) {
          final rust = BettboxConfig.nodeFilterMatch(pattern, text);
          expect(rust, isNotNull, reason: '`$pattern` 应当能编译');
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

    test('Dart 拒绝的模式，Rust 也必须拒绝', () {
      for (final pattern in _invalid) {
        expect(_tryCompile(pattern), isNull, reason: '`$pattern` Dart 应当拒绝');
        expect(
          BettboxConfig.nodeFilterMatch(pattern, '任意文本'),
          isNull,
          reason: '`$pattern` Dart 拒绝，Rust 也必须拒绝',
        );
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
