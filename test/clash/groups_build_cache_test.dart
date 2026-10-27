import 'dart:convert';

import 'package:bett_box/clash/core.dart';
import 'package:bett_box/clash/groups_build_cache.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 内核 getProxies 的瘦身形态 + provider 原文形态（见 core/proxies_json.go）。
  const proxiesJson = '''
{
  "GLOBAL": {"name": "GLOBAL", "type": "Selector", "now": "节点1",
             "all": ["节点1", "节点2[机场A]"], "hidden": false,
             "icon": "", "testUrl": "https://www.gstatic.com/generate_204"},
  "节点1": {"name": "节点1", "type": "ss"}
}''';

  const providersJson =
      '[{"name":"机场A","type":"Proxy","vehicle-type":"HTTP","count":1,'
      '"update-at":"2026-09-20T04:00:00Z",'
      '"proxies":[{"name":"节点2","type":"vmess"}]}]';

  Map decodeProxies([String json = proxiesJson]) => jsonDecode(json) as Map;

  int digestOf({String proxies = proxiesJson, String providers = providersJson}) {
    return groupsSourceDigest(decodeProxies(proxies), providers);
  }

  test('两次独立解码出的同一份内容，指纹一致', () {
    // 每次 IPC 都是一份新解码的 Map：指纹必须按内容算，不能依赖对象身份。
    expect(digestOf(), digestOf());
  });

  test('分组选中节点变化会改变指纹', () {
    final switched = proxiesJson.replaceFirst(
      '"now": "节点1"',
      '"now": "节点2[机场A]"',
    );
    expect(digestOf(proxies: switched), isNot(digestOf()));
  });

  test('分组 all 顺序变化会改变指纹', () {
    final reordered = proxiesJson.replaceFirst(
      '"all": ["节点1", "节点2[机场A]"]',
      '"all": ["节点2[机场A]", "节点1"]',
    );
    expect(digestOf(proxies: reordered), isNot(digestOf()));
  });

  test('节点字段变化会改变指纹（含 UI 白名单之外的字段）', () {
    final retyped = proxiesJson.replaceFirst(
      '"节点1": {"name": "节点1", "type": "ss"}',
      '"节点1": {"name": "节点1", "type": "trojan"}',
    );
    expect(digestOf(proxies: retyped), isNot(digestOf()));
  });

  test('分组字段变化会改变指纹', () {
    for (final changed in [
      proxiesJson.replaceFirst('"hidden": false', '"hidden": true'),
      proxiesJson.replaceFirst('"icon": ""', '"icon": "https://a/b.png"'),
      proxiesJson.replaceFirst('generate_204', 'generate_204?v=2'),
    ]) {
      expect(digestOf(proxies: changed), isNot(digestOf()));
    }
  });

  test('provider 原文变化会改变指纹', () {
    final rotated = providersJson.replaceFirst('vmess', 'ss');
    expect(digestOf(providers: rotated), isNot(digestOf()));
  });

  test('缓存：指纹相同复用同一结果，指纹不同或 clear 后失效', () {
    final cache = GroupsBuildCache();
    final groups = [
      const Group(type: GroupType.Selector, name: 'GLOBAL'),
    ];

    expect(cache.lookup(1), isNull);

    cache.store(1, groups);
    // 同一个 List 实例：groupsProvider 按 identical 判定，内容没变就不通知重建。
    expect(cache.lookup(1), same(groups));
    expect(cache.lookup(2), isNull);

    cache.clear();
    expect(cache.lookup(1), isNull);
  });

  test('相同输入第二次调用复用同一结果，内容变化或 clear 后重建', () async {
    final cache = GroupsBuildCache();

    final first = await ClashCore.buildGroupsWithCache(
      cache: cache,
      proxies: decodeProxies(),
      rawProvidersContent: providersJson,
    );

    // 新一轮 IPC 解出的等值 Map：命中缓存，返回同一个 List 实例
    // （groupsProvider 按 identical 判定，因此不会通知界面重建）。
    final second = await ClashCore.buildGroupsWithCache(
      cache: cache,
      proxies: decodeProxies(),
      rawProvidersContent: providersJson,
    );
    expect(second, same(first));
    expect(second.map((group) => group.name), contains('GLOBAL'));
    expect(second.first.all.map((proxy) => proxy.name), contains('节点2'));

    final changed = await ClashCore.buildGroupsWithCache(
      cache: cache,
      proxies: decodeProxies(),
      rawProvidersContent: providersJson.replaceFirst('vmess', 'ss'),
    );
    expect(changed, isNot(same(first)));

    cache.clear();
    final rebuilt = await ClashCore.buildGroupsWithCache(
      cache: cache,
      proxies: decodeProxies(),
      rawProvidersContent: providersJson,
    );
    expect(rebuilt, isNot(same(first)));
  });
}
