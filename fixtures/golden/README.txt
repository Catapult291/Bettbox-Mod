Bettbox-Mod golden 期望输出（阶段 5）
====================================

这是什么
--------
「配置改写管道」的期望输出快照，由 **Dart 镜像**（`lib/common/config_patch.dart` 的
`applyConfigPatch` + `lib/common/js_runtime_manager.dart` 的 qjs 求值）在真实 fixture 上
跑出来后落盘。Rust 侧测试（`rust/bettbox-native/tests/golden.rs`）只读这些文件、
驱动 C ABI、逐字段比对。

用途是路线稿 §1.5 的第 1、2 步：先把参照输出固化下来，等 Dart 镜像与 qjs 路径删除后
（第 3 步），回归保护不会跟着一起丢——`cargo test` 一条命令即可覆盖整条管道，
不再依赖 flutter 与参考 dll。

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
    "scriptError": "…" | null,          // 脚本报错时的错误串（与 Dart 侧逐字一致）
    "output":    { ... }                // Dart 镜像产出的期望配置
  }

`input` 是生成时喂给 Dart 镜像的**同一份 JSON**（process_profile 是跑脚本前的输入，
脚本由 Rust 入口内部执行）。存整份输入而不是只存期望输出，是为了让 Rust 侧不必
重新实现一遍用例构造器——输入即事实，不存在两端构造器漂移的可能。

用例集
------
用例清单在 `test/rust/pipeline_cases.dart` 的 `pipelineCases()`，从
`test/rust/patch_config_diff_test.dart` / `process_profile_diff_test.dart` 的差分用例里
挑出分支覆盖面最广的一批（两份真实 profile、各类 override 开关、Android 分支、
节点过滤与正则、tolerance 归一化、分组开关、provider 路径、tun/sniffer/tunnels、
真实脚本 × 两份 profile、脚本报错、customOptions）。完整用例仍由那两个差分测试跑。

重新生成
--------
前提与差分测试相同：`test/build/Debug/ffiquickjs.dll` 存在，且 PATH 里有它依赖的
`flutter_windows.dll`（CI 的做法是把 `build/windows/x64/runner/Release/flutter_qjs_plugin.dll`
拷成该文件，并把 runner 目录加进 PATH）：

    export PATH="$PWD/build/windows/x64/runner/Release:$PATH"
    flutter test test/rust/golden_generate_test.dart --dart-define=GOLDEN_GENERATE=true

不带 `--dart-define=GOLDEN_GENERATE=true` 时该用例只会被跳过，正常的
`flutter test` 不会覆写期望输出。

纪律
----
* **golden 变了 = 管道行为变了。** 生成后必须复查 diff：如果改动是有意的，要在提交说明里
  写清行为变更点与理由；无意变更就是回归，要查根因而不是重生成糊过去。
* 生成器会用当前用例集清空两个目录下的 `*.json` 再写，所以用例改名/删除不会留下孤儿文件。
* 这些是测试数据（可重建），入库；重新生成不需要脱敏，因为输入本身就是脱敏 fixture。
