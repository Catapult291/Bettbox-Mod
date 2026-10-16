//! BettboxProxyGuard：Windows 系统代理看门狗。
//!
//! 应用启动时拉起本进程（GUI 子系统，无窗口、无控制台），持有应用进程的
//! 句柄一直等到它退出；醒来后读 `--snapshot` 指向的快照文件：
//!   - 文件在 → 按快照还原系统代理（与应用内 `_restorePersisted` 同一份
//!     Rust 实现，含「只还原仍归我们管的连接」的归属判定），成功后删文件；
//!   - 文件不在 → 应用已正常关闭（关代理时就把文件删了），什么都不做。
//!
//! 这样「被强杀 → 下次启动」之间系统代理不再指向死端口：还原在进程死后
//! 几十毫秒内就发生，不必等下次启动。快照的归属判定保证正常退出路径的
//! 二次还原是幂等 no-op。
//!
//! 用法：`BettboxProxyGuard.exe --pid <应用PID> --snapshot <快照路径> --log <日志路径>`

#![cfg_attr(windows, windows_subsystem = "windows")]

use std::env;
use std::fs;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use bettbox_native::system_proxy::{self, ProxySnapshot, RestoreReport};

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let pid = arg_value(&args, "--pid").and_then(|value| value.parse::<u32>().ok());
    let snapshot = arg_value(&args, "--snapshot");
    let log = arg_value(&args, "--log");
    let (Some(pid), Some(snapshot), Some(log)) = (pid, snapshot, log) else {
        // GUI 子系统没有 stderr，参数不全直接静默退出（调用方是应用自己）。
        std::process::exit(2);
    };

    // 崩溃收集（路线稿 §4.5）：panic / 未处理异常往 %TEMP%\BettboxCrash 写 minidump。
    crash_dump::install(crash_dump::InstallConfig {
        dir: crash_dump::default_dir(),
        tag: "guard",
    });

    let code = run(pid, Path::new(&snapshot), Path::new(&log), restore_json);
    std::process::exit(code);
}

/// 从参数表里取 flag 后面的值。
fn arg_value(args: &[String], flag: &str) -> Option<String> {
    args.iter()
        .position(|arg| arg == flag)
        .and_then(|index| args.get(index + 1))
        .cloned()
}

/// 等 [pid] 指向的进程退出。进程句柄在等待前就握在手里，PID 被复用也不受影响。
#[cfg(windows)]
fn wait_for_exit(pid: u32) -> Result<(), String> {
    use windows::Win32::Foundation::{CloseHandle, WAIT_OBJECT_0};
    use windows::Win32::System::Threading::{
        OpenProcess, WaitForSingleObject, INFINITE, PROCESS_SYNCHRONIZE,
    };

    unsafe {
        let handle = OpenProcess(PROCESS_SYNCHRONIZE, false, pid)
            .map_err(|error| format!("OpenProcess({pid}) 失败：{error}"))?;
        let result = WaitForSingleObject(handle, INFINITE);
        let _ = CloseHandle(handle);
        if result == WAIT_OBJECT_0 {
            Ok(())
        } else {
            Err(format!("WaitForSingleObject 返回 {result:?}"))
        }
    }
}

#[cfg(not(windows))]
fn wait_for_exit(_pid: u32) -> Result<(), String> {
    Err("BettboxProxyGuard 只在 Windows 上有意义".to_string())
}

/// 把一行带时间戳的记录追加进日志（应用在拉起前会先清掉上一轮的日志）。
fn log_line(path: &Path, message: &str) {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or_default();
    let _ = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .and_then(|mut file| {
            use std::io::Write;
            writeln!(file, "[{stamp}] {message}")
        });
}

/// 主流程；`restore` 注入以便用例不碰真实系统代理。
fn run(
    pid: u32,
    snapshot_path: &Path,
    log_path: &Path,
    restore: impl FnOnce(&str) -> Result<RestoreReport, String>,
) -> i32 {
    log_line(log_path, &format!("等待应用进程 {pid} 退出"));
    if let Err(error) = wait_for_exit(pid) {
        log_line(log_path, &format!("等待失败：{error}"));
        return 1;
    }
    log_line(log_path, "应用进程已退出，检查快照");

    let raw = match fs::read_to_string(snapshot_path) {
        Ok(raw) => raw,
        Err(_) => {
            log_line(log_path, "无快照文件，系统代理未改动");
            return 0;
        }
    };
    match restore(&raw) {
        Ok(report) => {
            log_line(
                log_path,
                &format!("已还原 {} 项，跳过 {} 项", report.restored, report.skipped),
            );
            for warning in &report.warnings {
                log_line(log_path, &format!("警告：{warning}"));
            }
            let _ = fs::remove_file(snapshot_path);
            0
        }
        Err(error) => {
            // 快照留着：下次启动时应用还会用偏好设置里那份再试一次。
            log_line(log_path, &format!("还原失败，快照保留：{error}"));
            1
        }
    }
}

/// 与应用内 `_restorePersisted` 完全同源的还原路径。
fn restore_json(raw: &str) -> Result<RestoreReport, String> {
    let snapshot = ProxySnapshot::from_json(raw)?;
    system_proxy::restore(&snapshot)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_paths(tag: &str) -> (std::path::PathBuf, std::path::PathBuf) {
        let base = std::env::temp_dir().join(format!(
            "bettbox_proxy_guard_test_{tag}_{}",
            std::process::id()
        ));
        let _ = fs::remove_file(&base);
        let log = base.with_extension("log");
        (base, log)
    }

    /// 短命子进程当「被等的应用」：ping 两发大约 1 秒，OpenProcess 不会扑空。
    fn spawn_short_lived_child() -> std::process::Child {
        std::process::Command::new("cmd.exe")
            .args(["/c", "ping", "-n", "2", "127.0.0.1"])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn child")
    }

    #[test]
    fn arg_value_reads_flag_value_pairs() {
        let args: Vec<String> = ["--pid", "4242", "--snapshot", "a.json"]
            .iter()
            .map(|value| value.to_string())
            .collect();
        assert_eq!(arg_value(&args, "--pid").as_deref(), Some("4242"));
        assert_eq!(arg_value(&args, "--snapshot").as_deref(), Some("a.json"));
        assert_eq!(arg_value(&args, "--log"), None);
        assert_eq!(
            arg_value(&args, "--pid").and_then(|v| v.parse().ok()),
            Some(4242)
        );
    }

    #[cfg(windows)]
    #[test]
    fn run_restores_and_removes_snapshot_after_parent_exits() {
        let (snapshot_path, log_path) = temp_paths("restore");
        fs::write(&snapshot_path, "{\"version\":1}").expect("write snapshot");

        let mut child = spawn_short_lived_child();

        let mut called = false;
        let code = run(child.id(), &snapshot_path, &log_path, |raw| {
            called = true;
            assert_eq!(raw, "{\"version\":1}");
            Ok(RestoreReport {
                restored: 1,
                skipped: 0,
                warnings: vec![],
            })
        });
        let _ = child.wait();

        assert_eq!(code, 0);
        assert!(called, "进程死后必须走到还原");
        assert!(!snapshot_path.exists(), "还原成功后快照文件要删掉");
        let log = fs::read_to_string(&log_path).expect("log");
        assert!(log.contains("已还原 1 项"), "{log}");
        let _ = fs::remove_file(&log_path);
    }

    #[cfg(windows)]
    #[test]
    fn run_without_snapshot_file_is_a_noop() {
        let (snapshot_path, log_path) = temp_paths("noop");
        let mut child = spawn_short_lived_child();

        let mut called = false;
        let code = run(child.id(), &snapshot_path, &log_path, |_| {
            called = true;
            Ok(RestoreReport::default())
        });
        let _ = child.wait();

        assert_eq!(code, 0);
        assert!(!called, "没有快照就不该碰系统代理");
        let log = fs::read_to_string(&log_path).expect("log");
        assert!(log.contains("无快照文件"), "{log}");
        let _ = fs::remove_file(&log_path);
    }

    #[cfg(windows)]
    #[test]
    fn run_keeps_snapshot_when_restore_fails() {
        let (snapshot_path, log_path) = temp_paths("fail");
        fs::write(&snapshot_path, "not json").expect("write snapshot");

        let mut child = spawn_short_lived_child();

        let code = run(child.id(), &snapshot_path, &log_path, |_| {
            Err("解析失败".to_string())
        });
        let _ = child.wait();

        assert_eq!(code, 1);
        assert!(snapshot_path.exists(), "失败时快照要留给下次启动重试");
        let log = fs::read_to_string(&log_path).expect("log");
        assert!(log.contains("还原失败"), "{log}");
        let _ = fs::remove_file(&log_path);
        let _ = fs::remove_file(&snapshot_path);
    }

    #[test]
    fn restore_json_rejects_bad_input() {
        assert!(restore_json("not json").is_err());
        assert!(restore_json("{\"version\":99,\"connections\":[]}").is_err());
    }
}
