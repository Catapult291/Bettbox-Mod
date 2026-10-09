//! 计划任务注册与注销（`helper.exe task register|unregister`）。
//!
//! 旧实现是应用侧拼任务 XML 再 `runas('schtasks', '/Create /TN … /XML …')`：XML 里不转义，
//! 失败也只剩一个退出码。这里沿用同一份 XML（它在现场已经跑通），但由 helper 直接交给
//! Task Scheduler 的 COM 接口，错误是 HRESULT，能带回结果文件里。

use std::path::Path;

use windows::core::BSTR;
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
};
use windows::Win32::System::TaskScheduler::{
    ITaskFolder, ITaskService, TaskScheduler, TASK_CREATE_OR_UPDATE, TASK_LOGON_INTERACTIVE_TOKEN,
};
use windows::Win32::System::Variant::VARIANT;

use crate::cli::{validate_name, CliError, TaskRegisterRequest};

const DEFAULT_DESCRIPTION: &str = "开机自动启动代理服务";

/// `ERROR_FILE_NOT_FOUND` 的 HRESULT 形式，`ITaskFolder::DeleteTask` 在任务不存在时返回它。
const HRESULT_FILE_NOT_FOUND: u32 = 0x8007_0002;

pub fn register(request: &TaskRegisterRequest) -> Result<(), CliError> {
    validate_name("task name", &request.task_name)?;
    let xml = build_task_xml(request)?;
    let folder = task_folder()?;

    unsafe {
        folder
            .RegisterTask(
                &BSTR::from(request.task_name.as_str()),
                &BSTR::from(xml.as_str()),
                TASK_CREATE_OR_UPDATE.0,
                VARIANT::default(),
                VARIANT::default(),
                TASK_LOGON_INTERACTIVE_TOKEN,
                VARIANT::default(),
            )
            .map_err(|error| CliError::from_hresult("TASK_REGISTER_FAILED", &error))?;
    }

    Ok(())
}

/// 注销任务。任务本来就不存在时也算成功（幂等）。
pub fn unregister(task_name: &str) -> Result<(), CliError> {
    validate_name("task name", task_name)?;
    let folder = task_folder()?;
    let name = BSTR::from(task_name);

    match unsafe { folder.DeleteTask(&name, 0) } {
        Ok(()) => Ok(()),
        Err(error) if error.code().0 as u32 == HRESULT_FILE_NOT_FOUND => Ok(()),
        Err(error) => Err(CliError::from_hresult("TASK_DELETE_FAILED", &error)),
    }
}

/// 连上 Task Scheduler 并取根文件夹。
///
/// 这一步与具体的注册/注销动作分开，是为了让「管道起不来」和「动作被拒」在结果里
/// 区分得开：`unregister` 只把 `DeleteTask` 自己的 NOT_FOUND 当作成功。
fn task_folder() -> Result<ITaskFolder, CliError> {
    unsafe {
        // Task Scheduler 是进程内 COM 组件。CLI 是一次性进程，不配对 CoUninitialize。
        CoInitializeEx(None, COINIT_MULTITHREADED)
            .map_err(|error| CliError::from_hresult("COM_INIT_FAILED", &error))?;

        let service: ITaskService = CoCreateInstance(
            &TaskScheduler,
            None::<&windows::core::IUnknown>,
            CLSCTX_INPROC_SERVER,
        )
        .map_err(|error| CliError::from_hresult("TASK_SERVICE_FAILED", &error))?;

        service
            .Connect(
                VARIANT::default(),
                VARIANT::default(),
                VARIANT::default(),
                VARIANT::default(),
            )
            .map_err(|error| CliError::from_hresult("TASK_SERVICE_CONNECT_FAILED", &error))?;

        service
            .GetFolder(&BSTR::from("\\"))
            .map_err(|error| CliError::from_hresult("TASK_FOLDER_FAILED", &error))
    }
}

fn build_task_xml(request: &TaskRegisterRequest) -> Result<String, CliError> {
    if !Path::new(&request.executable_path).is_absolute() {
        return Err(CliError::new(
            "INVALID_REQUEST",
            format!(
                "executablePath must be absolute: {}",
                request.executable_path
            ),
        ));
    }
    if !Path::new(&request.working_directory).is_absolute() {
        return Err(CliError::new(
            "INVALID_REQUEST",
            format!(
                "workingDirectory must be absolute: {}",
                request.working_directory
            ),
        ));
    }

    let uri = escape_xml(&request.task_name);
    let description = escape_xml(
        request
            .description
            .as_deref()
            .unwrap_or(DEFAULT_DESCRIPTION),
    );
    let command = escape_xml(&request.executable_path);
    let working_directory = escape_xml(&request.working_directory);

    Ok(format!(
        r#"<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>{description}</Description>
    <URI>\{uri}</URI>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
  </Triggers>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>6</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>"{command}"</Command>
      <WorkingDirectory>{working_directory}</WorkingDirectory>
    </Exec>
  </Actions>
</Task>"#
    ))
}

/// 安装路径里出现 `&`、`<`、`"` 都不该让整份任务 XML 解析失败。
fn escape_xml(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());

    for character in value.chars() {
        match character {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&apos;"),
            other => escaped.push(other),
        }
    }

    escaped
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(executable_path: &str) -> TaskRegisterRequest {
        TaskRegisterRequest {
            task_name: "Bettbox".to_string(),
            executable_path: executable_path.to_string(),
            working_directory: r"C:\Program Files\Bettbox".to_string(),
            description: None,
        }
    }

    #[test]
    fn builds_the_same_task_shape_the_old_xml_had() {
        let xml = build_task_xml(&request(r"C:\Program Files\Bettbox\Bettbox.exe")).unwrap();

        assert!(xml.contains("<URI>\\Bettbox</URI>"));
        assert!(xml.contains("<LogonTrigger>"));
        assert!(xml.contains("<LogonType>InteractiveToken</LogonType>"));
        assert!(xml.contains("<RunLevel>HighestAvailable</RunLevel>"));
        assert!(xml.contains("<Command>\"C:\\Program Files\\Bettbox\\Bettbox.exe\"</Command>"));
        assert!(xml.contains("<WorkingDirectory>C:\\Program Files\\Bettbox</WorkingDirectory>"));
        assert!(xml.contains("<Description>开机自动启动代理服务</Description>"));
    }

    #[test]
    fn escapes_paths_that_would_break_the_xml() {
        let xml = build_task_xml(&request(r"C:\A & B\X<Y>.exe")).unwrap();

        assert!(xml.contains(r#"<Command>"C:\A &amp; B\X&lt;Y&gt;.exe"</Command>"#));
        assert!(!xml.contains("A & B"));
    }

    #[test]
    fn rejects_paths_that_are_not_absolute() {
        assert!(build_task_xml(&request("Bettbox.exe")).is_err());

        let mut relative_working_directory = request(r"C:\Bettbox\Bettbox.exe");
        relative_working_directory.working_directory = "Bettbox".to_string();
        assert!(build_task_xml(&relative_working_directory).is_err());
    }
}
