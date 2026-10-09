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
    // 子命令是应用侧提权调用的入口，不能交给服务分发器。
    if let Some(code) = cli::run_if_cli() {
        std::process::exit(code);
    }

    service::windows::main()
}

#[cfg(not(all(feature = "windows-service", target_os = "windows")))]
fn main() {
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
