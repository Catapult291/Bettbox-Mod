//! 覆盖 `patch_config` 入口：任意 JSON 输入不 panic（结构错误返回 Err）。
#![no_main]

use bettbox_native::patch_config::patch_config;
use libfuzzer_sys::fuzz_target;
use serde_json::Value;

fuzz_target!(|data: &[u8]| {
    if let Ok(input) = serde_json::from_slice::<Value>(data) {
        let _ = patch_config(&input);
    }
});
