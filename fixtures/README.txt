Bettbox-Mod 配置管道测试 fixture
================================

来源
----
由 fixtures/sanitize_fixtures.py 从本机真实运行数据脱敏生成（2026-10-03）：

  config/profile-a.json       订阅配置（解析后的 profile；7 节点 / 3 分组 / 2621 规则）
  config/profile-b.json       订阅配置（172 节点 / 31 分组 / 3486 规则，规模样本）
  config/running-config.json  应用改写后交给内核的运行配置（config.yaml）
  config/app-config.json      应用设置（shared_preferences 里 flutter.config 的对象）
  scripts/dns.js              覆写脚本正文（scriptProps.scripts[].content）

脱敏规则
--------
见 fixtures/sanitize_fixtures.py 的模块注释。要点：

  * 代理 server / sni / host 与订阅地址主机名 -> node<N>.example.com
  * password / uuid / url / token / secret / path / username 等 -> 形状保持替换
    （字母数字变 X，保留标点，长度不变）
  * 规则与脚本正文里出现的机场域名 -> example.com
  * 顶层 hosts -> 固定示例映射
  * 订阅流量信息（upload/download/total/expire）-> 0
  * 提供商名 -> fixture-a / fixture-b

入库纪律
--------
这些文件已脱敏，可以入库；**不要**把原始数据（含订阅令牌、真实服务器与密码）放进仓库。
重新生成时用 sanitize_fixtures.py 指向本机数据目录，生成后必须复查残留
（对真实域名/令牌 grep 应无命中）再提交。

其它目录
--------
  golden/   配置改写管道的 golden 期望输出（阶段 5 第 1 步由 Dart 镜像生成，
            镜像删除后它是整条管道唯一的回归网，Rust 侧测试只读对比），
            见 fixtures/golden/README.txt
