#[cfg(not(all(feature = "windows-service", target_os = "windows")))]
use crate::service::hub::run_service;
#[cfg(not(all(feature = "windows-service", target_os = "windows")))]
use tokio::runtime::Runtime;

#[cfg(target_os = "windows")]
mod cli;
mod ipc;
mod ops;
mod rpc;
mod service;

#[cfg(all(feature = "windows-service", target_os = "windows"))]
pub fn main() -> windows_service::Result<()> {
    install_crash_dump();

    // 子命令是应用侧提权调用的入口，不能交给服务分发器。
    if let Some(code) = cli::run_if_cli() {
        std::process::exit(code);
    }

    service::windows::main()
}

#[cfg(not(all(feature = "windows-service", target_os = "windows")))]
fn main() {
    install_crash_dump();

    #[cfg(target_os = "windows")]
    if let Some(code) = cli::run_if_cli() {
        std::process::exit(code);
    }

    if let Ok(rt) = Runtime::new() {
        rt.block_on(async {
            let _ = run_service().await;
        });
    }
}

/// 崩溃收集（路线稿 §4.5）：panic / 未处理异常写 minidump 与文本日志。
///
/// 目录用 `BETTBOX_CRASH_DIR` 覆盖后的默认值（`%TEMP%\BettboxCrash`）。服务以
/// SYSTEM 运行时 temp 是 `C:\Windows\Temp`，与既有 helper 错误日志同根，取证路径一致。
fn install_crash_dump() {
    crash_dump::install(crash_dump::InstallConfig {
        dir: crash_dump::default_dir(),
        tag: "helper",
    });
}
