//! 进程内存占用。
//!
//! 状态栏的内存项用它显示当前 Lithe 进程的 resident memory。读取失败返回
//! `None`，状态栏显示 `—`，不影响其他功能。

/// 当前进程的 resident memory（字节）。
pub fn process_memory_bytes() -> Option<u64> {
    // memory-stats 的 physical_mem 在各平台分别对应 RSS / Working Set。
    memory_stats::memory_stats().map(|stats| stats.physical_mem as u64)
}

/// 把字节格式化成紧凑的 MB 文本，例如 `312 MB`。
pub fn format_memory(bytes: u64) -> String {
    const MIB: f64 = 1024.0 * 1024.0;
    let mib = bytes as f64 / MIB;
    if mib >= 1024.0 {
        format!("{:.1} GB", mib / 1024.0)
    } else {
        format!("{mib:.0} MB")
    }
}
