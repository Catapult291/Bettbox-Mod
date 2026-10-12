//! Windows 系统代理（WinINet 的 per-connection 设置）的读取、启用与还原。
//!
//! 取代原先的 Flutter 插件 `plugins/proxy`（`proxy_plugin.cpp`）：这块逻辑并入
//! `bettbox_native`，Windows 之外的平台导出同名入口但一律返回「不支持」。
//!
//! 与旧插件的三处有意差别：
//!   1. 启用前先抓一份快照（LAN 连接 + 所有 RAS 拨号项），由调用方持久化；
//!   2. 还原时只动**仍是我们写下的那一份**（服务器串等于 `applied`），用户或别的
//!      程序在这期间改过的连接不碰——旧实现停止时无差别把 `ProxyEnable` 置 0，
//!      会连带清掉其他程序设置的系统代理；
//!   3. 崩溃/强杀后留下的设置由下次启动用持久化的快照还原（见 Dart 侧
//!      `lib/common/system_proxy.dart`），旧实现只能等下次启动无差别清掉。
//!
//! 另有两条针对「没有快照」场景的补路径：
//!   - 升级过渡期 / 偏好丢失导致快照缺失时，`claim_residual` 认领
//!     「服务器串正是本应用会写的 `127.0.0.1:<port>`、显式代理开着、且该端口
//!     已经没人监听」的残留——端口还活着的（别的代理客户端占着 7890 之类）不碰，
//!     避免把 §108 修掉的「清掉别人的代理」又引回来；
//!   - 应用进程被强杀后的残留由同目录的 `BettboxProxyGuard` 看门狗在进程死后
//!     按同一份快照还原（它与本库同源编译，语义完全一致）。

use serde::{Deserialize, Serialize};

/// 快照格式版本；字段变动时递增，旧版本快照按「无法还原」处理。
pub const SNAPSHOT_VERSION: u32 = 1;

/// 本应用写下的 flags：`PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY`。
pub const APPLIED_FLAGS: u32 = 0x1 | 0x2;

/// `PROXY_TYPE_PROXY`，用于判断某个连接是否仍是本应用设置的。
const PROXY_TYPE_PROXY: u32 = 0x2;

/// 单个连接的代理设置快照。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnectionSnapshot {
    /// 连接名；`None` 表示 LAN 连接（`pszConnection = NULL`）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// `INTERNET_PER_CONN_FLAGS` 的原始位掩码。
    pub flags: u32,
    /// `INTERNET_PER_CONN_PROXY_SERVER`。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server: Option<String>,
    /// `INTERNET_PER_CONN_PROXY_BYPASS`。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bypass: Option<String>,
    /// `INTERNET_PER_CONN_AUTOCONFIG_URL`。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub autoconfig_url: Option<String>,
}

/// 一份完整的系统代理快照。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProxySnapshot {
    pub version: u32,
    /// 本应用写下的代理服务器串（`127.0.0.1:<port>`）。`query` 出来的快照是 `None`，
    /// `enable` 返回的快照会带上它，还原时靠它判断连接是否仍归我们管。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub applied: Option<String>,
    pub connections: Vec<ConnectionSnapshot>,
}

impl ProxySnapshot {
    pub fn to_json(&self) -> Result<String, String> {
        serde_json::to_string(self).map_err(|error| format!("序列化系统代理快照失败：{error}"))
    }

    pub fn from_json(raw: &str) -> Result<Self, String> {
        let snapshot: Self =
            serde_json::from_str(raw).map_err(|error| format!("解析系统代理快照失败：{error}"))?;
        if snapshot.version != SNAPSHOT_VERSION {
            return Err(format!(
                "系统代理快照版本不支持：{}（当前 {SNAPSHOT_VERSION}）",
                snapshot.version
            ));
        }
        Ok(snapshot)
    }
}

/// 还原结果：只还原仍是我们写下的连接，其余跳过并记原因。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct RestoreReport {
    pub restored: usize,
    pub skipped: usize,
    pub warnings: Vec<String>,
}

/// 认领残留的结果。`listening` 为 true 表示端口上有监听者、按保守策略整轮未动。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct ClaimReport {
    /// 本次把 `ProxyEnable` 关掉的连接数。
    pub claimed: usize,
    /// 认领前探测到 `127.0.0.1:<port>` 有人监听（此时不碰注册表）。
    pub listening: bool,
    pub warnings: Vec<String>,
}

/// 由绕过域名列表拼出 `INTERNET_PER_CONN_PROXY_BYPASS` 的值。
///
/// 与旧插件一致：固定以 `<local>` 开头，其后逐个追加；空项被跳过（旧实现会留下
/// 一个空段）。
pub fn build_bypass(domains: &[String]) -> String {
    let mut parts = vec!["<local>".to_string()];
    parts.extend(domains.iter().filter(|domain| !domain.is_empty()).cloned());
    parts.join(";")
}

/// 读取当前所有连接（LAN + RAS 拨号项）的代理设置。
pub fn query() -> Result<ProxySnapshot, String> {
    platform::query_snapshot()
}

/// 启用指向 `127.0.0.1:<port>` 的系统代理，返回**启用前**的快照（已带上 `applied`）
/// 与逐连接的非致命失败。
pub fn enable(port: u16, bypass: &[String]) -> Result<(ProxySnapshot, Vec<String>), String> {
    platform::enable(port, &build_bypass(bypass))
}

/// 按快照还原：只还原仍是我们写下的连接。
pub fn restore(snapshot: &ProxySnapshot) -> Result<RestoreReport, String> {
    platform::restore(snapshot)
}

/// 当前设置是否仍是本应用写下的那一份（服务器串一致且开着显式代理）。
pub(crate) fn is_ours(current: &ConnectionSnapshot, applied: &str) -> bool {
    current.server.as_deref() == Some(applied) && current.flags & PROXY_TYPE_PROXY != 0
}

/// 认领没有快照可还原的残留：把「指向本应用端口且端口已死」的连接关掉。
///
/// 判定复用 [`is_ours`]（服务器串必须正好是本应用 `enable` 会写的
/// `127.0.0.1:<port>`，所以别的程序的 `localhost:7890` 之类不算——§113 验证过
/// 要原样不动）。端口上有监听者时整轮跳过：那多半是别的代理客户端占着同一
/// 端口，按 §108 的结论不能碰。没有匹配的连接时是纯 no-op（正常启动的多数情形）。
pub fn claim_residual(port: u16) -> Result<ClaimReport, String> {
    platform::claim_residual(port)
}

#[cfg(windows)]
mod platform {
    use super::{
        ConnectionSnapshot, ProxySnapshot, RestoreReport, APPLIED_FLAGS, SNAPSHOT_VERSION,
    };
    use windows::core::{PCWSTR, PWSTR};
    use windows::Win32::Foundation::{GlobalFree, ERROR_SUCCESS, HGLOBAL};
    use windows::Win32::NetworkManagement::Rras::{
        RasEnumEntriesW, ERROR_BUFFER_TOO_SMALL, RASENTRYNAMEW,
    };
    use windows::Win32::Networking::WinInet::{
        InternetQueryOptionW, InternetSetOptionW, INTERNET_OPTION_PER_CONNECTION_OPTION,
        INTERNET_OPTION_REFRESH, INTERNET_OPTION_SETTINGS_CHANGED,
        INTERNET_PER_CONN_AUTOCONFIG_URL, INTERNET_PER_CONN_FLAGS, INTERNET_PER_CONN_OPTIONW,
        INTERNET_PER_CONN_OPTIONW_0, INTERNET_PER_CONN_OPTION_LISTW,
        INTERNET_PER_CONN_PROXY_BYPASS, INTERNET_PER_CONN_PROXY_SERVER,
    };

    /// 查询与设置都用到的选项个数：flags / server / bypass / autoconfig url。
    const OPTION_COUNT: usize = 4;

    /// 空的 C 串，用于把「本来没有这项设置」还原成空值。
    const EMPTY: &str = "";

    fn wide(value: &str) -> Vec<u16> {
        value.encode_utf16().chain(std::iter::once(0)).collect()
    }

    fn connection_ptr(wide_name: &Option<Vec<u16>>) -> PWSTR {
        match wide_name {
            Some(buffer) => PWSTR(buffer.as_ptr() as *mut u16),
            None => PWSTR(std::ptr::null_mut()),
        }
    }

    /// 取出 `pszValue` 指向的字符串并释放它（查询时由 API 用 `GlobalAlloc` 分配）。
    unsafe fn take_string(value: &mut INTERNET_PER_CONN_OPTIONW_0) -> Option<String> {
        let ptr = unsafe { value.pszValue };
        if ptr.is_null() {
            return None;
        }
        let text = unsafe { ptr.to_string() }.ok();
        unsafe {
            let _ = GlobalFree(HGLOBAL(ptr.0.cast()));
        }
        text.filter(|text| !text.is_empty())
    }

    fn query_connection(name: Option<&str>) -> Result<ConnectionSnapshot, String> {
        let wide_name = name.map(wide);
        let mut options: [INTERNET_PER_CONN_OPTIONW; OPTION_COUNT] = unsafe { std::mem::zeroed() };
        options[0].dwOption = INTERNET_PER_CONN_FLAGS;
        options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
        options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
        options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;

        let mut list = INTERNET_PER_CONN_OPTION_LISTW {
            dwSize: std::mem::size_of::<INTERNET_PER_CONN_OPTION_LISTW>() as u32,
            pszConnection: connection_ptr(&wide_name),
            dwOptionCount: OPTION_COUNT as u32,
            dwOptionError: 0,
            pOptions: options.as_mut_ptr(),
        };
        let mut size = std::mem::size_of::<INTERNET_PER_CONN_OPTION_LISTW>() as u32;
        let queried = unsafe {
            InternetQueryOptionW(
                None,
                INTERNET_OPTION_PER_CONNECTION_OPTION,
                Some((&mut list as *mut INTERNET_PER_CONN_OPTION_LISTW).cast()),
                &mut size,
            )
        };
        if let Err(error) = queried {
            return Err(format!(
                "InternetQueryOptionW 失败（{error}，{}，optionError {}）",
                std::io::Error::last_os_error(),
                list.dwOptionError
            ));
        }

        let flags = unsafe { options[0].Value.dwValue };
        let server = unsafe { take_string(&mut options[1].Value) };
        let bypass = unsafe { take_string(&mut options[2].Value) };
        let autoconfig_url = unsafe { take_string(&mut options[3].Value) };
        Ok(ConnectionSnapshot {
            name: name.map(str::to_string),
            flags,
            server,
            bypass,
            autoconfig_url,
        })
    }

    fn set_connection(
        name: Option<&str>,
        flags: u32,
        server: &str,
        bypass: &str,
        autoconfig_url: &str,
    ) -> Result<(), String> {
        let wide_name = name.map(wide);
        let wide_server = wide(server);
        let wide_bypass = wide(bypass);
        let wide_autoconfig = wide(autoconfig_url);

        let mut options: [INTERNET_PER_CONN_OPTIONW; OPTION_COUNT] = unsafe { std::mem::zeroed() };
        options[0].dwOption = INTERNET_PER_CONN_FLAGS;
        options[0].Value = INTERNET_PER_CONN_OPTIONW_0 { dwValue: flags };
        options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
        options[1].Value = INTERNET_PER_CONN_OPTIONW_0 {
            pszValue: PWSTR(wide_server.as_ptr() as *mut u16),
        };
        options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
        options[2].Value = INTERNET_PER_CONN_OPTIONW_0 {
            pszValue: PWSTR(wide_bypass.as_ptr() as *mut u16),
        };
        options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
        options[3].Value = INTERNET_PER_CONN_OPTIONW_0 {
            pszValue: PWSTR(wide_autoconfig.as_ptr() as *mut u16),
        };

        let mut list = INTERNET_PER_CONN_OPTION_LISTW {
            dwSize: std::mem::size_of::<INTERNET_PER_CONN_OPTION_LISTW>() as u32,
            pszConnection: connection_ptr(&wide_name),
            dwOptionCount: OPTION_COUNT as u32,
            dwOptionError: 0,
            pOptions: options.as_mut_ptr(),
        };
        // 官方文档给的缓冲区大小是「结构体 + 选项数组」，与旧插件传的
        // sizeof(结构体) 不同；这里按文档给足。
        let size = (std::mem::size_of::<INTERNET_PER_CONN_OPTION_LISTW>()
            + (OPTION_COUNT - 1) * std::mem::size_of::<INTERNET_PER_CONN_OPTIONW>())
            as u32;
        let ok = unsafe {
            InternetSetOptionW(
                None,
                INTERNET_OPTION_PER_CONNECTION_OPTION,
                Some((&mut list as *mut INTERNET_PER_CONN_OPTION_LISTW).cast()),
                size,
            )
        };
        if let Err(error) = ok {
            return Err(format!(
                "InternetSetOptionW 失败（{error}，{}）",
                std::io::Error::last_os_error()
            ));
        }
        Ok(())
    }

    /// 让已改动的设置在系统里生效（旧插件同样在最后做这两步）。
    fn refresh() {
        unsafe {
            let _ = InternetSetOptionW(None, INTERNET_OPTION_SETTINGS_CHANGED, None, 0);
            let _ = InternetSetOptionW(None, INTERNET_OPTION_REFRESH, None, 0);
        }
    }

    /// 所有 RAS 拨号项的名字。枚举失败（例如本机没有任何拨号项）返回空表。
    fn ras_entry_names() -> Vec<String> {
        let mut size = 0u32;
        let mut count = 0u32;
        let ret =
            unsafe { RasEnumEntriesW(PCWSTR::null(), PCWSTR::null(), None, &mut size, &mut count) };
        if count == 0 || (ret != ERROR_BUFFER_TOO_SMALL && ret != ERROR_SUCCESS.0) {
            return Vec::new();
        }

        let mut entries: Vec<RASENTRYNAMEW> = vec![unsafe { std::mem::zeroed() }; count as usize];
        for entry in entries.iter_mut() {
            entry.dwSize = std::mem::size_of::<RASENTRYNAMEW>() as u32;
        }
        size = std::mem::size_of::<RASENTRYNAMEW>() as u32 * count;
        let ret = unsafe {
            RasEnumEntriesW(
                PCWSTR::null(),
                PCWSTR::null(),
                Some(entries.as_mut_ptr()),
                &mut size,
                &mut count,
            )
        };
        if ret != ERROR_SUCCESS.0 {
            return Vec::new();
        }

        entries
            .iter()
            .take(count as usize)
            .map(|entry| {
                let name = &entry.szEntryName;
                let len = name.iter().position(|&c| c == 0).unwrap_or(name.len());
                String::from_utf16_lossy(&name[..len])
            })
            .filter(|name| !name.is_empty())
            .collect()
    }

    pub(super) fn query_snapshot() -> Result<ProxySnapshot, String> {
        let mut connections = vec![query_connection(None)?];
        for name in ras_entry_names() {
            if let Ok(snapshot) = query_connection(Some(&name)) {
                connections.push(snapshot);
            }
        }
        Ok(ProxySnapshot {
            version: SNAPSHOT_VERSION,
            applied: None,
            connections,
        })
    }

    pub(super) fn enable(port: u16, bypass: &str) -> Result<(ProxySnapshot, Vec<String>), String> {
        let mut snapshot = query_snapshot()?;
        let server = format!("127.0.0.1:{port}");
        let mut warnings = Vec::new();
        let mut lan_done = false;

        for connection in &snapshot.connections {
            let label = connection.name.clone().unwrap_or_else(|| "LAN".to_string());
            match set_connection(
                connection.name.as_deref(),
                APPLIED_FLAGS,
                &server,
                bypass,
                EMPTY,
            ) {
                Ok(()) => {
                    if connection.name.is_none() {
                        lan_done = true;
                    }
                }
                Err(error) => warnings.push(format!("{label}: {error}")),
            }
        }
        if !lan_done {
            return Err(format!(
                "设置 LAN 连接的系统代理失败：{}",
                warnings.join("; ")
            ));
        }

        refresh();
        snapshot.applied = Some(server);
        Ok((snapshot, warnings))
    }

    pub(super) fn restore(snapshot: &ProxySnapshot) -> Result<RestoreReport, String> {
        let Some(applied) = snapshot.applied.as_deref() else {
            return Err("快照里没有 applied，无法判断哪些连接归本应用管".to_string());
        };

        let mut report = RestoreReport::default();
        for connection in &snapshot.connections {
            let label = connection.name.clone().unwrap_or_else(|| "LAN".to_string());
            let current = match query_connection(connection.name.as_deref()) {
                Ok(current) => current,
                Err(error) => {
                    report.skipped += 1;
                    report.warnings.push(format!("{label}: {error}"));
                    continue;
                }
            };
            if !super::is_ours(&current, applied) {
                // 期间被用户或别的程序改过，不覆盖。
                report.skipped += 1;
                continue;
            }
            match set_connection(
                connection.name.as_deref(),
                connection.flags,
                connection.server.as_deref().unwrap_or(EMPTY),
                connection.bypass.as_deref().unwrap_or(EMPTY),
                connection.autoconfig_url.as_deref().unwrap_or(EMPTY),
            ) {
                Ok(()) => report.restored += 1,
                Err(error) => {
                    report.skipped += 1;
                    report.warnings.push(format!("{label}: {error}"));
                }
            }
        }

        if report.restored > 0 {
            refresh();
        }
        Ok(report)
    }

    /// 本机回环上该端口是否有监听者。连接得上就算活着（250ms 上限）。
    pub(super) fn probe_listening(port: u16) -> bool {
        use std::net::{Ipv4Addr, SocketAddr, TcpStream};
        use std::time::Duration;
        let address = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
        TcpStream::connect_timeout(&address, Duration::from_millis(250)).is_ok()
    }

    pub(super) fn claim_residual(port: u16) -> Result<super::ClaimReport, String> {
        let snapshot = query_snapshot()?;
        let our_server = format!("127.0.0.1:{port}");
        if !snapshot
            .connections
            .iter()
            .any(|connection| super::is_ours(connection, &our_server))
        {
            // 没有指向本应用端口的残留：连端口探测都不用做（启动时的常态）。
            return Ok(super::ClaimReport::default());
        }
        if probe_listening(port) {
            return Ok(super::ClaimReport {
                claimed: 0,
                listening: true,
                warnings: Vec::new(),
            });
        }

        let mut report = super::ClaimReport::default();
        for connection in &snapshot.connections {
            if !super::is_ours(connection, &our_server) {
                continue;
            }
            let label = connection.name.clone().unwrap_or_else(|| "LAN".to_string());
            match set_connection(
                connection.name.as_deref(),
                connection.flags & !super::PROXY_TYPE_PROXY,
                connection.server.as_deref().unwrap_or(EMPTY),
                connection.bypass.as_deref().unwrap_or(EMPTY),
                connection.autoconfig_url.as_deref().unwrap_or(EMPTY),
            ) {
                Ok(()) => report.claimed += 1,
                Err(error) => report.warnings.push(format!("{label}: {error}")),
            }
        }
        if report.claimed > 0 {
            refresh();
        }
        Ok(report)
    }
}

#[cfg(not(windows))]
mod platform {
    use super::{ProxySnapshot, RestoreReport};

    const UNSUPPORTED: &str = "系统代理只在 Windows 上支持";

    pub(super) fn query_snapshot() -> Result<ProxySnapshot, String> {
        Err(UNSUPPORTED.to_string())
    }

    pub(super) fn enable(
        _port: u16,
        _bypass: &str,
    ) -> Result<(ProxySnapshot, Vec<String>), String> {
        Err(UNSUPPORTED.to_string())
    }

    pub(super) fn restore(_snapshot: &ProxySnapshot) -> Result<RestoreReport, String> {
        Err(UNSUPPORTED.to_string())
    }

    pub(super) fn claim_residual(_port: u16) -> Result<super::ClaimReport, String> {
        Err(UNSUPPORTED.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bypass_starts_with_local_and_skips_empty_entries() {
        assert_eq!(build_bypass(&[]), "<local>");
        assert_eq!(
            build_bypass(&["localhost".to_string(), String::new(), "127.*".to_string()]),
            "<local>;localhost;127.*"
        );
    }

    #[test]
    fn snapshot_round_trips_through_json() {
        let snapshot = ProxySnapshot {
            version: SNAPSHOT_VERSION,
            applied: Some("127.0.0.1:7890".to_string()),
            connections: vec![
                ConnectionSnapshot {
                    name: None,
                    flags: APPLIED_FLAGS,
                    server: Some("127.0.0.1:7890".to_string()),
                    bypass: Some("<local>".to_string()),
                    autoconfig_url: None,
                },
                ConnectionSnapshot {
                    name: Some("VPN".to_string()),
                    flags: 0x1,
                    server: None,
                    bypass: None,
                    autoconfig_url: Some("http://example.com/pac".to_string()),
                },
            ],
        };

        let json = snapshot.to_json().expect("serialize");
        assert!(!json.contains("autoconfig_url\":null"), "{json}");
        assert_eq!(ProxySnapshot::from_json(&json).expect("parse"), snapshot);
    }

    #[test]
    fn from_json_rejects_bad_input_and_unknown_version() {
        assert!(ProxySnapshot::from_json("not json").is_err());
        assert!(ProxySnapshot::from_json("{\"version\":99,\"connections\":[]}").is_err());
    }

    #[test]
    fn is_ours_requires_our_server_and_explicit_proxy() {
        let ours = ConnectionSnapshot {
            name: None,
            flags: APPLIED_FLAGS,
            server: Some("127.0.0.1:7890".to_string()),
            bypass: None,
            autoconfig_url: None,
        };
        assert!(is_ours(&ours, "127.0.0.1:7890"));

        let other_server = ConnectionSnapshot {
            server: Some("127.0.0.1:1080".to_string()),
            ..ours.clone()
        };
        assert!(!is_ours(&other_server, "127.0.0.1:7890"));

        let other_form = ConnectionSnapshot {
            server: Some("localhost:7890".to_string()),
            ..ours.clone()
        };
        assert!(!is_ours(&other_form, "127.0.0.1:7890"));

        let direct_only = ConnectionSnapshot {
            flags: 0x1,
            ..ours.clone()
        };
        assert!(!is_ours(&direct_only, "127.0.0.1:7890"));
    }

    /// 端口存活探测：绑着的端口算活着，释放后算死的。
    #[cfg(windows)]
    #[test]
    fn probe_listening_tracks_bind_and_drop() {
        use std::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().expect("addr").port();
        assert!(super::platform::probe_listening(port));
        drop(listener);
        assert!(!super::platform::probe_listening(port));
    }

    /// 会改动本机系统代理的 `#[ignore]` 用例共用的互斥：cargo 默认并行跑测试，
    /// 两条机器用例同时执行会互相覆盖对方写下的残留与快照（实测 during 快照被
    /// 另一条的 restore 冲回基线），必须串行。
    #[cfg(windows)]
    static MACHINE_PROXY_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[cfg(windows)]
    fn lock_machine_proxy() -> std::sync::MutexGuard<'static, ()> {
        MACHINE_PROXY_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// 只在手工验证时跑（会真的改动本机系统代理，跑完逐项还原）：
    /// `cargo test -p bettbox-native --lib system_proxy -- --ignored --nocapture`
    ///
    /// 覆盖认领的两条分支：端口活着整轮跳过、端口死了才关 `ProxyEnable`。
    /// 断言失败也会把注册表还原（清理放在 catch_unwind 之后），不留残留。
    #[cfg(windows)]
    #[test]
    #[ignore = "会改动本机系统代理设置"]
    fn claim_residual_round_trips_on_this_machine() {
        use std::net::TcpListener;
        use std::panic::{catch_unwind, AssertUnwindSafe};
        const DEAD_PORT: u16 = 7991;
        let our_server = format!("127.0.0.1:{DEAD_PORT}");
        let _machine = lock_machine_proxy();

        let before = query().expect("query");
        let (residual, warnings) = enable(DEAD_PORT, &[]).expect("enable");
        assert!(warnings.is_empty(), "{warnings:?}");
        assert!(!super::platform::probe_listening(DEAD_PORT));

        let outcome = catch_unwind(AssertUnwindSafe(|| {
            let during = query().expect("query during");

            // 1) 端口被占住（装作别的代理客户端活着）：整轮跳过，注册表不动。
            let listener = TcpListener::bind(("127.0.0.1", DEAD_PORT)).expect("bind");
            let report = claim_residual(DEAD_PORT).expect("claim while listening");
            assert_eq!(report.claimed, 0, "{report:?}");
            assert!(report.listening, "{report:?}");
            assert_eq!(query().expect("query live"), during);
            drop(listener);

            // 2) 端口已死：所有指向该端口的连接都被认领（ProxyEnable 关掉、服务器串保留）。
            let report = claim_residual(DEAD_PORT).expect("claim dead");
            assert!(!report.listening, "{report:?}");
            assert_eq!(report.claimed, residual.connections.len(), "{report:?}");
            let after_claim = query().expect("query claimed");
            for connection in &after_claim.connections {
                assert_eq!(connection.flags & PROXY_TYPE_PROXY, 0, "{connection:?}");
            }
        }));

        // 清理：把注册表逐项还原成开跑前的样子。认领把 flags 关掉后
        // restore 会因「不再是我们写的」跳过，所以先重新 enable 放行归属判定。
        let current = query().expect("query cleanup");
        let lan = current
            .connections
            .iter()
            .find(|connection| connection.name.is_none())
            .expect("LAN");
        if !super::is_ours(lan, &our_server) {
            let _ = enable(DEAD_PORT, &[]);
        }
        let report = restore(&residual).expect("restore");
        assert_eq!(report.restored, residual.connections.len(), "{report:?}");
        assert_eq!(query().expect("query restored"), before);

        if let Err(payload) = outcome {
            std::panic::resume_unwind(payload);
        }
    }

    /// 只读：查询结果必须与注册表里的 LAN 代理值一致（`ProxyEnable` /
    /// `ProxyServer` 就是 LAN 连接的这两项）。
    #[cfg(windows)]
    #[test]
    fn query_matches_registry_for_lan_connection() {
        let snapshot = query().expect("query");
        let lan = snapshot
            .connections
            .iter()
            .find(|connection| connection.name.is_none())
            .expect("LAN 连接必须在快照里");

        let enabled = registry_value("ProxyEnable").map(|value| value != "0x0");
        match enabled {
            Some(enabled) => assert_eq!(lan.flags & PROXY_TYPE_PROXY != 0, enabled),
            // 该值不存在时只断言「开着显式代理就必须有服务器串」。
            None => {
                if lan.flags & PROXY_TYPE_PROXY != 0 {
                    assert!(lan.server.is_some());
                }
            }
        }

        if let Some(server) = registry_value("ProxyServer") {
            assert_eq!(lan.server.as_deref(), Some(server.as_str()));
        }
        if let Some(bypass) = registry_value("ProxyOverride") {
            assert_eq!(lan.bypass.as_deref(), Some(bypass.as_str()));
        }
        if let Some(url) = registry_value("AutoConfigURL") {
            assert_eq!(lan.autoconfig_url.as_deref(), Some(url.as_str()));
        }
    }

    /// 只在手工验证时跑（会真的改动本机系统代理，跑完还原）：
    /// `cargo test -p bettbox-native --lib system_proxy -- --ignored --nocapture`
    #[cfg(windows)]
    #[test]
    #[ignore = "会改动本机系统代理设置"]
    fn enable_then_restore_round_trips_on_this_machine() {
        let _machine = lock_machine_proxy();
        let before = query().expect("query");
        let (snapshot, warnings) = enable(7890, &[]).expect("enable");
        assert_eq!(snapshot.applied.as_deref(), Some("127.0.0.1:7890"));
        assert!(warnings.is_empty(), "{warnings:?}");

        let during = query().expect("query");
        let lan = during
            .connections
            .iter()
            .find(|c| c.name.is_none())
            .unwrap();
        assert!(is_ours(lan, "127.0.0.1:7890"), "{lan:?}");

        let report = restore(&snapshot).expect("restore");
        assert_eq!(report.restored, snapshot.connections.len());

        let after = query().expect("query");
        assert_eq!(after.connections, before.connections);
    }

    /// 读 `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings` 下的值。
    #[cfg(windows)]
    fn registry_value(name: &str) -> Option<String> {
        let output = std::process::Command::new("reg")
            .args([
                "query",
                r"HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings",
                "/v",
                name,
            ])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let text = String::from_utf8_lossy(&output.stdout);
        text.lines()
            .find(|line| line.contains(name))
            .and_then(|line| line.split_whitespace().last())
            .map(str::to_string)
    }
}
