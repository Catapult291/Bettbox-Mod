# cargo-fuzz（§4.2 / B⑨）

覆盖三个纯函数入口：

| target | 入口 | 说明 |
| --- | --- | --- |
| `rule_parse` | `ParsedRule::parse` / `to_config_string` | 规则字符串不炸、序列化稳定 |
| `regex_matcher` | `RegexMatcher::compile` / `is_match` | 非法模式 Err、合法模式不炸 |
| `patch_config` | `patch_config` | 任意 JSON 输入不 panic |

独立于 `rust/` 工作区（本目录自己的 `[workspace]`），CI 的 `cargo test --workspace`
不会构建 libFuzzer 目标。日常回归靠 `bettbox-native/tests/property.rs` 的 proptest；
本目录用于本地/夜间更长的无界探索。

## 运行

```bash
# 需要 nightly（cargo-fuzz 的 -Z sanitizer）。父目录 rust-toolchain.toml 锁的是
# 稳定版；从 rust/ 目录跑 cargo fuzz 会被根锁定盖住，显式指定 nightly：
cargo install cargo-fuzz

cd rust
# 首次可把种子拷进运行语料（seed_corpus/ 已入库，corpus/ 不入库）：
mkdir -p fuzz/corpus/rule_parse && cp fuzz/seed_corpus/rule_parse/* fuzz/corpus/rule_parse/

RUSTUP_TOOLCHAIN=nightly cargo fuzz run rule_parse -- -max_total_time=30
RUSTUP_TOOLCHAIN=nightly cargo fuzz run regex_matcher -- -max_total_time=30
RUSTUP_TOOLCHAIN=nightly cargo fuzz run patch_config -- -max_total_time=30
```

崩溃复现文件落在 `crashes/`；**不要**把 corpus 增量与 crash 文件当源码提交，
`.gitignore` 已排除 `rust/fuzz/{artifacts,crashes,corpus,target}` 下的运行产物。

## 已知限制

- **Windows MSVC + 本 crate 的 cdylib 链不过**：cargo-fuzz 给整条依赖图注入
  `/include:main`，`bettbox_native.dll`（crate-type 含 `cdylib`）链上时报
  `LNK2001: 无法解析的外部符号 main`。这是 libFuzzer 与「库同时出 DLL」在 MSVC 上的
  组合限制，不是规则/管道逻辑问题。Linux 或 WSL 下可正常 `cargo fuzz run`。
  Windows 侧的属性覆盖由 proptest（`tests/property.rs`，随 `cargo test`）承担。
- libFuzzer 在 Windows/MSVC 上整体支持有限；跑不动时用 WSL，或只依赖 proptest。
- 从仓库根 / `rust/` 运行时，根 `rust-toolchain.toml`（1.98.0）优先于本目录的
  `rust-toolchain.toml`；必须带 `RUSTUP_TOOLCHAIN=nightly`（或在 `rust/fuzz/` 下直接跑）。
- `patch_config` 的 fuzz 输入是任意 JSON，大量用例在信封校验处直接 Err——属预期，
  目标是「不 panic」而非「高通过率」。
