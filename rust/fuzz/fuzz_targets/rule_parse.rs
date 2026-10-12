//! 覆盖 `ParsedRule::parse` / `to_config_string`：任意字节序列不炸，round-trip 稳定。
#![no_main]

use bettbox_native::rule::ParsedRule;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else {
        return;
    };
    let first = ParsedRule::parse(text);
    let serialized = first.to_config_string();
    let second = ParsedRule::parse(&serialized);
    debug_assert_eq!(second.to_config_string(), serialized);
});
