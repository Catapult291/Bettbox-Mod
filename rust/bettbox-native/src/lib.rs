//! Bettbox-Mod 的 Rust 原生实现：配置改写管道 + 覆写脚本引擎（内嵌 QuickJS）。
//!
//! 这两块原先是两个 cdylib（`bettbox-config` / `bettbox-script`），合并成本 crate 后
//! 只出一个动态库（`bettbox_native`）。Dart 侧仍按两块 ABI 分别绑定——头文件
//! `include/bettbox_config.h` 与 `include/bettbox_script.h` 各自独立，ffigen 也各生成
//! 一份绑定——但两者加载的是同一个库。
//!
//! 目标不变：把 Dart 侧 `lib/state.dart` 的配置链路（`patchRawConfig` /
//! `handleEvaluate` / `_writeRunningConfig`）与 `lib/common/js_runtime_manager.dart`
//! 的脚本求值逐片迁到这里，最终删除 Dart 镜像。

mod ffi_support;

pub mod dns_override;
pub mod eval;
pub mod ffi;
pub mod group_switch;
pub mod patch_config;
pub mod provider;
pub mod regex_matcher;
pub mod rule;
pub mod script_ffi;
