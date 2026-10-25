//! Read-only Windows file references for the Agent composer.

#[cfg(windows)]
#[tauri::command]
pub fn agent_clipboard_file_paths() -> Result<Vec<String>, &'static str> {
    use std::ffi::c_void;
    use windows_sys::Win32::System::DataExchange::{
        CloseClipboard, GetClipboardData, IsClipboardFormatAvailable, OpenClipboard,
    };

    #[link(name = "shell32")]
    extern "system" {
        fn DragQueryFileW(drop: *mut c_void, index: u32, buffer: *mut u16, capacity: u32) -> u32;
    }
    const FILE_DROP: u32 = 15;
    struct ClipboardLease;
    impl Drop for ClipboardLease {
        fn drop(&mut self) {
            // SAFETY: this lease exists only after a successful OpenClipboard.
            unsafe { CloseClipboard() };
        }
    }
    // SAFETY: clipboard handles remain owned by Windows. No pointer survives the
    // lease, and DragQueryFileW copies at most the bounded UTF-16 buffer length.
    unsafe {
        if IsClipboardFormatAvailable(FILE_DROP) == 0 {
            return Ok(Vec::new());
        }
        if OpenClipboard(std::ptr::null_mut()) == 0 {
            return Err("agent.composer.clipboardBusy");
        }
        let _lease = ClipboardLease;
        let drop = GetClipboardData(FILE_DROP);
        if drop.is_null() {
            return Ok(Vec::new());
        }
        let count = DragQueryFileW(drop, u32::MAX, std::ptr::null_mut(), 0);
        if count > 32 {
            return Err("agent.composer.tooManyFiles");
        }
        let mut paths = Vec::new();
        for index in 0..count {
            let length = DragQueryFileW(drop, index, std::ptr::null_mut(), 0);
            if length == 0 || length >= 32768 {
                return Err("agent.context.unavailable");
            }
            let mut buffer = vec![0; length as usize + 1];
            if DragQueryFileW(drop, index, buffer.as_mut_ptr(), buffer.len() as u32) != length {
                return Err("agent.context.unavailable");
            }
            let path = String::from_utf16(&buffer[..length as usize])
                .map_err(|_| "agent.context.unavailable")?;
            if !std::path::Path::new(&path).is_file() {
                return Err("agent.context.unavailable");
            }
            paths.push(path);
        }
        Ok(paths)
    }
}

#[cfg(not(windows))]
#[tauri::command]
pub fn agent_clipboard_file_paths() -> Result<Vec<String>, &'static str> {
    Ok(Vec::new())
}
