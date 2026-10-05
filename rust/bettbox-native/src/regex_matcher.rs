//! 节点过滤用的 ECMAScript 正则匹配（复用 QuickJS 自带的 libregexp）。
//!
//! 取代原先手写的 `mini_regex` 子集：直接调 vendored QuickJS 的 `lre_compile` /
//! `lre_exec`，语义与 Dart `RegExp(pattern)`（非 unicode）一致，`{n}`、反向引用、
//! `\b`、`(?=…)` 等写法不再让整条管道回退 Dart。
//!
//! 编码约定（对齐 Dart 非 unicode RegExp 的行为）：
//! - 模式编成 **CESU-8** 且 `re_flags = 0`——与 QuickJS 自己编译非 unicode 正则时
//!   的编码一致（astral 字符按代理对拆开），并补一个 NUL 结尾（`lre_compile` 会
//!   读模式末尾之后一个字节）；
//! - 被匹配文本按 **UTF-16 码元** 传入（`cbuf_type = 1`），`.` 等按码元而非码点匹配。
//!
//! 每个 [`RegexMatcher`] 自持一个 JSRuntime/JSContext——libregexp 的 `lre_realloc` /
//! `lre_check_stack_overflow` 钩子在本仓库绑定到 JSContext，详见 `c/quickjs_shim.c`。

use std::ffi::c_void;
use std::os::raw::c_char;

extern "C" {
    fn bbq_regex_compile(pattern: *const c_char, pattern_len: usize) -> *mut c_void;
    fn bbq_regex_is_match(handle: *mut c_void, text: *const u16, text_len: usize) -> i32;
    fn bbq_regex_free(handle: *mut c_void);
}

/// 编译好的正则。只支持「是否匹配」，与 Dart `RegExp.hasMatch` 等价。
pub struct RegexMatcher {
    handle: *mut c_void,
}

impl RegexMatcher {
    /// 编译模式；语法非法（或内存不足）返回 `Err`。
    ///
    /// 注意：调用方不应把 `Err` 当成错误传播——Dart 侧 `RegExp(pattern)` 失败时是
    /// 静默跳过节点过滤（见 `lib/common/config_patch.dart` 的 `catch (_) {}`），
    /// 所以 `patch_config` 在编译失败时按「没有过滤器」处理。
    pub fn compile(pattern: &str) -> Result<Self, String> {
        let mut bytes = to_cesu8(pattern);
        // lre_compile 需要末尾的 NUL，见本模块与 shim 的说明。
        bytes.push(0);
        let handle = unsafe { bbq_regex_compile(bytes.as_ptr().cast(), bytes.len() - 1) };
        if handle.is_null() {
            return Err(format!("无法编译正则 `{pattern}`"));
        }
        Ok(Self { handle })
    }

    /// 是否存在匹配（在任意起点尝试，等价于 Dart `RegExp.hasMatch`）。
    pub fn is_match(&self, text: &str) -> bool {
        let utf16: Vec<u16> = text.encode_utf16().collect();
        unsafe { bbq_regex_is_match(self.handle, utf16.as_ptr(), utf16.len()) == 1 }
    }
}

impl Drop for RegexMatcher {
    fn drop(&mut self) {
        unsafe { bbq_regex_free(self.handle) };
    }
}

/// 把 UTF-8 字符串编成 CESU-8：astral 字符（代理对）拆成两个 3 字节序列。
/// BMP 及以下与 UTF-8 完全相同。
fn to_cesu8(text: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(text.len());
    for unit in text.encode_utf16() {
        if unit < 0x80 {
            out.push(unit as u8);
        } else if unit < 0x800 {
            out.push(0xc0 | (unit >> 6) as u8);
            out.push(0x80 | (unit & 0x3f) as u8);
        } else {
            out.push(0xe0 | (unit >> 12) as u8);
            out.push(0x80 | ((unit >> 6) & 0x3f) as u8);
            out.push(0x80 | (unit & 0x3f) as u8);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn matches(pattern: &str, text: &str) -> bool {
        RegexMatcher::compile(pattern)
            .unwrap_or_else(|error| panic!("`{pattern}` 应能编译：{error}"))
            .is_match(text)
    }

    #[test]
    fn literals_and_search_semantics() {
        assert!(matches("abc", "xabcx"));
        assert!(!matches("abc", "abx"));
    }

    #[test]
    fn brace_quantifiers_now_supported() {
        // 旧 mini_regex 对 `{n}` 整条回退；换成 libregexp 后直接可用。
        assert!(matches(r"a{2}", "xaa"));
        assert!(!matches(r"a{2}", "xa"));
        assert!(matches(r"a{1,}", "xa"));
    }

    #[test]
    fn backreference_and_lookahead_and_word_boundary() {
        assert!(matches(r"(a)\1", "aa"));
        assert!(!matches(r"(a)\1", "ab"));
        // `(?=a)b` 是不可匹配的（前瞻要求 'a'，随后又要 'b' 在同一位置），
        // 所以用 `a(?=b)` 验证前瞻本身可用。
        assert!(matches(r"a(?=b)", "ab"));
        assert!(!matches(r"a(?=b)", "ac"));
        assert!(matches(r"\bfoo", "a foo"));
        assert!(!matches(r"\bfoo", "afoo"));
    }

    #[test]
    fn hex_and_unicode_escapes() {
        assert!(matches(r"\x41", "A"));
        assert!(matches(r"\u0041", "A"));
    }

    #[test]
    fn invalid_pattern_is_rejected() {
        // 这些在 Dart `RegExp` 里也抛 FormatException（`"\\"` 是单个反斜杠）。
        for pattern in [r"(?i)abc", "[a", "a**", "*abc", "a+*", "\\"] {
            assert!(
                RegexMatcher::compile(pattern).is_err(),
                "`{pattern}` 应编译失败"
            );
        }
    }
}
