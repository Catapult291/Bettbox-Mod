//! `bb_process_profile` 性能基准（计划 §3；关闭路线稿 §1.4 的「尚未量化」欠账）。
//!
//! 每个夹具跑三条路径，报告每次调用的 min / p50 / mean 与「合并入口 vs 两次 FFI」加速比：
//!
//! 1. `merged`     —— `bb_process_profile`，出货路径（整份配置只跨一次 FFI）；
//! 2. `two-ffi`    —— 模拟删 Dart 镜像前的往返：`bb_eval_script` 求值 → 用结果替换
//!    `rawConfig` → `bb_patch_config`（两次跨 FFI，中间各一次 JSON 解析/序列化）；
//! 3. `patch-only` —— 单独 `bb_patch_config`，纯管道基线。
//!
//! 形态按计划 §3.2：手写 `std::time::Instant` 循环（不引 criterion——新依赖进 deny.toml
//! 审计面，一次量化也不需要统计框架）；每路径预热 3 次后自适应跑到累计 ≥1 s
//! （至少 5 次，上限 60 s / 100 万次），报告 min / p50 / mean。
//! 三条路径**轮流采样**（同一夹具内交替各取一个样本，谁没跑够谁继续）：顺序各测一段
//! 会让先跑的路径吃 CPU 频率爬坡的亏，首轮实测合并入口反而显得更慢，交替后抵消。
//!
//! 夹具与校验语义：
//! * `process_profile/profile-{a,b}-real-script.json`（真实脚本 × 真实 profile，最大头）：
//!   `merged` / `two-ffi` 与 golden 逐字段对拍；`patch-only` 只是无脚本基线，golden 含脚本
//!   改动，不与它比。
//! * `patch_config/profile-a-default.json`（纯 patch 对照）：夹具没有脚本，`merged` / `two-ffi`
//!   用恒等脚本补齐三条路径的结构；QuickJS 会把 `127.0` 归一成 `127`（数值种类变化），
//!   所以这两条只互相对拍、不与 golden 逐字段比，`patch-only` 与 golden 比。
//!
//! **two-ffi 是模拟**：在同进程内串两次 C ABI 调用，含信封解析与二次序列化，但没有历史
//! Dart 镜像侧的开销（Dart 的 map 构造/序列化近似为 Rust 的 `Value` clone + `to_string`），
//! 相对真实历史往返偏乐观。三条路径都含每次调用的输入 JSON 序列化，对齐 Dart 每次先拼
//! JSON 再跨 FFI 的形状。
//!
//! 夹具默认取 `CARGO_MANIFEST_DIR/../../fixtures/golden`（不设环境变量也能跑）；
//! `--json <path>` 把结果落盘，便于贴进 `CHANGES-vs-upstream.md`。
//!
//! 运行（release；CI 不跑）：
//!
//! ```text
//! cd rust/bettbox-native && cargo bench --bench process_profile
//! ```

use std::ffi::{CStr, CString};
use std::hint::black_box;
use std::os::raw::c_char;
use std::path::{Path, PathBuf};
use std::ptr;
use std::time::{Duration, Instant};

use bettbox_native::{ffi, script_ffi};
use serde_json::Value;

/// 每条路径的预热次数。
const WARMUP: usize = 3;
/// 每条路径的最少计时次数。
const MIN_ITERS: usize = 5;
/// 每条路径的计时下限：累计跑满这个时长才停。
const MIN_TOTAL_MS: u64 = 1_000;
/// 每条路径的计时上限（与次数上限双保险）。
const MAX_TOTAL_S: u64 = 60;
/// 每条路径的计时次数绝对上限。
const MAX_ITERS: usize = 1_000_000;

/// 纯 patch 夹具没有脚本：`merged` / `two-ffi` 用恒等脚本补齐三条路径的结构。
const IDENTITY_SCRIPT: &str = "function main(c) { return c; }";

#[derive(Clone, Copy, PartialEq, Eq)]
enum ScriptKind {
    /// 夹具自带真实脚本：`merged` / `two-ffi` 与 golden 对拍。
    Real,
    /// 纯 patch 夹具：路径 1/2 用恒等脚本。
    Identity,
}

/// 计划 §3.2 点名的三个夹具（夹具路径按文件名序稳定）。
const FIXTURES: &[(&str, ScriptKind)] = &[
    (
        "process_profile/profile-a-real-script.json",
        ScriptKind::Real,
    ),
    (
        "process_profile/profile-b-real-script.json",
        ScriptKind::Real,
    ),
    ("patch_config/profile-a-default.json", ScriptKind::Identity),
];

struct Fixture {
    name: String,
    source: &'static str,
    kind: ScriptKind,
    input: Value,
    script: String,
    options: Option<String>,
    expected_output: Value,
    expected_script_error: Value,
}

struct PathStats {
    iterations: usize,
    min: Duration,
    p50: Duration,
    mean: Duration,
    total: Duration,
}

fn golden_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/golden")
}

fn kind_label(kind: ScriptKind) -> &'static str {
    match kind {
        ScriptKind::Real => "real-script",
        ScriptKind::Identity => "identity-script",
    }
}

struct Args {
    json_out: Option<PathBuf>,
}

impl Args {
    fn parse() -> Self {
        let mut json_out = None;
        let mut args = std::env::args().skip(1);
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--json" => {
                    let path = args.next().unwrap_or_else(|| {
                        eprintln!("--json 需要一个路径参数");
                        std::process::exit(2);
                    });
                    json_out = Some(PathBuf::from(path));
                }
                // cargo 偶尔转发的 libtest 参数：harness = false 下无实际作用。
                "--bench" => {}
                "-h" | "--help" => {
                    println!("用法: cargo bench --bench process_profile [-- --json <path>]");
                    std::process::exit(0);
                }
                other => {
                    eprintln!("未知参数: {other}（可用: --json <path>）");
                    std::process::exit(2);
                }
            }
        }
        Self { json_out }
    }
}

fn load_fixture(dir: &Path, source: &'static str, kind: ScriptKind) -> Fixture {
    let path = dir.join(source);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("读取 {} 失败：{error}", path.display()));
    let case: Value = serde_json::from_str(&text)
        .unwrap_or_else(|error| panic!("解析 {} 失败：{error}", path.display()));
    let name = path
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_default();
    let script = match kind {
        ScriptKind::Real => case["script"]
            .as_str()
            .unwrap_or_else(|| panic!("{name}: 缺 script"))
            .to_owned(),
        ScriptKind::Identity => IDENTITY_SCRIPT.to_owned(),
    };
    let options = case
        .get("customOptions")
        .filter(|value| !value.is_null())
        .map(|value| value.to_string());
    Fixture {
        name,
        source,
        kind,
        input: case["input"].clone(),
        script,
        options,
        expected_output: case["output"].clone(),
        expected_script_error: case.get("scriptError").cloned().unwrap_or(Value::Null),
    }
}

fn to_cstring(text: &str, what: &str) -> CString {
    CString::new(text).unwrap_or_else(|_| panic!("{what}含 NUL，无法转成 C 字符串"))
}

/// 调 FFI 并取回字符串；NULL 即 panic（基准里 ABI 级失败等于该次结果无效）。
fn take_string(call: impl FnOnce() -> *mut c_char, what: &str) -> String {
    let out = call();
    assert!(!out.is_null(), "{what} 返回 NULL");
    let text = unsafe { CStr::from_ptr(out) }
        .to_str()
        .expect("FFI 返回的不是 UTF-8")
        .to_owned();
    unsafe { ffi::bb_string_free(out) };
    text
}

/// 路径 1：合并入口，一次 JSON 进出。返回整个信封（校验要用 `scriptError`）。
fn merged_once(f: &Fixture) -> Value {
    let input = to_cstring(&f.input.to_string(), "输入");
    let script = to_cstring(&f.script, "脚本");
    let options = f.options.as_deref().map(|text| to_cstring(text, "选项"));
    let envelope = take_string(
        || unsafe {
            ffi::bb_process_profile(
                input.as_ptr(),
                script.as_ptr(),
                options.as_ref().map_or(ptr::null(), |value| value.as_ptr()),
            )
        },
        "bb_process_profile",
    );
    serde_json::from_str(&envelope).expect("bb_process_profile 信封不是合法 JSON")
}

/// 路径 2：模拟删 Dart 镜像前的两次 FFI 往返，返回最终配置。
fn two_ffi_once(f: &Fixture) -> Value {
    let script = to_cstring(&f.script, "脚本");
    let options = f.options.as_deref().map(|text| to_cstring(text, "选项"));

    // 第一跳：与旧 Dart 路径一致，先对 rawConfig 文本求值。
    let raw_config = to_cstring(&f.input["rawConfig"].to_string(), "rawConfig");
    let eval_text = take_string(
        || unsafe {
            script_ffi::bb_eval_script(
                script.as_ptr(),
                raw_config.as_ptr(),
                options.as_ref().map_or(ptr::null(), |value| value.as_ptr()),
            )
        },
        "bb_eval_script",
    );
    let envelope: Value =
        serde_json::from_str(&eval_text).expect("bb_eval_script 信封不是合法 JSON");
    // 与合并入口语义一致：脚本失败保留原 rawConfig。
    let evaluated = if envelope["ok"] == Value::Bool(true) {
        envelope["config"].clone()
    } else {
        f.input["rawConfig"].clone()
    };

    // 第二跳：换上求值结果再走纯 patch（这一步的历史成本含 Dart 侧 map 更新与再序列化）。
    let mut input = f.input.clone();
    input["rawConfig"] = evaluated;
    let input_c = to_cstring(&input.to_string(), "输入");
    let output = take_string(
        || unsafe { ffi::bb_patch_config(input_c.as_ptr()) },
        "bb_patch_config",
    );
    serde_json::from_str(&output).expect("bb_patch_config 输出不是合法 JSON")
}

/// 路径 3：纯管道基线，返回配置。
fn patch_only_once(f: &Fixture) -> Value {
    let input = to_cstring(&f.input.to_string(), "输入");
    let output = take_string(
        || unsafe { ffi::bb_patch_config(input.as_ptr()) },
        "bb_patch_config",
    );
    serde_json::from_str(&output).expect("bb_patch_config 输出不是合法 JSON")
}

/// 计时前先对拍：确认三条路径跑的是 golden 那条语义，数字才有意义。
fn validate(f: &Fixture) {
    let envelope = merged_once(f);
    assert_eq!(
        envelope["ok"],
        Value::Bool(true),
        "{}: merged ok 不为 true",
        f.name
    );
    let actual_error = envelope.get("scriptError").cloned().unwrap_or(Value::Null);
    assert_eq!(
        actual_error, f.expected_script_error,
        "{}: scriptError 不一致",
        f.name
    );
    let merged_config = envelope["config"].clone();
    let two = two_ffi_once(f);
    let patch = patch_only_once(f);
    assert!(patch.is_object(), "{}: patch-only 输出不是对象", f.name);

    match f.kind {
        ScriptKind::Real => {
            assert_eq!(
                merged_config, f.expected_output,
                "{}: merged 与 golden 不一致",
                f.name
            );
            assert_eq!(
                two, f.expected_output,
                "{}: two-ffi 与 golden 不一致",
                f.name
            );
        }
        ScriptKind::Identity => {
            // 恒等脚本经 QuickJS 会把 `127.0` 归一成 `127`（数值种类变化），
            // 不与 golden 逐字段比；换成两条脚本路径互相对拍。
            assert_eq!(
                merged_config, two,
                "{}: merged 与 two-ffi 输出不一致",
                f.name
            );
            assert_eq!(
                patch, f.expected_output,
                "{}: patch-only 与 golden 不一致",
                f.name
            );
        }
    }
}

/// 单条路径的采样池：轮流采样时按路径各自累计。
#[derive(Default)]
struct Samples {
    values: Vec<Duration>,
    total: Duration,
}

impl Samples {
    /// 该路径是否还需要继续采样（≥`MIN_TOTAL_MS` 且 ≥`MIN_ITERS` 次，带双保险上限）。
    fn wants(&self) -> bool {
        self.values.len() < MAX_ITERS
            && self.total < Duration::from_secs(MAX_TOTAL_S)
            && (self.total < Duration::from_millis(MIN_TOTAL_MS) || self.values.len() < MIN_ITERS)
    }

    fn time_one(&mut self, work: &mut impl FnMut() -> Value) {
        let start = Instant::now();
        black_box(work());
        let elapsed = start.elapsed();
        self.values.push(elapsed);
        self.total += elapsed;
    }

    fn into_stats(self) -> PathStats {
        let iterations = self.values.len();
        let mut sorted = self.values;
        sorted.sort_unstable();
        let min = sorted
            .first()
            .copied()
            .expect("计时样本为空（不应发生：wants() 保证至少采 5 次）");
        let p50 = sorted[iterations / 2];
        let mean = self.total / (iterations as u32);
        PathStats {
            iterations,
            min,
            p50,
            mean,
            total: self.total,
        }
    }
}

/// 三条路径**轮流**采样（而非各自跑完一条再跑下一条）：桌面 CPU 的频率爬坡与后台抖动
/// 会系统性偏袒后跑的路径，轮流采样让三条路径吃同一段运行环境。
/// 预热同样交替：每路径各 `WARMUP` 次，轮流执行。
fn measure_interleaved<F1, F2, F3>(
    mut merged: F1,
    mut two: F2,
    mut patch: F3,
) -> (PathStats, PathStats, PathStats)
where
    F1: FnMut() -> Value,
    F2: FnMut() -> Value,
    F3: FnMut() -> Value,
{
    for _ in 0..WARMUP {
        black_box(merged());
        black_box(two());
        black_box(patch());
    }
    let (mut a, mut b, mut c) = (Samples::default(), Samples::default(), Samples::default());
    while a.wants() || b.wants() || c.wants() {
        if a.wants() {
            a.time_one(&mut merged);
        }
        if b.wants() {
            b.time_one(&mut two);
        }
        if c.wants() {
            c.time_one(&mut patch);
        }
    }
    (a.into_stats(), b.into_stats(), c.into_stats())
}

fn fmt_duration(duration: Duration) -> String {
    let secs = duration.as_secs_f64();
    if secs < 1e-3 {
        format!("{:.0} µs", secs * 1e6)
    } else if secs < 1.0 {
        format!("{:.2} ms", secs * 1e3)
    } else {
        format!("{:.3} s", secs)
    }
}

fn print_row(label: &str, stats: &PathStats) {
    println!(
        "   {:<11} {:>9} {:>10} {:>10} {:>10}",
        label,
        stats.iterations,
        fmt_duration(stats.min),
        fmt_duration(stats.p50),
        fmt_duration(stats.mean),
    );
}

fn stats_json(stats: &PathStats) -> Value {
    serde_json::json!({
        "iterations": stats.iterations,
        "min_us": stats.min.as_micros() as u64,
        "p50_us": stats.p50.as_micros() as u64,
        "mean_us": stats.mean.as_secs_f64() * 1e6,
        "total_ms": stats.total.as_millis() as u64,
    })
}

fn main() {
    let args = Args::parse();
    let dir = golden_dir();
    let fixtures: Vec<Fixture> = FIXTURES
        .iter()
        .map(|(source, kind)| load_fixture(&dir, source, *kind))
        .collect();

    println!("bb_process_profile 性能基准（计划 §3）");
    println!("夹具目录: {}", dir.display());
    println!(
        "环境: {} {} | 每路径预热 {WARMUP} 次 | 累计 ≥{MIN_TOTAL_MS} ms、至少 {MIN_ITERS} 次（上限 {MAX_TOTAL_S} s / {MAX_ITERS} 次）",
        std::env::consts::OS,
        std::env::consts::ARCH,
    );

    let mut report_fixtures = Vec::new();
    for fixture in &fixtures {
        validate(fixture);

        // 三路径轮流采样，消除顺序（频率爬坡/热漂移）偏差，见 measure_interleaved。
        let (merged, two, patch) = measure_interleaved(
            || black_box(merged_once(fixture)),
            || black_box(two_ffi_once(fixture)),
            || black_box(patch_only_once(fixture)),
        );

        let p50_ratio = two.p50.as_secs_f64() / merged.p50.as_secs_f64();
        let mean_ratio = two.mean.as_secs_f64() / merged.mean.as_secs_f64();

        println!();
        println!("== {} （{}）", fixture.name, fixture.source);
        println!(
            "   input {} B | rawConfig {} B | script {} B",
            fixture.input.to_string().len(),
            fixture.input["rawConfig"].to_string().len(),
            fixture.script.len(),
        );
        if fixture.kind == ScriptKind::Identity {
            println!(
                "   注：纯 patch 夹具无脚本，merged / two-ffi 用恒等脚本补齐结构（不与 golden 逐字段比）"
            );
        }
        println!(
            "   {:<11} {:>9} {:>10} {:>10} {:>10}",
            "path", "iters", "min", "p50", "mean"
        );
        print_row("merged", &merged);
        print_row("two-ffi", &two);
        print_row("patch-only", &patch);
        println!("   加速比 two-ffi ÷ merged：p50 {p50_ratio:.2}×，mean {mean_ratio:.2}×");

        report_fixtures.push(serde_json::json!({
            "name": fixture.name,
            "source": fixture.source,
            "script_kind": kind_label(fixture.kind),
            "input_bytes": fixture.input.to_string().len(),
            "raw_config_bytes": fixture.input["rawConfig"].to_string().len(),
            "script_bytes": fixture.script.len(),
            "paths": {
                "merged": stats_json(&merged),
                "two-ffi": stats_json(&two),
                "patch-only": stats_json(&patch),
            },
            "speedup_two_ffi_over_merged": { "p50": p50_ratio, "mean": mean_ratio },
        }));
    }

    let report = serde_json::json!({
        "meta": {
            "os": std::env::consts::OS,
            "arch": std::env::consts::ARCH,
            "warmup_per_path": WARMUP,
            "min_total_ms": MIN_TOTAL_MS,
            "min_iters": MIN_ITERS,
            "max_total_s": MAX_TOTAL_S,
            "profile": "bench（release）",
            "note": "三路径轮流采样以抵消频率爬坡偏差；two-ffi 为同进程内模拟的历史两次 FFI 往返，无 Dart 侧开销，相对真实历史路径偏乐观；三条路径均含每次调用的输入 JSON 序列化",
        },
        "fixtures": report_fixtures,
    });

    if let Some(path) = &args.json_out {
        let text = serde_json::to_string_pretty(&report).expect("序列化报告失败");
        std::fs::write(path, text)
            .unwrap_or_else(|error| panic!("写入 {} 失败：{error}", path.display()));
        println!();
        println!("JSON 报告: {}", path.display());
    }
}
