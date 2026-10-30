//! 最近项目列表的持久化。
//!
//! 存储格式是 `serde_json` 生成的字符串数组，数组顺序就是最近打开顺序
//! （最近的在最前）。读取失败、内容损坏或不是 UTF-8 时统一降级为空列表，
//! 避免平台层错误阻断启动。

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

/// 最近项目最多保留的条数，与 macOS 现有实现保持一致。
const MAX_RECENT_PROJECTS: usize = 20;
const STORE_FILE_NAME: &str = "recent-projects.json";

/// 读取最近项目。
///
/// 文件不存在、不可读、不是 UTF-8 或 JSON 损坏时都返回空列表；这些情况都
/// 视为“没有历史记录”。损坏的文件不会被立刻重写，等下一次成功调用
/// [`remember`] 时自然覆盖。
pub(crate) fn load() -> Vec<PathBuf> {
    let Some(path) = store_file_path() else {
        return Vec::new();
    };
    let Ok(text) = fs::read_to_string(&path) else {
        return Vec::new();
    };
    let Ok(paths) = serde_json::from_str::<Vec<String>>(&text) else {
        return Vec::new();
    };
    dedupe(paths.into_iter().map(PathBuf::from))
}

/// 把项目移到列表最前面并落盘。
///
/// 去重按 `PathBuf` 精确比较；空路径和非 UTF-8 路径无法写入 JSON，直接忽略，
/// 以免内存列表与磁盘内容不一致。任何 I/O 失败都静默丢弃，不向上抛错。
pub(crate) fn remember(project: &Path) {
    if project.as_os_str().is_empty() || project.to_str().is_none() {
        return;
    }

    let mut projects = load();
    projects.retain(|existing| existing != project);
    projects.insert(0, project.to_path_buf());
    projects.truncate(MAX_RECENT_PROJECTS);
    save(&projects);
}

fn store_file_path() -> Option<PathBuf> {
    app_data_dir().map(|directory| directory.join(STORE_FILE_NAME))
}

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

/// 未知平台：没有专属目录约定，退回 XDG，保证最近项目仍然可用。
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

/// 保序去重，并截断到上限。
fn dedupe(projects: impl IntoIterator<Item = PathBuf>) -> Vec<PathBuf> {
    let mut unique = Vec::new();
    for project in projects {
        if project.as_os_str().is_empty() {
            continue;
        }
        if unique.iter().any(|existing| existing == &project) {
            continue;
        }
        unique.push(project);
        if unique.len() >= MAX_RECENT_PROJECTS {
            break;
        }
    }
    unique
}

fn save(projects: &[PathBuf]) {
    let Some(directory) = app_data_dir() else {
        return;
    };
    // 目录创建失败时直接放弃持久化，欢迎页仍可用本次会话内的内存结果。
    if fs::create_dir_all(&directory).is_err() {
        return;
    }

    // 非 UTF-8 路径无法在 JSON 字符串中无损表示，跳过而不是写入有损值。
    let values: Vec<&str> = projects
        .iter()
        .filter_map(|project| project.to_str())
        .collect();
    let Ok(payload) = serde_json::to_string(&values) else {
        return;
    };

    let target = directory.join(STORE_FILE_NAME);
    // 临时文件带进程号，降低多个实例同时写入时互相踩踏的概率。
    let temporary = directory.join(format!(".{STORE_FILE_NAME}.{}.tmp", std::process::id()));

    if fs::write(&temporary, payload.as_bytes()).is_err() {
        let _ = fs::remove_file(&temporary);
        return;
    }

    // 同一目录内的 rename 是原子替换；失败时清理临时文件并保留旧列表。
    // Windows 上 std::fs::rename 会替换已存在的目标文件。
    if fs::rename(&temporary, &target).is_err() {
        let _ = fs::remove_file(&temporary);
    }
}
