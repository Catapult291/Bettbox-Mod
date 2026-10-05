//! 编译 vendored QuickJS（`vendor/quickjs`）与本 crate 的薄封装。
//!
//! 用仓库里同一份 QuickJS 源码而不是 crates.io 上的绑定，是为了让 Rust 路径与
//! 插件 `plugins/flutter_qjs` 跑**同一份引擎**——否则两处脚本语义可能漂移，
//! 而脚本正文由用户编写，回归很难在测试里穷举。
//!
//! 这份源码原本放在 `plugins/flutter_qjs/cxx/quickjs`，因为 `build.rs` 依赖插件目录，
//! 删插件会连源码一起丢；2026-10-06 移进 crate 后它成为唯一副本，插件的
//! `cxx/quickjs.cmake` 与 `cxx/prebuild.sh` 反过来指向这里（见 `vendor/README.txt`）。
//! 源文件清单与编译选项仍照抄 `plugins/flutter_qjs/cxx/quickjs.cmake`。
//!
//! 编译开关另对齐插件 Windows 构建（CMake Release）的取值：`/O2` + `-DNDEBUG`。
//! 原因不是性能：排查「同一份字节偶发解析失败」时发现，失败率随 C 侧代码形态在
//! 0/2000 与 28/30 之间摆动，只出现在与插件不同的构建配置（`/Od`、无 `NDEBUG`、
//! 带额外诊断代码）下；改成与插件一致的 Release 取值后，`many_evaluations_stay_stable`
//! 连续 2000 次求值稳定。不要为了调试方便把它降回 `/Od`——那会引入与出货配置不同的
//! 代码生成，让这类偶发问题无法与出货行为对照。

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
        // 同一处 MSVC 规避，见 quickjs.cmake 里的注释（上游 flutter_qjs issue #7）。
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
