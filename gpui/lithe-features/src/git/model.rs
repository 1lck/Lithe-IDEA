//! Git 面板的 Core 响应模型与解析辅助。
//!
//! 拆分自原 `git.rs`：本文件只承载「Core 数据 → 本地 camelCase 结构体」的
//! 解析层与视图常量，不包含任何渲染与动作逻辑。`lithe-features` 的直接依赖
//! 只有 `serde_json`，没有 `serde`，因此全部字段用 `parse_*` 从 `Value`
//! 读取，不为一个视图给 crate 增加 serde 派生依赖。

use std::path::{Path, PathBuf};

use gpui_kit::{Hsla, Rgba};
use lithe_ui::i18n::tr;
use serde_json::Value;

use super::ChangeGroup;

pub(crate) fn hex(hex: u32) -> Hsla {
    let r = ((hex >> 16) & 0xff) as f32 / 255.0;
    let g = ((hex >> 8) & 0xff) as f32 / 255.0;
    let b = (hex & 0xff) as f32 / 255.0;
    Rgba { r, g, b, a: 1.0 }.into()
}

// --- 视图内部派生尺寸 ------------------------------------------------------
// LitheMetrics 是跨工具窗共享的刻度；下面这些只属于 Git 面板，因此留在本模块，
// 避免为了一个视图去扩充冻结的 `lithe-ui` 契约。
/// 单个变更行的高度；两行文本（文件名 + 路径）需要比树行略高。
pub(crate) const CHANGE_ROW_HEIGHT: f32 = 38.0;
/// 分组标题行高度。
pub(crate) const GROUP_HEADER_HEIGHT: f32 = 26.0;
/// 工具条状态行（错误/提示）高度。
pub(crate) const STATUS_LINE_HEIGHT: f32 = 22.0;
/// 提交区消息输入框的默认高度（对应 Tauri `COMMIT_MESSAGE_DEFAULT_HEIGHT`）。
pub(crate) const COMMIT_MESSAGE_HEIGHT: f32 = 92.0;
/// 提交区元信息行高度（Amend / AI / 文件计数）。
pub(crate) const COMMIT_METADATA_HEIGHT: f32 = 24.0;
/// 提交按钮行高度。
pub(crate) const COMMIT_ACTIONS_HEIGHT: f32 = 32.0;
/// 提交区左右内边距（对应 Tauri `padding: 3px 11px 6px`）。
pub(crate) const COMMIT_PADDING_X: f32 = 11.0;
/// IntelliJ 提交输入框的圆角与边框宽度。
pub(crate) const COMMIT_INPUT_RADIUS: f32 = 4.0;
/// 日志条目高度。
#[allow(dead_code)]
pub(crate) const LOG_ROW_HEIGHT: f32 = 40.0;
/// 刷新 / 提交等动作的横向内边距。
pub(crate) const ACTION_HORIZONTAL_PADDING: f32 = 10.0;
/// 变更工具栏高度（对应 Tauri `h-10`）。
pub(crate) const CHANGES_TOOLBAR_HEIGHT: f32 = 40.0;
/// 变更工具栏里的图标按钮尺寸（对应 Tauri `size-[22px]`）。
pub(crate) const CHANGES_TOOLBAR_BUTTON_SIZE: f32 = 22.0;
/// Stash 列表行高度。
pub(crate) const STASH_ROW_HEIGHT: f32 = 36.0;

/// 一次「打开文件」回调。与 `ProjectTree` 保持同一形态。
pub(crate) type OpenFileHandler = std::rc::Rc<dyn Fn(PathBuf, &mut gpui_kit::Window, &mut gpui_kit::App) + 'static>;
/// 「去设置里配置」一类无参回调；与 `SettingsView::on_open_run` 同形。
pub(crate) type OpenHandler = std::rc::Rc<dyn Fn(&mut gpui_kit::Window, &mut gpui_kit::App) + 'static>;
/// 打开提交差异：(commit hash, 相对路径)。
pub(crate) type CommitDiffHandler =
    std::rc::Rc<dyn Fn(String, String, &mut gpui_kit::Window, &mut gpui_kit::App) + 'static>;
/// 打开 Git 管理器对话框（Push/Pull/Branch Manager 等）的回调。
pub(crate) type OpenDialogHandler =
    std::rc::Rc<dyn Fn(super::GitDialogKind, &mut gpui_kit::Window, &mut gpui_kit::App) + 'static>;

/// 视图的两种用途。同一个视图实体类型服务两个工具窗，避免重复实现列表逻辑。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GitPanelMode {
    /// 提交面板：变更树 + 底部提交区。
    Changes,
    /// 提交记录：只有历史列表。
    Log,
}

// --- Core 响应模型（只声明本视图消费的字段） --------------------------------

#[derive(Debug, Clone)]
pub(crate) struct CoreChange {
    pub(crate) path: String,
    pub(crate) original_path: Option<String>,
    pub(crate) status: String,
    pub(crate) staged: bool,
    pub(crate) worktree: bool,
    pub(crate) untracked: bool,
    pub(crate) untracked_file_count: Option<usize>,
    /// Core 对子模块父 gitlink 等无法安全切换暂存状态的条目置 false；
    /// 缺失时按 true 处理，与 macOS 的默认值一致。
    pub(crate) can_toggle_staging: bool,
}

impl CoreChange {
    /// 汇总的未跟踪目录（路径以 `/` 结尾）。
    pub(crate) fn is_untracked_directory(&self) -> bool {
        self.untracked && self.path.ends_with('/')
    }
}

#[derive(Debug, Clone, Default)]
pub(crate) struct CoreStatus {
    pub(crate) branch: Option<String>,
    pub(crate) ahead: usize,
    pub(crate) behind: usize,
    pub(crate) changes: Vec<CoreChange>,
}

/// 提交图例计数（对齐 Tauri `buildCommitLegend`：untracked 计入 added、
/// rename 计入 modified，其余两位码第一位判定）。
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct ChangeStatusCounts {
    pub(crate) added: usize,
    pub(crate) modified: usize,
    pub(crate) deleted: usize,
}

impl ChangeStatusCounts {
    pub(crate) fn from_status(status: Option<&CoreStatus>) -> Self {
        let Some(status) = status else {
            return Self::default();
        };
        let mut counts = Self::default();
        for change in &status.changes {
            if !change.staged && !change.worktree && !change.untracked {
                continue;
            }
            // 已暂存与工作区是两个维度，同一路径可能同时出现；图例按
            // 「将进入提交的集合」计算，优先取暂存态。
            let letter = if change.staged {
                status_letter(change, ChangeGroup::Staged)
            } else {
                status_letter(change, ChangeGroup::Worktree)
            };
            if change.untracked {
                counts.added += 1;
            } else {
                match letter {
                    'A' => counts.added += 1,
                    'D' => counts.deleted += 1,
                    'R' | 'C' => counts.modified += 1,
                    _ => counts.modified += 1,
                }
            }
        }
        counts
    }

    pub(crate) fn total(self) -> usize {
        self.added + self.modified + self.deleted
    }
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub(crate) struct CoreCommit {
    pub(crate) hash: String,
    pub(crate) short_hash: String,
    pub(crate) date: String,
    pub(crate) subject: String,
    pub(crate) author_name: String,
    pub(crate) decorations: String,
    pub(crate) parent_hashes: Vec<String>,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct CoreHistoryPage {
    pub(crate) commits: Vec<CoreCommit>,
}

/// 一条 Git 引用（本地分支 / 远程分支 / 标签）。
///
/// 字段来自 Core `git.references` 的 `GitReferenceResponse`，camelCase 逐条对应。
#[derive(Debug, Clone, Default)]
pub(crate) struct CoreReference {
    pub(crate) full_name: String,
    pub(crate) short_name: String,
    /// `"local"` / `"remote"` / `"tag"`。
    pub(crate) kind: String,
    /// 是否指向提交。标签可能指向 tree/blob；当前 UI 只按提交处理。
    #[allow(dead_code)]
    pub(crate) peels_to_commit: bool,
    pub(crate) is_current: bool,
    /// 上游分支短名。分支动作（push/pull 计数来源）消费。
    pub(crate) upstream_short_name: Option<String>,
    pub(crate) ahead: usize,
    pub(crate) behind: usize,
}

impl CoreReference {
    pub(crate) fn is_local(&self) -> bool {
        self.kind == "local"
    }

    pub(crate) fn is_remote(&self) -> bool {
        self.kind == "remote"
    }

    pub(crate) fn is_tag(&self) -> bool {
        self.kind == "tag"
    }

    /// `origin/feature/x` 里的远端名。
    pub(crate) fn remote_name(&self) -> &str {
        self.full_name
            .strip_prefix("refs/remotes/")
            .and_then(|rest| rest.split('/').next())
            .unwrap_or("")
    }
}

/// 一条 stash 条目（Core `git.stashes` 的 `GitStashResponse`）。
#[derive(Debug, Clone, Default)]
pub(crate) struct CoreStash {
    /// `stash@{n}` 形式的稳定引用。
    pub(crate) reference: String,
    /// 提交对象 id；在另一条 stash 入栈后位置会变，但对象 id 不变。
    pub(crate) oid: String,
    pub(crate) message: String,
    pub(crate) branch: Option<String>,
    pub(crate) date: String,
}

/// 引用树的折叠状态键：分组标题或远端名。
pub(crate) type ExpandedSet = std::collections::HashSet<String>;

#[derive(Debug, Clone, Default)]
pub(crate) struct CoreCommand {
    pub(crate) exit_code: i32,
    pub(crate) output: String,
    pub(crate) stderr: String,
}

// --- 分组 ------------------------------------------------------------------

impl ChangeGroup {
    pub(crate) const ALL: [ChangeGroup; 3] = [
        ChangeGroup::Staged,
        ChangeGroup::Worktree,
        ChangeGroup::Untracked,
    ];

    pub(crate) fn id(self) -> &'static str {
        match self {
            ChangeGroup::Staged => "staged",
            ChangeGroup::Worktree => "worktree",
            ChangeGroup::Untracked => "untracked",
        }
    }

    pub(crate) fn title(self) -> &'static str {
        match self {
            ChangeGroup::Staged => tr("Staged"),
            ChangeGroup::Worktree => tr("Changes"),
            ChangeGroup::Untracked => tr("Untracked"),
        }
    }
}

// --- Core `data` 解析 ------------------------------------------------------
//
// 所有字段都按 camelCase 读取；缺失字段回落为空/0，只有顶层形状不对才报错，
// 这样单个可选字段的变化不会让整个面板变成错误页。

pub(crate) fn parse_status(value: &Value) -> Result<CoreStatus, String> {
    let object = value
        .as_object()
        .ok_or_else(|| "Git status response was not an object".to_string())?;
    let changes = match object.get("changes") {
        Some(Value::Array(items)) => items.iter().map(parse_change).collect(),
        Some(Value::Null) | None => Vec::new(),
        Some(_) => return Err("Git status changes was not an array".to_string()),
    };
    Ok(CoreStatus {
        branch: optional_string(object.get("branch")),
        ahead: usize_field(object.get("ahead")),
        behind: usize_field(object.get("behind")),
        changes,
    })
}

pub(crate) fn parse_change(value: &Value) -> CoreChange {
    CoreChange {
        path: string_field(value.get("path")),
        original_path: optional_string(value.get("originalPath")),
        status: string_field(value.get("status")),
        staged: bool_field(value.get("staged")),
        worktree: bool_field(value.get("worktree")),
        untracked: bool_field(value.get("untracked")),
        untracked_file_count: value
            .get("untrackedFileCount")
            .and_then(Value::as_u64)
            .map(|count| usize::try_from(count).unwrap_or(usize::MAX)),
        // 旧版 Core 不带这个字段，按「可切换」处理。
        can_toggle_staging: value
            .get("canToggleStaging")
            .and_then(Value::as_bool)
            .unwrap_or(true),
    }
}

pub(crate) fn parse_history_page(value: &Value) -> Result<CoreHistoryPage, String> {
    let object = value
        .as_object()
        .ok_or_else(|| "Git history response was not an object".to_string())?;
    let commits = match object.get("commits") {
        Some(Value::Array(items)) => items.iter().map(parse_commit).collect(),
        Some(Value::Null) | None => Vec::new(),
        Some(_) => return Err("Git history commits was not an array".to_string()),
    };
    Ok(CoreHistoryPage { commits })
}

/// 解析 `git.references` 响应的 `references` 数组。
pub(crate) fn parse_references(value: &Value) -> Vec<CoreReference> {
    value
        .get("references")
        .and_then(Value::as_array)
        .map(|items| items.iter().map(parse_reference).collect())
        .unwrap_or_default()
}

pub(crate) fn parse_reference(value: &Value) -> CoreReference {
    CoreReference {
        full_name: string_field(value.get("fullName")),
        short_name: string_field(value.get("shortName")),
        kind: string_field(value.get("kind")),
        peels_to_commit: bool_field(value.get("peelsToCommit")),
        is_current: bool_field(value.get("isCurrent")),
        upstream_short_name: optional_string(value.get("upstreamShortName")),
        ahead: value.get("ahead").and_then(Value::as_u64).unwrap_or(0) as usize,
        behind: value.get("behind").and_then(Value::as_u64).unwrap_or(0) as usize,
    }
}

/// 解析 `git.stashes` 响应的 `stashes` 数组（Git 原生最新在前顺序）。
pub(crate) fn parse_stashes(value: &Value) -> Vec<CoreStash> {
    value
        .get("stashes")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .map(|item| CoreStash {
                    reference: string_field(item.get("reference")),
                    oid: string_field(item.get("oid")),
                    message: string_field(item.get("message")),
                    branch: optional_string(item.get("branch")),
                    date: string_field(item.get("date")),
                })
                .collect()
        })
        .unwrap_or_default()
}

pub(crate) fn parse_commit(value: &Value) -> CoreCommit {
    let parent_hashes = value
        .get("parentHashes")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();
    CoreCommit {
        hash: string_field(value.get("hash")),
        short_hash: string_field(value.get("shortHash")),
        date: string_field(value.get("date")),
        subject: string_field(value.get("subject")),
        author_name: string_field(value.get("authorName")),
        decorations: string_field(value.get("decorations")),
        parent_hashes,
    }
}

pub(crate) fn parse_command(value: &Value) -> Result<CoreCommand, String> {
    let object = value
        .as_object()
        .ok_or_else(|| "Git command response was not an object".to_string())?;
    Ok(CoreCommand {
        exit_code: object
            .get("exitCode")
            .and_then(Value::as_i64)
            .and_then(|code| i32::try_from(code).ok())
            .unwrap_or(-1),
        output: string_field(object.get("output")),
        stderr: string_field(object.get("stderr")),
    })
}

/// Git 失败时的可见文本：优先 stderr，其次兼容字段 `output`，都没有才用动作名。
pub(crate) fn command_failure_detail(command: &CoreCommand, fallback: &str) -> String {
    let stderr = command.stderr.trim();
    let output = command.output.trim();
    let detail = if stderr.is_empty() { output } else { stderr };
    if detail.is_empty() {
        fallback.to_string()
    } else {
        detail.to_string()
    }
}

pub(crate) fn string_field(value: Option<&Value>) -> String {
    value
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

pub(crate) fn optional_string(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).map(str::to_string)
}

pub(crate) fn bool_field(value: Option<&Value>) -> bool {
    value.and_then(Value::as_bool).unwrap_or(false)
}

pub(crate) fn usize_field(value: Option<&Value>) -> usize {
    value
        .and_then(Value::as_u64)
        .map(|number| usize::try_from(number).unwrap_or(usize::MAX))
        .unwrap_or(0)
}

// --- 小工具 ----------------------------------------------------------------

pub(crate) fn normalize_root(root: PathBuf) -> Option<PathBuf> {
    if root.as_os_str().is_empty() {
        None
    } else {
        Some(root)
    }
}

pub(crate) fn root_text(root: &Path) -> Option<String> {
    root.to_str().map(ToString::to_string)
}

pub(crate) fn in_group(change: &CoreChange, group: ChangeGroup) -> bool {
    match group {
        ChangeGroup::Staged => change.staged,
        ChangeGroup::Worktree => change.worktree,
        ChangeGroup::Untracked => change.untracked,
    }
}

pub(crate) fn split_path(path: &str) -> (String, String) {
    match path.rsplit_once('/') {
        Some((directory, file_name)) => (file_name.to_string(), directory.to_string()),
        None => (path.to_string(), String::new()),
    }
}

/// 单字母状态。porcelain v2 的两位码里，暂存组看第一位，工作区组看第二位。
pub(crate) fn status_letter(change: &CoreChange, group: ChangeGroup) -> char {
    if group == ChangeGroup::Untracked || change.untracked {
        return 'U';
    }
    let bytes = change.status.as_bytes();
    let candidate = match group {
        ChangeGroup::Staged => bytes.first().copied(),
        ChangeGroup::Worktree => bytes.get(1).copied(),
        ChangeGroup::Untracked => Some(b'U'),
    }
    .map(|byte| byte as char)
    .unwrap_or('M');
    match candidate {
        ' ' | '?' => 'M',
        other => other,
    }
}

pub(crate) fn status_color(letter: char, untracked: bool, tokens: lithe_ui::LitheTokens) -> Hsla {
    if untracked {
        return tokens.success;
    }
    match letter {
        'A' => tokens.success,
        'D' => tokens.error,
        'R' | 'C' => tokens.link,
        'U' => tokens.warning,
        _ => tokens.warning,
    }
}
