//! 只读查询（`helper.exe service query`）。
//!
//! 与 `ops::service` 的 install/stop 不同，查询不依赖 `windows-service` feature：
//! 用 `windows` crate 的 SCM / 注册表 API，以**当前用户**权限打开（与旧的
//! `sc query` / `sc qc` / `reg query` 权限面一致）。应用侧对这条路径禁止提权。

use serde::Serialize;
use windows::core::{w, PCWSTR};
use windows::Win32::Security::SC_HANDLE;
use windows::Win32::System::Registry::{
    RegCloseKey, RegOpenKeyExW, RegQueryValueExW, HKEY, HKEY_LOCAL_MACHINE, KEY_READ,
    REG_VALUE_TYPE,
};
use windows::Win32::System::Services::{
    CloseServiceHandle, OpenSCManagerW, OpenServiceW, QueryServiceConfigW, QueryServiceStatusEx,
    QUERY_SERVICE_CONFIGW, SC_MANAGER_CONNECT, SC_STATUS_PROCESS_INFO, SERVICE_QUERY_CONFIG,
    SERVICE_QUERY_STATUS, SERVICE_RUNNING, SERVICE_STATUS_PROCESS, SERVICE_STOPPED,
};

use crate::cli::{validate_name, CliError};

/// `ERROR_SERVICE_DOES_NOT_EXIST` 的 HRESULT 形式（`HRESULT_FROM_WIN32(1060)`）。
const HRESULT_SERVICE_DOES_NOT_EXIST: u32 = 0x8007_0424;

const ERROR_SERVICE_DOES_NOT_EXIST: u32 = 1060;

/// `service query` 成功时的 `data` 载荷。
#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ServiceQueryData {
    /// `missing` / `inactive` / `running`——与旧 `sc query` 的三分类一致。
    pub state: &'static str,
    /// `QueryServiceConfigW` 的 `lpBinaryPathName`；拿不到为 null。
    pub bin_path: Option<String>,
    /// 服务 `Environment` 里是否还留着旧版明文 `HELPER_AUTH_KEY=`。
    pub has_legacy_environment_key: bool,
    /// 状态码是否为 `SERVICE_STOPPED`。等待健康时用它把「停了」和「还在启动」分开。
    pub is_stopped: bool,
}

impl ServiceQueryData {
    fn missing() -> Self {
        Self {
            state: "missing",
            bin_path: None,
            has_legacy_environment_key: false,
            is_stopped: false,
        }
    }
}

/// 查询服务状态、binPath 与遗留明文 key 标志。服务不存在是合法结果（`state = missing`）。
pub fn query(service_name: &str) -> Result<ServiceQueryData, CliError> {
    validate_name("service name", service_name)?;

    let manager = unsafe {
        OpenSCManagerW(PCWSTR::null(), PCWSTR::null(), SC_MANAGER_CONNECT)
            .map_err(|error| CliError::from_hresult("SCM_OPEN_FAILED", &error))?
    };

    let result = open_and_inspect(manager, service_name);
    let _ = unsafe { CloseServiceHandle(manager) };
    result
}

fn open_and_inspect(manager: SC_HANDLE, service_name: &str) -> Result<ServiceQueryData, CliError> {
    let wide_name: Vec<u16> = service_name
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let access = SERVICE_QUERY_STATUS | SERVICE_QUERY_CONFIG;

    let service = unsafe {
        match OpenServiceW(manager, PCWSTR(wide_name.as_ptr()), access) {
            Ok(service) => service,
            Err(error) if is_service_does_not_exist(&error) => {
                return Ok(ServiceQueryData::missing());
            }
            Err(error) => {
                return Err(CliError::from_hresult("SERVICE_OPEN_FAILED", &error));
            }
        }
    };

    // state 最高优先级；binPath / 注册表子查询失败时置默认值，不把整次查询打成失败。
    let (state, is_stopped) = unsafe { query_state(service) }.unwrap_or(("inactive", false));
    let bin_path = unsafe { query_bin_path(service) }.unwrap_or(None);
    let _ = unsafe { CloseServiceHandle(service) };

    let has_legacy_environment_key = legacy_environment_key(service_name).unwrap_or(false);

    Ok(ServiceQueryData {
        state,
        bin_path,
        has_legacy_environment_key,
        is_stopped,
    })
}

fn is_service_does_not_exist(error: &windows::core::Error) -> bool {
    let hresult = error.code().0 as u32;
    hresult == HRESULT_SERVICE_DOES_NOT_EXIST || (hresult & 0xFFFF) == ERROR_SERVICE_DOES_NOT_EXIST
}

unsafe fn query_state(service: SC_HANDLE) -> Result<(&'static str, bool), CliError> {
    let mut needed = 0u32;
    let mut buffer = vec![0u8; std::mem::size_of::<SERVICE_STATUS_PROCESS>()];

    QueryServiceStatusEx(
        service,
        SC_STATUS_PROCESS_INFO,
        Some(&mut buffer),
        &mut needed,
    )
    .map_err(|error| CliError::from_hresult("SERVICE_QUERY_FAILED", &error))?;

    let status = &*(buffer.as_ptr() as *const SERVICE_STATUS_PROCESS);
    if status.dwCurrentState == SERVICE_RUNNING {
        Ok(("running", false))
    } else if status.dwCurrentState == SERVICE_STOPPED {
        Ok(("inactive", true))
    } else {
        Ok(("inactive", false))
    }
}

unsafe fn query_bin_path(service: SC_HANDLE) -> Result<Option<String>, CliError> {
    let mut needed = 0u32;
    // 先探缓冲大小：`QueryServiceConfigW` 在缓冲不足时返回所需字节数。
    let first = QueryServiceConfigW(service, None, 0, &mut needed);
    if needed == 0 {
        return Err(match first {
            Err(error) => CliError::from_hresult("SERVICE_CONFIG_QUERY_FAILED", &error),
            Ok(()) => CliError::new(
                "SERVICE_CONFIG_QUERY_FAILED",
                "QueryServiceConfigW reported zero bytes needed",
            ),
        });
    }

    let mut buffer = vec![0u8; needed as usize];
    QueryServiceConfigW(
        service,
        Some(buffer.as_mut_ptr() as *mut QUERY_SERVICE_CONFIGW),
        needed,
        &mut needed,
    )
    .map_err(|error| CliError::from_hresult("SERVICE_CONFIG_QUERY_FAILED", &error))?;

    let config = &*(buffer.as_ptr() as *const QUERY_SERVICE_CONFIGW);
    if config.lpBinaryPathName.is_null() {
        return Ok(None);
    }
    // PWSTR::to_string 在带内嵌 NUL 或非法 UTF-16 时失败；这里按 UTF-16 解码后取到
    // 首个 NUL 为止即可（binPath 本身不含 NUL）。
    let words = config.lpBinaryPathName;
    let mut len = 0usize;
    while *words.0.add(len) != 0 {
        len += 1;
    }
    let slice = std::slice::from_raw_parts(words.0, len);
    Ok(Some(String::from_utf16_lossy(slice).trim().to_string()))
}

/// 读 `HKLM\SYSTEM\CurrentControlSet\Services\<name>` 的 `Environment`（`REG_MULTI_SZ`）。
///
/// 值本身是 UTF-16LE，不能按 UTF-8 直接扫原始字节。解码成 UTF-8 文本后按子串找
/// `HELPER_AUTH_KEY=`——该前缀是纯 ASCII，非 ASCII 路径不会影响判定；与旧 Dart 侧
/// `reg query … stdoutEncoding: latin1` + `contains('HELPER_AUTH_KEY=')` 语义一致。
fn legacy_environment_key(service_name: &str) -> Result<bool, CliError> {
    let subkey: Vec<u16> = format!("SYSTEM\\CurrentControlSet\\Services\\{service_name}")
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();

    let mut key = HKEY::default();

    unsafe {
        RegOpenKeyExW(
            HKEY_LOCAL_MACHINE,
            PCWSTR(subkey.as_ptr()),
            0,
            KEY_READ,
            &mut key,
        )
        .map_err(|error| CliError::from_hresult("REGISTRY_OPEN_FAILED", &error))?;

        let result = (|| {
            let mut kind = REG_VALUE_TYPE::default();
            let mut size = 0u32;
            RegQueryValueExW(
                key,
                w!("Environment"),
                None,
                Some(&mut kind),
                None,
                Some(&mut size),
            )
            .map_err(|error| CliError::from_hresult("REGISTRY_QUERY_FAILED", &error))?;

            if size == 0 {
                return Ok(false);
            }

            let mut data = vec![0u8; size as usize];
            RegQueryValueExW(
                key,
                w!("Environment"),
                None,
                Some(&mut kind),
                Some(data.as_mut_ptr()),
                Some(&mut size),
            )
            .map_err(|error| CliError::from_hresult("REGISTRY_QUERY_FAILED", &error))?;

            Ok(environment_has_legacy_auth_key(&data))
        })();

        let _ = RegCloseKey(key);
        result
    }
}

/// 把 `REG_MULTI_SZ` 的 UTF-16LE 字节解成文本，再找 `HELPER_AUTH_KEY=`。
fn environment_has_legacy_auth_key(data: &[u8]) -> bool {
    let units: Vec<u16> = data
        .as_chunks::<2>()
        .0
        .iter()
        .map(|chunk| u16::from_le_bytes(*chunk))
        .collect();
    let text = String::from_utf16_lossy(&units);
    text.contains("HELPER_AUTH_KEY=")
}

// `OpenSCManagerW` 在 0.52 里返回 `SC_HANDLE`，其内部就是 HANDLE 包装；
// 这里不额外转换，直接把 SC_HANDLE 当句柄用。

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_names_that_cannot_go_into_a_registry_path() {
        assert!(query(" ").is_err());
        assert!(query("a\\b").is_err());
        assert!(query("a\nb").is_err());
    }

    fn multi_sz(entries: &[&str]) -> Vec<u8> {
        let mut units: Vec<u16> = Vec::new();
        for entry in entries {
            units.extend(entry.encode_utf16());
            units.push(0);
        }
        units.push(0);
        units.iter().flat_map(|unit| unit.to_le_bytes()).collect()
    }

    #[test]
    fn finds_legacy_auth_key_in_reg_multi_sz() {
        let data = multi_sz(&[
            "HELPER_AUTH_KEY=abc123",
            "HELPER_SERVICE_NAME=BettboxHelperService",
        ]);
        assert!(environment_has_legacy_auth_key(&data));
    }

    #[test]
    fn key_file_variable_does_not_count_as_legacy_plaintext() {
        let data = multi_sz(&[
            "HELPER_AUTH_KEY_FILE=C:\\Users\\x\\helper.key",
            "HELPER_SERVICE_NAME=BettboxHelperService",
        ]);
        assert!(!environment_has_legacy_auth_key(&data));
    }

    #[test]
    fn empty_or_missing_value_is_not_legacy() {
        assert!(!environment_has_legacy_auth_key(b""));
        assert!(!environment_has_legacy_auth_key(&multi_sz(&["A=1"])));
    }
}
