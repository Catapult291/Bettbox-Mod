//! Windows 实现：`MiniDumpWriteDump` 落盘 + 顶层未处理异常过滤器。
//!
//! 过滤器链回原有 filter（`SetUnhandledExceptionFilter` 的返回值）；原本没有
//! 时按 EXCEPTION_EXECUTE_HANDLER 终止，与系统默认行为一致。

use std::ffi::c_void;
use std::fs::File;
use std::os::windows::io::AsRawHandle;
use std::path::Path;
use std::sync::atomic::{AtomicPtr, Ordering};

use windows::Win32::Foundation::{FALSE, HANDLE};
use windows::Win32::System::Diagnostics::Debug::{
    MiniDumpNormal, MiniDumpWithThreadInfo, MiniDumpWriteDump, SetUnhandledExceptionFilter,
    MINIDUMP_EXCEPTION_INFORMATION, MINIDUMP_TYPE,
};
use windows::Win32::System::Threading::{GetCurrentProcess, GetCurrentThreadId};

pub(crate) use windows::Win32::System::Diagnostics::Debug::EXCEPTION_POINTERS as ExceptionPointers;

/// winuser.h 的 `EXCEPTION_EXECUTE_HANDLER`（windows 0.52 绑定未导出该常量）。
const EXCEPTION_EXECUTE_HANDLER: i32 = 1;

type TopLevelExceptionFilter = Option<unsafe extern "system" fn(*const ExceptionPointers) -> i32>;

/// 原有顶层过滤器（fn 指针按裸指针存，避免依赖 Sync；空指针表示「原本没有」）。
static PREVIOUS_FILTER: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

/// dump 类型：默认 dump + 线程时间戳。MiniDumpNormal 已含全部线程栈与模块
/// 列表，定位 panic / 访问违规的调用栈足够；不带句柄与全内存，单文件控制在
/// 数 MB 级。
fn dump_type() -> MINIDUMP_TYPE {
    MiniDumpNormal | MiniDumpWithThreadInfo
}

/// 安装未处理异常过滤器；幂等性由调用方（`install` 的原子标志）保证。
pub(crate) fn install_exception_filter() {
    let previous = unsafe { SetUnhandledExceptionFilter(Some(unhandled_exception_filter)) };
    let stored = match previous {
        Some(func) => func as *const () as *mut c_void,
        None => std::ptr::null_mut(),
    };
    PREVIOUS_FILTER.store(stored, Ordering::SeqCst);
}

/// 未处理异常（访问违规、非法指令等）入口：写带异常上下文的 dump，再链回原有过滤器。
unsafe extern "system" fn unhandled_exception_filter(
    exception_info: *const ExceptionPointers,
) -> i32 {
    if let Some(dir) = crate::dump_dir() {
        crate::record_unhandled(dir, crate::tag(), exception_info.cast_mut());
    }
    let previous = PREVIOUS_FILTER.load(Ordering::SeqCst);
    if previous.is_null() {
        return EXCEPTION_EXECUTE_HANDLER;
    }
    let filter: TopLevelExceptionFilter = unsafe { std::mem::transmute(previous) };
    match filter {
        Some(func) => func(exception_info),
        None => EXCEPTION_EXECUTE_HANDLER,
    }
}

/// 创建 dump 文件并调用 dbghelp 写入；失败返回 Err（调用方丢弃即可）。
pub(crate) fn write_minidump(
    path: &Path,
    exception: Option<*mut ExceptionPointers>,
) -> std::io::Result<()> {
    let file = File::create(path)?;
    let handle = HANDLE(file.as_raw_handle() as isize);

    // 本地量借出指针：MiniDumpWriteDump 只在调用期间读取该结构。
    let exception_param = exception.map(|pointers| MINIDUMP_EXCEPTION_INFORMATION {
        ThreadId: unsafe { GetCurrentThreadId() },
        ExceptionPointers: pointers,
        ClientPointers: FALSE,
    });

    let result = unsafe {
        MiniDumpWriteDump(
            GetCurrentProcess(),
            std::process::id(),
            handle,
            dump_type(),
            exception_param
                .as_ref()
                .map(|param| param as *const MINIDUMP_EXCEPTION_INFORMATION),
            None,
            None,
        )
    };
    result.map_err(|error| std::io::Error::other(format!("MiniDumpWriteDump 失败：{error}")))
}
