//! 节点过滤用的最小正则匹配器。
//!
//! 只为 `nodeExcludeFilter` 服务：不引 `regex` crate（它给 dll 加了约 1.6 MB），
//! 手写一个够用的子集。**只判定「是否匹配」**，所以量词的贪婪/惰性不影响结果。
//!
//! 支持的写法（与 Dart `RegExp` 语义一致的部分）：
//! - 字面量、`.`（任意字符）
//! - 转义：`\d` `\D` `\w` `\W` `\s` `\S`，以及 `\n` `\t` `\r` `\f` `\v`，
//!   和 `\.` `\|` 这类「反斜杠 + 元字符」的字面量转义
//! - 字符类：`[abc]`、`[a-z]`、`[^...]`、`[a-]`，类内可用上面的转义；
//!   `[]` 是空字符类（永不匹配）、`[^]` 匹配任意字符——与 ECMAScript 一致
//! - 分组 `(...)`、选择 `|`、量词 `*` `+` `?`（惰性写法 `*?` 等一并接受）
//! - 锚点 `^` `$`
//!
//! **子集之外的写法一律返回 [`Unsupported`]**，由调用方整条回退到 Dart 路径，
//! 绝不「当成字面量」猜——那会让两端行为悄悄分叉。所以 `{}`、`(?`、`\b`、`\1`、
//! `\p{...}`、`\uXXXX`、`\xHH` 等都是拒绝的。
//!
//! 已知的语义差异：无。`.` 与 `\s` 都按 ECMAScript 的定义实现（`.` 不匹配行终止符，
//! `\s` 用的是 ECMAScript 的空白集合而不是 Rust 的 `char::is_whitespace`），
//! 免得与 Dart 的 `RegExp` 在这些细节上分叉。

use std::fmt;

/// 模式用到了本匹配器不支持的写法。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Unsupported(pub String);

impl fmt::Display for Unsupported {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

#[derive(Debug, Clone)]
enum ClassItem {
    Char(char),
    Range(char, char),
    Digit(bool),
    Word(bool),
    Space(bool),
}

impl ClassItem {
    fn matches(&self, c: char) -> bool {
        match self {
            ClassItem::Char(x) => *x == c,
            ClassItem::Range(low, high) => *low <= c && c <= *high,
            // ECMAScript 的 \d \w \s 都是它自己定义的集合，不能用 Rust 的 Unicode 判定。
            ClassItem::Digit(negated) => c.is_ascii_digit() != *negated,
            ClassItem::Word(negated) => (c.is_ascii_alphanumeric() || c == '_') != *negated,
            ClassItem::Space(negated) => is_ecma_space(c) != *negated,
        }
    }
}

/// ECMAScript 的行终止符。
fn is_line_terminator(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{2028}' | '\u{2029}')
}

/// ECMAScript `\s` 的字符集合（WhiteSpace ∪ LineTerminator）。
fn is_ecma_space(c: char) -> bool {
    is_line_terminator(c)
        || matches!(
            c,
            '\t' | '\u{b}'
                | '\u{c}'
                | ' '
                | '\u{a0}'
                | '\u{feff}'
                | '\u{1680}'
                | '\u{202f}'
                | '\u{205f}'
                | '\u{3000}'
        )
        || ('\u{2000}'..='\u{200a}').contains(&c)
}

#[derive(Debug, Clone)]
enum Node {
    Empty,
    Char(char),
    AnyChar,
    Class {
        negated: bool,
        items: Vec<ClassItem>,
    },
    Start,
    End,
    Concat(Vec<Node>),
    Alternate(Vec<Node>),
    Repeat {
        node: Box<Node>,
        min: usize,
        max: Option<usize>,
    },
}

/// 编译好的模式。
#[derive(Debug, Clone)]
pub struct MiniRegex {
    root: Node,
}

/// 编译模式；用到子集之外的写法时返回 [`Unsupported`]。
pub fn compile(pattern: &str) -> Result<MiniRegex, Unsupported> {
    let mut parser = Parser {
        chars: pattern.chars().collect(),
        pos: 0,
    };
    let root = parser.parse_alternation()?;
    if parser.pos != parser.chars.len() {
        return Err(Unsupported(format!(
            "多余的 `{}`",
            parser.chars[parser.pos]
        )));
    }
    Ok(MiniRegex { root })
}

impl MiniRegex {
    /// 是否存在匹配（等价于 Dart `RegExp.hasMatch`，即在任意起点尝试）。
    pub fn is_match(&self, text: &str) -> bool {
        let chars: Vec<char> = text.chars().collect();
        (0..=chars.len()).any(|start| !ends(&self.root, &chars, start).is_empty())
    }
}

/// 从 `pos` 出发，列出所有可能的结束位置。
fn ends(node: &Node, text: &[char], pos: usize) -> Vec<usize> {
    match node {
        Node::Empty => vec![pos],
        Node::Char(expected) => match text.get(pos) {
            Some(c) if c == expected => vec![pos + 1],
            _ => Vec::new(),
        },
        Node::AnyChar => match text.get(pos) {
            // ECMAScript 的 `.` 不匹配行终止符。
            Some(c) if !is_line_terminator(*c) => vec![pos + 1],
            _ => Vec::new(),
        },
        Node::Class { negated, items } => match text.get(pos) {
            Some(c) if items.iter().any(|item| item.matches(*c)) != *negated => vec![pos + 1],
            _ => Vec::new(),
        },
        Node::Start => {
            if pos == 0 {
                vec![pos]
            } else {
                Vec::new()
            }
        }
        Node::End => {
            if pos == text.len() {
                vec![pos]
            } else {
                Vec::new()
            }
        }
        Node::Concat(nodes) => {
            let mut positions = vec![pos];
            for node in nodes {
                let mut next: Vec<usize> = positions
                    .iter()
                    .flat_map(|p| ends(node, text, *p))
                    .collect();
                dedup(&mut next);
                if next.is_empty() {
                    return Vec::new();
                }
                positions = next;
            }
            positions
        }
        Node::Alternate(alts) => {
            let mut out: Vec<usize> = alts.iter().flat_map(|alt| ends(alt, text, pos)).collect();
            dedup(&mut out);
            out
        }
        Node::Repeat { node, min, max } => {
            let mut out = Vec::new();
            let mut current = vec![pos];
            let mut count = 0usize;
            loop {
                if count >= *min {
                    out.extend(current.iter().copied());
                }
                if max.is_some_and(|max| count >= max) {
                    break;
                }
                let mut next: Vec<usize> =
                    current.iter().flat_map(|p| ends(node, text, *p)).collect();
                dedup(&mut next);
                // 丢掉上一层已有的位置：节点能匹配空串时（如 `(a?)*`）否则会死循环，
                // 而同一位置在更高层重复出现对「是否匹配」没有新信息。
                next.retain(|p| !current.contains(p));
                if next.is_empty() {
                    break;
                }
                current = next;
                count += 1;
            }
            dedup(&mut out);
            out
        }
    }
}

fn dedup(positions: &mut Vec<usize>) {
    positions.sort_unstable();
    positions.dedup();
}

struct Parser {
    chars: Vec<char>,
    pos: usize,
}

impl Parser {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn parse_alternation(&mut self) -> Result<Node, Unsupported> {
        let mut alts = vec![self.parse_concat()?];
        while self.peek() == Some('|') {
            self.pos += 1;
            alts.push(self.parse_concat()?);
        }
        Ok(if alts.len() == 1 {
            alts.pop().expect("alts 至少一项")
        } else {
            Node::Alternate(alts)
        })
    }

    fn parse_concat(&mut self) -> Result<Node, Unsupported> {
        let mut items = Vec::new();
        while let Some(c) = self.peek() {
            if c == '|' || c == ')' {
                break;
            }
            items.push(self.parse_repeat()?);
        }
        Ok(match items.len() {
            0 => Node::Empty,
            1 => items.pop().expect("items 长度为 1"),
            _ => Node::Concat(items),
        })
    }

    fn parse_repeat(&mut self) -> Result<Node, Unsupported> {
        let atom = self.parse_atom()?;
        let (min, max) = match self.peek() {
            Some('*') => (0, None),
            Some('+') => (1, None),
            Some('?') => (0, Some(1)),
            _ => return Ok(atom),
        };
        self.pos += 1;
        // 惰性量词的 `?` 只影响匹配长度，这里只判定「是否匹配」，直接吞掉。
        if self.peek() == Some('?') {
            self.pos += 1;
        }
        if matches!(self.peek(), Some('*') | Some('+') | Some('?')) {
            return Err(Unsupported("连续量词".to_string()));
        }
        Ok(Node::Repeat {
            node: Box::new(atom),
            min,
            max,
        })
    }

    fn parse_atom(&mut self) -> Result<Node, Unsupported> {
        let c = self
            .peek()
            .ok_or_else(|| Unsupported("模式意外结束".to_string()))?;
        match c {
            '(' => {
                self.pos += 1;
                if self.peek() == Some('?') {
                    return Err(Unsupported("分组修饰 `(?`".to_string()));
                }
                let inner = self.parse_alternation()?;
                if self.peek() != Some(')') {
                    return Err(Unsupported("括号未闭合".to_string()));
                }
                self.pos += 1;
                Ok(inner)
            }
            ')' => Err(Unsupported("多余的 `)`".to_string())),
            '[' => self.parse_class(),
            // Dart 里 `]` `}` 在字符类之外就是字面量。
            ']' | '}' => {
                self.pos += 1;
                Ok(Node::Char(c))
            }
            '{' => Err(Unsupported("量词 `{}`".to_string())),
            '.' => {
                self.pos += 1;
                Ok(Node::AnyChar)
            }
            '^' => {
                self.pos += 1;
                Ok(Node::Start)
            }
            '$' => {
                self.pos += 1;
                Ok(Node::End)
            }
            '*' | '+' | '?' => Err(Unsupported("量词前没有可重复的元素".to_string())),
            '\\' => {
                self.pos += 1;
                self.parse_escape()
            }
            other => {
                self.pos += 1;
                Ok(Node::Char(other))
            }
        }
    }

    fn parse_escape(&mut self) -> Result<Node, Unsupported> {
        let c = self
            .peek()
            .ok_or_else(|| Unsupported("反斜杠后没有字符".to_string()))?;
        self.pos += 1;
        Ok(match c {
            'd' => class(ClassItem::Digit(false)),
            'D' => class(ClassItem::Digit(true)),
            'w' => class(ClassItem::Word(false)),
            'W' => class(ClassItem::Word(true)),
            's' => class(ClassItem::Space(false)),
            'S' => class(ClassItem::Space(true)),
            'n' => Node::Char('\n'),
            't' => Node::Char('\t'),
            'r' => Node::Char('\r'),
            'f' => Node::Char('\u{c}'),
            'v' => Node::Char('\u{b}'),
            // 这些在 Dart 里有别的语义，猜错会让两端分叉，一律拒绝。
            'b' | 'B' | 'p' | 'P' | 'u' | 'x' | 'k' | '0'..='9' => {
                return Err(Unsupported(format!("转义 `\\{c}`")));
            }
            other => Node::Char(other),
        })
    }

    fn parse_class(&mut self) -> Result<Node, Unsupported> {
        self.pos += 1; // '['
        let negated = if self.peek() == Some('^') {
            self.pos += 1;
            true
        } else {
            false
        };
        let mut items = Vec::new();
        loop {
            let c = self
                .peek()
                .ok_or_else(|| Unsupported("字符类未闭合".to_string()))?;
            // ECMAScript 里 `]` 紧跟 `[`（或 `[^`）就是闭合：`[]` 是空字符类（永不匹配），
            // `[^]` 匹配任意字符。这里不能按 Perl 习惯把它当字面量。
            if c == ']' {
                self.pos += 1;
                break;
            }

            let item = if c == '\\' {
                self.pos += 1;
                let escaped = self
                    .peek()
                    .ok_or_else(|| Unsupported("字符类里反斜杠后没有字符".to_string()))?;
                self.pos += 1;
                match escaped {
                    'd' => ClassItem::Digit(false),
                    'D' => ClassItem::Digit(true),
                    'w' => ClassItem::Word(false),
                    'W' => ClassItem::Word(true),
                    's' => ClassItem::Space(false),
                    'S' => ClassItem::Space(true),
                    'n' => ClassItem::Char('\n'),
                    't' => ClassItem::Char('\t'),
                    'r' => ClassItem::Char('\r'),
                    'f' => ClassItem::Char('\u{c}'),
                    'v' => ClassItem::Char('\u{b}'),
                    // 字符类里 `\b` 是退格；其余照旧拒绝。
                    'b' => ClassItem::Char('\u{8}'),
                    'p' | 'P' | 'u' | 'x' | 'k' | '0'..='9' => {
                        return Err(Unsupported(format!("字符类里的转义 `\\{escaped}`")));
                    }
                    other => ClassItem::Char(other),
                }
            } else {
                self.pos += 1;
                ClassItem::Char(c)
            };

            // 区间 `a-z`：只有单字符元素能当左端，且 `-` 后面不是 `]`。
            if let ClassItem::Char(low) = item {
                if self.peek() == Some('-') && self.chars.get(self.pos + 1).copied() != Some(']') {
                    let high = self
                        .chars
                        .get(self.pos + 1)
                        .copied()
                        .ok_or_else(|| Unsupported("字符类里区间没有右端".to_string()))?;
                    self.pos += 2;
                    items.push(ClassItem::Range(low, high));
                    continue;
                }
                items.push(ClassItem::Char(low));
                continue;
            }
            items.push(item);
        }
        Ok(Node::Class { negated, items })
    }
}

fn class(item: ClassItem) -> Node {
    Node::Class {
        negated: false,
        items: vec![item],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn matches(pattern: &str, text: &str) -> bool {
        compile(pattern)
            .unwrap_or_else(|error| panic!("`{pattern}` 应能编译：{error}"))
            .is_match(text)
    }

    fn unsupported(pattern: &str) -> bool {
        compile(pattern).is_err()
    }

    #[test]
    fn literals_and_search_semantics() {
        assert!(matches("abc", "xabcx"));
        assert!(!matches("abc", "abx"));
        assert!(matches("", "任意"));
    }

    #[test]
    fn anchors() {
        assert!(matches("^test-", "test-1"));
        assert!(!matches("^test-", "xtest-1"));
        assert!(matches("-IEPL$", "香港-IEPL"));
        assert!(!matches("-IEPL$", "香港-IEPLx"));
        assert!(matches("^$", ""));
        assert!(!matches("^$", "a"));
    }

    #[test]
    fn alternation_and_groups() {
        assert!(matches("过期|剩余|官网", "剩余流量"));
        assert!(matches("过期|剩余|官网", "节点官网"));
        assert!(!matches("过期|剩余|官网", "正常节点"));
        assert!(matches("^(香港|台湾)", "台湾01"));
        assert!(matches("(ab|cd)+", "abcdab"));
    }

    #[test]
    fn digit_escape_and_quantifiers() {
        assert!(matches(r"\d+", "G123"));
        assert!(!matches(r"\d+", "abc"));
        assert!(matches(r"^\d+$", "42"));
        assert!(!matches(r"^\d+$", "4a"));
        assert!(matches(r"[0-9]+G", "10Gbps"));
        assert!(matches("a*", "bbb"));
        assert!(matches("ab?c", "ac"));
        assert!(matches("ab?c", "abc"));
        assert!(!matches("ab?c", "abbc"));
        // 惰性写法只影响长度，不影响是否匹配。
        assert!(matches(r"\d+?", "12"));
    }

    #[test]
    fn dot_and_word_classes() {
        assert!(matches("a.c", "abc"));
        assert!(!matches("a.c", "abbc"));
        assert!(matches(r"\w+", "_x1"));
        assert!(!matches(r"^\w+$", "中文"));
        assert!(matches(r"\s", "a b"));
        assert!(matches(r"\S+", "中文"));
        assert!(matches(r"^\D+$", "abc"));
    }

    #[test]
    fn character_classes() {
        assert!(matches("[abc]", "zzb"));
        assert!(!matches("[abc]", "zzz"));
        assert!(matches("[a-z]+", "abc"));
        assert!(matches("[^0-9]", "a1"));
        assert!(!matches("^[^0-9]+$", "a1"));
        assert!(matches(r"[\d]+", "42"));
        assert!(matches(r"^[\w-]+$", "a-b_c"));
        // ECMAScript 语义：`[]` 永不匹配、`[^]` 匹配任意字符（含换行）；
        // `-` 在类尾是字面量。
        assert!(!matches("[]", "x"));
        assert!(matches("[^]", "\n"));
        assert!(!matches("[]]", "x]"));
        assert!(matches("[a-]", "-"));
        assert!(matches("[a-]", "a"));
    }

    #[test]
    fn literal_escapes() {
        assert!(matches(r"a\.b", "a.b"));
        assert!(!matches(r"a\.b", "axb"));
        assert!(matches(r"\|", "|"));
        assert!(matches(r"\\", r"a\b"));
        assert!(matches(r"\n", "a\nb"));
    }

    #[test]
    fn unsupported_syntax_is_rejected() {
        for pattern in [
            r"a{2}", r"(?i)abc", r"(?:ab)", r"(?=a)", r"\bfoo", r"(a)\1", r"\p{L}", r"\u0041",
            r"\x41", r"[a", r"a**", r"*abc", r"a{1,}", r"a+*", r"\",
        ] {
            assert!(unsupported(pattern), "`{pattern}` 应被拒绝");
        }
    }
}
