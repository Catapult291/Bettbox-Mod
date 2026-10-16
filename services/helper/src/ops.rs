#[cfg(all(target_os = "windows", feature = "windows-service"))]
pub mod service;
#[cfg(target_os = "windows")]
pub mod task;

pub mod core {
    use once_cell::sync::Lazy;
    use serde::{Deserialize, Serialize};
    use sha2::{Digest, Sha256};
    use std::fs::{File, Metadata, OpenOptions};
    use std::io::{BufRead, BufReader, Error, Read};
    use std::process::{Command, Stdio};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::thread;
    use std::time::{Duration, UNIX_EPOCH};

    use super::logs::log_message;

    const HASH_BUFFER_SIZE: usize = 65536;

    #[derive(Debug, Deserialize, Serialize, Clone)]
    pub struct StartParams {
        pub path: String,
        pub arg: String,
        pub home_dir: Option<String>,
    }

    #[derive(Debug, Clone)]
    struct CachedFileHash {
        path: String,
        size: u64,
        modified_nanos: u128,
        hash: String,
    }

    static PROCESS: Lazy<Arc<Mutex<Option<std::process::Child>>>> =
        Lazy::new(|| Arc::new(Mutex::new(None)));
    static FILE_HASH_CACHE: Lazy<Arc<Mutex<Option<CachedFileHash>>>> =
        Lazy::new(|| Arc::new(Mutex::new(None)));

    pub fn start_core(start_params: StartParams) -> String {
        if let Err(e) = validate_core_path(&start_params.path) {
            log_message(e.clone());
            return e;
        }

        let file = match OpenOptions::new().read(true).open(&start_params.path) {
            Ok(f) => f,
            Err(e) => {
                let msg = format!("Failed to open file: {}", e);
                log_message(msg.clone());
                return msg;
            }
        };

        if let Err(e) = file.lock_shared() {
            let msg = format!("Failed to lock file: {}", e);
            log_message(msg.clone());
            return msg;
        }

        let sha256 = match sha256_file_with_lock(&file, &start_params.path) {
            Ok(hash) => hash,
            Err(e) => {
                let _ = file.unlock();
                let msg = format!("Failed to calculate SHA256: {}", e);
                log_message(msg.clone());
                return msg;
            }
        };

        if sha256 != env!("TOKEN") {
            let _ = file.unlock();
            let msg = format!("The SHA256 hash of the program requesting execution is: {}. The helper program only allows execution of applications with the SHA256 hash: {}.", sha256, env!("TOKEN"));
            log_message(msg.clone());
            return msg;
        }

        let _ = file.unlock();
        drop(file);

        stop_core();
        let mut process = PROCESS.lock().unwrap_or_else(|e| e.into_inner());

        let mut command = Command::new(&start_params.path);
        command.stderr(Stdio::piped()).arg(&start_params.arg);

        if let Some(home_dir) = &start_params.home_dir {
            command.env("SAFE_PATHS", home_dir);
        }

        match command.spawn() {
            Ok(child) => {
                *process = Some(child);

                if let Some(ref mut child) = *process {
                    if let Some(stderr) = child.stderr.take() {
                        let reader = std::io::BufReader::new(stderr);
                        thread::spawn(move || {
                            for line in reader.lines() {
                                match line {
                                    Ok(output) => log_message(output),
                                    Err(_) => break,
                                }
                            }
                        });
                    }
                }
                start_dev_core_exit_watcher();
                "".to_string()
            }
            Err(e) => {
                log_message(e.to_string());
                e.to_string()
            }
        }
    }

    static WATCHER_STARTED: AtomicBool = AtomicBool::new(false);

    fn start_dev_core_exit_watcher() {
        if !should_exit_service_when_core_exits() {
            return;
        }
        if WATCHER_STARTED.swap(true, Ordering::SeqCst) {
            return;
        }

        thread::spawn(|| loop {
            thread::sleep(Duration::from_millis(500));

            let mut process = PROCESS.lock().unwrap_or_else(|e| e.into_inner());
            let Some(child) = process.as_mut() else {
                WATCHER_STARTED.store(false, Ordering::SeqCst);
                break;
            };

            match child.try_wait() {
                Ok(Some(status)) => {
                    log_message(format!("Core process exited: {}", status));
                    *process = None;
                    drop(process);
                    log_message("Dev helper service exiting after core exit".to_string());
                    std::process::exit(0);
                }
                Ok(None) => {}
                Err(e) => {
                    log_message(format!("Failed to monitor core process: {}", e));
                    *process = None;
                    drop(process);
                    std::process::exit(1);
                }
            }
        });
    }

    fn should_exit_service_when_core_exits() -> bool {
        env_contains_dev("HELPER_SERVICE_NAME")
            || env_contains_dev("HELPER_PIPE_NAME")
            || current_exe_name_contains_dev()
    }

    fn env_contains_dev(name: &str) -> bool {
        std::env::var(name)
            .map(|value| value.contains("Dev"))
            .unwrap_or(false)
    }

    fn current_exe_name_contains_dev() -> bool {
        std::env::current_exe()
            .ok()
            .and_then(|path| {
                path.file_stem()
                    .map(|stem| stem.to_string_lossy().to_string())
            })
            .map(|name| name.contains("Dev"))
            .unwrap_or(false)
    }

    fn validate_core_path(path: &str) -> Result<(), String> {
        let path = std::path::Path::new(path);
        if !path.is_absolute() {
            return Err("core path must be absolute".to_string());
        }
        if path
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
        {
            return Err("core path must not contain '..'".to_string());
        }
        Ok(())
    }

    pub fn stop_core() -> String {
        let mut process = PROCESS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(mut child) = process.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        *process = None;
        "".to_string()
    }

    fn metadata_signature(metadata: &Metadata) -> Result<(u64, u128), Error> {
        let modified_nanos = metadata
            .modified()?
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        Ok((metadata.len(), modified_nanos))
    }

    fn sha256_file_with_lock(file: &File, path: &str) -> Result<String, Error> {
        let metadata = file.metadata()?;
        let (size, modified_nanos) = metadata_signature(&metadata)?;

        if let Ok(cache_guard) = FILE_HASH_CACHE.lock() {
            if let Some(cache) = cache_guard.as_ref() {
                if cache.path == path
                    && cache.size == size
                    && cache.modified_nanos == modified_nanos
                {
                    return Ok(cache.hash.clone());
                }
            }
        }

        let mut hasher = Sha256::new();
        let mut buffer = [0; HASH_BUFFER_SIZE];
        let mut reader = BufReader::new(file);

        loop {
            let bytes_read = reader.read(&mut buffer)?;
            if bytes_read == 0 {
                break;
            }
            hasher.update(&buffer[..bytes_read]);
        }

        let hash = format!("{:x}", hasher.finalize());
        if let Ok(mut cache_guard) = FILE_HASH_CACHE.lock() {
            *cache_guard = Some(CachedFileHash {
                path: path.to_string(),
                size,
                modified_nanos,
                hash: hash.clone(),
            });
        }
        Ok(hash)
    }
}

pub mod logs {
    use once_cell::sync::Lazy;
    use std::collections::VecDeque;
    use std::sync::{Arc, Mutex};

    const MAX_LOG_ENTRIES: usize = 100;

    static LOGS: Lazy<Arc<Mutex<VecDeque<String>>>> =
        Lazy::new(|| Arc::new(Mutex::new(VecDeque::with_capacity(MAX_LOG_ENTRIES))));

    pub fn log_message(message: String) {
        let mut log_buffer = LOGS.lock().unwrap_or_else(|e| e.into_inner());
        if log_buffer.len() == MAX_LOG_ENTRIES {
            log_buffer.pop_front();
        }
        log_buffer.push_back(message);
    }

    pub fn logs() -> Vec<String> {
        LOGS.lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .cloned()
            .collect()
    }
}

pub mod process {
    use serde::{Deserialize, Serialize};

    #[derive(Debug, Deserialize, Serialize, Clone)]
    pub struct PriorityParams {
        pub process_name: String,
        pub enable: bool,
    }

    pub fn set_process_priority(process_name: &str, enable: bool) -> String {
        use windows::Win32::Foundation::CloseHandle;
        use windows::Win32::System::Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
            TH32CS_SNAPPROCESS,
        };
        use windows::Win32::System::Threading::{
            OpenProcess, ProcessMemoryPriority, SetPriorityClass, SetProcessInformation,
            ABOVE_NORMAL_PRIORITY_CLASS, MEMORY_PRIORITY_INFORMATION, MEMORY_PRIORITY_NORMAL,
            NORMAL_PRIORITY_CLASS, PROCESS_SET_INFORMATION,
        };

        let priority_class = if enable {
            ABOVE_NORMAL_PRIORITY_CLASS
        } else {
            NORMAL_PRIORITY_CLASS
        };

        unsafe {
            let snapshot = match CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) {
                Ok(s) => s,
                Err(e) => return format!("Failed to create snapshot: {}", e),
            };

            let mut entry = PROCESSENTRY32W {
                dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
                ..Default::default()
            };

            let mut found = false;

            if Process32FirstW(snapshot, &mut entry).is_ok() {
                loop {
                    let exe_name = String::from_utf16_lossy(&entry.szExeFile);
                    let exe_name = exe_name.trim_end_matches('\0');

                    if exe_name.eq_ignore_ascii_case(process_name) {
                        let process_handle = match OpenProcess(
                            PROCESS_SET_INFORMATION,
                            false,
                            entry.th32ProcessID,
                        ) {
                            Ok(h) => h,
                            Err(e) => {
                                crate::ops::logs::log_message(format!(
                                    "Failed to open process {}: {}",
                                    entry.th32ProcessID, e
                                ));
                                if Process32NextW(snapshot, &mut entry).is_err() {
                                    break;
                                }
                                continue;
                            }
                        };

                        match SetPriorityClass(process_handle, priority_class) {
                            Ok(_) => {
                                found = true;
                                crate::ops::logs::log_message(format!(
                                    "Set priority for {} (PID: {}) to {}",
                                    process_name,
                                    entry.th32ProcessID,
                                    if enable { "above normal" } else { "normal" }
                                ));
                            }
                            Err(e) => {
                                crate::ops::logs::log_message(format!(
                                    "Failed to set priority for {}: {}",
                                    process_name, e
                                ));
                            }
                        }

                        if enable {
                            let memory_priority = MEMORY_PRIORITY_INFORMATION {
                                MemoryPriority: MEMORY_PRIORITY_NORMAL,
                            };
                            if let Err(e) = SetProcessInformation(
                                process_handle,
                                ProcessMemoryPriority,
                                &memory_priority as *const MEMORY_PRIORITY_INFORMATION as _,
                                std::mem::size_of::<MEMORY_PRIORITY_INFORMATION>() as u32,
                            ) {
                                crate::ops::logs::log_message(format!(
                                    "Failed to set memory priority for {}: {}",
                                    process_name, e
                                ));
                            } else {
                                crate::ops::logs::log_message(format!(
                                    "Set memory priority for {} (PID: {}) to normal",
                                    process_name, entry.th32ProcessID
                                ));
                            }
                        }

                        let _ = CloseHandle(process_handle);
                    }

                    if Process32NextW(snapshot, &mut entry).is_err() {
                        break;
                    }
                }
            }

            let _ = CloseHandle(snapshot);

            if found {
                "".to_string()
            } else {
                format!("Process {} not found", process_name)
            }
        }
    }

    /// 运行中进程的一行信息。`path` 为空表示打开失败（权限/系统进程）。
    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct ProcessEntry {
        pub pid: u32,
        pub name: String,
        pub path: String,
        pub description: String,
    }

    /// 枚举当前运行中的进程（Toolhelp32 快照 + QueryFullProcessImageNameW 取路径）。
    ///
    /// 以 helper 服务（SYSTEM）身份运行时几乎都能读到路径；读不到的条目 `path`
    /// 为空串，调用方可据此禁用「加入名单」而不是静默生成一条空规则。
    pub fn list_processes() -> Vec<ProcessEntry> {
        use windows::core::PWSTR;
        use windows::Win32::Foundation::CloseHandle;
        use windows::Win32::System::Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
            TH32CS_SNAPPROCESS,
        };
        use windows::Win32::System::Threading::{
            OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_FORMAT,
            PROCESS_QUERY_LIMITED_INFORMATION,
        };

        let mut entries: Vec<ProcessEntry> = Vec::new();

        unsafe {
            let snapshot = match CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) {
                Ok(s) => s,
                Err(_) => return entries,
            };

            let mut proc_entry = PROCESSENTRY32W {
                dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
                ..Default::default()
            };

            if Process32FirstW(snapshot, &mut proc_entry).is_ok() {
                loop {
                    let name = String::from_utf16_lossy(&proc_entry.szExeFile);
                    let name = name.trim_end_matches('\0').to_string();
                    let pid = proc_entry.th32ProcessID;

                    // Idle(0) / System(4) 没有可分流的用户态路径。
                    if pid != 0 && pid != 4 {
                        let mut path = String::new();
                        if let Ok(handle) =
                            OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
                        {
                            let mut size = 32768u32;
                            let mut buf = vec![0u16; size as usize];
                            let ok = QueryFullProcessImageNameW(
                                handle,
                                PROCESS_NAME_FORMAT(0),
                                PWSTR(buf.as_mut_ptr()),
                                &mut size,
                            );
                            if ok.is_ok() {
                                path = String::from_utf16_lossy(&buf[..size as usize]);
                            }
                            let _ = CloseHandle(handle);
                        }

                        let description = if path.is_empty() {
                            String::new()
                        } else {
                            file_description(&path)
                        };

                        entries.push(ProcessEntry {
                            pid,
                            name,
                            path,
                            description,
                        });
                    }

                    if Process32NextW(snapshot, &mut proc_entry).is_err() {
                        break;
                    }
                }
            }

            let _ = CloseHandle(snapshot);
        }

        entries
    }

    /// 单个 exe 的 FileDescription（版本资源）；读不到返回空串。
    ///
    /// 走 version.dll 的裸 FFI，避免为 windows-rs 再开一组 features：这段只需要
    /// 三个导出，且 StringFileInfo 的语言/代码页组合必须自己扫。
    fn file_description(path: &str) -> String {
        use std::ffi::c_void;
        use windows::core::PCWSTR;

        #[link(name = "version")]
        extern "system" {
            fn GetFileVersionInfoSizeW(lptstrfilename: PCWSTR, lpdwhandle: *mut u32) -> u32;
            fn GetFileVersionInfoW(
                lptstrfilename: PCWSTR,
                dwhandle: u32,
                dwlen: u32,
                lpdata: *mut c_void,
            ) -> i32;
            fn VerQueryValueW(
                pblock: *const c_void,
                lpsubblock: PCWSTR,
                lplpbuffer: *mut *const c_void,
                pulen: *mut u32,
            ) -> i32;
        }

        unsafe {
            let wide: Vec<u16> = path.encode_utf16().chain(std::iter::once(0)).collect();
            let mut handle = 0u32;
            let size = GetFileVersionInfoSizeW(PCWSTR(wide.as_ptr()), &mut handle);
            if size == 0 {
                return String::new();
            }
            let mut buf = vec![0u8; size as usize];
            if GetFileVersionInfoW(PCWSTR(wide.as_ptr()), handle, size, buf.as_mut_ptr() as _) == 0
            {
                return String::new();
            }

            let mut len = 0u32;
            // 语言/代码页从 VarFileInfo\Translation 读；读不到退回 en-US 常见组合。
            let mut lang = 0x0409u16;
            let mut codepage = 0x04b0u16;
            let trans_sub: Vec<u16> = "\\VarFileInfo\\Translation"
                .encode_utf16()
                .chain(std::iter::once(0))
                .collect();
            let mut trans_ptr: *const c_void = std::ptr::null();
            if VerQueryValueW(
                buf.as_ptr() as _,
                PCWSTR(trans_sub.as_ptr()),
                &mut trans_ptr,
                &mut len,
            ) != 0
                && !trans_ptr.is_null()
                && len >= 4
            {
                let pair = *(trans_ptr as *const u32);
                lang = (pair & 0xffff) as u16;
                codepage = ((pair >> 16) & 0xffff) as u16;
            }

            for key in ["FileDescription", "ProductName"] {
                let sub: Vec<u16> =
                    format!("\\StringFileInfo\\{:04x}{:04x}\\{}", lang, codepage, key)
                        .encode_utf16()
                        .chain(std::iter::once(0))
                        .collect();
                let mut text_ptr: *const c_void = std::ptr::null();
                if VerQueryValueW(
                    buf.as_ptr() as _,
                    PCWSTR(sub.as_ptr()),
                    &mut text_ptr,
                    &mut len,
                ) != 0
                    && !text_ptr.is_null()
                {
                    // StringFileInfo 的 `pulen` 实测是**含 NUL 的 WCHAR 个数**，
                    // 不是文档含糊的字节数（真机三例：`Bettbox`→8、
                    // `Bettbox Dev`→12、`PixPin`→7）。旧代码按字节语义再 `/2`，
                    // 把字符串砍成前一半——UI 里表现为程序名显示不全
                    // （`Bett` / `Bettbo` / `Pix`，2026-10-15 反馈）。
                    // 按字符数取；`avail`（text_ptr 到版本缓冲区末端）做硬上界，
                    // 个别按字节返回的实现由随后的首个 NUL 截住，不会越界。
                    let base = text_ptr as *const u16;
                    let buf_end = buf.as_ptr() as usize + buf.len();
                    let avail = buf_end.saturating_sub(base as usize) / 2;
                    let take = version_value_word_len(len, avail);
                    let text = utf16_c_str(std::slice::from_raw_parts(base, take));
                    if !text.is_empty() {
                        return text;
                    }
                }
            }
        }
        String::new()
    }

    /// 版本字符串值可安全取用的 u16 个数：`VerQueryValueW` 报告长度与缓冲区
    /// 余量取小。
    fn version_value_word_len(reported_len: u32, avail_words: usize) -> usize {
        (reported_len as usize).min(avail_words)
    }

    /// UTF-16 序列扫到首个 NUL 得到文本（去首尾空白）；无 NUL 则整段取用。
    fn utf16_c_str(words: &[u16]) -> String {
        let end = words.iter().position(|&c| c == 0).unwrap_or(words.len());
        String::from_utf16_lossy(&words[..end]).trim().to_string()
    }

    /// 从 exe 路径提取 32 位图标，返回 RGBA 像素与尺寸（自上而下）。
    ///
    /// 调用方（应用侧）按 path 缓存；失败返回 None，UI 回落默认图标。
    pub fn icon_rgba(path: &str) -> Option<(u32, u32, Vec<u8>)> {
        use windows::Win32::Graphics::Gdi::{
            CreateCompatibleDC, DeleteDC, DeleteObject, GetDIBits, GetObjectW, SelectObject,
            BITMAP, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HDC, HGDIOBJ,
        };
        use windows::Win32::UI::Shell::ExtractIconExW;
        use windows::Win32::UI::WindowsAndMessaging::{DestroyIcon, GetIconInfo, HICON, ICONINFO};

        unsafe {
            let wide: Vec<u16> = path.encode_utf16().chain(std::iter::once(0)).collect();
            let mut hicon = HICON::default();
            let count = ExtractIconExW(
                windows::core::PCWSTR(wide.as_ptr()),
                0,
                Some(&mut hicon),
                None,
                1,
            );
            if count == 0 || hicon.is_invalid() {
                return None;
            }

            let mut icon_info = ICONINFO::default();
            if GetIconInfo(hicon, &mut icon_info).is_err() {
                let _ = DestroyIcon(hicon);
                return None;
            }
            let _ = DestroyIcon(hicon);

            // 优先彩色位图；单色图标（极少）回退用 mask，这里直接放弃。
            if icon_info.hbmColor.is_invalid() {
                if !icon_info.hbmMask.is_invalid() {
                    let _ = DeleteObject(icon_info.hbmMask);
                }
                return None;
            }

            let mut bmp = BITMAP::default();
            let got = GetObjectW(
                icon_info.hbmColor,
                std::mem::size_of::<BITMAP>() as i32,
                Some(&mut bmp as *mut BITMAP as *mut std::ffi::c_void),
            );
            if got == 0 || bmp.bmWidth <= 0 || bmp.bmHeight <= 0 {
                let _ = DeleteObject(icon_info.hbmColor);
                if !icon_info.hbmMask.is_invalid() {
                    let _ = DeleteObject(icon_info.hbmMask);
                }
                return None;
            }

            let width = bmp.bmWidth as u32;
            let height = bmp.bmHeight as u32;
            let mut bits = vec![0u32; (width * height) as usize];

            let mut bmi = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: bmp.bmWidth,
                    // 负高度 = 自上而下，省一次翻转。
                    biHeight: -bmp.bmHeight,
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                },
                ..Default::default()
            };

            let hdc: HDC = CreateCompatibleDC(HDC::default());
            if hdc.is_invalid() {
                let _ = DeleteObject(icon_info.hbmColor);
                if !icon_info.hbmMask.is_invalid() {
                    let _ = DeleteObject(icon_info.hbmMask);
                }
                return None;
            }
            let prev = SelectObject(hdc, HGDIOBJ(icon_info.hbmColor.0));
            let lines = GetDIBits(
                hdc,
                icon_info.hbmColor,
                0,
                height,
                Some(bits.as_mut_ptr() as _),
                &mut bmi,
                DIB_RGB_COLORS,
            );
            let _ = SelectObject(hdc, prev);
            let _ = DeleteDC(hdc);
            let _ = DeleteObject(icon_info.hbmColor);
            if !icon_info.hbmMask.is_invalid() {
                let _ = DeleteObject(icon_info.hbmMask);
            }

            if lines == 0 {
                return None;
            }

            // DIB 是 BGRA；转成 Flutter 需要的 RGBA。图标的 alpha 常是预乘的，
            // 0 的 alpha 像素直接清零，非 0 的按经验足够 UI 展示。
            let mut rgba = Vec::with_capacity(bits.len() * 4);
            for px in bits.iter() {
                let b = (px & 0xff) as u8;
                let g = ((px >> 8) & 0xff) as u8;
                let r = ((px >> 16) & 0xff) as u8;
                let a = ((px >> 24) & 0xff) as u8;
                if a == 0 {
                    rgba.extend_from_slice(&[0, 0, 0, 0]);
                } else {
                    rgba.extend_from_slice(&[r, g, b, a]);
                }
            }

            Some((width, height, rgba))
        }
    }

    // 测试模块放文件末尾：clippy items-after-test-module 要求其后不再有非测试项。
    #[cfg(test)]
    mod file_description_tests {
        use super::{utf16_c_str, version_value_word_len};

        #[test]
        fn reported_len_is_wchar_count_not_bytes() {
            // 实测 pulen 含 NUL 的 WCHAR 数；不再除 2（旧行为会得到 4）。
            assert_eq!(version_value_word_len(8, 1024), 8);
            // 缓冲区末端兜底。
            assert_eq!(version_value_word_len(8, 5), 5);
        }

        #[test]
        fn decodes_full_names_that_used_to_be_halved() {
            for (raw, expect) in [
                ("Bettbox\0", "Bettbox"),
                ("Bettbox Dev\0", "Bettbox Dev"),
                ("PixPin\0", "PixPin"),
            ] {
                let words: Vec<u16> = raw.encode_utf16().collect();
                assert_eq!(utf16_c_str(&words), expect);
            }
        }

        #[test]
        fn trims_and_tolerates_missing_nul() {
            let padded: Vec<u16> = "  Bett  \0ignored".encode_utf16().collect();
            assert_eq!(utf16_c_str(&padded), "Bett");
            let no_nul: Vec<u16> = "PixPin".encode_utf16().collect();
            assert_eq!(utf16_c_str(&no_nul), "PixPin");
        }
    }
}
