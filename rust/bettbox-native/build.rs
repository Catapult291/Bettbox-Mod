//! 编译 vendored QuickJS（`vendor/quickjs`）与本 crate 的薄封装。
//!
//! 用仓库内 vendored 的 QuickJS 源码而不是 crates.io 上的绑定：引擎版本随仓库冻结
//! （见 `vendor/VERSION`），升级是一次可审计的整目录替换。
//!
//! 这份源码原本在 `plugins/flutter_qjs/cxx/quickjs`；2026-10-06 移进 crate（唯一副本），
//! 插件本身已在 Rust 迁移阶段 5 删除。源文件清单与编译选项沿用当时插件
//! `cxx/quickjs.cmake` 的取值。
//!
//! 编译开关对齐插件 Windows 构建（CMake Release）的取值：`/O2` + `-DNDEBUG`，
//! 使 C 侧代码生成不随 cargo profile 变，debug 与 release 跑的是同一份引擎代码。
//!
//! 排查记录（2026-10-09，见 `stage-log.md` §106）：曾经的「同一份字节偶发解析失败」
//! **不是**代码生成问题。根因是交给 `JS_Eval` 的缓冲区少了末尾 NUL——vendored QuickJS
//! 的词法分析无条件读 `buf[len]`（`next_token` 先 `c = *p` 再判 `p >= s->buf_end`），
//! 于是解析结果取决于紧邻堆内存的那一个字节。失败率看起来随 C 侧代码形态摆动，是因为
//! 分配布局随之变化，而不是 `/Od` 本身生成了错的代码：实测把 C 侧降回 `/Od` + 无
//! `NDEBUG` 后，补了 NUL 的 20000 次求值 0 失败；去掉 NUL 则同一份字节在 0/2000 与
//! 约 25% 之间摆动。现在由 `c/quickjs_shim.c` 的哨兵校验兜住，回归用例见
//! `tests/script_engine.rs` 的 `eval_rejects_a_program_without_nul_sentinel`。
//! 调试时仍不建议随手降回 `/Od`：它与出货配置不同，而且慢得多。

use std::path::PathBuf;

fn main() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let quickjs = manifest.join("vendor/quickjs");

    let version_path = quickjs.join("VERSION");
    println!("cargo:rerun-if-changed={}", version_path.display());
    let version = std::fs::read_to_string(&version_path).unwrap_or_default();
    let version = version.trim().to_string();

    let mut build = cc::Build::new();
    build.include(&quickjs);
    build.define("CONFIG_VERSION", format!("\"{version}\"").as_str());
    build.define("NDEBUG", None);
    // 与插件 Release 构建一致：代码生成不随 cargo profile 变。
    build.opt_level(2);
    build.debug(false);

    if build.get_compiler().is_like_msvc() {
        // 同一处 MSVC 规避（上游 flutter_qjs issue #7）。
        build.flag("/Oi-");
        build.define("alloca", "_alloca");
    } else {
        println!("cargo:rustc-link-lib=m");
    }

    for name in ["cutils.c", "libregexp.c", "libunicode.c", "quickjs.c"] {
        let path = quickjs.join(name);
        println!("cargo:rerun-if-changed={}", path.display());
        build.file(path);
    }

    let shim = manifest.join("c/quickjs_shim.c");
    println!("cargo:rerun-if-changed={}", shim.display());
    build.file(shim);

    build.warnings(false);
    build.compile("bettbox_quickjs");
}
