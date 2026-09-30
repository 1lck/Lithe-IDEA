//! Lithe 进程与受管语言服务的内存采样（Linux 平台适配层）。
//!
//! 对齐 Windows 的 `windows/tauri/src-tauri/src/memory.rs`：底部状态栏展示
//! 「Total（应用 + 受管语言服务） · Lithe（应用本体）」两个数字，采样失败时
//! 保留上一次成功值，绝不让采样异常阻塞或破坏工作台。
//!
//! 与 Windows 的差异仅在「受管进程」的定义：Windows 统计同一 WebView2 进程树，
//! Linux 的 UI 是单进程原生渲染，没有等价渲染子进程；这里改为统计 Lithe 进程树
//! 下真正的 JDT LS（Eclipse Equinox）进程，避免把终端、Run/Maven 等用户自启
//! 子进程误计入应用内存。
//!
//! 本模块是**平台适配层**：平台专有代码集中在 `#[cfg(target_os = "linux")]`
//! 的实现里，非 Linux 目标提供一个语义明确的空实现，因此 UI 层（`status_bar`、
//! `view`）只消费平台无关的 [`ProcessMemoryUsage`]，不直接接触任何平台 API。
//! 采样只读 `/proc`，不写任何发行目录（见 AGENTS.md 的运行时只读边界）。

use std::path::PathBuf;

/// 一次内存采样结果（字节）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ProcessMemoryUsage {
    /// Lithe 应用本体的常驻内存（RSS）。
    pub lithe_bytes: u64,
    /// 受管语言服务进程的常驻内存合计。
    pub language_server_bytes: u64,
}

impl ProcessMemoryUsage {
    /// 应用 + 受管语言服务的总内存。
    pub fn total_bytes(&self) -> u64 {
        self.lithe_bytes.saturating_add(self.language_server_bytes)
    }
}

/// JDT LS 进程命令行特征：Eclipse Equinox launcher 的 jar 名。
///
/// 与 `crate::lsp` 使用的 Equinox 前缀同源，但不引用其私有常量，避免把模块
/// 可见性绑死在采样代码上。
pub const JDTLS_PROCESS_SIGNATURE: &str = "org.eclipse.equinox.launcher";

/// `/proc` 根目录；测试可注入临时目录。
#[derive(Debug, Clone)]
pub struct Procfs {
    root: PathBuf,
}

impl Procfs {
    /// 真实系统的 `/proc`。
    #[allow(dead_code)]
    pub fn system() -> Self {
        Self {
            root: PathBuf::from("/proc"),
        }
    }

    /// 指定根目录，用于测试。
    #[allow(dead_code)]
    pub fn at(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// 读取当前进程的常驻内存（字节）。
    ///
    /// 优先用 `/proc/self/statm`（第二字段为常驻页数）；该文件不可用时回退到
    /// `/proc/self/status` 的 `VmRSS`。两者都失败返回 `None`，由调用方保留
    /// 上一次成功值。
    #[allow(dead_code)]
    pub fn current_process_resident_bytes(&self) -> Option<u64> {
        let page_size = page_size_bytes();
        if let Some(pages) = read_resident_pages(&self.root.join("self/statm")) {
            return Some(pages.saturating_mul(page_size));
        }
        read_vm_rss_bytes(&self.root.join("self/status"))
    }

    /// 统计 Lithe 进程树下所有语言服务进程的常驻内存合计。
    ///
    /// 以当前进程为根做一次进程树快照：只有「根的直接/间接子进程」且命令行
    /// 命中语言服务特征（`signature`）时才算作受管语言服务。终端、Run、Maven
    /// 等子进程因为不匹配特征而被排除，与 Windows 只统计 WebView2 树同理。
    #[allow(dead_code)]
    pub fn managed_language_server_bytes(&self, signature: &str) -> u64 {
        let Some(processes) = self.process_snapshot() else {
            return 0;
        };
        let root_pid = std::process::id();
        let owned = owned_descendant_pids(&processes, root_pid, signature);
        owned
            .iter()
            .filter_map(|pid| self.process_resident_bytes(*pid))
            .fold(0_u64, u64::saturating_add)
    }

    /// 读取指定 PID 的常驻内存（字节）。
    fn process_resident_bytes(&self, pid: u32) -> Option<u64> {
        let page_size = page_size_bytes();
        let statm = self.root.join(pid.to_string()).join("statm");
        let pages = read_resident_pages(&statm)?;
        Some(pages.saturating_mul(page_size))
    }

    /// 读取一份 `pid → (父 pid, 命令行)` 快照；`/proc` 不可用时返回 `None`。
    fn process_snapshot(&self) -> Option<std::collections::HashMap<u32, ProcessRecord>> {
        let entries = std::fs::read_dir(&self.root).ok()?;
        let mut processes = std::collections::HashMap::new();
        for entry in entries.flatten() {
            let Some(pid) = entry
                .file_name()
                .to_str()
                .and_then(|name| name.parse::<u32>().ok())
            else {
                continue;
            };
            let dir = entry.path();
            let Some(parent_pid) = read_process_stat(&dir.join("stat")) else {
                continue;
            };
            processes.insert(
                pid,
                ProcessRecord {
                    parent_pid,
                    command_line: read_process_command_line(&dir.join("cmdline")),
                },
            );
        }
        Some(processes)
    }
}

/// 一份进程记录。
#[derive(Debug, Clone, PartialEq, Eq)]
struct ProcessRecord {
    parent_pid: u32,
    /// `cmdline` 以 NUL 分隔的参数拼接文本；无权限读取时为空串。
    command_line: String,
}

/// 计算「根进程树中命中 `signature` 的子进程」PID 集合。
///
/// 抽成纯函数以便测试：先做根的直接子进程过滤（防止把 Lithe 之外的进程树算进来），
/// 再沿 `parent → child` 逐层向下扩展，与 Windows 的 `owned_webview_process_ids`
/// 保持同一语义。
fn owned_descendant_pids(
    processes: &std::collections::HashMap<u32, ProcessRecord>,
    root_pid: u32,
    signature: &str,
) -> Vec<u32> {
    let mut owned: std::collections::HashSet<u32> = processes
        .iter()
        .filter(|(_, record)| {
            record.parent_pid == root_pid && record.command_line.contains(signature)
        })
        .map(|(pid, _)| *pid)
        .collect();

    loop {
        let before = owned.len();
        for (pid, record) in processes {
            if owned.contains(&record.parent_pid) && record.command_line.contains(signature) {
                owned.insert(*pid);
            }
        }
        if owned.len() == before {
            break;
        }
    }

    let mut pids: Vec<u32> = owned.into_iter().collect();
    pids.sort_unstable();
    pids
}

/// 平台页大小（字节）。
#[cfg(target_os = "linux")]
fn page_size_bytes() -> u64 {
    // SAFETY: `sysconf` 只读取系统常量，无副作用。
    let size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    if size > 0 {
        return size as u64;
    }
    4096
}

#[cfg(not(target_os = "linux"))]
fn page_size_bytes() -> u64 {
    4096
}

/// 从 `/proc/<pid>/statm` 解析常驻页数（第二字段）。
fn read_resident_pages(path: &std::path::Path) -> Option<u64> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut fields = text.split_whitespace();
    let _size = fields.next()?;
    fields.next()?.parse::<u64>().ok()
}

/// 从 `/proc/<pid>/status` 解析 `VmRSS`（单位 kB）。
fn read_vm_rss_bytes(path: &std::path::Path) -> Option<u64> {
    let text = std::fs::read_to_string(path).ok()?;
    for line in text.lines() {
        let Some(rest) = line.strip_prefix("VmRSS:") else {
            continue;
        };
        let kilobytes = rest.split_whitespace().next()?.parse::<u64>().ok()?;
        return Some(kilobytes.saturating_mul(1024));
    }
    None
}

/// 从 `/proc/<pid>/stat` 解析父 PID。
///
/// `comm`（第二字段）可能包含空格与括号，必须从行尾最后一个 `)` 之后再切分：
/// 剩余字段依次是 state、ppid…，因此父 PID 是第 2 个 token。
fn read_process_stat(path: &std::path::Path) -> Option<u32> {
    let text = std::fs::read_to_string(path).ok()?;
    let after_comm = text.rsplit_once(')')?.1;
    let mut fields = after_comm.split_whitespace();
    let _state = fields.next()?;
    fields.next()?.parse::<u32>().ok()
}

/// 从 `/proc/<pid>/cmdline` 读取命令行文本（NUL → 空格）。
///
/// 内核线程的 `cmdline` 为空，返回空串即可；权限不足时同样回退为空串，
/// 保证快照不会因为个别进程而整体失败。
fn read_process_command_line(path: &std::path::Path) -> String {
    let Ok(bytes) = std::fs::read(path) else {
        return String::new();
    };
    bytes
        .split(|byte| *byte == 0)
        .filter(|segment| !segment.is_empty())
        .map(|segment| String::from_utf8_lossy(segment))
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::fs;

    fn record(parent_pid: u32, command_line: &str) -> ProcessRecord {
        ProcessRecord {
            parent_pid,
            command_line: command_line.to_string(),
        }
    }

    fn temp_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("lithe-mem-{tag}-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        dir
    }

    #[test]
    fn selects_only_matching_descendants_of_the_root() {
        let mut processes = HashMap::new();
        processes.insert(10, record(1, "lithe-linux"));
        // 根的直接子进程，命中特征。
        processes.insert(
            20,
            record(10, "java -jar org.eclipse.equinox.launcher_1.6.jar"),
        );
        // 间接子进程，命中特征，应被逐层收录。
        processes.insert(
            21,
            record(20, "jdtls worker org.eclipse.equinox.launcher_1.6.jar"),
        );
        // 根的子进程，但未命中特征（终端），必须排除。
        processes.insert(30, record(10, "bash"));
        // 根的子进程下的其它应用的 LS，不能算作 Lithe 的。
        processes.insert(
            40,
            record(30, "java -jar org.eclipse.equinox.launcher_1.6.jar"),
        );
        // 无关进程树。
        processes.insert(
            50,
            record(99, "java -jar org.eclipse.equinox.launcher_1.6.jar"),
        );

        assert_eq!(
            owned_descendant_pids(&processes, 10, JDTLS_PROCESS_SIGNATURE),
            vec![20, 21]
        );
    }

    #[test]
    fn no_matching_descendants_is_empty() {
        let mut processes = HashMap::new();
        processes.insert(10, record(1, "lithe-linux"));
        processes.insert(30, record(10, "bash"));

        assert!(owned_descendant_pids(&processes, 10, JDTLS_PROCESS_SIGNATURE).is_empty());
    }

    #[test]
    fn resident_pages_parses_second_field() {
        let dir = temp_dir("statm");
        let statm = dir.join("statm");
        fs::write(&statm, "4579 480 480 4 0 124 0\n").expect("write statm");

        assert_eq!(read_resident_pages(&statm), Some(480));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn vm_rss_fallback_parses_kilobytes() {
        let dir = temp_dir("vmrss");
        let status = dir.join("status");
        fs::write(&status, "Name:\tlithe\nVmRSS:\t  2560 kB\n").expect("write status");

        assert_eq!(read_vm_rss_bytes(&status), Some(2560 * 1024));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn process_stat_handles_spaces_and_parens_in_comm() {
        let dir = temp_dir("stat");
        let stat = dir.join("stat");
        fs::write(&stat, "42 (my (weird) app) S 7 42 42 0 -1\n").expect("write stat");

        assert_eq!(read_process_stat(&stat), Some(7));

        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn current_process_resident_bytes_is_nonzero_on_linux() {
        // 真实 `/proc` 采样：只断言可读且非零，避免依赖机器内存数值。
        let usage = Procfs::system()
            .current_process_resident_bytes()
            .expect("current process resident memory should be readable on Linux");
        assert!(usage > 0);
    }
}
