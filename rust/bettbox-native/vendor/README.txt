vendored QuickJS
================

来源：原 `plugins/flutter_qjs` 插件（上游 https://github.com/ekibun/flutter_qjs）自带的
`cxx/quickjs`。2026-10-06 从 `plugins/flutter_qjs/cxx/quickjs` 移到这里，成为仓库里的
唯一副本；随后 flutter_qjs 插件本身在 Rust 迁移阶段 5 删除，这里是它唯一的遗留源码。

版本：见同目录 `VERSION`（`2026-06-14`）。`build.rs` 把它作为 `CONFIG_VERSION` 编进引擎。

许可证：MIT，版权与全文在各源文件头部，本目录未另附。

编译的源文件（沿用原插件 `cxx/quickjs.cmake` 的清单）：
`cutils.c`、`libregexp.c`、`libunicode.c`、`quickjs.c`。其余文件是头文件与未启用的
`libbf.c` / `quickjs-libc.c` / `unicode_gen.c`，跟着保留以便整体升级。

谁来用：

- `rust/bettbox-native/build.rs`：直接编译本目录（`cc` crate，MSVC 用 `/Oi-` 与
  `alloca=_alloca`，取值对齐原插件的 Release 构建）。

升级做法：整目录替换成新版 QuickJS 源码，核对 VERSION，然后重跑 `cargo test --workspace`
（golden）。
