[Setup]
AppId={{APP_ID}}
AppVersion={{APP_VERSION}}
AppName={{DISPLAY_NAME}}
AppPublisher={{PUBLISHER_NAME}}
AppPublisherURL={{PUBLISHER_URL}}
AppSupportURL={{PUBLISHER_URL}}
AppUpdatesURL={{PUBLISHER_URL}}
DefaultDirName={{INSTALL_DIR_NAME}}
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename={{OUTPUT_BASE_FILENAME}}
Compression=lzma
SolidCompression=yes
SetupIconFile={{SETUP_ICON_FILE}}
UninstallDisplayIcon={app}\{{EXECUTABLE_NAME}}
WizardStyle=modern
PrivilegesRequired={{PRIVILEGES_REQUIRED}}
ArchitecturesAllowed={{ARCH}}
ArchitecturesInstallIn64BitMode={{ARCH}}
CloseApplications=yes
CloseApplicationsFilter={{EXECUTABLE_NAME}},{{CORE_EXECUTABLE_NAME}},{{HELPER_EXECUTABLE_NAME}}
SetupLogging=yes

[Code]
var
  ShouldCleanUserData: Boolean;

{ 调一次 helper 的子命令。请求 JSON 与结果都走文件，和 lib/common/system.dart 是同一条路：
  参数不进命令行（路径可能带空格与非 ASCII 字符），helper 把结构化结果写进结果文件。 }
function RunHelperCommand(const SubCommand, RequestJson: String): Boolean;
var
  ResultCode: Integer;
  HelperPath: String;
  RequestPath: String;
  ResultPath: String;
  Lines: TArrayOfString;
  i: Integer;
begin
  Result := False;

  HelperPath := ExpandConstant('{app}\{{HELPER_EXECUTABLE_NAME}}');
  if not FileExists(HelperPath) then
  begin
    Log('helper not found, skipping: ' + SubCommand);
    Exit;
  end;

  RequestPath := ExpandConstant('{tmp}\bettbox_helper.request.json');
  ResultPath := ExpandConstant('{tmp}\bettbox_helper.result.json');
  SaveStringToFile(RequestPath, RequestJson, False);
  DeleteFile(ResultPath);

  Exec(HelperPath, SubCommand + ' "' + RequestPath + '" "' + ResultPath + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  if LoadStringsFromFile(ResultPath, Lines) then
  begin
    for i := 0 to GetArrayLength(Lines) - 1 do
    begin
      if Pos('"ok": true', Lines[i]) > 0 then
      begin
        Result := True;
        Break;
      end;
    end;
  end;

  if not Result then
    Log('helper did not report ok: ' + SubCommand + ' (exit ' + IntToStr(ResultCode) + ')');

  DeleteFile(RequestPath);
  DeleteFile(ResultPath);
end;

{ 覆盖 helper.exe 之前让它真的停下。
  先试 service stop：helper 1.19.16 起才有，它会先停内核、再向 SCM 报 Stopped，
  已配好的崩溃恢复策略因此不会在 5 秒后把服务重新拉起来。
  更早的 helper 不认这个子命令，而「只停不删」的话服务会被恢复策略拉起、正好落在文件
  复制中间，所以退回 service uninstall（停 + 删服务）——删掉的服务没法被拉起来，
  服务由 ssPostInstall 的 RegisterHelperService 重建。 }
function StopHelperForUpgrade: Boolean;
var
  ServiceJson: String;
begin
  ServiceJson := '{"serviceName":"{{HELPER_SERVICE_NAME}}"}';

  Result := RunHelperCommand('service stop', ServiceJson);

  if not Result then
    Result := RunHelperCommand('service uninstall', ServiceJson);
end;

{ 本包带进来的文件清单，由 package_windows.dart 在打包时写出（{{MANIFEST_FILE_NAME}}），
  随包装到安装目录。升级安装时按「上一版清单 - 本版清单」的差集删文件，清掉本版已不再提供的
  旧 dll / 下线插件；只删安装器自己写进去的文件，用户自己放进安装目录的东西不动。 }
procedure BackupPreviousManifest;
var
  ManifestPath: String;
begin
  ManifestPath := ExpandConstant('{app}\{{MANIFEST_FILE_NAME}}');
  if FileExists(ManifestPath) then
  begin
    { 必须先备份：ssInstall 时安装目录里还是上一版内容，等 [Files] 复制完，同名清单已被本包覆盖。 }
    if CopyFile(ManifestPath, ExpandConstant('{tmp}\bettbox_prev_manifest.txt'), False) then
      Log('previous install manifest saved for stale file cleanup')
    else
      Log('could not save previous install manifest');
  end;
end;

procedure RemoveStaleFiles;
var
  PrevManifest: String;
  CurrManifest: String;
  PrevLines: TArrayOfString;
  CurrLines: TArrayOfString;
  StaleDirs: TArrayOfString;
  RelPath: String;
  FullPath: String;
  i, j, StaleCount, Pass: Integer;
  Found: Boolean;
begin
  PrevManifest := ExpandConstant('{tmp}\bettbox_prev_manifest.txt');
  CurrManifest := ExpandConstant('{app}\{{MANIFEST_FILE_NAME}}');

  if not (FileExists(PrevManifest) and FileExists(CurrManifest)) then
  begin
    { 没有上一版清单，说明这次升级来自清单机制上线前的版本：按已知下线的文件名清一遍
      （一次性迁移，之后各版都靠清单差集）。这些文件不会被任何版本加载，属死重量。 }
    DeleteFile(ExpandConstant('{app}\bettbox_config.dll'));
    DeleteFile(ExpandConstant('{app}\bettbox_script.dll'));
    DeleteFile(ExpandConstant('{app}\flutter_qjs_plugin.dll'));
    DeleteFile(ExpandConstant('{app}\proxy_plugin.dll'));
    Exit;
  end;

  if not LoadStringsFromFile(PrevManifest, PrevLines) then
  begin
    Log('previous install manifest unreadable, skipping stale file cleanup');
    Exit;
  end;

  if not LoadStringsFromFile(CurrManifest, CurrLines) then
  begin
    Log('install manifest unreadable, skipping stale file cleanup');
    Exit;
  end;

  SetArrayLength(StaleDirs, GetArrayLength(PrevLines));
  StaleCount := 0;

  for i := 0 to GetArrayLength(PrevLines) - 1 do
  begin
    RelPath := Trim(PrevLines[i]);
    if RelPath <> '' then
    begin
      Found := False;
      j := 0;
      while (not Found) and (j < GetArrayLength(CurrLines)) do
      begin
        if Trim(CurrLines[j]) = RelPath then
          Found := True;
        j := j + 1;
      end;

      if not Found then
      begin
        FullPath := ExpandConstant('{app}\') + RelPath;
        if FileExists(FullPath) then
        begin
          if DeleteFile(FullPath) then
            Log('removed file dropped from package: ' + RelPath)
          else
            Log('failed to remove file dropped from package: ' + RelPath);
        end;
        StaleDirs[StaleCount] := ExtractFileDir(FullPath);
        StaleCount := StaleCount + 1;
      end;
    end;
  end;

  { RemoveDir 只在目录为空时成功，所以由深到浅多跑几遍，把因此空掉的子目录也清掉。 }
  for Pass := 0 to 7 do
  begin
    for i := 0 to StaleCount - 1 do
    begin
      if StaleDirs[i] <> '' then
        RemoveDir(StaleDirs[i]);
    end;
  end;
end;

function IsProcessRunning(ProcessName: String): Boolean;
var
  ResultCode: Integer;
begin
  Exec('cmd.exe', '/c tasklist /fi "imagename eq ' + ProcessName + '" 2>nul | find /i "' + ProcessName + '" >nul', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := (ResultCode = 0);
end;

procedure ForceKillProcesses(IsUninstall: Boolean);
var
  ResultCode: Integer;
  WaitCount: Integer;
begin
  if IsProcessRunning('{{HELPER_EXECUTABLE_NAME}}') then
  begin
    StopHelperForUpgrade;

    WaitCount := 0;
    while (WaitCount < 10) and IsProcessRunning('{{HELPER_EXECUTABLE_NAME}}') do
    begin
      Sleep(400);
      WaitCount := WaitCount + 1;
    end;

    if IsProcessRunning('{{HELPER_EXECUTABLE_NAME}}') then
      Exec('taskkill', '/f /im {{HELPER_EXECUTABLE_NAME}}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;

  { Try to elegantly exit the main app using --exit parameter }
  if FileExists(ExpandConstant('{app}\{{EXECUTABLE_NAME}}')) and IsProcessRunning('{{EXECUTABLE_NAME}}') then
  begin
    if IsUninstall then
      UninstallProgressForm.StatusLabel.Caption := CustomMessage('ShuttingDownRunningApp')
    else
      WizardForm.StatusLabel.Caption := CustomMessage('ShuttingDownRunningApp');
    Exec(ExpandConstant('{app}\{{EXECUTABLE_NAME}}'), '--exit', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

    { Wait up to 4 seconds for the main app and core to exit }
    WaitCount := 0;
    while (WaitCount < 8) and (IsProcessRunning('{{EXECUTABLE_NAME}}') or IsProcessRunning('{{CORE_EXECUTABLE_NAME}}')) do
    begin
      Sleep(500);
      WaitCount := WaitCount + 1;
    end;
  end;

  { Fallback: force-kill if still running }
  if IsProcessRunning('{{EXECUTABLE_NAME}}') then
    Exec('taskkill', '/f /im {{EXECUTABLE_NAME}}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  if IsProcessRunning('{{CORE_EXECUTABLE_NAME}}') then
    Exec('taskkill', '/f /im {{CORE_EXECUTABLE_NAME}}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure CleanWintunDevices;
var
  ResultCode: Integer;
  PowerShellScript: String;
  TempScriptPath: String;
begin
  PowerShellScript := 
    '$ErrorActionPreference = ''SilentlyContinue'';' + #13#10 +
    'Write-Host "Cleaning old Wintun/Bettbox/LiClash network adapters...";' + #13#10 +
    '$adapters = Get-NetAdapter | Where-Object {' + #13#10 +
    '$_.InterfaceDescription -like "*Bettbox*" -or' + #13#10 +
    '  $_.Name -like "*Bettbox*"' + #13#10 +
    '};' + #13#10 +
    'if ($adapters) {' + #13#10 +
    '  foreach ($adapter in $adapters) {' + #13#10 +
    '    Write-Host "Removing adapter: $($adapter.Name) - $($adapter.InterfaceDescription)";' + #13#10 +
    '    try {' + #13#10 +
    '      $adapter | Disable-NetAdapter -Confirm:$false -ErrorAction Stop;' + #13#10 +
    '      Start-Sleep -Milliseconds 500;' + #13#10 +
    '      $adapter | Remove-NetAdapter -Confirm:$false -ErrorAction Stop;' + #13#10 +
    '      Write-Host "Successfully removed: $($adapter.Name)";' + #13#10 +
    '    } catch {' + #13#10 +
    '      Write-Host "Failed to remove $($adapter.Name): $_";' + #13#10 +
    '    }' + #13#10 +
    '  }' + #13#10 +
    '} else {' + #13#10 +
    '  Write-Host "No old adapters found.";' + #13#10 +
    '}' + #13#10 +
    'Write-Host "Cleanup completed.";';
  
  TempScriptPath := ExpandConstant('{tmp}\clean_wintun.ps1');
  SaveStringToFile(TempScriptPath, PowerShellScript, False);

  Exec('powershell.exe', 
    '-NoProfile -ExecutionPolicy Bypass -File "' + TempScriptPath + '"', 
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  
  DeleteFile(TempScriptPath);
end;

procedure RegisterHelperService;
begin
  // 就地改指向（服务还在）或新建（服务不存在，或刚被 StopHelperForUpgrade 删掉）。
  // 服务还在时不删服务：Environment（key 文件路径、管道 ACL）留着，应用侧不必每次升级都重发。
  RunHelperCommand('service config', '{"serviceName":"{{HELPER_SERVICE_NAME}}","startType":"auto"}');
end;

procedure UnregisterHelperService;
begin
  RunHelperCommand('service uninstall', '{"serviceName":"{{HELPER_SERVICE_NAME}}"}');
end;

procedure UnregisterTaskScheduler;
begin
  RunHelperCommand('task unregister', '{"taskName":"{{TASK_NAME}}"}');
end;

procedure CleanRegistry;
var
  RegistryKeys: TArrayOfString;
  i: Integer;
begin
  SetArrayLength(RegistryKeys, 4);
  RegistryKeys[0] := 'Software\com.appshub.bettbox';
  RegistryKeys[1] := 'Software\com.appshub\Bettbox';
  // v1.19.7–v1.19.18 期间 Runner.rc 的 CompanyName 变成 Catapult291 时可能写过的键
  RegistryKeys[2] := 'Software\Catapult291\Bettbox';
  RegistryKeys[3] := 'Software\Catapult291';

  for i := 0 to GetArrayLength(RegistryKeys)-1 do
  begin
    RegDeleteKeyIncludingSubkeys(HKCU, RegistryKeys[i]);
  end;
end;

procedure CleanUserData;
var
  UserDataPaths: TArrayOfString;
  i: Integer;
  AppDataPath: String;
begin
  AppDataPath := ExpandConstant('{userappdata}');

  // 0：包名身份；1：钉死的 com.appshub\Bettbox（迁移目标，也是上游老身份）
  // 2：v1.19.7+ CompanyName=Catapult291 时的数据目录（启动迁移前可能仍在这里）
  SetArrayLength(UserDataPaths, 3);
  UserDataPaths[0] := AppDataPath + '\com.appshub.bettbox';
  UserDataPaths[1] := AppDataPath + '\com.appshub\Bettbox';
  UserDataPaths[2] := AppDataPath + '\Catapult291\Bettbox';

  for i := 0 to GetArrayLength(UserDataPaths)-1 do
  begin
    if DirExists(UserDataPaths[i]) then
    begin
      DelTree(UserDataPaths[i], True, True, True);
    end;
  end;

  if DirExists(AppDataPath + '\com.appshub') then
  begin
    RemoveDir(AppDataPath + '\com.appshub');
  end;
  if DirExists(AppDataPath + '\Catapult291') then
  begin
    RemoveDir(AppDataPath + '\Catapult291');
  end;
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
end;

function InitializeUninstall(): Boolean;
var
  Response: Integer;
begin
  Response := MsgBox(CustomMessage('RemoveUserDataPrompt'), mbConfirmation, MB_YESNOCANCEL);
  
  if Response = IDCANCEL then
  begin
    Result := False;
  end
  else
  begin
    ShouldCleanUserData := (Response = IDYES);
    Result := True;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    { Let Inno Setup try CloseApplications first; force-kill any leftovers before files are copied. }
    ForceKillProcesses(False);
    BackupPreviousManifest;
  end;

  if CurStep = ssPostInstall then
  begin
    RemoveStaleFiles;
    RegisterHelperService;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    ForceKillProcesses(True);
    CleanWintunDevices;

    // 服务的注销与计划任务的删除都走 helper 的子命令，必须赶在 {app} 被删掉之前调用
    // （usPostUninstall 时 helper.exe 已经不在了）。
    UnregisterTaskScheduler;
    UnregisterHelperService;
  end;

  if CurUninstallStep = usPostUninstall then
  begin
    if ShouldCleanUserData then
    begin
      CleanUserData;
      CleanRegistry;
    end;
  end;
end;

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
{% if LOCALES %}
{% for locale in LOCALES %}
{% if locale.lang == 'zh' %}
Name: "chineseSimplified"; MessagesFile: {% if locale.file %}{{ locale.file }}{% else %}"compiler:Languages\\ChineseSimplified.isl"{% endif %}
{% endif %}
{% endfor %}
{% endif %}

[CustomMessages]
english.ShuttingDownRunningApp=Shutting down running {{DISPLAY_NAME}}...
english.RemoveUserDataPrompt=Do you want to remove all user data?%n%nThis will remove:%n• Configuration files%n• Profiles and subscriptions%n• Settings and preferences%n• Registry entries%n%nThis action cannot be undone.
{% if LOCALES %}
{% for locale in LOCALES %}
{% if locale.lang == 'zh' %}
chineseSimplified.ShuttingDownRunningApp=正在关闭运行中的 {{DISPLAY_NAME}}...
chineseSimplified.RemoveUserDataPrompt=是否要删除所有用户数据？%n%n这将删除：%n• 配置文件%n• 代理配置与订阅%n• 设置和偏好%n• 注册表记录%n%n此操作无法撤销。
{% endif %}
{% endfor %}
{% endif %}

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: {% if CREATE_DESKTOP_ICON != true %}unchecked{% else %}checkedonce{% endif %}
[Files]
Source: "{{SOURCE_DIR}}\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{autoprograms}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"
Name: "{autodesktop}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"; Tasks: desktopicon
[Run]
Filename: "{app}\\{{EXECUTABLE_NAME}}"; Description: "{cm:LaunchProgram,{{DISPLAY_NAME}}}"; Flags: {% if PRIVILEGES_REQUIRED == 'admin' %}runascurrentuser{% endif %} nowait postinstall skipifsilent