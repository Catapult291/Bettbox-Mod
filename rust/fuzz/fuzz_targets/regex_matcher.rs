//! 覆盖 `RegexMatcher::compile` / `is_match`：非法模式走 Err，合法模式不炸。
#![no_main]

use bettbox_native::regex_matcher::RegexMatcher;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: (String, String)| {
    let (pattern, text) = data;
    if let Ok(matcher) = RegexMatcher::compile(&pattern) {
        let _ = matcher.is_match(&text);
    }
});
