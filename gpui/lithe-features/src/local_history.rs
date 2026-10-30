//! 本地历史（File > Local History）快照存储。
//!
//! 每次保存成功后把整份文本落一份快照，存放于应用数据目录下的
//! `local-history/<hash>/<unix_millis>.txt`。目录约定与
//! [`crate::settings`] 一致：Windows `%APPDATA%\Lithe`、macOS
//! `$HOME/Library/Application Support/Lithe`、Linux `$XDG_CONFIG_HOME/lithe`
//! （未设置时退回 `$HOME/.config/lithe`）。
//!
//! 这里只做「尽力而为」的旁路记录：任何 I/O 失败都静默丢弃，不写日志也不
//! panic。原因是快照属于附加能力，保存本身才是用户真正发起的动作；如果快照
//! 失败（磁盘满、目录无权限、路径过长）把错误冒泡出去，用户会看到一次明明
//! 已经写盘成功的保存被报成失败，甚至阻断编辑。旁路能力不能反过来伤害主流程。
//!
//! 每个文件一个哈希目录，而不是把所有快照堆在同一目录：这样按路径查历史
//! 只需读一个目录，裁剪旧快照、删除某文件历史都能局部完成，也不会因为不同
//! 文件的同名毫秒时间戳互相覆盖。哈希取绝对路径，避免同一个文件因工作区
//! 相对路径不同而被拆成多份历史。

use std::collections::hash_map::DefaultHasher;
use std::env;
use std::fs;
use std::hash::{Hash as _, Hasher as _};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// 一次本地历史快照。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snapshot {
    /// 快照写入时间。
    pub recorded: std::time::SystemTime,
    /// 快照文件路径。
    pub path: std::path::PathBuf,
}

/// 每个文件最多保留多少份。
pub const KEEP_PER_FILE: usize = 50;

/// 本地历史根目录名。
const HISTORY_DIR_NAME: &str = "local-history";
/// 快照文件扩展名；`snapshots` 只认这个后缀。
const SNAPSHOT_EXT: &str = "txt";

/// 保存成功后记录一份快照；失败静默（本地历史不能影响保存主流程）。
pub fn record(target: &std::path::Path, text: &str) {
    let Some(directory) = history_dir(target) else {
        return;
    };
    // 目录可能还不存在（第一次记录），也可能刚被用户清空，直接创建即可。
    if fs::create_dir_all(&directory).is_err() {
        return;
    }
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis())
        .unwrap_or(0);
    let path = directory.join(format!("{millis}.{SNAPSHOT_EXT}"));
    // 同一毫秒内重复保存会覆盖同名快照，这是可接受的：文件内容本来就相同
    // 或极接近，没必要为此引入额外序号破坏「文件名即时间戳」的约定。
    if fs::write(&path, text).is_err() {
        return;
    }
    prune(&directory);
}

/// 某个文件的历史快照，按时间倒序（最新在前）。
pub fn snapshots(target: &std::path::Path) -> Vec<Snapshot> {
    let Some(directory) = history_dir(target) else {
        return Vec::new();
    };
    let Ok(entries) = fs::read_dir(&directory) else {
        return Vec::new();
    };
    let mut list = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some(SNAPSHOT_EXT) {
            continue;
        }
        // 文件名是毫秒时间戳；无法解析的（用户手动放进去的文件）一律跳过。
        let Some(millis) = path
            .file_stem()
            .and_then(|stem| stem.to_str())
            .and_then(|stem| stem.parse::<u64>().ok())
        else {
            continue;
        };
        list.push(Snapshot {
            recorded: UNIX_EPOCH + Duration::from_millis(millis),
            path,
        });
    }
    sort_snapshots(&mut list);
    list
}

/// 读取快照内容。
pub fn read(snapshot: &std::path::Path) -> Option<String> {
    fs::read_to_string(snapshot).ok()
}

/// 把 SystemTime 格式化为 `YYYY-MM-DD HH:MM:SS`（本地时区偏移不做处理，用 UTC）。
pub fn format_time(time: std::time::SystemTime) -> String {
    // 早于 Unix 纪元的时间没有意义（快照时间总是 now），统一按 0 处理。
    let seconds = time
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or(0);
    let days = (seconds / 86_400) as i64;
    let rest = seconds % 86_400;
    let (year, month, day) = civil_from_days(days);
    let hour = rest / 3_600;
    let minute = (rest % 3_600) / 60;
    let second = rest % 60;
    format!("{year:04}-{month:02}-{day:02} {hour:02}:{minute:02}:{second:02}")
}

/// 按记录时间倒序排列；单独拆出来便于测试纯排序逻辑。
fn sort_snapshots(list: &mut [Snapshot]) {
    list.sort_by_key(|snapshot| std::cmp::Reverse(snapshot.recorded));
}

/// 生成某个文件的历史目录；没有应用数据目录时返回 `None`。
fn history_dir(target: &Path) -> Option<PathBuf> {
    let absolute = absolute_path(target);
    let directory = app_data_dir()?
        .join(HISTORY_DIR_NAME)
        .join(path_hash(&absolute));
    Some(directory)
}

/// 相对路径先补成绝对路径，保证同一个文件始终落到同一个哈希目录。
fn absolute_path(target: &Path) -> PathBuf {
    if target.is_absolute() {
        return target.to_path_buf();
    }
    env::current_dir()
        .map(|current| current.join(target))
        .unwrap_or_else(|_| target.to_path_buf())
}

/// 用 `DefaultHasher` 对绝对路径字符串求十六进制哈希。
///
/// `DefaultHasher::new()` 不带随机种子，跨进程稳定，因此目录名在重启后仍然
/// 指向同一份历史；哈希只用于分目录，碰撞时最多是两份历史混在同一目录，
/// 不会读错或覆盖用户文件。
fn path_hash(path: &Path) -> String {
    let text = path.to_string_lossy();
    let mut hasher = DefaultHasher::new();
    text.hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

/// 超过 [`KEEP_PER_FILE`] 时按文件名（即时间）升序删最旧的。
fn prune(directory: &Path) {
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    let mut files: Vec<(u64, PathBuf)> = entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            if path.extension().and_then(|ext| ext.to_str()) != Some(SNAPSHOT_EXT) {
                return None;
            }
            let millis = path
                .file_stem()
                .and_then(|stem| stem.to_str())
                .and_then(|stem| stem.parse::<u64>().ok())?;
            Some((millis, path))
        })
        .collect();
    if files.len() <= KEEP_PER_FILE {
        return;
    }
    files.sort_by_key(|(millis, _)| *millis);
    let excess = files.len() - KEEP_PER_FILE;
    for (_, path) in files.into_iter().take(excess) {
        let _ = fs::remove_file(path);
    }
}

/// 应用数据目录；与 [`crate::settings`] 的约定保持一致。
///
/// macOS：`$HOME/Library/Application Support/Lithe`。
#[cfg(target_os = "macos")]
fn app_data_dir() -> Option<PathBuf> {
    env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join("Library/Application Support/Lithe"))
}

/// Windows：`%APPDATA%\Lithe`。
#[cfg(target_os = "windows")]
fn app_data_dir() -> Option<PathBuf> {
    env::var_os("APPDATA").map(|appdata| PathBuf::from(appdata).join("Lithe"))
}

/// Linux：`$XDG_CONFIG_HOME/lithe`，否则 `$HOME/.config/lithe`。
#[cfg(target_os = "linux")]
fn app_data_dir() -> Option<PathBuf> {
    xdg_config_lithe()
}

/// 未知平台：没有专属目录约定，退回 XDG，保证本地历史仍然可用。
#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
fn app_data_dir() -> Option<PathBuf> {
    xdg_config_lithe()
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn xdg_config_lithe() -> Option<PathBuf> {
    // 空字符串在 XDG 规范里等价于未设置，需要忽略。
    let base = env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|path| !path.as_os_str().is_empty())
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")));
    base.map(|directory| directory.join("lithe"))
}

/// Howard Hinnant 的 `civil_from_days`：把「Unix 纪元起的天数」还原成
/// (年, 月, 日)。不引入 chrono，避免为一次格式化拖入整条时间依赖。
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let shifted = days + 719_468;
    let era = if shifted >= 0 {
        shifted
    } else {
        shifted - 146_096
    } / 146_097;
    let day_of_era = (shifted - era * 146_097) as u64; // [0, 146096]
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era as i64 + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = (day_of_year - (153 * month_prime + 2) / 5 + 1) as u32;
    let month = if month_prime < 10 {
        month_prime + 3
    } else {
        month_prime - 9
    } as u32;
    let year = year + i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 纪元原点必须格式化成 1970 年元旦零点。
    #[test]
    fn format_time_epoch() {
        assert_eq!(format_time(UNIX_EPOCH), "1970-01-01 00:00:00");
    }

    /// 已知时间戳 1_700_000_000 秒 = 2023-11-14 22:13:20 UTC。
    #[test]
    fn format_time_known_timestamp() {
        let time = UNIX_EPOCH + Duration::from_secs(1_700_000_000);
        assert_eq!(format_time(time), "2023-11-14 22:13:20");
    }

    /// 排序辅助函数必须把乱序输入整理成时间倒序。
    #[test]
    fn sort_snapshots_orders_newest_first() {
        let build = |offset: u64| Snapshot {
            recorded: UNIX_EPOCH + Duration::from_millis(offset),
            path: PathBuf::from(format!("{offset}.txt")),
        };
        let mut list = vec![build(300), build(100), build(500), build(200)];
        sort_snapshots(&mut list);
        let order: Vec<u64> = list
            .iter()
            .map(|snapshot| {
                snapshot
                    .recorded
                    .duration_since(UNIX_EPOCH)
                    .map(|elapsed| elapsed.as_millis() as u64)
                    .unwrap_or(0)
            })
            .collect();
        assert_eq!(order, vec![500, 300, 200, 100]);
    }
}
