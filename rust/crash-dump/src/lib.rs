//! 崩溃收集（路线稿 §4.5）：Rust panic hook + Windows 未处理异常过滤器。
//!
//! 安装后：
//! - **panic**（含 FFI 边界 `catch_unwind` 捕获之前）在目录里追加一行文本日志，
//!   并（Windows 上）写一个进程 minidump；panic dump 按进程限频（10 秒 1 个），
//!   防止「必崩输入被反复调用」把时间耗在落盘上。
//! - **未处理异常**（访问违规等，如 QuickJS C 代码里的内存错误）在 Windows 上写
//!   minidump，然后链回原有过滤器（没有则按 EXCEPTION_EXECUTE_HANDLER 终止）。
//!
//! 落盘位置默认 `%TEMP%\BettboxCrash`（[default_dir]），可用环境变量
//! `BETTBOX_CRASH_DIR` 覆盖；文件按 `<tag>-<毫秒时间戳>-<pid>` 命名，每个 tag
//! 只保留最近 [MAX_DUMPS] 个 dump（`<tag>-crash.log` 是配套的文本记录，超过
//! 256 KiB 会轮转成 `.old`）。处理器内所有 I/O 均尽力而为：崩溃路径上不允许
//! 再抛错。

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::panic::{self, PanicHookInfo};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

#[cfg(windows)]
mod windows_impl;

/// 每个 tag 保留的 minidump 上限。
const MAX_DUMPS: usize = 3;
/// 两次 panic minidump 之间的最短间隔（毫秒）；文本日志不受此限制。
const PANIC_DUMP_MIN_INTERVAL_MS: u64 = 10_000;
/// `<tag>-crash.log` 超过该大小时轮转为 `<tag>-crash.log.old`。
const LOG_ROTATE_BYTES: u64 = 256 * 1024;

/// 安装参数。
#[derive(Debug, Clone)]
pub struct InstallConfig {
    /// dump 与日志的存放目录（不存在则创建）。
    pub dir: PathBuf,
    /// 文件名与日志行的来源前缀，如 `native` / `guard` / `helper`。
    pub tag: &'static str,
}

static INSTALLED: AtomicBool = AtomicBool::new(false);
static WRITING_DUMP: AtomicBool = AtomicBool::new(false);
static LAST_PANIC_DUMP_MS: AtomicU64 = AtomicU64::new(0);
static DUMP_DIR: OnceLock<PathBuf> = OnceLock::new();
static TAG: OnceLock<&'static str> = OnceLock::new();

/// 默认落盘目录：`BETTBOX_CRASH_DIR`，未设则 `%TEMP%\BettboxCrash`。
pub fn default_dir() -> PathBuf {
    std::env::var_os("BETTBOX_CRASH_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("BettboxCrash"))
}

/// 幂等安装崩溃收集。返回是否本次调用完成了安装（已装过则返回 false）。
///
/// 安装内容：panic hook（全平台）；Windows 上另有未处理异常过滤器。目录创建
/// 失败不阻断安装——处理器内所有 I/O 都是尽力而为。
pub fn install(config: InstallConfig) -> bool {
    if INSTALLED.swap(true, Ordering::SeqCst) {
        return false;
    }
    let _ = fs::create_dir_all(&config.dir);
    let _ = DUMP_DIR.set(config.dir.clone());
    let _ = TAG.set(config.tag);

    let dir = config.dir;
    let tag = config.tag;
    let previous = panic::take_hook();
    panic::set_hook(Box::new(move |info| {
        record_panic(&dir, tag, info);
        previous(info);
    }));

    #[cfg(windows)]
    windows_impl::install_exception_filter();

    true
}

/// 当前 dump 目录（未安装时为 None）。崩溃处理器内部用。
pub(crate) fn dump_dir() -> Option<&'static Path> {
    DUMP_DIR.get().map(PathBuf::as_path)
}

/// 当前 tag（未安装时为 None）。
pub(crate) fn tag() -> &'static str {
    TAG.get().copied().unwrap_or("crash")
}

fn record_panic(dir: &Path, tag: &str, info: &PanicHookInfo<'_>) {
    let payload = payload_str(info.payload());
    let location = info
        .location()
        .map(|loc| format!("{}:{}", loc.file(), loc.line()))
        .unwrap_or_else(|| "<无位置>".to_string());

    let dump = maybe_write_panic_dump(dir, tag);
    let dump_note = match dump {
        Some(path) => format!(
            " dump={}",
            path.file_name().unwrap_or_default().to_string_lossy()
        ),
        None => String::new(),
    };
    append_log(
        dir,
        tag,
        &format!("panic: {payload} @ {location}{dump_note}"),
    );
}

fn payload_str(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(text) = payload.downcast_ref::<&'static str>() {
        (*text).to_string()
    } else if let Some(text) = payload.downcast_ref::<String>() {
        text.clone()
    } else {
        "<非字符串 panic 载荷>".to_string()
    }
}

/// panic 的 minidump 限频写入；返回实际落盘的文件（被限频或写失败时为 None）。
fn maybe_write_panic_dump(dir: &Path, tag: &str) -> Option<PathBuf> {
    let now_ms = unix_ms();
    let last = LAST_PANIC_DUMP_MS.load(Ordering::Relaxed);
    if now_ms.saturating_sub(last) < PANIC_DUMP_MIN_INTERVAL_MS {
        return None;
    }
    if LAST_PANIC_DUMP_MS
        .compare_exchange(last, now_ms, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return None;
    }
    write_dump(dir, tag, "panic", now_ms, None)
}

/// 未处理异常的落盘 + 文本记录（Windows 之外为 no-op）。供异常过滤器调用。
#[cfg(windows)]
pub(crate) fn record_unhandled(
    dir: &Path,
    tag: &str,
    exception: *mut windows_impl::ExceptionPointers,
) {
    let now_ms = unix_ms();
    let dump = write_dump(dir, tag, "unhandled", now_ms, Some(exception));
    let code = unsafe { (*(*exception).ExceptionRecord).ExceptionCode.0 };
    let dump_note = match dump {
        Some(path) => format!(
            " dump={}",
            path.file_name().unwrap_or_default().to_string_lossy()
        ),
        None => String::new(),
    };
    append_log(
        dir,
        tag,
        &format!("unhandled exception 0x{code:08X}{dump_note}"),
    );
}

/// 写一个 minidump 并执行保留策略。Windows 之外恒为 None。
#[cfg(windows)]
fn write_dump(
    dir: &Path,
    tag: &str,
    kind: &str,
    now_ms: u64,
    exception: Option<*mut windows_impl::ExceptionPointers>,
) -> Option<PathBuf> {
    if WRITING_DUMP
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return None;
    }
    let path = dir.join(format!(
        "{tag}-{kind}-{now_ms:013}-{}.dmp",
        std::process::id()
    ));
    let result = windows_impl::write_minidump(&path, exception);
    WRITING_DUMP.store(false, Ordering::SeqCst);
    if result.is_err() {
        return None;
    }
    prune_old_dumps(dir, tag);
    Some(path)
}

#[cfg(not(windows))]
fn write_dump(
    _dir: &Path,
    _tag: &str,
    _kind: &str,
    _now_ms: u64,
    _exception: Option<()>,
) -> Option<PathBuf> {
    None
}

/// 只保留每个 tag 最近 [MAX_DUMPS] 个 `.dmp`（按文件名里的零填充时间戳排序）。
fn prune_old_dumps(dir: &Path, tag: &str) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let prefix = format!("{tag}-");
    let mut dumps: Vec<PathBuf> = entries
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension().is_some_and(|ext| ext == "dmp")
                && path
                    .file_name()
                    .is_some_and(|name| name.to_string_lossy().starts_with(&prefix))
        })
        .collect();
    if dumps.len() <= MAX_DUMPS {
        return;
    }
    dumps.sort();
    let excess = dumps.len() - MAX_DUMPS;
    for path in dumps.into_iter().take(excess) {
        let _ = fs::remove_file(path);
    }
}

/// 追加一行日志；超过 [LOG_ROTATE_BYTES] 先轮转。
fn append_log(dir: &Path, tag: &str, message: &str) {
    let path = dir.join(format!("{tag}-crash.log"));
    if fs::metadata(&path).is_ok_and(|meta| meta.len() > LOG_ROTATE_BYTES) {
        let _ = fs::rename(&path, dir.join(format!("{tag}-crash.log.old")));
    }
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(file, "[{}] {}", format_utc(unix_secs()), message);
    }
}

pub(crate) fn unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or_default()
}

fn unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or_default()
}

/// Unix 秒 → `YYYY-MM-DDTHH:MM:SSZ`（UTC；civil-from-days 算法）。
fn format_utc(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let sod = secs % 86_400;
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]，3 月起
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    let y = if m <= 2 { y + 1 } else { y };
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        sod / 3600,
        (sod % 3600) / 60,
        sod % 60
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_test_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "crash_dump_test_{tag}_{}_{}",
            std::process::id(),
            unix_ms()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn format_utc_matches_known_instants() {
        assert_eq!(format_utc(0), "1970-01-01T00:00:00Z");
        assert_eq!(format_utc(86_400), "1970-01-02T00:00:00Z");
        // 2020-02-29T00:00:00Z（闰年边界）
        assert_eq!(format_utc(1_582_934_400), "2020-02-29T00:00:00Z");
        // 2026-10-16T00:00:00Z
        assert_eq!(format_utc(1_792_108_800), "2026-10-16T00:00:00Z");
    }

    #[test]
    fn prune_keeps_newest_dumps_only() {
        let dir = temp_test_dir("prune");
        for i in 0..5 {
            fs::write(dir.join(format!("native-panic-{i:013}-1.dmp")), b"x").unwrap();
        }
        // 其他 tag 与其他扩展名不受影响
        fs::write(dir.join("helper-panic-0000000000000-1.dmp"), b"x").unwrap();
        fs::write(dir.join("native-crash.log"), b"x").unwrap();

        prune_old_dumps(&dir, "native");

        let mut names: Vec<String> = fs::read_dir(&dir)
            .unwrap()
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert_eq!(
            names,
            [
                "helper-panic-0000000000000-1.dmp",
                "native-crash.log",
                "native-panic-0000000000002-1.dmp",
                "native-panic-0000000000003-1.dmp",
                "native-panic-0000000000004-1.dmp",
            ],
            "应只留最近 3 个 native dump，且不动其他 tag / 日志"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    /// 合并「幂等安装」与「panic 落盘」：install 是进程级一次性的，
    /// 拆成两个用例会因并行抢装而随缘指向对方的目录。
    #[test]
    fn install_is_idempotent_and_panic_leaves_trace() {
        let dir = temp_test_dir("install_panic");

        assert!(
            install(InstallConfig {
                dir: dir.clone(),
                tag: "native",
            }),
            "首次安装应成功"
        );
        assert!(
            !install(InstallConfig {
                dir: temp_test_dir("other"),
                tag: "other",
            }),
            "重复安装应被忽略"
        );

        let result = std::panic::catch_unwind(|| panic!("crash-dump 单测故意 panic"));
        assert!(result.is_err());

        let log = fs::read_to_string(dir.join("native-crash.log")).expect("panic 必须写文本日志");
        assert!(
            log.contains("crash-dump 单测故意 panic") && log.contains("lib.rs"),
            "日志应含 payload 与源码位置：{log}"
        );

        #[cfg(windows)]
        {
            let dumps: Vec<PathBuf> = fs::read_dir(&dir)
                .unwrap()
                .filter_map(|entry| entry.ok())
                .map(|entry| entry.path())
                .filter(|path| path.extension().is_some_and(|ext| ext == "dmp"))
                .collect();
            assert_eq!(dumps.len(), 1, "首个 panic 应写出 minidump：{dumps:?}");
            let magic = fs::read(&dumps[0]).unwrap();
            assert!(
                magic.starts_with(b"MDMP"),
                "minidump 魔数应为 MDMP，实际 {magic:?}"
            );
        }

        let _ = fs::remove_dir_all(&dir);
    }
}
