//! 按工作区持久化锚点工具窗布局。
//!
//! 文件位于平台应用数据目录下的 `workspace-layout.json`：
//!
//! - Windows：`%APPDATA%\Lithe\workspace-layout.json`
//! - macOS：`$HOME/Library/Application Support/Lithe/workspace-layout.json`
//! - Linux：`$XDG_CONFIG_HOME/lithe/workspace-layout.json`，否则
//!   `$HOME/.config/lithe/workspace-layout.json`
//!
//! 结构是一个按项目根路径索引的对象；每个工作区记录三个锚点的活动工具窗、
//! 可见性以及尺寸。读取失败、JSON 损坏或版本不符时整体退回默认布局，不向
//! 上抛错；写入使用临时文件 + rename，避免进程中断留下半个 JSON。
//!
//! 当前编辑器标签和活动标签暂不持久化：恢复它们需要重新读盘，超出了本次
//! 锚点布局重构的范围。

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use gpui_kit::private::serde_json::{self, Value, json};

const STORE_FILE_NAME: &str = "workspace-layout.json";
const STORE_VERSION: u64 = 1;
const DEFAULT_LEFT_WIDTH: f32 = 300.0;
const DEFAULT_RIGHT_WIDTH: f32 = 320.0;
const DEFAULT_BOTTOM_HEIGHT: f32 = 260.0;

/// 一个工作区的锚点布局偏好。
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct WorkspaceLayout {
    /// 左侧活动工具窗 id。
    pub active_left: String,
    /// 底部活动工具窗 id；`None` 表示从未打开过底部 dock。
    pub active_bottom: Option<String>,
    /// 右侧活动工具窗 id。
    pub active_right: Option<String>,
    pub left_visible: bool,
    pub bottom_visible: bool,
    pub right_visible: bool,
    pub left_width: f32,
    pub right_width: f32,
    pub bottom_height: f32,
}

impl Default for WorkspaceLayout {
    fn default() -> Self {
        Self {
            active_left: "project".to_string(),
            active_bottom: None,
            active_right: None,
            left_visible: true,
            bottom_visible: false,
            right_visible: false,
            left_width: DEFAULT_LEFT_WIDTH,
            right_width: DEFAULT_RIGHT_WIDTH,
            bottom_height: DEFAULT_BOTTOM_HEIGHT,
        }
    }
}

/// 读取某个工作区的布局。缺失或损坏时返回默认值。
pub(crate) fn load(project_root: &Path) -> WorkspaceLayout {
    let Some(key) = workspace_key(project_root) else {
        return WorkspaceLayout::default();
    };
    let Some(store) = read_store() else {
        return WorkspaceLayout::default();
    };
    store
        .get("workspaces")
        .and_then(Value::as_object)
        .and_then(|workspaces| workspaces.get(&key))
        .map(layout_from_value)
        .unwrap_or_default()
}

/// 保存某个工作区的布局；保留同一文件中其他工作区的记录。
pub(crate) fn save(project_root: &Path, layout: &WorkspaceLayout) {
    let Some(key) = workspace_key(project_root) else {
        return;
    };
    let Some(directory) = app_data_dir() else {
        return;
    };
    let Some(path) = store_file_path() else {
        return;
    };

    // 已有文件损坏时从空表开始，不把坏内容继续写回去。
    let mut store = read_store().unwrap_or_else(|| json!({ "version": STORE_VERSION }));
    if store
        .get("version")
        .and_then(Value::as_u64)
        .unwrap_or_default()
        != STORE_VERSION
    {
        store = json!({ "version": STORE_VERSION, "workspaces": {} });
    }
    let Some(root) = store.as_object_mut() else {
        return;
    };
    let Some(workspaces) = root
        .entry("workspaces")
        .or_insert_with(|| Value::Object(Default::default()))
        .as_object_mut()
    else {
        return;
    };
    workspaces.insert(key, layout_to_value(layout));

    // 非 UTF-8 的目录或项目路径无法可靠写入，放弃本次持久化。
    let Ok(payload) = serde_json::to_string(&store) else {
        return;
    };
    if fs::create_dir_all(&directory).is_err() {
        return;
    }

    // 临时文件带进程号，降低多实例同时写入时互相踩踏的概率。
    let temporary = directory.join(format!(".{STORE_FILE_NAME}.{}.tmp", std::process::id()));
    if fs::write(&temporary, payload.as_bytes()).is_err() {
        let _ = fs::remove_file(&temporary);
        return;
    }

    // Windows 上 rename 不会覆盖已存在的目标；先尝试原子 rename，失败时
    // 删除旧文件后再试一次。两步之间崩溃只会丢失布局偏好，不会损坏其他文件。
    if fs::rename(&temporary, &path).is_err() {
        let _ = fs::remove_file(&path);
        if fs::rename(&temporary, &path).is_err() {
            let _ = fs::remove_file(&temporary);
        }
    }
}

fn layout_from_value(value: &Value) -> WorkspaceLayout {
    let defaults = WorkspaceLayout::default();
    WorkspaceLayout {
        active_left: string_field(value, "activeLeft")
            .unwrap_or_else(|| defaults.active_left.clone()),
        active_bottom: string_field(value, "activeBottom"),
        active_right: string_field(value, "activeRight"),
        left_visible: bool_field(value, "leftVisible").unwrap_or(defaults.left_visible),
        bottom_visible: bool_field(value, "bottomVisible").unwrap_or(defaults.bottom_visible),
        right_visible: bool_field(value, "rightVisible").unwrap_or(defaults.right_visible),
        left_width: number_field(value, "leftWidth").unwrap_or(defaults.left_width),
        right_width: number_field(value, "rightWidth").unwrap_or(defaults.right_width),
        bottom_height: number_field(value, "bottomHeight").unwrap_or(defaults.bottom_height),
    }
}

fn layout_to_value(layout: &WorkspaceLayout) -> Value {
    json!({
        "activeLeft": layout.active_left,
        "activeBottom": layout.active_bottom,
        "activeRight": layout.active_right,
        "leftVisible": layout.left_visible,
        "bottomVisible": layout.bottom_visible,
        "rightVisible": layout.right_visible,
        "leftWidth": layout.left_width,
        "rightWidth": layout.right_width,
        "bottomHeight": layout.bottom_height,
    })
}

fn string_field(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_string)
}

fn bool_field(value: &Value, key: &str) -> Option<bool> {
    value.get(key).and_then(Value::as_bool)
}

fn number_field(value: &Value, key: &str) -> Option<f32> {
    value
        .get(key)
        .and_then(Value::as_f64)
        .filter(|number| number.is_finite())
        .map(|number| number as f32)
}

fn read_store() -> Option<Value> {
    let path = store_file_path()?;
    let text = fs::read_to_string(path).ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    // 版本不符时不猜测旧字段含义，直接当没有记录。
    if value.get("version").and_then(Value::as_u64) != Some(STORE_VERSION) {
        return None;
    }
    Some(value)
}

/// 项目根在 JSON 里的 key。统一分隔符，并在 Windows 上折叠大小写，
/// 让同一目录因写法不同仍能命中同一条记录。
fn workspace_key(project_root: &Path) -> Option<String> {
    let text = project_root.to_str()?;
    let key = if cfg!(windows) {
        text.replace('\\', "/").to_lowercase()
    } else {
        text.replace('\\', "/")
    };
    (!key.is_empty()).then_some(key)
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

/// 未知平台：没有专属目录约定，退回 XDG。
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
