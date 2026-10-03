//! Bettbox-Mod 覆写脚本引擎的 Rust 实现（内嵌 QuickJS）。
//!
//! 目标：把 Dart 侧 `lib/common/js_runtime_manager.dart` 的脚本求值搬到这里，
//! 后续与 `rust/bettbox-config` 的配置改写管道合流，省掉整份 config 的 JSON 往返。
//! 契约与 Dart 侧 `IsolateQjs` 用法逐项对齐，见 [`eval`]。

pub mod eval;
pub mod ffi;
