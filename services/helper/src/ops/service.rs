//! 服务注册与卸载（`helper.exe service install|uninstall`）。
//!
//! 替掉应用侧拼的 `sc stop & sc delete & sc create … & reg add …Environment… & sc start`：
//! 那条命令串既怕引号与转义，失败时也只剩一个退出码。这里用 `windows-service` 的
//! `ServiceManager` 建服务、注册表 API 写服务 `Environment`，并给服务配上崩溃恢复策略。

use std::ffi::{OsStr, OsString};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use windows::core::{w, PCWSTR, PWSTR};
use windows::Win32::Security::SC_HANDLE;
use windows::Win32::System::Registry::{
    RegCloseKey, RegCreateKeyExW, RegSetValueExW, HKEY, HKEY_LOCAL_MACHINE, KEY_SET_VALUE,
    REG_MULTI_SZ, REG_OPTION_NON_VOLATILE,
};
use windows::Win32::System::Services::{
    ChangeServiceConfig2W, SC_ACTION, SC_ACTION_RESTART, SERVICE_CONFIG_FAILURE_ACTIONS,
    SERVICE_FAILURE_ACTIONSW,
};
use windows_service::service::{
    ServiceAccess, ServiceErrorControl, ServiceInfo, ServiceStartType, ServiceState, ServiceType,
};
use windows_service::service_manager::{ServiceManager, ServiceManagerAccess};
use windows_service::Error as ServiceError;

use crate::cli::{validate_name, CliError, ServiceInstallRequest};

/// 等服务停下来的上限。
const STOP_TIMEOUT: Duration = Duration::from_secs(15);
/// 等服务从 SCM 数据库里真正消失（被标记删除之后）的上限。
const CREATE_TIMEOUT: Duration = Duration::from_secs(15);
/// 服务启动后等它进入 RUNNING 的上限。
const START_TIMEOUT: Duration = Duration::from_secs(10);
const POLL_INTERVAL: Duration = Duration::from_millis(150);

/// `sc failure <name> reset= 86400 actions= restart/5000/restart/10000/restart/30000` 的等价配置。
const FAILURE_RESET_PERIOD_SECS: u32 = 86_400;
const FAILURE_ACTIONS: [SC_ACTION; 3] = [
    SC_ACTION {
        Type: SC_ACTION_RESTART,
        Delay: 5_000,
    },
    SC_ACTION {
        Type: SC_ACTION_RESTART,
        Delay: 10_000,
    },
    SC_ACTION {
        Type: SC_ACTION_RESTART,
        Delay: 30_000,
    },
];

/// 注册（或重装）服务：停掉旧服务并等它从 SCM 消失 → 建服务 → 写 `Environment` → 配恢复策略 → 启动。
///
/// 旧实现在一条 cmd 串里连着 `sc stop` / `sc delete` / `sc create`，删除是异步的，紧跟的
/// `sc create` 可能撞上 `ERROR_SERVICE_MARKED_FOR_DELETE`；这里改成等真的删掉再建。
pub fn install(request: &ServiceInstallRequest) -> Result<(), CliError> {
    validate_name("service name", &request.service_name)?;

    let start_type = match request.start_type.as_str() {
        "auto" => ServiceStartType::AutoStart,
        "demand" => ServiceStartType::OnDemand,
        other => {
            return Err(CliError::new(
                "INVALID_REQUEST",
                format!("unsupported startType: {other}"),
            ))
        }
    };

    let manager = ServiceManager::local_computer(
        None::<&str>,
        ServiceManagerAccess::CONNECT | ServiceManagerAccess::CREATE_SERVICE,
    )
    .map_err(|error| from_service_error("SERVICE_MANAGER_FAILED", error))?;

    stop_and_delete(&manager, &request.service_name)?;

    let info = ServiceInfo {
        name: OsString::from(&request.service_name),
        display_name: OsString::from(&request.service_name),
        service_type: ServiceType::OWN_PROCESS,
        start_type,
        error_control: ServiceErrorControl::Normal,
        // 注册的就是正在跑的这个 helper.exe：调用方启动的路径与它一致，由进程自己取路径
        // 比让调用方再传一个可能对不上的路径更稳。
        executable_path: current_executable()?,
        launch_arguments: Vec::new(),
        dependencies: Vec::new(),
        account_name: None,
        account_password: None,
    };

    let service = create_with_retry(&manager, &info)?;

    // 空列表表示「不要动现有 Environment」（服务是新装的，本就没有这个值）。
    if !request.environment.is_empty() {
        set_environment(&request.service_name, &request.environment)?;
    }

    set_recovery(&service)?;

    service
        .start(&[] as &[&OsStr])
        .map_err(|error| from_service_error("SERVICE_START_FAILED", error))?;

    wait_for_state(&service, ServiceState::Running, START_TIMEOUT)
}

/// 卸载服务：停掉并删除。服务本来就不存在时也算成功（幂等）。
pub fn uninstall(service_name: &str) -> Result<(), CliError> {
    validate_name("service name", service_name)?;

    let manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)
        .map_err(|error| from_service_error("SERVICE_MANAGER_FAILED", error))?;

    stop_and_delete(&manager, service_name)
}

fn stop_and_delete(manager: &ServiceManager, service_name: &str) -> Result<(), CliError> {
    let access = ServiceAccess::STOP | ServiceAccess::QUERY_STATUS | ServiceAccess::DELETE;
    let service = match manager.open_service(service_name, access) {
        Ok(service) => service,
        Err(error) if raw_os_error(&error) == Some(ERROR_SERVICE_DOES_NOT_EXIST) => return Ok(()),
        Err(error) => return Err(from_service_error("SERVICE_OPEN_FAILED", error)),
    };

    match service.query_status() {
        // 已经停下就不用再发停止指令。
        Ok(status) if status.current_state == ServiceState::Stopped => {}
        _ => match service.stop() {
            // 停止途中（ERROR_SERVICE_CANNOT_ACCEPT_CTRL）与已经停下
            // （ERROR_SERVICE_NOT_ACTIVE）都不是错误，继续等它到 Stopped。
            Ok(_) => {}
            Err(error)
                if matches!(
                    raw_os_error(&error),
                    Some(ERROR_SERVICE_NOT_ACTIVE) | Some(ERROR_SERVICE_CANNOT_ACCEPT_CTRL)
                ) => {}
            Err(error) => return Err(from_service_error("SERVICE_STOP_FAILED", error)),
        },
    }

    wait_for_state(&service, ServiceState::Stopped, STOP_TIMEOUT)?;

    service
        .delete()
        .map_err(|error| from_service_error("SERVICE_DELETE_FAILED", error))
}

/// 建服务。被标记删除的服务要等它真的消失才能复用同名，所以撞上这两个错误码时重试。
fn create_with_retry(
    manager: &ServiceManager,
    info: &ServiceInfo,
) -> Result<windows_service::service::Service, CliError> {
    let access = ServiceAccess::CHANGE_CONFIG | ServiceAccess::QUERY_STATUS | ServiceAccess::START;
    let deadline = Instant::now() + CREATE_TIMEOUT;

    loop {
        match manager.create_service(info, access) {
            Ok(service) => return Ok(service),
            Err(error)
                if matches!(
                    raw_os_error(&error),
                    Some(ERROR_SERVICE_MARKED_FOR_DELETE) | Some(ERROR_SERVICE_EXISTS)
                ) && Instant::now() < deadline =>
            {
                std::thread::sleep(POLL_INTERVAL);
            }
            Err(error) => return Err(from_service_error("SERVICE_CREATE_FAILED", error)),
        }
    }
}

fn wait_for_state(
    service: &windows_service::service::Service,
    target: ServiceState,
    timeout: Duration,
) -> Result<(), CliError> {
    let deadline = Instant::now() + timeout;

    loop {
        let status = service
            .query_status()
            .map_err(|error| from_service_error("SERVICE_QUERY_FAILED", error))?;

        if status.current_state == target {
            return Ok(());
        }

        if Instant::now() >= deadline {
            return Err(CliError::new(
                "SERVICE_STATE_TIMEOUT",
                format!(
                    "service did not reach {target:?} within {timeout:?} (state: {:?})",
                    status.current_state
                ),
            ));
        }

        std::thread::sleep(POLL_INTERVAL);
    }
}

/// 写服务 `Environment`（`REG_MULTI_SZ`）：helper 的鉴权 key 文件路径、服务名、管道名与
/// 管道 ACL 允许的 SID 都从这里进服务进程。
fn set_environment(service_name: &str, entries: &[String]) -> Result<(), CliError> {
    let subkey: Vec<u16> = format!("SYSTEM\\CurrentControlSet\\Services\\{service_name}")
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();

    let mut key = HKEY::default();

    unsafe {
        RegCreateKeyExW(
            HKEY_LOCAL_MACHINE,
            PCWSTR(subkey.as_ptr()),
            0,
            PCWSTR::null(),
            REG_OPTION_NON_VOLATILE,
            KEY_SET_VALUE,
            None,
            &mut key,
            None,
        )
        .map_err(|error| CliError::from_hresult("REGISTRY_OPEN_FAILED", &error))?;

        // REG_MULTI_SZ：每项以 NUL 结尾，整串再补一个 NUL 收尾。
        let bytes = encode_multi_sz(entries);
        let result = RegSetValueExW(key, w!("Environment"), 0, REG_MULTI_SZ, Some(&bytes));

        let _ = RegCloseKey(key);

        result.map_err(|error| CliError::from_hresult("REGISTRY_WRITE_FAILED", &error))?;
    }

    Ok(())
}

/// `REG_MULTI_SZ` 的数据布局：每项以 NUL 结尾，整串再补一个 NUL 收尾。
fn encode_multi_sz(entries: &[String]) -> Vec<u8> {
    let mut data: Vec<u16> = Vec::new();

    for entry in entries {
        data.extend(entry.encode_utf16());
        data.push(0);
    }
    data.push(0);

    data.iter().flat_map(|unit| unit.to_le_bytes()).collect()
}

/// 崩溃恢复策略。release 构建是 `panic = "abort"`，崩溃表现为「非正常退出」而不是
/// crash，要打开 `FAILURE_ACTIONS_FLAG` 恢复动作才会触发。
fn set_recovery(service: &windows_service::service::Service) -> Result<(), CliError> {
    let mut actions = FAILURE_ACTIONS;
    let mut failure_actions = SERVICE_FAILURE_ACTIONSW {
        dwResetPeriod: FAILURE_RESET_PERIOD_SECS,
        lpRebootMsg: PWSTR::null(),
        lpCommand: PWSTR::null(),
        cActions: actions.len() as u32,
        lpsaActions: actions.as_mut_ptr(),
    };

    unsafe {
        ChangeServiceConfig2W(
            SC_HANDLE(service.raw_handle()),
            SERVICE_CONFIG_FAILURE_ACTIONS,
            Some(&mut failure_actions as *mut _ as *const std::ffi::c_void),
        )
        .map_err(|error| CliError::from_hresult("SERVICE_RECOVERY_FAILED", &error))?;
    }

    service
        .set_failure_actions_on_non_crash_failures(true)
        .map_err(|error| from_service_error("SERVICE_RECOVERY_FAILED", error))
}

fn current_executable() -> Result<PathBuf, CliError> {
    let path =
        std::env::current_exe().map_err(|error| CliError::from_io("SELF_PATH_FAILED", &error))?;

    // 个别情况下拿到的是 `\\?\C:\…` 形式的 verbatim 路径，SCM 里存 binPath 要普通路径。
    let text = path.to_string_lossy();
    Ok(match text.strip_prefix(r"\\?\") {
        Some(stripped) => PathBuf::from(stripped),
        None => path,
    })
}

fn raw_os_error(error: &ServiceError) -> Option<i32> {
    match error {
        ServiceError::Winapi(io_error) => io_error.raw_os_error(),
        _ => None,
    }
}

fn from_service_error(code: &str, error: ServiceError) -> CliError {
    match error {
        ServiceError::Winapi(io_error) => CliError::from_io(code, &io_error),
        other => CliError::new(code, other.to_string()),
    }
}

const ERROR_SERVICE_DOES_NOT_EXIST: i32 = 1060;
const ERROR_SERVICE_NOT_ACTIVE: i32 = 1062;
const ERROR_SERVICE_CANNOT_ACCEPT_CTRL: i32 = 1061;
const ERROR_SERVICE_MARKED_FOR_DELETE: i32 = 1072;
const ERROR_SERVICE_EXISTS: i32 = 1073;

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(encoded: &[u8]) -> Vec<u16> {
        encoded
            .as_chunks::<2>()
            .0
            .iter()
            .map(|chunk| u16::from_le_bytes(*chunk))
            .collect()
    }

    /// 少一个收尾 NUL 会让 SCM 读到的最后一项带着垃圾，是这类编码最容易错的地方。
    #[test]
    fn terminates_every_entry_and_the_whole_multi_string() {
        let encoded = encode_multi_sz(&["A=1".to_string(), "B=2".to_string()]);

        assert_eq!(
            decode(&encoded),
            vec![0x41, 0x3D, 0x31, 0x00, 0x42, 0x3D, 0x32, 0x00, 0x00]
        );
    }

    #[test]
    fn keeps_non_ascii_entries_intact() {
        let entries = vec!["HELPER_AUTH_KEY_FILE=C:\\用户\\helper.key".to_string()];
        let encoded = encode_multi_sz(&entries);
        let units = decode(&encoded);

        assert_eq!(units.len(), entries[0].encode_utf16().count() + 2);
        assert_eq!(
            String::from_utf16(&units[..units.len() - 2]).unwrap(),
            entries[0]
        );
    }
}
