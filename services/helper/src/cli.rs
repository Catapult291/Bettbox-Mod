//! helper.exe 的命令行入口。
//!
//! 应用侧（`lib/common/system.dart`）不再自己拼 `sc` / `reg` / `schtasks` 命令串，
//! 而是把参数写成一份请求 JSON，以一次 `runas` 提权调用这里的子命令：
//!
//! ```text
//! helper.exe service install   <request.json> <result.json>
//! helper.exe service uninstall <request.json> <result.json>
//! helper.exe task register     <request.json> <result.json>
//! helper.exe task unregister   <request.json> <result.json>
//! ```
//!
//! 参数走文件而不是命令行，是为了绕开 Windows 命令行的引号/转义与代码页问题：路径可以
//! 带空格和非 ASCII 字符，环境变量值里还有 `;`、`=` 之类的字符。
//!
//! `ShellExecuteW(runas)` 拿不到子进程的 stdout，所以结果写进 `<result.json>`：
//! `{"ok":bool,"command":str,"code":str|null,"message":str|null,"osError":u32|null}`；
//! 退出码只作为兜底（见 [`EXIT_OK`] 等常量）。请求文件读不出来时也会写结果文件，应用侧
//! 因此总能看到一条结构化的失败原因。

use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// 命令执行成功。
pub const EXIT_OK: i32 = 0;
/// 命令执行失败（结果文件已写出）。
pub const EXIT_FAILED: i32 = 1;
/// 参数用法错误（没有结果文件可写）。
pub const EXIT_USAGE: i32 = 2;
/// 请求文件不可用（结果文件已写出）。
pub const EXIT_REQUEST: i32 = 3;

const USAGE: &str = "usage: helper.exe <service install|service uninstall|task register|task unregister> <request.json> <result.json>";

/// 结构化错误：`code` 供应用侧判断，`message` 给人看。
#[derive(Debug, Clone)]
pub struct CliError {
    pub code: String,
    pub message: String,
    pub os_error: Option<u32>,
}

impl CliError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            os_error: None,
        }
    }

    /// 把 `io::Error` 转成结构化错误。
    ///
    /// 访问被拒（Win32 5）单独给一个稳定的 code：提权被拒是最常见的失败，应用侧要能
    /// 把它和别的失败区分开。
    pub fn from_io(code: impl Into<String>, error: &std::io::Error) -> Self {
        let os_error = error.raw_os_error().map(|value| value as u32);
        let code = match os_error {
            Some(5) => "ACCESS_DENIED".to_string(),
            _ => code.into(),
        };
        Self {
            code,
            message: error.to_string(),
            os_error,
        }
    }

    /// 把 HRESULT 转成结构化错误。
    ///
    /// 只折叠「访问被拒」：它是最常见的失败，且任何调用点上的含义都一样。别的取值一律
    /// 保留调用方给的 code，让调用点自己判断（例如 `task unregister` 要单独认 NOT_FOUND）。
    pub fn from_hresult(code: impl Into<String>, error: &windows::core::Error) -> Self {
        let hresult = error.code().0 as u32;
        let code = match hresult {
            0x8007_0005 => "ACCESS_DENIED".to_string(),
            _ => code.into(),
        };
        Self {
            code,
            message: error.message().to_string(),
            os_error: Some(hresult),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Command {
    ServiceInstall,
    ServiceUninstall,
    TaskRegister,
    TaskUnregister,
}

impl Command {
    fn name(self) -> &'static str {
        match self {
            Command::ServiceInstall => "service install",
            Command::ServiceUninstall => "service uninstall",
            Command::TaskRegister => "task register",
            Command::TaskUnregister => "task unregister",
        }
    }
}

enum Parsed {
    /// 不是命令行调用（例如由服务控制管理器启动的服务进程），继续走原来的服务逻辑。
    NotCli,
    Usage(String),
    Run {
        command: Command,
        request: PathBuf,
        result: PathBuf,
    },
}

/// 命令行调用则执行并返回退出码；不是命令行调用返回 `None`。
pub fn run_if_cli() -> Option<i32> {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    match parse(&args) {
        Parsed::NotCli => None,
        Parsed::Usage(message) => {
            eprintln!("{message}");
            eprintln!("{USAGE}");
            Some(EXIT_USAGE)
        }
        Parsed::Run {
            command,
            request,
            result,
        } => Some(execute(command, &request, &result)),
    }
}

fn parse(args: &[OsString]) -> Parsed {
    let Some(group) = args.first().and_then(|arg| arg.to_str()) else {
        return Parsed::NotCli;
    };

    let command = match group {
        "service" => match args.get(1).and_then(|arg| arg.to_str()) {
            Some("install") => Command::ServiceInstall,
            Some("uninstall") => Command::ServiceUninstall,
            Some(other) => return Parsed::Usage(format!("unknown service subcommand: {other}")),
            None => return Parsed::Usage("missing service subcommand".to_string()),
        },
        "task" => match args.get(1).and_then(|arg| arg.to_str()) {
            Some("register") => Command::TaskRegister,
            Some("unregister") => Command::TaskUnregister,
            Some(other) => return Parsed::Usage(format!("unknown task subcommand: {other}")),
            None => return Parsed::Usage("missing task subcommand".to_string()),
        },
        _ => return Parsed::NotCli,
    };

    if args.len() != 4 {
        return Parsed::Usage(format!(
            "{} expects <request.json> <result.json>",
            command.name()
        ));
    }

    Parsed::Run {
        command,
        request: PathBuf::from(&args[2]),
        result: PathBuf::from(&args[3]),
    }
}

fn execute(command: Command, request_path: &Path, result_path: &Path) -> i32 {
    let (exit_code, result) = match run(command, request_path) {
        Ok(()) => (EXIT_OK, CliResult::success(command)),
        Err(error) => {
            eprintln!(
                "{} failed: {} ({})",
                command.name(),
                error.message,
                error.code
            );
            let exit_code = if error.code == "REQUEST_READ_FAILED" {
                EXIT_REQUEST
            } else {
                EXIT_FAILED
            };
            (exit_code, CliResult::failure(command, &error))
        }
    };

    if let Err(error) = write_result(result_path, &result) {
        eprintln!("failed to write {}: {}", result_path.display(), error);
        return EXIT_FAILED;
    }

    exit_code
}

fn run(command: Command, request_path: &Path) -> Result<(), CliError> {
    let raw = fs::read_to_string(request_path)
        .map_err(|error| CliError::from_io("REQUEST_READ_FAILED", &error))?;

    match command {
        Command::ServiceInstall => {
            let request: ServiceInstallRequest = parse_request(&raw)?;
            install_service(&request)
        }
        Command::ServiceUninstall => {
            let request: ServiceUninstallRequest = parse_request(&raw)?;
            uninstall_service(&request.service_name)
        }
        Command::TaskRegister => {
            let request: TaskRegisterRequest = parse_request(&raw)?;
            crate::ops::task::register(&request)
        }
        Command::TaskUnregister => {
            let request: TaskUnregisterRequest = parse_request(&raw)?;
            crate::ops::task::unregister(&request.task_name)
        }
    }
}

/// 只有带 `windows-service` feature 的构建才能建服务——出货构建（`setup.dart`）带这个 feature，
/// 开发态手工跑管道服务的构建不带。
#[cfg(feature = "windows-service")]
fn install_service(request: &ServiceInstallRequest) -> Result<(), CliError> {
    crate::ops::service::install(request)
}

#[cfg(not(feature = "windows-service"))]
fn install_service(_request: &ServiceInstallRequest) -> Result<(), CliError> {
    Err(unsupported_build())
}

#[cfg(feature = "windows-service")]
fn uninstall_service(service_name: &str) -> Result<(), CliError> {
    crate::ops::service::uninstall(service_name)
}

#[cfg(not(feature = "windows-service"))]
fn uninstall_service(_service_name: &str) -> Result<(), CliError> {
    Err(unsupported_build())
}

#[cfg(not(feature = "windows-service"))]
fn unsupported_build() -> CliError {
    CliError::new(
        "UNSUPPORTED_BUILD",
        "helper was built without the windows-service feature",
    )
}

fn parse_request<T: for<'de> Deserialize<'de>>(raw: &str) -> Result<T, CliError> {
    serde_json::from_str(raw).map_err(|error| CliError::new("INVALID_REQUEST", error.to_string()))
}

// 不带 `windows-service` feature 的构建里没人读这些字段，显式放行。
#[cfg_attr(not(feature = "windows-service"), allow(dead_code))]
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceInstallRequest {
    pub service_name: String,
    /// `auto`（开机自启）或 `demand`（手动启动，开发态用）。
    #[serde(default = "default_start_type")]
    pub start_type: String,
    /// 服务 `Environment` 值（`REG_MULTI_SZ`）的逐条内容。留空则不动现有值。
    #[serde(default)]
    pub environment: Vec<String>,
}

fn default_start_type() -> String {
    "auto".to_string()
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceUninstallRequest {
    pub service_name: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskRegisterRequest {
    pub task_name: String,
    pub executable_path: String,
    pub working_directory: String,
    #[serde(default)]
    pub description: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskUnregisterRequest {
    pub task_name: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CliResult {
    ok: bool,
    command: &'static str,
    code: Option<String>,
    message: Option<String>,
    os_error: Option<u32>,
}

impl CliResult {
    fn success(command: Command) -> Self {
        Self {
            ok: true,
            command: command.name(),
            code: None,
            message: None,
            os_error: None,
        }
    }

    fn failure(command: Command, error: &CliError) -> Self {
        Self {
            ok: false,
            command: command.name(),
            code: Some(error.code.clone()),
            message: Some(error.message.clone()),
            os_error: error.os_error,
        }
    }
}

fn write_result(path: &Path, result: &CliResult) -> std::io::Result<()> {
    let encoded = serde_json::to_string_pretty(result)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))?;
    fs::write(path, encoded)
}

/// 服务名/任务名共用的校验：名字要能直接进注册表路径与 Task Scheduler 命名空间。
pub fn validate_name(kind: &str, name: &str) -> Result<(), CliError> {
    if name.trim().is_empty() {
        return Err(CliError::new(
            "INVALID_REQUEST",
            format!("{kind} must not be empty"),
        ));
    }
    if name.contains(['\\', '/']) {
        return Err(CliError::new(
            "INVALID_REQUEST",
            format!("{kind} must not contain path separators: {name}"),
        ));
    }
    if name.chars().any(|c| c.is_control()) {
        return Err(CliError::new(
            "INVALID_REQUEST",
            format!("{kind} must not contain control characters"),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(values: &[&str]) -> Vec<OsString> {
        values.iter().map(OsString::from).collect()
    }

    #[test]
    fn recognizes_every_subcommand() {
        let cases = [
            (
                ["service", "install", "a.json", "b.json"],
                Command::ServiceInstall,
            ),
            (
                ["service", "uninstall", "a.json", "b.json"],
                Command::ServiceUninstall,
            ),
            (
                ["task", "register", "a.json", "b.json"],
                Command::TaskRegister,
            ),
            (
                ["task", "unregister", "a.json", "b.json"],
                Command::TaskUnregister,
            ),
        ];

        for (input, expected) in cases {
            match parse(&args(&input)) {
                Parsed::Run { command, .. } => assert_eq!(command, expected),
                _ => panic!("{input:?} was not parsed as a command"),
            }
        }
    }

    /// 服务控制管理器启动服务时不带参数；带别的参数也不能被当成 CLI 调用。
    #[test]
    fn treats_other_invocations_as_service_start() {
        assert!(matches!(parse(&args(&[])), Parsed::NotCli));
        assert!(matches!(parse(&args(&["--version"])), Parsed::NotCli));
        assert!(matches!(parse(&args(&["install"])), Parsed::NotCli));
    }

    #[test]
    fn reports_usage_for_broken_invocations() {
        for input in [
            vec!["service"],
            vec!["service", "restart", "a.json", "b.json"],
            vec!["task"],
            vec!["service", "install", "a.json"],
            vec!["service", "install", "a.json", "b.json", "c.json"],
        ] {
            assert!(
                matches!(parse(&args(&input)), Parsed::Usage(_)),
                "{input:?} should be a usage error"
            );
        }
    }

    #[test]
    fn rejects_names_that_cannot_go_into_a_registry_path() {
        assert!(validate_name("service name", "BettboxHelperService").is_ok());
        assert!(validate_name("service name", " ").is_err());
        assert!(validate_name("service name", "a\\b").is_err());
        assert!(validate_name("task name", "a/b").is_err());
        assert!(validate_name("task name", "a\nb").is_err());
    }
}
