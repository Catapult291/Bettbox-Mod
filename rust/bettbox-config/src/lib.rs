//! Bettbox-Mod 配置改写管道的 Rust 实现。
//!
//! 目标是把 Dart 侧 `lib/state.dart` 的配置链路（`patchRawConfig` /
//! `handleEvaluate` / `_writeRunningConfig`）与 provider 解析逐步迁到这里。
//! 已移植的切片：规则解析、DNS 节点覆写、provider 解析与构组、分组开关；
//! 后续切片见 `.grok/stage-log.md` 的候选清单。

pub mod dns_override;
pub mod ffi;
pub mod group_switch;
pub mod patch_config;
pub mod provider;
pub mod rule;
