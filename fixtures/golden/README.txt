Bettbox-Mod golden 期望输出（阶段 5）
====================================

这是什么
--------
「配置改写管道」的期望输出快照。阶段 5 第 1 步用**当时还存在的 Dart 镜像**
（`lib/common/config_patch.dart` 的 `applyConfigPatch` + qjs 求值）在真实 fixture 上跑出来
后落盘；阶段 5 第 3 步删掉 Dart 镜像与 qjs 路径之后，它成了整条管道**唯一的跨版本回归网**：

    cd rust && cargo test --workspace

`rust/bettbox-native/tests/golden.rs` 只读这些文件、驱动 C ABI、逐字段比对。`cargo test`
一条命令即覆盖整条管道，不需要 flutter，也不依赖任何参考实现。

目录
----
  patch_config/*.json      走 `bb_patch_config`（无脚本覆写时的配置改写）
  process_profile/*.json   走 `bb_process_profile`（脚本求值 + 配置改写的合并入口）

文件格式
--------
  {
    "name":      "用例名（= 文件名）",
    "entry":     "patch_config" | "process_profile",
    "input":     { "rawConfig", "patch", "profile", "env" },  // 喂给入口的完整输入
    "script":    "覆写脚本正文",        // 仅 process_profile
    "customOptions": {...},             // 仅 process_profile 且脚本声明了选项
    "scriptError": "…" | null,          // 脚本报错时的期望错误串
    "output":    { ... }                // 期望配置
  }

存整份输入而不是只存期望输出，是为了让 Rust 侧不必重新实现一遍用例构造器——输入即事实。
用例覆盖：两份真实 profile、各类 override 开关、Android 分支、节点过滤与正则、
tolerance 归一化、分组开关、provider 路径、tun/sniffer/tunnels、真实脚本 × 两份 profile、
脚本报错、customOptions。

怎么更新（重要）
----------------
Dart 镜像删掉后就不再有独立参照，golden 只代表「当前 Rust 实现的行为」。所以：

* 正常情况**不要**重生成：`cargo test` 报差异就是行为变了，先按报出的路径查根因。
* 确认是有意的行为变更时，人工复核差异、在提交说明里写清变更点与理由，然后重生成：

      cd rust && cargo test --test golden -- --ignored regenerate_golden

  该用例会用当前管道重跑 golden 里的输入，把 `output`（`process_profile` 连
  `scriptError`）定点写回文件，其余字节不动；输入与行为都没变时它是幂等的。
  注意：`output` 的键序会变成 Rust 侧的字典序（入库文件当初由 Dart 生成，是插入序），
  所以**第一次**重生成会带一次纯键序的 diff，之后才只反映真实行为变化。
  重生成后 `cargo test` 必然通过——它只记录行为，不校验行为。

这些是测试数据（可重建），入库；输入本身就是脱敏 fixture。
