import 'package:bett_box/models/models.dart';
import 'package:bett_box/views/profiles/override_profile.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _group(
  String name,
  String type, {
  bool? hidden,
  List<String>? proxies,
}) {
  return {
    'name': name,
    'type': type,
    'hidden': ?hidden,
    'proxies': ?proxies,
  };
}

/// 复现用户脚本(sing-mix)的输出结构:隐藏的辅助分组与非顶层分组
/// (`tg - Fallback`)不属于 GLOBAL 成员,不应出现在规则目标列表里。
List<Map<String, Object?>> _scriptGroups({bool globalListsHidden = false}) {
  return [
    _group('fcm', 'select', hidden: true, proxies: ['DIRECT']),
    _group('main', 'select', proxies: ['All', 'HK', 'TW_SG_JP_KR', 'US', 'Other']),
    _group('URL Test - All', 'url-test', hidden: true),
    _group('All', 'select'),
    _group('ai', 'select'),
    _group('URL Test - All-ai', 'url-test', hidden: true),
    _group('All-ai', 'select'),
    _group('tg - Fallback', 'fallback', proxies: ['TW_SG_JP_KR', 'main']),
    _group('tg', 'select'),
    _group('URL Test - HK', 'url-test', hidden: true),
    _group('HK', 'select'),
    _group('URL Test - TW_SG_JP_KR', 'url-test', hidden: true),
    _group('TW_SG_JP_KR', 'select'),
    _group('URL Test - US', 'url-test', hidden: true),
    _group('US', 'select'),
    _group('URL Test - Other', 'url-test', hidden: true),
    _group('Other', 'select'),
    _group('info', 'select'),
    if (globalListsHidden) _group('Hidden Member', 'select', hidden: true),
    _group(
      'GLOBAL',
      'select',
      proxies: [
        'main',
        'All',
        'ai',
        'All-ai',
        'tg',
        'HK',
        'TW_SG_JP_KR',
        'US',
        'Other',
        'info',
        if (globalListsHidden) 'Hidden Member',
      ],
    ),
  ];
}

List<String> _names(List<ProxyGroup> groups) =>
    groups.map((group) => group.name).toList();

void main() {
  group('getRuleTargetGroups 规则目标分组', () {
    test('只列出 GLOBAL 顶层分组,排除 tg - Fallback 等非顶层分组', () {
      final snippet = ClashConfigSnippet.fromJson({
        'proxy-groups': _scriptGroups(),
      });

      final targets = getRuleTargetGroups(
        snippet.proxyGroups,
        showHiddenItems: false,
      );

      expect(_names(targets), [
        'main',
        'All',
        'ai',
        'All-ai',
        'tg',
        'HK',
        'TW_SG_JP_KR',
        'US',
        'Other',
        'info',
      ]);
    });

    test('显示隐藏项开启时仍不包含非顶层分组', () {
      final snippet = ClashConfigSnippet.fromJson({
        'proxy-groups': _scriptGroups(),
      });

      final targets = getRuleTargetGroups(
        snippet.proxyGroups,
        showHiddenItems: true,
      );

      expect(_names(targets), isNot(contains('tg - Fallback')));
      expect(_names(targets), isNot(contains('fcm')));
      expect(_names(targets), isNot(contains('URL Test - All')));
    });

    test('隐藏的顶层分组仅在显示隐藏项开启时列出', () {
      final snippet = ClashConfigSnippet.fromJson({
        'proxy-groups': _scriptGroups(globalListsHidden: true),
      });

      expect(
        _names(
          getRuleTargetGroups(snippet.proxyGroups, showHiddenItems: false),
        ),
        isNot(contains('Hidden Member')),
      );
      expect(
        _names(getRuleTargetGroups(snippet.proxyGroups, showHiddenItems: true)),
        contains('Hidden Member'),
      );
    });

    test('配置未显式定义 GLOBAL 时不过滤成员,仅过滤隐藏分组', () {
      final groups = [
        _group('fcm', 'select', hidden: true, proxies: ['DIRECT']),
        _group('main', 'select'),
        _group('URL Test - All', 'url-test', hidden: true),
        _group('All', 'select'),
        _group('tg - Fallback', 'fallback'),
      ];

      final snippet = ClashConfigSnippet.fromJson({'proxy-groups': groups});

      expect(
        _names(
          getRuleTargetGroups(snippet.proxyGroups, showHiddenItems: false),
        ),
        ['main', 'All', 'tg - Fallback'],
      );
      expect(
        _names(getRuleTargetGroups(snippet.proxyGroups, showHiddenItems: true)),
        ['fcm', 'main', 'URL Test - All', 'All', 'tg - Fallback'],
      );
    });
  });
}
