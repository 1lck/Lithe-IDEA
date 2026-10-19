//! Exclusive publication of flushed files in the same writable directory.
#[cfg(not(windows))]
use std::fs;
use std::path::Path;

#[cfg(windows)]
pub(crate) fn publish_new_record(from: &Path, to: &Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{MoveFileExW, MOVEFILE_WRITE_THROUGH};
    let from: Vec<u16> = from.as_os_str().encode_wide().chain(Some(0)).collect();
    let to: Vec<u16> = to.as_os_str().encode_wide().chain(Some(0)).collect();
    // No replacement or cross-volume copy; also works on FAT/exFAT.
    if unsafe { MoveFileExW(from.as_ptr(), to.as_ptr(), MOVEFILE_WRITE_THROUGH) } == 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(not(windows))]
pub(crate) fn publish_new_record(from: &Path, to: &Path) -> std::io::Result<()> {
    fs::hard_link(from, to)
}
