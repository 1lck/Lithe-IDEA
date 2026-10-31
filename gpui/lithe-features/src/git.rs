//! Git 工具窗。
//!
//! 交互对齐 Windows/Tauri 的实现（Windows 是提交界面的 SSOT）：
//!
//! - **提交面板**（`Changes`）：单栏纵向布局。顶部是变更工具栏，中间是
//!   按「已暂存 / 工作区 / 未跟踪」分组的变更树，底部是 IntelliJ 提交区
//!   （Amend 行 → 消息输入框 → 校验提示 → 提交 / 提交并推送按钮行）。点击
//!   文件把 diff 交给上层在编辑器中打开，不在面板内再分一栏。
//! - **提交记录**（`Git Log`）：同一个视图的日志模式，只渲染提交历史。
//!
//! # 数据边界
//!
//! Git 的全部业务规则都在 `rust/lithe-core`。本视图只通过
//! `CoreClient::execute_raw` 发送 `git.status`、`git.historyPage` 和
//! `git.command`，并用本地 camelCase 结构体反序列化 `data`，不复制 Core
//! 的规则，也不扩展 `lithe-core-client` 的公开 API。
//!
//! # 异步
//!
//! 所有 Core 调用都是阻塞的，必须在 `cx.background_spawn` 中执行，结果再经
//! `this.update` 回到视图线程。`generation` 在 `set_root` / `refresh` 时递增，
//! 用来丢弃旧工作区仍在飞行中的结果。构造期不发起任务，首次加载由 `Render`
//! 里的 `defer_in` 排到当前 App 借用释放之后。
//!
//! # 路径
//!
//! Core 的 `GitChange.path` 是工作区相对路径。只有回传给上层的「打开文件」
//! 回调才与 `root` 拼成绝对路径。
//!
//! # 变更操作
//!
//! 行内与工具条上的暂存 / 取消暂存 / 丢弃都走 `git.command` 的参数数组：
//! `["add","--",path]`、`["reset","HEAD","--",path]`、`["checkout","--",path]`，
//! 批量操作用 `["add","-A"]` 与 `["reset","HEAD"]`。同一时刻只允许一个写操作，
//! `pending_action` 既挡住重复点击，也是按钮的进行中标记；成功后复用
//! `reload_all` 刷新 status / log，失败则把 Git 的 stderr 留在状态行。
//! 未跟踪项不提供 Discard——那等于删除用户还没纳入版本控制的文件。
//!
//! # Stash 视图
//!
//! 标题栏的「提交 / Stash」分段由工作台提供，本视图只暴露 `set_view`，
//! 收到请求后清空选择并在 Stash 视图给出占位说明，避免伪造尚未接入的
//! stash 命令边界。
//!
//! # Amend
//!
//! 提交区的 Amend 开关只改变 `git.command` 的参数数组：勾选时是
//! `["commit","--amend","-m",message]`，否则保持 `["commit","-m",message]`。
//! 提交成功后开关复位为关闭。
//!
//! # 提交区交互
//!
//! 消息输入是多行 `TextareaState`：`Enter` 换行，`Ctrl/Cmd+Enter` 提交
//! （gpui-base 把这两个组合绑成 `secondary: true` 的 `Enter`，与 Tauri 的
//! `handleKeyDown` 一致）。按钮在「无暂存文件 / 无消息 / 忙碌」时禁用，但键盘
//! 提交仍会留下 `commit_hint` 说明缺什么，用户补上后对应那半提示自动消失。
//!
//! AI 生成按钮只对齐位置与可用性：GPUI 构建没有 HTTP 客户端，生成动作由
//! Agent 面板承担，点击按钮与右侧齿轮都跳到设置页「AI 与提交」。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::checkbox::Checkbox;
use gpui_kit::component::input::{Input, InputEvent, InputState, Textarea, TextareaState};
use gpui_kit::component::menu::{DropdownMenu, PopupMenuItem};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    Anchor, AnyElement, App, AppContext as _, ClickEvent, Context, Div, Entity, FontWeight,
    InteractiveElement as _, IntoElement, ParentElement, Render, SharedString, Stateful,
    StatefulInteractiveElement as _, Styled, Window, anchored, deferred, div, px, white,
};
use lithe_core_client::CoreClient;
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, MONO_FONT_FAMILY, current_tokens, icon};
use serde_json::Value;

fn hex(hex: u32) -> gpui_kit::Hsla {
    let r = ((hex >> 16) & 0xff) as f32 / 255.0;
    let g = ((hex >> 8) & 0xff) as f32 / 255.0;
    let b = (hex & 0xff) as f32 / 255.0;
    gpui_kit::Rgba { r, g, b, a: 1.0 }.into()
}

// --- 视图内部派生尺寸 ------------------------------------------------------
// LitheMetrics 是跨工具窗共享的刻度；下面这些只属于 Git 面板，因此留在本文件，
// 避免为了一个视图去扩充冻结的 `lithe-ui` 契约。
/// 单个变更行的高度；两行文本（文件名 + 路径）需要比树行略高。
const CHANGE_ROW_HEIGHT: f32 = 38.0;
/// 分组标题行高度。
const GROUP_HEADER_HEIGHT: f32 = 26.0;
/// 工具条状态行（错误/提示）高度。
const STATUS_LINE_HEIGHT: f32 = 22.0;
/// 提交区消息输入框的默认高度（对应 Tauri `COMMIT_MESSAGE_DEFAULT_HEIGHT`）。
const COMMIT_MESSAGE_HEIGHT: f32 = 92.0;
/// 提交区元信息行高度（Amend / AI / 文件计数）。
const COMMIT_METADATA_HEIGHT: f32 = 24.0;
/// 提交按钮行高度。
const COMMIT_ACTIONS_HEIGHT: f32 = 32.0;
/// 提交区左右内边距（对应 Tauri `padding: 3px 11px 6px`）。
const COMMIT_PADDING_X: f32 = 11.0;
/// IntelliJ 提交输入框的圆角与边框宽度。
const COMMIT_INPUT_RADIUS: f32 = 4.0;
/// 日志条目高度。
#[allow(dead_code)]
const LOG_ROW_HEIGHT: f32 = 40.0;
/// 刷新 / 提交等动作的横向内边距。
const ACTION_HORIZONTAL_PADDING: f32 = 10.0;
/// 变更工具栏高度（对应 Tauri `h-10`）。
const CHANGES_TOOLBAR_HEIGHT: f32 = 40.0;
/// 变更工具栏里的图标按钮尺寸（对应 Tauri `size-[22px]`）。
const CHANGES_TOOLBAR_BUTTON_SIZE: f32 = 22.0;

/// 一次「打开文件」回调。与 `ProjectTree` 保持同一形态。
type OpenFileHandler = Rc<dyn Fn(PathBuf, &mut Window, &mut App) + 'static>;
/// 「去设置里配置」一类无参回调；与 `SettingsView::on_open_run` 同形。
type OpenHandler = Rc<dyn Fn(&mut Window, &mut App) + 'static>;
/// 打开提交差异：(commit hash, 相对路径)。
type CommitDiffHandler = Rc<dyn Fn(String, String, &mut Window, &mut App) + 'static>;

/// 视图的两种用途。同一个视图实体类型服务两个工具窗，避免重复实现列表逻辑。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GitPanelMode {
    /// 提交面板：变更树 + 底部提交区。
    Changes,
    /// 提交记录：只有历史列表。
    Log,
}

// --- Core 响应模型（只声明本视图消费的字段） --------------------------------
//
// `lithe-features` 的直接依赖只有 `serde_json`，没有 `serde`，因此这里不派生
// `Deserialize`；用下面的 `parse_*` 从 `Value` 读取字段，避免为了一个视图给
// crate 增加依赖。

#[derive(Debug, Clone)]
struct CoreChange {
    path: String,
    original_path: Option<String>,
    status: String,
    staged: bool,
    worktree: bool,
    untracked: bool,
    untracked_file_count: Option<usize>,
    /// Core 对子模块父 gitlink 等无法安全切换暂存状态的条目置 false；
    /// 缺失时按 true 处理，与 macOS 的默认值一致。
    can_toggle_staging: bool,
}

#[derive(Debug, Clone, Default)]
struct CoreStatus {
    branch: Option<String>,
    ahead: usize,
    behind: usize,
    changes: Vec<CoreChange>,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
struct CoreCommit {
    hash: String,
    short_hash: String,
    date: String,
    subject: String,
    author_name: String,
    decorations: String,
    parent_hashes: Vec<String>,
}

#[derive(Debug, Clone, Default)]
struct CoreHistoryPage {
    commits: Vec<CoreCommit>,
}

/// 一条 Git 引用（本地分支 / 远程分支 / 标签）。
///
/// 字段来自 Core `git.references` 的 `GitReferenceResponse`，camelCase 逐条对应。
#[derive(Debug, Clone, Default)]
struct CoreReference {
    full_name: String,
    short_name: String,
    /// `"local"` / `"remote"` / `"tag"`。
    kind: String,
    /// 是否指向提交。标签可能指向 tree/blob；当前 UI 只按提交处理，
    /// 引入标签动作（删除/检出）时必须用它禁用不可用的操作。
    #[allow(dead_code)]
    peels_to_commit: bool,
    is_current: bool,
    /// 上游分支短名。分支动作（push/pull 计数来源）后续会消费。
    #[allow(dead_code)]
    upstream_short_name: Option<String>,
    ahead: usize,
    behind: usize,
}

impl CoreReference {
    fn is_local(&self) -> bool {
        self.kind == "local"
    }

    fn is_remote(&self) -> bool {
        self.kind == "remote"
    }

    fn is_tag(&self) -> bool {
        self.kind == "tag"
    }

    /// `origin/feature/x` 里的远端名。
    fn remote_name(&self) -> &str {
        self.full_name
            .strip_prefix("refs/remotes/")
            .and_then(|rest| rest.split('/').next())
            .unwrap_or("")
    }
}

/// 引用树的折叠状态键：分组标题或远端名。
type ExpandedSet = std::collections::HashSet<String>;

#[derive(Debug, Clone, Default)]
struct CoreCommand {
    exit_code: i32,
    output: String,
    stderr: String,
}

// --- 分组与选择 ------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ChangeGroup {
    Staged,
    Worktree,
    Untracked,
}

impl ChangeGroup {
    const ALL: [ChangeGroup; 3] = [
        ChangeGroup::Staged,
        ChangeGroup::Worktree,
        ChangeGroup::Untracked,
    ];

    fn id(self) -> &'static str {
        match self {
            ChangeGroup::Staged => "staged",
            ChangeGroup::Worktree => "worktree",
            ChangeGroup::Untracked => "untracked",
        }
    }

    fn title(self) -> &'static str {
        match self {
            ChangeGroup::Staged => tr("Staged"),
            ChangeGroup::Worktree => tr("Changes"),
            ChangeGroup::Untracked => tr("Untracked"),
        }
    }
}

/// 变更行上可执行的写操作。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ChangeAction {
    Stage,
    Unstage,
    Discard,
}

impl ChangeAction {
    fn label(self) -> &'static str {
        match self {
            ChangeAction::Stage => tr("Stage"),
            ChangeAction::Unstage => tr("Unstage"),
            ChangeAction::Discard => tr("Discard"),
        }
    }

    fn id(self) -> &'static str {
        match self {
            ChangeAction::Stage => "stage",
            ChangeAction::Unstage => "unstage",
            ChangeAction::Discard => "discard",
        }
    }

    fn success_message(self) -> &'static str {
        match self {
            ChangeAction::Stage => tr("Staged"),
            ChangeAction::Unstage => tr("Unstaged"),
            ChangeAction::Discard => tr("Discarded"),
        }
    }

    /// Git 没有输出时显示的兜底错误。
    fn failure_message(self) -> &'static str {
        match self {
            ChangeAction::Stage => tr("Stage failed"),
            ChangeAction::Unstage => tr("Unstage failed"),
            ChangeAction::Discard => tr("Discard failed"),
        }
    }

    /// `git.command` 的参数数组。路径放在 `--` 之后，避免以 `-` 开头的
    /// 文件名被当成选项，也避免拼 shell。
    fn arguments(self, path: &str) -> Vec<String> {
        match self {
            ChangeAction::Stage => vec!["add".to_string(), "--".to_string(), path.to_string()],
            ChangeAction::Unstage => vec![
                "reset".to_string(),
                "HEAD".to_string(),
                "--".to_string(),
                path.to_string(),
            ],
            ChangeAction::Discard => {
                vec!["checkout".to_string(), "--".to_string(), path.to_string()]
            }
        }
    }
}

/// 正在进行中的写操作。既是重复点击的闸门，也是按钮的进行中标记。
#[derive(Debug, Clone, PartialEq, Eq)]
enum PendingAction {
    Change {
        path: String,
        group: ChangeGroup,
        action: ChangeAction,
    },
    StageAll,
    UnstageAll,
}

impl PendingAction {
    fn arguments(&self) -> Vec<String> {
        match self {
            PendingAction::Change { path, action, .. } => action.arguments(path),
            PendingAction::StageAll => vec!["add".to_string(), "-A".to_string()],
            PendingAction::UnstageAll => vec!["reset".to_string(), "HEAD".to_string()],
        }
    }

    fn success_message(&self) -> &'static str {
        match self {
            PendingAction::Change { action, .. } => action.success_message(),
            PendingAction::StageAll => tr("Staged all changes"),
            PendingAction::UnstageAll => tr("Unstaged all changes"),
        }
    }

    fn failure_message(&self) -> &'static str {
        match self {
            PendingAction::Change { action, .. } => action.failure_message(),
            PendingAction::StageAll => tr("Stage all failed"),
            PendingAction::UnstageAll => tr("Unstage all failed"),
        }
    }
}

/// 当前高亮的变更身份。同一个路径可能同时出现在 Staged 与 Worktree，
/// 因此分组也是身份的一部分。
#[derive(Debug, Clone, PartialEq, Eq)]
struct Selection {
    path: String,
    group: ChangeGroup,
}

/// Git 工具窗。
pub struct GitPanel {
    client: CoreClient,
    /// 本实体服务哪个工具窗；决定渲染提交面板还是提交记录。
    mode: GitPanelMode,
    /// 空路径表示「还没有打开项目」，与 `ProjectTree` 的语义一致。
    root: Option<PathBuf>,
    status: Option<CoreStatus>,
    selected: Option<Selection>,
    history: Vec<CoreCommit>,
    /// 提交消息输入。`TextareaState::new` 需要 `&mut Window`，而公开构造签名
    /// 没有 window，因此延迟到首帧用 `defer_in` 创建。用多行输入对齐 Tauri
    /// 的 `Textarea`：提交说明允许换行，Ctrl/Cmd+Enter 才提交。
    commit_input: Option<Entity<TextareaState>>,
    loading_status: bool,
    loading_history: bool,
    committing: bool,
    /// 下一次提交是否追加 `--amend`；提交成功后复位。
    amend: bool,
    /// 正在执行的暂存 / 取消暂存 / 丢弃；非空时所有写操作按钮禁用。
    pending_action: Option<PendingAction>,
    /// 等待确认的丢弃操作。破坏性操作必须先二次确认，不能一键执行。
    pending_discard: Option<(String, ChangeGroup)>,
    /// 来自设置页的 Git 偏好（workspace.rs 在启动与设置变更时注入）。
    git_confirm_discard: bool,
    git_show_untracked: bool,
    git_show_staged_first: bool,
    /// 可见错误；失败不会 panic，也不会清空已有数据。
    error: Option<SharedString>,
    /// 成功提示（提交完成等）。
    notice: Option<SharedString>,
    /// `set_root` / `refresh` 时递增，丢弃旧根目录的异步结果。
    generation: u64,
    /// 首帧是否还要创建提交输入。
    pending_input_init: bool,
    /// 首帧是否还要加载根目录状态。
    pending_initial_load: bool,
    /// 提交成功后等待在 render 里清空输入。
    pending_clear_message: bool,
    /// AI 提交开关来自设置页（`AppSettings::ai_commit_enabled`）。GPUI 构建
    /// 没有 HTTP 客户端，生成能力本身不接；按钮的可用性仍与 Tauri 一致，
    /// 关掉开关就禁用，避免给出一个点了没反应的按钮。
    ai_commit_enabled: bool,
    /// 键盘提交时的校验提示，对齐 Tauri `commitHint`：按钮本身会被禁用，
    /// 但 Ctrl/Cmd+Enter 仍要告诉用户缺了什么。用户补上对应内容后该部分自动消失。
    commit_hint: Option<CommitHint>,
    /// 提交输入框是否聚焦。`TextareaState` 没有公开的焦点句柄，因此从
    /// `InputEvent::Focus` / `Blur` 里跟踪，用于聚焦时把描边换成强调色。
    commit_focused: bool,
    /// 点「AI 设置」齿轮时打开设置页 AI & Commit 的回调。
    /// 变更列表展示方式：目录分组（true，默认）或平铺列表（false，对齐 Tauri `gitChangesFolderView`）。
    folder_view: bool,
    /// 选中的提交哈希（用于在右侧展示该提交的文件树与正文）。
    selected_commit_hash: Option<String>,
    /// 选中的提交改动文件列表。
    commit_files: Vec<String>,
    /// 是否正在加载选中提交的文件列表。
    loading_commit_files: bool,
    /// 选中文件的工作区相对路径；用于文件树高亮。
    selected_commit_file: Option<String>,
    /// 提交文件树里折叠的目录路径。
    collapsed_commit_dirs: ExpandedSet,
    /// Git Log 左侧选中的分支或引用名称。
    selected_reference: Option<String>,
    /// `git.references` 返回的全部引用；Log 模式的引用树真数据源。
    references: Vec<CoreReference>,
    /// 是否正在加载引用。
    loading_references: bool,
    /// 引用树折叠状态：折叠的分组名 / 远端名。
    collapsed_groups: ExpandedSet,
    /// 提交表文本过滤关键字。
    commit_filter: String,
    /// 提交表过滤作用域。
    commit_filter_scope: CommitFilterScope,
    /// 提交表过滤输入框（惰性创建，需要 Window）。
    filter_input: Option<Entity<InputState>>,
    /// 提交表是否显示分支/标签装饰胶囊。
    show_decorations: bool,
    /// 正在执行的引用 / 历史写操作名称；非空时禁用所有引用动作按钮。
    reference_mutation: Option<&'static str>,
    /// 等待输入的分支操作（新建 / 重命名）及其来源引用。
    branch_prompt: Option<(BranchPromptAction, CoreReference)>,
    /// 分支输入框状态。`branch_prompt` 打开后的下一帧创建（需要 Window）。
    branch_input: Option<Entity<InputState>>,
    /// 等待确认的引用动作。破坏性 / 集成操作必须二次确认，对齐 Tauri
    /// `showConfirmDialog`。
    reference_confirm: Option<ReferenceConfirm>,
    /// 打开中的引用动作菜单。
    /// 右键创建的弹出菜单与其触发位置；渲染期用 `anchored` 挂到前景层。
    reference_menu: Option<(
        Entity<gpui_kit::component::menu::PopupMenu>,
        gpui_kit::Point<gpui_kit::Pixels>,
    )>,
    /// 提交表触发的提交动作（预览 / 确认 / 输入）。
    commit_action: Option<CommitAction>,
    /// 提交行动作菜单。
    commit_menu: Option<(
        Entity<gpui_kit::component::menu::PopupMenu>,
        gpui_kit::Point<gpui_kit::Pixels>,
    )>,
    /// 正在加载历史改写预览。
    loading_rewrite_preview: bool,
    /// 暂存的改写预览（Rewrite 确认时取用）。
    pending_rewrite_preview: Option<Box<RewritePreview>>,
    on_open_ai_settings: Option<OpenHandler>,
    /// 「设置」按钮：打开设置页的 Git 分类（对齐 Tauri `openSettingsDialog("git")`）。
    on_open_git_settings: Option<OpenHandler>,
    /// 点提交改动文件时，在中央编辑区打开该提交的差异。
    on_open_commit_diff: Option<CommitDiffHandler>,
    on_open_file: Option<OpenFileHandler>,
}

/// 提交表文本过滤的作用域（对齐 Tauri `GitLogFilterScope`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CommitFilterScope {
    /// 匹配 subject / 哈希（默认）。
    Text,
    /// 匹配作者名与邮箱。
    Author,
    /// 匹配分支装饰。
    Branch,
}

impl CommitFilterScope {
    /// 工具栏下拉的展示名。
    fn label(self) -> &'static str {
        match self {
            Self::Text => tr("Text"),
            Self::Author => tr("Author"),
            Self::Branch => tr("Branch"),
        }
    }

    /// 该作用域下提交是否命中关键字。空关键字一律命中。
    fn matches(self, commit: &CoreCommit, query: &str) -> bool {
        if query.is_empty() {
            return true;
        }
        match self {
            Self::Author => commit.author_name.to_lowercase().contains(query),
            Self::Branch => commit.decorations.to_lowercase().contains(query),
            Self::Text => {
                commit.subject.to_lowercase().contains(query)
                    || commit.hash.to_lowercase().contains(query)
            }
        }
    }
}

/// 分支输入弹窗的操作类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BranchPromptAction {
    Create,
    Rename,
}

/// `git.historyRewritePreview` 支持的历史改写操作。
///
/// `SquashCommits` 需要提交表多选状态，尚未接入；接入时补上 wire/title。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RewriteOperation {
    UndoCommit,
    EditCommitMessage,
    DeleteCommit,
}

impl RewriteOperation {
    /// Core `git.historyRewritePreview` / `git.write` 的 operation 字段。
    fn wire(self) -> &'static str {
        match self {
            Self::UndoCommit => "undoCommit",
            Self::EditCommitMessage => "editCommitMessage",
            Self::DeleteCommit => "deleteCommit",
        }
    }

    fn title(self) -> &'static str {
        match self {
            Self::UndoCommit => tr("Undo Commit"),
            Self::EditCommitMessage => tr("Edit Commit Message"),
            Self::DeleteCommit => tr("Delete Commit"),
        }
    }
}

/// `git.historyRewritePreview` 响应中 GPUI 消费的字段。
///
/// 单提交动作只关心 `selectedCommits` 的数量；接入 Squash 后再消费
/// 每条的 hash / message。
#[derive(Debug, Clone, Default)]
struct RewritePreview {
    allowed: bool,
    blockers: Vec<String>,
    selected_count: usize,
    suggested_message: String,
    /// 原样回传给 `git.write` 的不可变期望快照。
    expected_state: Option<Value>,
}

impl RewritePreview {
    /// 确认弹窗的摘要文案（对齐 Tauri 改写弹窗显示选中计数的行为）。
    fn affected_commit_summary(&self) -> String {
        format!("{}: {}", tr("Selected commits"), self.selected_count)
    }
}

/// 提交表右键触发的提交动作状态机。
#[derive(Debug, Clone)]
enum CommitAction {
    /// 需要预览确认的历史改写（undo / edit / delete）。
    Rewrite {
        operation: RewriteOperation,
        /// 预览通过后执行用；确认弹窗本身不读。
        #[allow(dead_code)]
        revision: String,
    },
    /// Reset 三选一（soft / mixed / hard）。
    Reset { revision: String },
    /// 直接确认后执行。
    Simple {
        operation: &'static str,
        /// 确认后执行用；弹窗展示只读 title / message。
        #[allow(dead_code)]
        revision: String,
        title: &'static str,
        message: String,
    },
    /// 编辑提交消息：预览已通过，弹窗输入框预填 `suggestedMessage`
    ///（预览数据在 `pending_rewrite_preview`）。
    EditMessageInput {
        /// 执行时回传 Core；输入弹窗本身不读。
        #[allow(dead_code)]
        revision: String,
    },
}

/// 引用树等待确认的结构（对齐 Tauri `showConfirmDialog`）。
#[derive(Debug, Clone)]
struct ReferenceConfirm {
    /// Core `git.write` 的 operation 字段（checkoutAndRebase / merge / rebase /
    /// pull / deleteBranch 等）。
    operation: &'static str,
    reference: CoreReference,
    /// 确认弹窗标题（对齐 Tauri `t("git.log.action.${action}")`）。
    title: &'static str,
    message: String,
    /// 确认后展示的成功提示。
    success: &'static str,
}

/// 引用动作的标题与确认文案 key（对齐 Tauri `t("git.log.action.${action}")`）。
fn reference_action_title(action: &str) -> &'static str {
    match action {
        "checkout" => tr("Checkout"),
        "checkoutAndRebase" => tr("Checkout and Rebase"),
        "rebaseCurrentOnto" => tr("Rebase Current onto Selected"),
        "mergeIntoCurrent" => tr("Merge Selected into Current"),
        "pullRebaseIntoCurrent" => tr("Pull (Rebase) into Current"),
        "pullMergeIntoCurrent" => tr("Pull (Merge) into Current"),
        "update" => tr("Update Selected"),
        "push" => tr("Push"),
        "rename" => tr("Rename"),
        "deleteLocal" => tr("Delete Branch"),
        "deleteRemote" => tr("Delete Remote Branch"),
        "deleteTag" => tr("Delete"),
        "createBranch" => tr("New Branch"),
        _ => tr("Git operation"),
    }
}

/// 引用动作在确认/执行后用于 notice 的短 key：checkoutAndRebase 这类
/// 复合动作的 operation 与展示名不同。
fn reference_action_key(operation: &str) -> &'static str {
    match operation {
        "merge" => "mergeIntoCurrent",
        "rebase" => "rebaseCurrentOnto",
        "pull" => "pullMergeIntoCurrent",
        other => match other {
            "checkoutAndRebase" => "checkoutAndRebase",
            "checkout" => "checkout",
            "deleteBranch" => "deleteLocal",
            "deleteTag" => "deleteTag",
            "createBranch" => "createBranch",
            "renameBranch" => "rename",
            "updateBranch" => "update",
            "push" => "push",
            _ => "checkout",
        },
    }
}

/// 键盘提交失败的原因组合，对齐 Tauri `commitHint`。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct CommitHint {
    no_changes: bool,
    no_message: bool,
}

impl GitPanel {
    /// 提交面板（`ToolWindow::Changes`）。
    pub fn new(client: CoreClient, root: PathBuf, cx: &mut Context<Self>) -> Self {
        Self::with_mode(client, root, GitPanelMode::Changes, cx)
    }

    /// 提交记录（`ToolWindow::GitLog`）。与提交面板共用同一套 Core 边界。
    pub fn new_log(client: CoreClient, root: PathBuf, cx: &mut Context<Self>) -> Self {
        Self::with_mode(client, root, GitPanelMode::Log, cx)
    }

    fn with_mode(
        client: CoreClient,
        root: PathBuf,
        mode: GitPanelMode,
        _cx: &mut Context<Self>,
    ) -> Self {
        let root = normalize_root(root);
        Self {
            client,
            mode,
            pending_initial_load: root.is_some(),
            root,
            status: None,
            selected: None,
            history: Vec::new(),
            commit_input: None,
            loading_status: false,
            loading_history: false,
            committing: false,
            amend: false,
            pending_action: None,
            pending_discard: None,
            git_confirm_discard: true,
            git_show_untracked: true,
            git_show_staged_first: true,
            error: None,
            notice: None,
            generation: 0,
            pending_input_init: true,
            pending_clear_message: false,
            ai_commit_enabled: false,
            commit_hint: None,
            commit_focused: false,
            folder_view: true,
            selected_commit_hash: None,
            commit_files: Vec::new(),
            loading_commit_files: false,
            selected_commit_file: None,
            collapsed_commit_dirs: ExpandedSet::new(),
            selected_reference: None,
            references: Vec::new(),
            loading_references: false,
            collapsed_groups: ExpandedSet::new(),
            commit_filter: String::new(),
            commit_filter_scope: CommitFilterScope::Text,
            filter_input: None,
            show_decorations: true,
            reference_mutation: None,
            branch_prompt: None,
            branch_input: None,
            reference_confirm: None,
            reference_menu: None,
            commit_action: None,
            commit_menu: None,
            loading_rewrite_preview: false,
            pending_rewrite_preview: None,
            on_open_ai_settings: None,
            on_open_git_settings: None,
            on_open_commit_diff: None,
            on_open_file: None,
        }
    }

    /// 切换工作区根。空路径表示关闭项目。
    pub fn set_root(&mut self, root: PathBuf, _window: &mut Window, cx: &mut Context<Self>) {
        self.root = normalize_root(root);
        // 已在 `set_root` 内主动加载，首帧不再重复请求。
        self.pending_initial_load = false;
        self.reload_all(cx);
        cx.notify();
    }

    /// 重新读取 status、history，并清空当前选中与 diff。
    pub fn refresh(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        self.reload_all(cx);
        cx.notify();
    }

    /// 选中某一个提交并异步获取该提交改动的文件列表（`git.commitFiles`）。
    fn select_commit(&mut self, hash: String, cx: &mut Context<Self>) {
        if self.selected_commit_hash.as_ref() == Some(&hash) {
            return;
        }
        self.selected_commit_hash = Some(hash.clone());
        self.commit_files.clear();
        self.loading_commit_files = true;
        let Some(root) = self.root.clone() else {
            return;
        };
        let client = self.client;
        cx.spawn(async move |this, cx| {
            let payload = serde_json::json!({
                "root": root.to_string_lossy(),
                "commit": hash,
            });
            let result = cx
                .background_spawn(async move { client.execute_raw("git.commitFiles", payload) })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.loading_commit_files = false;
                if let Ok(value) = result {
                    if let Some(files) = value.get("files").and_then(Value::as_array) {
                        this.commit_files = files
                            .iter()
                            .filter_map(|item| item.get("path").and_then(Value::as_str))
                            .map(String::from)
                            .collect();
                    }
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }

    /// 选中提交里的一个文件，并请求在**中央编辑区**打开它的差异
    /// （对齐 Tauri `openCommitDiff`：差异是编辑器页，不是 Log 右栏内容）。
    fn select_commit_file(&mut self, path: String, window: &mut Window, cx: &mut Context<Self>) {
        self.selected_commit_file = Some(path.clone());
        let Some(hash) = self.selected_commit_hash.clone() else {
            cx.notify();
            return;
        };
        if let Some(handler) = self.on_open_commit_diff.clone() {
            handler(hash, path, window, cx);
        }
        cx.notify();
    }

    /// 注册「在中央编辑区打开提交差异」的回调。工作台在构造时接线。
    pub fn on_open_commit_diff(
        &mut self,
        handler: impl Fn(String, String, &mut Window, &mut App) + 'static,
    ) {
        self.on_open_commit_diff = Some(Rc::new(handler));
    }

    pub fn on_open_file(&mut self, handler: impl Fn(PathBuf, &mut Window, &mut App) + 'static) {
        self.on_open_file = Some(Rc::new(handler));
    }

    /// 点提交区「AI 设置」齿轮时跳转设置页 AI & Commit。
    pub fn on_open_ai_settings(&mut self, handler: impl Fn(&mut Window, &mut App) + 'static) {
        self.on_open_ai_settings = Some(Rc::new(handler));
    }

    /// 点 Git Log 标题栏「设置」时跳转设置页的 Git 分类。
    pub fn on_open_git_settings(&mut self, handler: impl Fn(&mut Window, &mut App) + 'static) {
        self.on_open_git_settings = Some(Rc::new(handler));
    }

    /// 同步设置页里的 AI 提交开关；关闭时提交区的 AI 按钮一并禁用。
    pub fn set_ai_commit_enabled(&mut self, enabled: bool, cx: &mut Context<Self>) {
        if self.ai_commit_enabled == enabled {
            return;
        }
        self.ai_commit_enabled = enabled;
        cx.notify();
    }

    /// 注入设置页的 Git 偏好（变更分组、丢弃确认、未跟踪显示）。
    pub fn set_git_preferences(
        &mut self,
        folder_view: bool,
        confirm_discard: bool,
        show_untracked: bool,
        show_staged_first: bool,
        cx: &mut Context<Self>,
    ) {
        let changed = self.folder_view != folder_view
            || self.git_confirm_discard != confirm_discard
            || self.git_show_untracked != show_untracked
            || self.git_show_staged_first != show_staged_first;
        if !changed {
            return;
        }
        self.folder_view = folder_view;
        self.git_confirm_discard = confirm_discard;
        self.git_show_untracked = show_untracked;
        self.git_show_staged_first = show_staged_first;
        cx.notify();
    }

    /// 重置派生状态并并发加载 status / history。
    ///
    /// `generation` 只在这里递增；两个请求共用同一个代数，早于本次刷新返回的
    /// 旧结果都会被丢弃。
    fn reload_all(&mut self, cx: &mut Context<Self>) {
        self.generation = self.generation.wrapping_add(1);
        self.status = None;
        self.selected = None;
        self.history.clear();
        self.loading_status = false;
        self.loading_history = false;
        // 若刷新发生在提交请求飞行期间，旧提交结果会因 generation 不匹配被
        // 丢弃；这里同时解除锁定，避免 Commit 按钮永久禁用。
        self.committing = false;
        // 写操作同理：generation 变化后旧结果不会再回来，必须主动解锁。
        self.pending_action = None;
        self.pending_discard = None;
        self.error = None;
        self.notice = None;

        if self.root.is_none() {
            return;
        }
        self.load_status(cx);
        self.load_references(cx);
        self.load_history(cx);
    }

    fn load_status(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root_text(&root) else {
            self.error = Some(SharedString::from(tr("Project path is not valid UTF-8")));
            return;
        };

        let generation = self.generation;
        let client = self.client;
        self.loading_status = true;
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    client.execute_raw(
                        "git.status",
                        serde_json::json!({
                            "root": root_text,
                            "includeIndexOnlyChanges": true,
                        }),
                    )
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.loading_status = false;
                match raw {
                    Ok(value) => match parse_status(&value) {
                        Ok(status) => {
                            this.status = Some(status);
                            this.error = None;
                        }
                        Err(message) => {
                            this.error = Some(SharedString::from(message));
                        }
                    },
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn load_history(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root_text(&root) else {
            return;
        };
        // 选中引用为空 = All branches；否则按完整引用名过滤（refs/heads/test）。
        let reference = self
            .selected_reference
            .as_ref()
            .and_then(|short| self.full_reference_name(short));

        let generation = self.generation;
        let client = self.client;
        self.loading_history = true;
        cx.spawn(async move |this, cx| {
            let mut payload = serde_json::json!({
                "root": root_text,
                "order": "date",
                "limit": 50,
            });
            // 选中引用时按它过滤历史；空 = 全部分支，Core 的 reference 可选。
            if let Some(full_name) = reference {
                payload["reference"] = serde_json::Value::String(full_name);
            }
            let raw = cx
                .background_spawn(async move { client.execute_raw("git.historyPage", payload) })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.loading_history = false;
                match raw {
                    Ok(value) => match parse_history_page(&value) {
                        Ok(page) => {
                            this.history = page.commits;
                        }
                        Err(message) => {
                            this.error = Some(SharedString::from(message));
                        }
                    },
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 把引用树的短名映射回 Core 需要的完整引用名。
    ///
    /// `git.references` 同时返回 `fullName`（refs/heads/test）和
    /// `shortName`（test），树的行 key 用短名，请求历史时换回全名。
    fn full_reference_name(&self, short_name: &str) -> Option<String> {
        self.references
            .iter()
            .find(|reference| reference.short_name == short_name)
            .map(|reference| reference.full_name.clone())
    }

    /// 读取全部引用（本地 / 远程 / 标签），供引用树渲染。
    fn load_references(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root_text(&root) else {
            return;
        };

        let generation = self.generation;
        let client = self.client;
        self.loading_references = true;
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    client.execute_raw("git.references", serde_json::json!({ "root": root_text }))
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.loading_references = false;
                match raw {
                    Ok(value) => {
                        this.references = parse_references(&value);
                        // 首次加载时把当前分支设为树的选中项。
                        if this.selected_reference.is_none() {
                            this.selected_reference = this
                                .references
                                .iter()
                                .find(|reference| reference.is_current)
                                .map(|reference| reference.short_name.clone());
                        }
                    }
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 选中一个变更。与 Tauri 一致，面板内不再渲染补丁；真正打开 diff 由
    /// 双击（`open_change`）交给上层编辑器完成。
    fn select_change(&mut self, selection: Selection, cx: &mut Context<Self>) {
        if self.selected.as_ref() == Some(&selection) {
            return;
        }
        self.selected = Some(selection);
        cx.notify();
    }

    fn open_change(&mut self, path: &str, window: &mut Window, cx: &mut Context<Self>) {
        // 汇总的未跟踪目录不是文件，无法在编辑器里打开。
        if path.ends_with('/') {
            return;
        }
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(handler) = self.on_open_file.clone() else {
            return;
        };
        handler(root.join(path), window, cx);
    }

    /// 是否至少有一个可暂存（工作区或未跟踪）的条目。
    fn can_stage_all(&self) -> bool {
        self.status.as_ref().is_some_and(|status| {
            status
                .changes
                .iter()
                .any(|change| change.can_toggle_staging && (change.worktree || change.untracked))
        })
    }

    /// 是否至少有一个已暂存条目。
    fn can_unstage_all(&self) -> bool {
        self.status.as_ref().is_some_and(|status| {
            status
                .changes
                .iter()
                .any(|change| change.staged && change.can_toggle_staging)
        })
    }

    /// 暂存全部工作区与未跟踪改动。工具窗标题栏的操作菜单复用同一入口。
    pub fn stage_all_changes(&mut self, cx: &mut Context<Self>) {
        self.execute_action(PendingAction::StageAll, cx);
    }

    /// 取消暂存全部条目。工具窗标题栏的操作菜单复用同一入口。
    pub fn unstage_all_changes(&mut self, cx: &mut Context<Self>) {
        self.execute_action(PendingAction::UnstageAll, cx);
    }

    fn apply_change_action(
        &mut self,
        path: String,
        group: ChangeGroup,
        action: ChangeAction,
        cx: &mut Context<Self>,
    ) {
        self.pending_discard = None;
        self.execute_action(
            PendingAction::Change {
                path,
                group,
                action,
            },
            cx,
        );
    }

    /// 丢弃是破坏性操作：默认先记录待确认项，由覆盖层二次确认；设置关闭
    /// 「丢弃前确认」时直接执行。
    fn request_discard(&mut self, path: String, group: ChangeGroup, cx: &mut Context<Self>) {
        if self.pending_action.is_some() || self.committing {
            return;
        }
        if !self.git_confirm_discard {
            self.apply_change_action(path, group, ChangeAction::Discard, cx);
            return;
        }
        self.pending_discard = Some((path, group));
        cx.notify();
    }

    /// 执行一次写操作：先占用 `pending_action`，再在后台调用 `git.command`。
    ///
    /// 成功复用 `reload_all`（status / diff / log 一起刷新），失败把 Git 的
    /// stderr 留在状态行；generation 变化时直接丢弃结果。
    fn execute_action(&mut self, pending: PendingAction, cx: &mut Context<Self>) {
        if self.pending_action.is_some() || self.committing {
            return;
        }
        let Some(root) = self.root.clone() else {
            self.error = Some(SharedString::from(tr("No project open")));
            self.notice = None;
            cx.notify();
            return;
        };
        let Some(root_text) = root_text(&root) else {
            self.error = Some(SharedString::from(tr("Project path is not valid UTF-8")));
            self.notice = None;
            cx.notify();
            return;
        };

        let arguments = pending.arguments();
        let failure = pending.failure_message();
        let success = pending.success_message();
        let generation = self.generation;
        let client = self.client;
        self.pending_action = Some(pending);
        self.error = None;
        self.notice = None;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    client.execute_raw(
                        "git.command",
                        serde_json::json!({
                            "root": root_text,
                            "arguments": arguments,
                        }),
                    )
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.pending_action = None;
                match raw {
                    Ok(value) => match parse_command(&value) {
                        Ok(command) if command.exit_code == 0 => {
                            // reload_all 会清空 error / notice，提示必须放在其后。
                            this.reload_all(cx);
                            this.notice = Some(SharedString::from(success));
                        }
                        Ok(command) => {
                            this.error = Some(SharedString::from(command_failure_detail(
                                &command, failure,
                            )));
                        }
                        Err(message) => {
                            this.error = Some(SharedString::from(message));
                        }
                    },
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn commit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.commit_inner(false, window, cx);
    }

    /// 「提交并推送」先提交，提交成功后再发起一次 `git push`。
    ///
    /// 两步共享同一个 `committing` 锁，任一步失败都把 Git 的 stderr 留在状态行，
    /// 绝不把「提交成功但推送失败」报成整体成功。
    fn commit_and_push(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.commit_inner(true, window, cx);
    }

    fn commit_inner(&mut self, push: bool, _window: &mut Window, cx: &mut Context<Self>) {
        if self.committing || self.pending_action.is_some() {
            return;
        }
        let Some(input) = self.commit_input.clone() else {
            return;
        };
        let message = input.read(cx).value().trim().to_string();
        // 对齐 Tauri `handleCommit`：按钮在缺少文件或消息时禁用，但键盘提交
        // 仍要留下可执行的提示，而不是静默什么都不做。
        let no_changes = self.staged_count() == 0;
        let no_message = message.is_empty();
        if no_changes || no_message {
            self.commit_hint = Some(CommitHint {
                no_changes,
                no_message,
            });
            self.notice = None;
            cx.notify();
            return;
        }
        self.commit_hint = None;
        let Some(root) = self.root.clone() else {
            self.error = Some(SharedString::from(tr("No project open")));
            cx.notify();
            return;
        };
        let Some(root_text) = root_text(&root) else {
            self.error = Some(SharedString::from(tr("Project path is not valid UTF-8")));
            cx.notify();
            return;
        };

        // Amend 只是同一个命令的参数变体；命令边界仍是参数数组，不经过 shell。
        let amend = self.amend;
        let mut arguments = vec!["commit".to_string()];
        if amend {
            arguments.push("--amend".to_string());
        }
        arguments.extend(["-m".to_string(), message]);

        let generation = self.generation;
        let client = self.client;
        self.committing = true;
        self.error = None;
        self.notice = None;
        cx.notify();

        cx.spawn(async move |this, cx| {
            // `git.command` 的边界是参数数组，不经过 shell，消息里的引号/
            // 换行不会被解释成额外命令。
            let raw = cx
                .background_spawn(async move {
                    client.execute_raw(
                        "git.command",
                        serde_json::json!({
                            "root": root_text,
                            "arguments": arguments,
                        }),
                    )
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.committing = false;
                match raw {
                    Ok(value) => match parse_command(&value) {
                        Ok(command) if command.exit_code == 0 => {
                            this.pending_clear_message = true;
                            // 提交成功即复位 Amend，后续提交恢复普通命令。
                            this.amend = false;
                            // status / log 都会在 reload_all 中重新加载；提示放在
                            // reload_all 之后，避免被它清理。
                            this.reload_all(cx);
                            if push {
                                this.push_after_commit(cx);
                            } else {
                                this.notice = Some(SharedString::from(tr("Commit created")));
                            }
                        }
                        Ok(command) => {
                            this.error = Some(SharedString::from(command_failure_detail(
                                &command,
                                tr("Commit failed"),
                            )));
                        }
                        Err(message) => {
                            this.error = Some(SharedString::from(message));
                        }
                    },
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 提交成功之后的推送步骤。失败时保留「已提交」的事实，只报告推送失败。
    fn push_after_commit(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            self.notice = Some(SharedString::from(tr("Commit created")));
            return;
        };
        let Some(root_text) = root_text(&root) else {
            self.notice = Some(SharedString::from(tr("Commit created")));
            return;
        };

        let generation = self.generation;
        let client = self.client;
        self.committing = true;
        self.notice = Some(SharedString::from(tr("Committed; push pending")));

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    client.execute_raw(
                        "git.command",
                        serde_json::json!({
                            "root": root_text,
                            "arguments": ["push"],
                        }),
                    )
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.committing = false;
                match raw {
                    Ok(value) => match parse_command(&value) {
                        Ok(command) if command.exit_code == 0 => {
                            this.notice = Some(SharedString::from(tr("Committed and pushed")));
                            this.error = None;
                        }
                        Ok(command) => {
                            this.error = Some(SharedString::from(command_failure_detail(
                                &command,
                                tr("Push failed"),
                            )));
                            this.notice = Some(SharedString::from(tr("Commit created")));
                        }
                        Err(message) => {
                            this.error = Some(SharedString::from(message));
                            this.notice = Some(SharedString::from(tr("Commit created")));
                        }
                    },
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                        this.notice = Some(SharedString::from(tr("Commit created")));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 丢弃当前选中的变更。工具栏入口没有单文件上下文，因此走确认流程后
    /// 用分组 + 路径还原出完整的 `PendingAction::Change`。
    /// 工具窗标题栏的操作菜单复用同一入口。
    pub fn discard_selected_change(&mut self, cx: &mut Context<Self>) {
        let Some(selection) = self.selected.clone() else {
            return;
        };
        self.request_discard(selection.path, selection.group, cx);
    }

    /// 首帧创建提交输入。`TextareaState::new` 需要 window，因此不能放在 `new`。
    ///
    /// 用多行输入对齐 Tauri 的 `Textarea`：提交说明允许换行，`Ctrl/Cmd+Enter`
    /// 才提交，`Enter` 只换行。gpui-base 的 `Enter` 动作把 `cmd-enter`（macOS）
    /// / `ctrl-enter`（其它平台）绑成 `secondary: true`，正好对应这里的判断。
    fn ensure_commit_input(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.commit_input.is_some() {
            return;
        }
        let input = cx.new(|cx| TextareaState::new(window, cx).placeholder(tr("Commit message")));
        cx.subscribe_in(&input, window, {
            move |this, _input, event: &InputEvent, window, cx| {
                match event {
                    // gpui-base 的 `Enter` 动作把 `cmd-enter`（macOS）/
                    // `ctrl-enter`（其它平台）绑成 `secondary: true`，正好对应
                    // Tauri 的 Ctrl/Cmd+Enter 提交；不带 Shift 才算提交。
                    InputEvent::PressEnter { secondary, shift } => {
                        if *secondary && !*shift {
                            this.commit(window, cx);
                        }
                    }
                    InputEvent::Focus => {
                        this.commit_focused = true;
                        cx.notify();
                    }
                    InputEvent::Blur => {
                        this.commit_focused = false;
                        cx.notify();
                    }
                    // 消息内容变化不需要额外处理：校验提示由 `visible_hint`
                    // 按当前内容重算，用户补上缺失项后那一半会自动消失。
                    InputEvent::Change => {}
                }
            }
        })
        .detach();
        self.commit_input = Some(input);
        cx.notify();
    }

    /// 本次提交会包含的已暂存文件数；对齐 Tauri 的「包含在提交里的文件数」。
    fn staged_count(&self) -> usize {
        self.status.as_ref().map_or(0, |status| {
            status
                .changes
                .iter()
                .filter(|change| change.staged && change.can_toggle_staging)
                .count()
        })
    }

    /// 变更区工具栏：对齐 Tauri `GitStatusPanel` 的 `SidebarToolbar`
    /// （40px 高、图标按钮 22px、右侧显示当前分支）。
    ///
    /// 面板标题由工作台的提交工具窗标题栏负责（提交 / Stash 分段），
    /// 因此这里不再重复标题，只保留变更操作。
    fn render_changes_toolbar(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let owner = cx.weak_entity();
        let branch = self
            .status
            .as_ref()
            .and_then(|status| status.branch.clone());
        let ahead = self.status.as_ref().map_or(0, |status| status.ahead);
        let behind = self.status.as_ref().map_or(0, |status| status.behind);
        // 任何写操作进行中时，所有写按钮一起禁用，避免并发改写索引。
        let busy = self.pending_action.is_some() || self.committing;
        let stage_all_pending =
            matches!(self.pending_action.as_ref(), Some(PendingAction::StageAll));
        let can_stage_all = !busy && self.can_stage_all();
        let can_unstage_all = !busy && self.can_unstage_all();
        // 没有选中项时，单文件动作（丢弃 / 预览）保持禁用。
        let has_selection = self.selected.is_some();

        h_flex()
            .id("lithe-git-changes-toolbar")
            .w_full()
            .flex_shrink_0()
            .h(px(CHANGES_TOOLBAR_HEIGHT))
            .items_center()
            .gap(px(2.0))
            .px(px(7.0))
            .bg(tokens.sidebar)
            .child(
                Button::new("lithe-git:refresh")
                    .ghost()
                    .with_size(px(CHANGES_TOOLBAR_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(icon(LitheIcon::Refresh).with_size(px(16.0)))
                    .tooltip(tr("Refresh"))
                    .disabled(
                        self.loading_status
                            || self.loading_history
                            || self.pending_action.is_some()
                            || self.committing,
                    )
                    .on_click(cx.listener(|this, _, window, cx| this.refresh(window, cx))),
            )
            .child(
                Button::new("lithe-git:discard-selected")
                    .ghost()
                    .with_size(px(CHANGES_TOOLBAR_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(
                        gpui_kit::component::Icon::new(gpui_kit::assets::IconName::Undo2)
                            .with_size(px(16.0)),
                    )
                    .tooltip(tr("Discard selected changes"))
                    .disabled(!has_selection || busy)
                    .on_click(cx.listener(|this, _, _window, cx| this.discard_selected_change(cx))),
            )
            .child(
                Button::new("lithe-git:stage-all")
                    .ghost()
                    .with_size(px(CHANGES_TOOLBAR_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(
                        gpui_kit::component::Icon::new(
                            gpui_kit::assets::IconName::ArrowDownToLine,
                        )
                        .with_size(px(16.0)),
                    )
                    .tooltip(tr("Stage all changes"))
                    .loading(stage_all_pending)
                    .disabled(!can_stage_all)
                    .on_click(cx.listener(|this, _, _window, cx| this.stage_all_changes(cx))),
            )
            .child(
                Button::new("lithe-git:diff-options")
                    .ghost()
                    .with_size(px(CHANGES_TOOLBAR_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(
                        gpui_kit::component::Icon::new(gpui_kit::assets::IconName::Eye)
                            .with_size(px(16.0)),
                    )
                    .tooltip(tr("Diff options")),
            )
            .child(
                Button::new("lithe-git:more-options")
                    .ghost()
                    .with_size(px(CHANGES_TOOLBAR_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(
                        gpui_kit::component::Icon::new(gpui_kit::assets::IconName::Ellipsis)
                            .with_size(px(16.0)),
                    )
                    .tooltip(tr("More options"))
                    .dropdown_menu_with_anchor(Anchor::TopLeft, {
                        let folder_view = self.folder_view;
                        let can_unstage = can_unstage_all;
                        let owner_opt = owner.clone();
                        move |menu, _window, _cx| {
                            let owner_grp = owner_opt.clone();
                            let owner_flt = owner_opt.clone();
                            let owner_uns = owner_opt.clone();
                            menu.item(
                                PopupMenuItem::new(tr("Group by Directory"))
                                    .checked(folder_view)
                                    .on_click(move |_, _, cx| {
                                        let _ = owner_grp.update(cx, |this, cx| {
                                            this.folder_view = true;
                                            cx.notify();
                                        });
                                    }),
                            )
                            .item(
                                PopupMenuItem::new(tr("Flat List"))
                                    .checked(!folder_view)
                                    .on_click(move |_, _, cx| {
                                        let _ = owner_flt.update(cx, |this, cx| {
                                            this.folder_view = false;
                                            cx.notify();
                                        });
                                    }),
                            )
                            .separator()
                            .item(PopupMenuItem::new(tr("Choose Diff Source")))
                            .item(
                                PopupMenuItem::new(tr("Unstage All Changes"))
                                    .disabled(!can_unstage)
                                    .on_click(move |_, _, cx| {
                                        let _ = owner_uns.update(cx, |this, cx| {
                                            this.unstage_all_changes(cx);
                                        });
                                    }),
                            )
                            .item(PopupMenuItem::new(tr("Stash All Unstaged")))
                        }
                    }),
            )
            .child(div().flex_1())
            .when(ahead > 0 || behind > 0, |this| {
                this.child(
                    div()
                        .flex_shrink_0()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.secondary_text)
                        .child(format!("↑{ahead} ↓{behind}")),
                )
            })
            .when_some(branch, |this, branch| {
                this.child(
                    div()
                        .min_w(px(0.0))
                        .flex_shrink_1()
                        .truncate()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.tertiary_text)
                        .child(branch),
                )
            })
            .into_any_element()
    }

    /// 更改列表选择栏与父仓库引用选项（完全对齐 Tauri `GitChangelistBar`）。
    fn render_changelist_bar(&self, tokens: LitheTokens, _cx: &mut Context<Self>) -> AnyElement {
        // 选择器曾经是纯静态 div（点不出任何菜单）。本地 changelist 管理
        // 尚未移植，先以单列表下拉的形式呈现当前激活列表；接入 store 后把
        // 列表项换成真实数据即可。
        let changelist_selector = Button::new("lithe-git:changelist-selector")
            .ghost()
            .h(px(26.0))
            .w(px(156.0))
            .px(px(8.0))
            .rounded(px(4.0))
            .border_1()
            .border_color(tokens.panel_border)
            .items_center()
            .justify_between()
            .child(
                div()
                    .truncate()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.primary_text)
                    .child(tr("Default Changelist")),
            )
            .child(
                Icon::new(gpui_kit::assets::IconName::ChevronDown)
                    .with_size(px(12.0))
                    .text_color(tokens.secondary_text),
            )
            .dropdown_menu(|menu, _window, _cx| {
                menu.item(PopupMenuItem::new(tr("Default Changelist")).checked(true))
            });

        let changelist_actions = h_flex()
            .items_center()
            .gap(px(2.0))
            .child(
                Button::new("lithe-git:new-changelist")
                    .ghost()
                    .with_size(px(CHANGES_TOOLBAR_BUTTON_SIZE))
                    .rounded(px(4.0))
                    .icon(Icon::new(gpui_kit::assets::IconName::Plus).with_size(px(13.0)))
                    .tooltip(tr("New Changelist"))
                    // 本地 changelist 管理尚未接入（对齐 Tauri 的 store 需要单独移植），
                    // 先诚实禁用而不是保留一个点了没反应的按钮。
                    .disabled(true),
            )
            .child(
                Button::new("lithe-git:edit-changelist")
                    .ghost()
                    .with_size(px(CHANGES_TOOLBAR_BUTTON_SIZE))
                    .rounded(px(4.0))
                    .icon(Icon::new(gpui_kit::assets::IconName::Pencil).with_size(px(13.0)))
                    .tooltip(tr("Rename Changelist"))
                    .disabled(true),
            )
            .child(
                Button::new("lithe-git:delete-changelist")
                    .ghost()
                    .with_size(px(CHANGES_TOOLBAR_BUTTON_SIZE))
                    .rounded(px(4.0))
                    .icon(Icon::new(gpui_kit::assets::IconName::Trash).with_size(px(13.0)))
                    .tooltip(tr("Delete Changelist"))
                    .disabled(true),
            );

        let row1 = h_flex()
            .w_full()
            .items_center()
            .justify_between()
            .child(changelist_selector)
            .child(changelist_actions);

        let parent_ref_checkbox = h_flex()
            .items_center()
            .gap(px(6.0))
            .child(
                Checkbox::new("lithe-git:update-parent-refs")
                    .small()
                    .checked(true),
            )
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr("Update Parent Repository References")),
            );

        v_flex()
            .id("lithe-git-changelist-bar")
            .w_full()
            .px(px(8.0))
            .pt(px(6.0))
            .pb(px(8.0))
            .gap(px(6.0))
            .bg(tokens.sidebar)
            .child(row1)
            .child(parent_ref_checkbox)
            .into_any_element()
    }

    fn render_body(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        // Tauri 的提交面板是单栏：工具条下方是更改列表选择器，接着是变更树，提交区固定在底部。
        v_flex()
            .w_full()
            .flex_1()
            .min_h_0()
            .child(self.render_changelist_bar(tokens, cx))
            .child(self.render_change_list(tokens, cx))
            .into_any_element()
    }

    fn render_change_list(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let mut list = v_flex()
            .id("lithe-git-changes-scroll")
            .w_full()
            .flex_1()
            .h_full()
            .min_h_0()
            .min_w_0()
            .bg(tokens.sidebar)
            // gpui 0.3.10 的 `overflow_y_scroll` 只在有稳定 id 的 Stateful 元素上。
            .overflow_y_scroll();

        let Some(status) = self.status.as_ref() else {
            return list
                .child(empty_state(
                    tokens,
                    if self.loading_status {
                        tr("Loading changes…")
                    } else {
                        tr("Changes unavailable")
                    },
                ))
                .into_any_element();
        };

        if status.branch.is_none() {
            return list
                .child(empty_state(tokens, tr("Not a Git repository")))
                .into_any_element();
        }

        let mut total = 0usize;
        // 提交与写操作都会改动索引，同一时刻只允许一个在飞。
        let busy = self.pending_action.is_some() || self.committing;
        // 「暂存优先」关闭时工作区变更排在暂存之前（Tauri showStagedFirst）。
        let groups: &[ChangeGroup] = if self.git_show_staged_first {
            &[
                ChangeGroup::Staged,
                ChangeGroup::Worktree,
                ChangeGroup::Untracked,
            ]
        } else {
            &[
                ChangeGroup::Worktree,
                ChangeGroup::Staged,
                ChangeGroup::Untracked,
            ]
        };
        for group in groups.iter().copied() {
            let changes = status
                .changes
                .iter()
                .filter(|change| in_group(change, group))
                .collect::<Vec<_>>();
            // 「显示未跟踪文件」关闭时隐藏整组。
            if group == ChangeGroup::Untracked && !self.git_show_untracked {
                continue;
            }
            if changes.is_empty() {
                continue;
            }
            total += changes.len();
            list = list.child(group_header(group, changes.len(), tokens));
            for change in changes {
                let selected = self.selected.as_ref().is_some_and(|selection| {
                    selection.group == group && selection.path == change.path
                });
                list = list.child(render_change_row(
                    change,
                    group,
                    selected,
                    self.pending_action.as_ref(),
                    busy,
                    tokens,
                    cx,
                ));
            }
        }

        if total == 0 {
            list = list.child(empty_state(tokens, tr("No changes")));
        }
        list.into_any_element()
    }

    /// IntelliJ 提交区：分隔线之上是变更树，之下依次是 Amend 行、消息输入框、
    /// 校验提示与提交按钮行。几何对齐 Tauri `git-commit-panel`（gap 6px、内边距
    /// `3px 11px 6px`），不为它再套一层卡片边框。
    fn render_bottom(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let message = self
            .commit_input
            .as_ref()
            .map(|input| input.read(cx).value())
            .unwrap_or_default();
        // 提交与索引写操作同一时刻只允许一个；Amend 开关同样在期间锁定。
        let busy = self.committing || self.pending_action.is_some();
        let staged_count = self.staged_count();
        let has_no_changes = staged_count == 0;
        let has_no_message = message.trim().is_empty();
        let can_commit = self.root.is_some()
            && self
                .status
                .as_ref()
                .is_some_and(|status| status.branch.is_some())
            && !busy
            && !has_no_changes
            && !has_no_message;
        // AI 生成按钮的可用性规则与 Tauri `isGenerateDisabled` 一致：
        // 未启用 / 没有暂存文件 / 正在提交时都禁用。
        let can_generate = self.ai_commit_enabled && !has_no_changes && !busy;

        // --- Amend 行：[x] Amend last commit ........ AI   {N} staged  🕘 ---
        let amend_row = h_flex()
            .w_full()
            .flex_shrink_0()
            .h(px(COMMIT_METADATA_HEIGHT))
            .items_center()
            .gap(px(7.0))
            .px(px(1.0))
            .child(
                // 受控开关：点击只写入请求值，由本视图重绘后回显。
                Checkbox::new("lithe-git:amend")
                    .small()
                    .flex_shrink_0()
                    .checked(self.amend)
                    .label(tr("Amend"))
                    .disabled(busy)
                    .on_change(cx.listener(|this, checked: &bool, _window, cx| {
                        this.amend = *checked;
                        cx.notify();
                    })),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.accent)
                    .child(tr("last commit")),
            )
            .child(div().flex_1())
            // AI 生成按钮。GPUI 构建没有 HTTP 客户端，生成能力由 Agent 面板
            // 承担，所以这里只对齐位置与可用性；关掉设置里的开关即禁用。
            .child(
                Button::new("lithe-git:generate-message")
                    .secondary()
                    .small()
                    .flex_shrink_0()
                    .label(tr("AI"))
                    .icon(Icon::new(gpui_kit::assets::IconName::Sparkles))
                    .tooltip(tr("Generate commit message with AI"))
                    .disabled(!can_generate)
                    .on_click(cx.listener(|this, _, window, cx| {
                        // 生成动作不在本构建里；点击把用户带去配置页，避免
                        // 留下一个点了没反应的按钮。
                        this.open_ai_settings(window, cx);
                    })),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(tr("{count} staged").replace("{count}", &staged_count.to_string())),
            )
            // 对齐 Tauri Amend 行右端的 `History` 回滚时钟图标。
            .child(
                Icon::new(gpui_kit::assets::IconName::RotateCcwClock)
                    .flex_shrink_0()
                    .text_color(tokens.tertiary_text),
            );

        // --- 消息输入框：1px 中性边框，聚焦时换成强调色，出错时换成错误色。 ---
        let focused = self.commit_focused;
        let has_error = self.error.is_some()
            || self
                .commit_hint
                .is_some_and(|hint| hint.no_message && has_no_message);
        let border_color = if has_error {
            tokens.error
        } else if focused {
            tokens.accent
        } else {
            tokens.panel_border
        };

        let input = match self.commit_input.as_ref() {
            Some(input) => Textarea::new(input)
                .w_full()
                .h_full()
                // 外框由下面的 message_box 提供，输入框自己不再画一层背景和描边，
                // 否则套在一起会出现双边框。
                .appearance(false)
                .bordered(false)
                .aria_label(tr("Commit message"))
                .into_any_element(),
            None => div()
                .w_full()
                .h(px(LitheMetrics::TREE_ROW_HEIGHT))
                .px(px(9.0))
                .flex()
                .items_center()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.tertiary_text)
                .child(tr("Commit message"))
                .into_any_element(),
        };

        let message_box = div()
            .w_full()
            .flex_shrink_0()
            .h(px(COMMIT_MESSAGE_HEIGHT))
            .overflow_hidden()
            .rounded(px(COMMIT_INPUT_RADIUS))
            .border_1()
            .border_color(border_color)
            .bg(tokens.editor)
            .child(input);

        // --- 校验提示：只在键盘提交被拦下、且用户还没改掉对应问题时出现。 ---
        // 与 Tauri 一致：补上文件或消息后，那一半提示自动消失。
        let visible_hint = self.commit_hint.and_then(|hint| {
            let no_changes = hint.no_changes && has_no_changes;
            let no_message = hint.no_message && has_no_message;
            // 每个分支都直接传字面量，i18n 生成脚本才会把三条文案收进词表。
            if no_changes && no_message {
                Some(tr("Select files to commit and specify commit message"))
            } else if no_changes {
                Some(tr("Select files to commit"))
            } else if no_message {
                Some(tr("Specify commit message"))
            } else {
                None
            }
        });

        // --- 按钮行：[提交] [提交并推送...] ......... 设置 ---
        let actions_row = h_flex()
            .w_full()
            .flex_shrink_0()
            .h(px(COMMIT_ACTIONS_HEIGHT))
            .items_center()
            .gap(px(6.0))
            .px(px(1.0))
            .child(
                Button::new("lithe-git:commit")
                    .primary()
                    .small()
                    .label(if self.committing {
                        tr("Committing...")
                    } else {
                        tr("Commit")
                    })
                    .disabled(!can_commit)
                    .on_click(cx.listener(|this, _, window, cx| this.commit(window, cx))),
            )
            .child(
                Button::new("lithe-git:commit-and-push")
                    .small()
                    .label(tr("Commit and Push..."))
                    .disabled(!can_commit)
                    .on_click(cx.listener(|this, _, window, cx| this.commit_and_push(window, cx))),
            )
            .child(div().flex_1())
            .child(
                Button::new("lithe-git:commit-settings")
                    .ghost()
                    .with_size(px(COMMIT_ACTIONS_HEIGHT - 6.0))
                    .rounded(px(4.0))
                    .icon(Icon::new(gpui_kit::assets::IconName::Settings))
                    .tooltip(tr("AI & Commit settings"))
                    .on_click(cx.listener(|this, _, window, cx| this.open_ai_settings(window, cx))),
            );

        v_flex()
            .id("lithe-git-commit-area")
            .w_full()
            .flex_shrink_0()
            .min_h_0()
            .gap(px(6.0))
            .px(px(COMMIT_PADDING_X))
            .pt(px(3.0))
            .pb(px(6.0))
            .bg(tokens.sidebar)
            .border_t_1()
            .border_color(tokens.divider)
            .child(amend_row)
            .child(message_box)
            .when_some(visible_hint, |this, hint| {
                this.child(
                    h_flex()
                        .w_full()
                        .flex_shrink_0()
                        .items_center()
                        .gap(px(6.0))
                        .child(
                            Icon::new(gpui_kit::assets::IconName::CircleAlert)
                                .flex_shrink_0()
                                .text_color(tokens.error),
                        )
                        .child(
                            div()
                                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                                .text_color(tokens.error)
                                .child(hint),
                        ),
                )
            })
            .child(actions_row)
            .into_any_element()
    }

    /// 打开设置页 AI & Commit。没有注册回调时静默返回（独立预览面板）。
    fn open_ai_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(handler) = self.on_open_ai_settings.clone() else {
            return;
        };
        handler(window, cx);
    }

    /// 提交记录模式：对齐 Tauri GitLogToolWindow 的专业三栏工作台布局。
    fn render_log_view(
        &mut self,
        window: &mut Window,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let content = v_flex()
            .id("lithe-git-log-view")
            .size_full()
            .min_w_0()
            .min_h_0()
            .bg(tokens.editor)
            .child(self.render_log_header(tokens, cx))
            .child(
                h_flex()
                    .flex_1()
                    .min_w_0()
                    .min_h_0()
                    .child(self.render_log_references_panel(tokens, cx))
                    .child(self.render_log_table(window, tokens, cx))
                    .child(self.render_log_inspector(tokens, cx)),
            );

        // 引用动作的确认弹窗与分支输入弹窗：与丢弃确认相同的模态覆盖模式。
        if let Some(confirm) = self.reference_confirm.clone() {
            return div()
                .relative()
                .size_full()
                .child(content)
                .child(self.render_reference_confirm(confirm, tokens, cx))
                .into_any_element();
        }
        if let Some((action, source)) = self.branch_prompt.clone() {
            return div()
                .relative()
                .size_full()
                .child(content)
                .child(self.render_branch_prompt(action, source, window, tokens, cx))
                .into_any_element();
        }

        // 提交动作：历史改写确认 / 编辑消息输入 / reset 模式选择 / 简单确认。
        if let Some(action) = self.commit_action.clone() {
            return div()
                .relative()
                .size_full()
                .child(content)
                .child(self.render_commit_action_overlay(action, window, tokens, cx))
                .into_any_element();
        }

        content.into_any_element()
    }

    /// 提交动作弹窗分发。
    fn render_commit_action_overlay(
        &mut self,
        action: CommitAction,
        window: &mut Window,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        match action {
            CommitAction::Rewrite { operation, .. } => {
                let preview = self
                    .pending_rewrite_preview
                    .as_ref()
                    .map(|boxed| (**boxed).clone());
                self.render_rewrite_confirm(operation, preview, tokens, cx)
            }
            CommitAction::EditMessageInput { .. } => {
                let preview = self
                    .pending_rewrite_preview
                    .as_ref()
                    .map(|boxed| (**boxed).clone())
                    .unwrap_or_default();
                self.render_edit_message_input(preview, window, tokens, cx)
            }
            CommitAction::Reset { revision } => self.render_reset_mode_choice(revision, tokens, cx),
            CommitAction::Simple { title, message, .. } => {
                self.render_simple_commit_confirm(title, message, tokens, cx)
            }
        }
    }

    /// 模态弹窗外壳（与引用确认相同的结构）。
    fn modal_shell(
        &self,
        id: &'static str,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        v_flex()
            .id(id)
            .w(px(440.0))
            .rounded(px(LitheMetrics::MENU_RADIUS))
            .border_1()
            .border_color(tokens.panel_border)
            .bg(tokens.raised)
            .p(px(16.0))
            .gap(px(10.0))
            .on_click(cx.listener(|_, _, _, cx| cx.stop_propagation()))
    }

    /// 复制任意文本到剪贴板（提交哈希 / 说明共用）。
    fn copy_text(&self, text: &str, _window: &mut Window, cx: &mut Context<Self>) {
        cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string(text.to_string()));
        cx.notify();
    }

    /// 引用动作确认弹窗（对齐 Tauri `showConfirmDialog` 的模态确认）。
    fn render_reference_confirm(
        &self,
        confirm: ReferenceConfirm,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let title = confirm.title;
        div()
            .id("lithe-git-reference-confirm-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .on_click(cx.listener(|this, _, _, cx| {
                this.cancel_reference_action(cx);
            }))
            .child(
                v_flex()
                    .id("lithe-git-reference-confirm-dialog")
                    .w(px(420.0))
                    .rounded(px(LitheMetrics::MENU_RADIUS))
                    .border_1()
                    .border_color(tokens.panel_border)
                    .bg(tokens.raised)
                    .p(px(16.0))
                    .gap(px(10.0))
                    .on_click(cx.listener(|_, _, _, cx| cx.stop_propagation()))
                    .child(
                        div()
                            .text_size(px(14.0))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.primary_text)
                            .child(title),
                    )
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(confirm.message.clone()),
                    )
                    .child(
                        h_flex()
                            .w_full()
                            .justify_end()
                            .gap(px(8.0))
                            .child(
                                Button::new("lithe-git-ref-confirm-cancel")
                                    .ghost()
                                    .small()
                                    .label(tr("Cancel"))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.cancel_reference_action(cx);
                                    })),
                            )
                            .child(
                                Button::new("lithe-git-ref-confirm-ok")
                                    .danger()
                                    .small()
                                    .label(title)
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.confirm_reference_action(cx);
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }

    /// 分支输入弹窗（新建 / 重命名）。GPUI 的 LithePrompt 绑定在工作台覆盖层，
    /// 面板内没有可复用的输入弹窗，这里用与确认弹窗相同的模态结构内置输入框。
    fn render_branch_prompt(
        &mut self,
        action: BranchPromptAction,
        source: CoreReference,
        window: &mut Window,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let (title, _label) = match action {
            BranchPromptAction::Create => (tr("New Branch"), tr("Branch name")),
            BranchPromptAction::Rename => (tr("Rename"), tr("Branch name")),
        };
        let source_desc = source.short_name.clone();
        div()
            .id("lithe-git-branch-prompt-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .on_click(cx.listener(|this, _, _, cx| {
                this.cancel_branch_prompt(cx);
            }))
            .child(
                v_flex()
                    .id("lithe-git-branch-prompt-dialog")
                    .w(px(420.0))
                    .rounded(px(LitheMetrics::MENU_RADIUS))
                    .border_1()
                    .border_color(tokens.panel_border)
                    .bg(tokens.raised)
                    .p(px(16.0))
                    .gap(px(10.0))
                    .on_click(cx.listener(|_, _, _, cx| cx.stop_propagation()))
                    .child(
                        div()
                            .text_size(px(14.0))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.primary_text)
                            .child(title),
                    )
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(format!("{}: {source_desc}", tr("Source"))),
                    )
                    .children(self.branch_input_element(window, cx))
                    .child(
                        h_flex()
                            .w_full()
                            .justify_end()
                            .gap(px(8.0))
                            .child(
                                Button::new("lithe-git-branch-prompt-cancel")
                                    .ghost()
                                    .small()
                                    .label(tr("Cancel"))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.cancel_branch_prompt(cx);
                                    })),
                            )
                            .child(
                                Button::new("lithe-git-branch-prompt-ok")
                                    .primary()
                                    .small()
                                    .label(title)
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.submit_branch_prompt(cx);
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }

    /// 历史改写确认弹窗：展示受影响提交，确认后带 expectedState 执行。
    fn render_rewrite_confirm(
        &self,
        operation: RewriteOperation,
        preview: Option<RewritePreview>,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let title = operation.title();
        let affected = preview
            .as_ref()
            .map(|preview| preview.affected_commit_summary())
            .unwrap_or_else(|| tr("Loading…").to_string());
        let suggestion = preview
            .as_ref()
            .map(|preview| preview.suggested_message.clone())
            .unwrap_or_default();

        let backdrop = div()
            .id("lithe-git-rewrite-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .on_click(cx.listener(|this, _, _, cx| {
                this.cancel_commit_action(cx);
            }));

        let mut dialog = self
            .modal_shell("lithe-git-rewrite-dialog", tokens, cx)
            .child(
                div()
                    .text_size(px(14.0))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.primary_text)
                    .child(title),
            )
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(affected),
            );

        if operation == RewriteOperation::EditCommitMessage && !suggestion.is_empty() {
            dialog = dialog.child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .font_family(MONO_FONT_FAMILY)
                    .text_color(tokens.primary_text)
                    .child(suggestion),
            );
        }

        dialog = dialog.child(
            h_flex()
                .w_full()
                .justify_end()
                .gap(px(8.0))
                .child(
                    Button::new("lithe-git-rewrite-cancel")
                        .ghost()
                        .small()
                        .label(tr("Cancel"))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.cancel_commit_action(cx);
                        })),
                )
                .child(
                    Button::new("lithe-git-rewrite-ok")
                        .danger()
                        .small()
                        .label(title)
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.confirm_commit_action(cx);
                        })),
                ),
        );

        backdrop.child(dialog).into_any_element()
    }

    /// 编辑提交消息输入弹窗（预填 Core 的 suggestedMessage）。
    fn render_edit_message_input(
        &mut self,
        preview: RewritePreview,
        window: &mut Window,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // 复用分支输入实体：弹窗打开时惰性创建并预填 suggestedMessage。
        if self.branch_input.is_none() {
            let initial = preview.suggested_message.clone();
            let input = cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(tr("Commit message"))
                    .default_value(initial)
            });
            let subscription = cx.subscribe_in(
                &input,
                window,
                |this: &mut Self, _input, event: &InputEvent, _window, cx| match event {
                    InputEvent::PressEnter { .. } => {
                        this.confirm_edit_message(cx);
                    }
                    InputEvent::Change | InputEvent::Focus | InputEvent::Blur => {}
                },
            );
            let _ = subscription;
            self.branch_input = Some(input);
            cx.notify();
        }

        let backdrop = div()
            .id("lithe-git-edit-message-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .on_click(cx.listener(|this, _, _, cx| {
                this.cancel_commit_action(cx);
            }));

        let dialog = self
            .modal_shell("lithe-git-edit-message-dialog", tokens, cx)
            .child(
                div()
                    .text_size(px(14.0))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.primary_text)
                    .child(tr("Edit Commit Message")),
            )
            .children(
                self.branch_input
                    .clone()
                    .map(|input| Input::new(&input).small().into_any_element()),
            )
            .child(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap(px(8.0))
                    .child(
                        Button::new("lithe-git-edit-message-cancel")
                            .ghost()
                            .small()
                            .label(tr("Cancel"))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.cancel_commit_action(cx);
                            })),
                    )
                    .child(
                        Button::new("lithe-git-edit-message-ok")
                            .primary()
                            .small()
                            .label(tr("Save"))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.confirm_edit_message(cx);
                            })),
                    ),
            );

        backdrop.child(dialog).into_any_element()
    }

    /// 提交编辑消息：读取输入框内容并执行改写。
    fn confirm_edit_message(&mut self, cx: &mut Context<Self>) {
        let Some(preview) = self.pending_rewrite_preview.clone() else {
            self.cancel_commit_action(cx);
            return;
        };
        let message = self
            .branch_input
            .take()
            .map(|input| input.read(cx).value().to_string())
            .unwrap_or_default();
        self.commit_action = None;
        self.execute_rewrite(*preview, Some(message), cx);
    }

    /// Reset 模式选择弹窗（soft / mixed / hard，对齐 Tauri showChoiceDialog）。
    fn render_reset_mode_choice(
        &self,
        revision: String,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let short_hash: String = revision.chars().take(8).collect();
        let backdrop = div()
            .id("lithe-git-reset-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .on_click(cx.listener(|this, _, _, cx| {
                this.cancel_commit_action(cx);
            }));

        let mut dialog = self
            .modal_shell("lithe-git-reset-dialog", tokens, cx)
            .child(
                div()
                    .text_size(px(14.0))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.primary_text)
                    .child(tr("Reset to Commit")),
            )
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .font_family(MONO_FONT_FAMILY)
                    .text_color(tokens.secondary_text)
                    .child(short_hash),
            );

        for (mode, label, danger) in [
            ("soft", tr("Soft - keep staged"), false),
            ("mixed", tr("Mixed - keep files"), false),
            ("hard", tr("Hard - discard changes"), true),
        ] {
            let revision = revision.clone();
            let mut button = Button::new(SharedString::from(format!("lithe-git-reset:{mode}")))
                .label(label)
                .small()
                .w_full();
            button = if danger {
                button.danger()
            } else {
                button.primary()
            };
            dialog = dialog.child(button.on_click(cx.listener(move |this, _, _, cx| {
                let revision = revision.clone();
                let title = tr("Reset to Commit");
                this.commit_action = None;
                this.run_simple_commit_write("reset", &revision, Some(mode), title, cx);
            })));
        }

        dialog = dialog.child(
            h_flex().w_full().justify_end().child(
                Button::new("lithe-git-reset-cancel")
                    .ghost()
                    .small()
                    .label(tr("Cancel"))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.cancel_commit_action(cx);
                    })),
            ),
        );

        backdrop.child(dialog).into_any_element()
    }

    /// 简单提交动作确认弹窗（cherry-pick / revert）。
    fn render_simple_commit_confirm(
        &self,
        title: &'static str,
        message: String,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let backdrop = div()
            .id("lithe-git-simple-confirm-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .on_click(cx.listener(|this, _, _, cx| {
                this.cancel_commit_action(cx);
            }));

        let dialog = self
            .modal_shell("lithe-git-simple-confirm-dialog", tokens, cx)
            .child(
                div()
                    .text_size(px(14.0))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.primary_text)
                    .child(title),
            )
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(message),
            )
            .child(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap(px(8.0))
                    .child(
                        Button::new("lithe-git-simple-confirm-cancel")
                            .ghost()
                            .small()
                            .label(tr("Cancel"))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.cancel_commit_action(cx);
                            })),
                    )
                    .child(
                        Button::new("lithe-git-simple-confirm-ok")
                            .primary()
                            .small()
                            .label(title)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.confirm_commit_action(cx);
                            })),
                    ),
            );

        backdrop.child(dialog).into_any_element()
    }

    /// Git Log 标题栏与 Tab 切换（对齐 Tauri 单层顶栏与模式 Tab）。
    fn render_log_header(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let title_row = h_flex()
            .w_full()
            .h(px(28.0))
            .items_center()
            .justify_between()
            .px(px(8.0))
            .bg(tokens.tool_header)
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                h_flex()
                    .items_center()
                    .gap(px(6.0))
                    .child(
                        Icon::new(gpui_kit::assets::IconName::GitBranch)
                            .with_size(px(13.0))
                            .text_color(tokens.primary_text),
                    )
                    .child(
                        div()
                            .text_size(px(LitheMetrics::TOOL_WINDOW_TITLE_FONT_SIZE))
                            .font_weight(FontWeight::BOLD)
                            .text_color(tokens.primary_text)
                            .child(tr("Git Log")),
                    )
                    .child(
                        h_flex()
                            .h(px(20.0))
                            .px(px(6.0))
                            .rounded(px(3.0))
                            .bg(tokens.sidebar)
                            .border_1()
                            .border_color(tokens.panel_border)
                            .items_center()
                            .gap(px(3.0))
                            .child(
                                div()
                                    .text_size(px(11.0))
                                    .text_color(tokens.primary_text)
                                    .child(tr("Log: All")),
                            )
                            .child(
                                Icon::new(gpui_kit::assets::IconName::ChevronDown)
                                    .with_size(px(9.0))
                                    .text_color(tokens.secondary_text),
                            ),
                    ),
            )
            .child(
                h_flex()
                    .items_center()
                    .gap(px(2.0))
                    .child(
                        Button::new("lithe-git-log:refresh")
                            .ghost()
                            .small()
                            .child(
                                Icon::new(gpui_kit::assets::IconName::RotateCw).with_size(px(12.0)),
                            )
                            .tooltip(tr("Refresh"))
                            .on_click(cx.listener(|this, _, window, cx| this.refresh(window, cx))),
                    )
                    .child(
                        Button::new("lithe-git-log:settings")
                            .ghost()
                            .small()
                            .child(
                                Icon::new(gpui_kit::assets::IconName::Settings).with_size(px(12.0)),
                            )
                            .tooltip(tr("Settings"))
                            // 对齐 Tauri `openSettingsDialog("git")`：打开设置页的
                            // Git 分类。回调由工作区在构造时注册。
                            .on_click(cx.listener(|this, _, window, cx| {
                                if let Some(handler) = this.on_open_git_settings.clone() {
                                    handler(window, cx);
                                }
                            })),
                    )
                    .child(
                        Button::new("lithe-git-log:minimize")
                            .ghost()
                            .small()
                            .child(Icon::new(gpui_kit::assets::IconName::Minus).with_size(px(12.0)))
                            .tooltip(tr("Minimize")),
                    ),
            );

        let tab_row = h_flex()
            .w_full()
            .h(px(24.0))
            .px(px(10.0))
            .items_center()
            .gap(px(14.0))
            .bg(tokens.tool_header)
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                div()
                    .h_full()
                    .flex()
                    .items_center()
                    .border_b(px(2.0))
                    .border_color(tokens.accent)
                    .text_size(px(11.5))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.primary_text)
                    .child(tr("Log")),
            )
            .child(
                div()
                    .h_full()
                    .flex()
                    .items_center()
                    .text_size(px(11.5))
                    .text_color(tokens.secondary_text)
                    .cursor_pointer()
                    .child(tr("Console")),
            );

        v_flex()
            .w_full()
            .child(title_row)
            .child(tab_row)
            .into_any_element()
    }

    /// Git Log 左栏：垂直图标条 + 分支与引用树（对齐截图左侧）。
    fn render_log_references_panel(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // 最左侧垂直小动作条（完全对齐 Tauri GitReferenceToolbar 的动作集合与
        // 可用性规则：新建 / 更新 / 删除 / 比较 | 刷新 | 定位 HEAD / 过滤）。
        let selected = self.selected_reference_object().cloned();
        let current = self.current_reference_object().cloned();
        let busy = self.is_reference_busy();
        // 更新按钮要求选中分支有上游（对齐 getGitReferenceToolbarState）。
        let can_update = selected.as_ref().is_some_and(|reference| {
            reference.is_local() && reference.upstream_short_name.is_some()
        });
        // 删除要求选中的是本地分支且不是当前分支。
        let can_delete = selected
            .as_ref()
            .is_some_and(|reference| reference.is_local() && !reference.is_current);
        // 比较要求选中的引用不是当前分支。
        let can_compare = selected
            .as_ref()
            .is_some_and(|reference| !reference.is_current);
        // 新建分支的起点：选中引用，缺省当前分支。
        let can_create = selected.is_some() || current.is_some();

        let action_stripe = v_flex()
            .w(px(36.0))
            .h_full()
            .items_center()
            .gap(px(2.0))
            .py(px(4.0))
            .bg(tokens.editor)
            .border_r_1()
            .border_color(tokens.divider)
            .child(
                Button::new("git-log-act:new-branch")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("New Branch"))
                    .disabled(busy || !can_create)
                    .child(Icon::new(gpui_kit::assets::IconName::Plus).with_size(px(14.0)))
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.run_reference_action("createBranch", cx);
                    })),
            )
            .child(
                Button::new("git-log-act:update")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Update Selected"))
                    .disabled(busy || !can_update)
                    .child(
                        Icon::new(gpui_kit::assets::IconName::ArrowDownToLine).with_size(px(14.0)),
                    )
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.run_reference_action("update", cx);
                    })),
            )
            .child(
                Button::new("git-log-act:delete-branch")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Delete Branch"))
                    .disabled(busy || !can_delete)
                    .child(Icon::new(gpui_kit::assets::IconName::Trash).with_size(px(14.0)))
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.run_reference_action("deleteLocal", cx);
                    })),
            )
            .child(
                Button::new("git-log-act:compare")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Compare with current"))
                    .disabled(busy || !can_compare)
                    .child(Icon::new(gpui_kit::assets::IconName::GitCompare).with_size(px(14.0)))
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.run_reference_action("compareWithCurrent", cx);
                    })),
            )
            // 分割线
            .child(div().w(px(20.0)).h(px(1.0)).my(px(4.0)).bg(tokens.divider))
            .child(
                Button::new("git-log-act:refresh")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Refresh"))
                    .disabled(busy)
                    .child(Icon::new(gpui_kit::assets::IconName::RotateCw).with_size(px(14.0)))
                    .on_click(cx.listener(|this, _, window, cx| this.refresh(window, cx))),
            )
            .child(
                Button::new("git-log-act:head")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Go to HEAD"))
                    .disabled(self.current_reference_object().is_none())
                    .child(Icon::new(gpui_kit::assets::IconName::Crosshair).with_size(px(14.0)))
                    // 定位 HEAD：选中当前分支并请求该分支的历史。
                    .on_click(cx.listener(|this, _, _window, cx| {
                        if let Some(current) = this
                            .references
                            .iter()
                            .find(|reference| reference.is_current)
                        {
                            this.select_reference(current.short_name.clone(), cx);
                        }
                    })),
            )
            .child(
                Button::new("git-log-act:all-branches")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("All branches"))
                    .child(Icon::new(gpui_kit::assets::IconName::ListFilter).with_size(px(14.0)))
                    // 回到全部分支视图：清空选中引用并重载。
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.select_reference(String::new(), cx);
                    })),
            )
            // 推至底部的全展开与全收起
            .child(div().flex_1())
            .child(
                Button::new("git-log-act:expand-all")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Expand all"))
                    .child(
                        Icon::new(gpui_kit::assets::IconName::ChevronsUpDown).with_size(px(14.0)),
                    )
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.collapsed_groups.clear();
                        cx.notify();
                    })),
            )
            .child(
                Button::new("git-log-act:collapse-all")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Collapse all"))
                    .child(Icon::new(gpui_kit::assets::IconName::Minimize2).with_size(px(14.0)))
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.collapse_all_groups();
                        cx.notify();
                    })),
            );

        // 引用树列表
        let mut tree = v_flex()
            .id("lithe-git-log-ref-tree")
            .flex_1()
            .h_full()
            .overflow_y_scroll()
            .p(px(6.0))
            .gap(px(2.0));

        let references = &self.references;
        let local: Vec<&CoreReference> = references
            .iter()
            .filter(|reference| reference.is_local())
            .collect();
        let remotes: Vec<&CoreReference> = references
            .iter()
            .filter(|reference| reference.is_remote())
            .collect();
        let tags: Vec<&CoreReference> = references
            .iter()
            .filter(|reference| reference.is_tag())
            .collect();

        // 顶部 `+ 引用 N`
        tree = tree.child(
            h_flex()
                .w_full()
                .h(px(24.0))
                .items_center()
                .justify_between()
                .px(px(4.0))
                .child(
                    h_flex()
                        .gap(px(4.0))
                        .items_center()
                        .child(
                            Icon::new(gpui_kit::assets::IconName::Plus)
                                .with_size(px(11.0))
                                .text_color(tokens.secondary_text),
                        )
                        .child(
                            div()
                                .text_size(px(12.0))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(tokens.primary_text)
                                .child(tr("References")),
                        ),
                )
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(tokens.tertiary_text)
                        .child(references.len().to_string()),
                ),
        );

        tree = self.render_reference_group(tree, tr("Local"), &local, true, tokens, cx);
        tree = self.render_remote_groups(tree, &remotes, tokens, cx);
        tree = self.render_reference_group(tree, tr("Tags"), &tags, false, tokens, cx);

        if references.is_empty() {
            tree = tree.child(
                div()
                    .p(px(12.0))
                    .text_size(px(12.0))
                    .text_color(tokens.secondary_text)
                    .child(if self.loading_references {
                        tr("Loading…")
                    } else {
                        tr("No branches")
                    }),
            );
        }

        h_flex()
            .id("lithe-git-log-sidebar")
            .w(px(280.0))
            .h_full()
            .flex_shrink_0()
            .bg(tokens.sidebar)
            .border_r_1()
            .border_color(tokens.divider)
            .child(action_stripe)
            .child(tree)
            .into_any_element()
    }

    /// 渲染一个本地分支 / 标签分组（平铺，无子目录）。
    fn render_reference_group(
        &self,
        mut tree: Stateful<Div>,
        title: &'static str,
        items: &[&CoreReference],
        show_current: bool,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        if items.is_empty() {
            return tree;
        }
        let group_key = title.to_string();
        let collapsed = self.collapsed_groups.contains(&group_key);
        tree = tree.child(
            h_flex()
                .id(SharedString::from(format!("git-log-group:{group_key}")))
                .w_full()
                .h(px(20.0))
                .items_center()
                .justify_between()
                .px(px(4.0))
                .rounded(px(3.0))
                .cursor_pointer()
                .hover(|s| s.bg(tokens.hover))
                .child(
                    h_flex()
                        .gap(px(4.0))
                        .items_center()
                        .child(group_chevron(collapsed, tokens))
                        .child(
                            div()
                                .text_size(px(12.0))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(tokens.primary_text)
                                .child(tr(title)),
                        ),
                )
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(tokens.tertiary_text)
                        .child(items.len().to_string()),
                )
                .on_click(cx.listener(move |this, _, _window, cx| {
                    this.toggle_group(&group_key.clone(), cx);
                })),
        );
        if collapsed {
            return tree;
        }
        for reference in items {
            tree = self.render_reference_row(tree, reference, show_current, tokens, cx);
        }
        tree
    }

    /// 渲染远程分组：远程 -> 按远端名折叠，内部平铺远程分支。
    fn render_remote_groups(
        &self,
        mut tree: Stateful<Div>,
        remotes: &[&CoreReference],
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        if remotes.is_empty() {
            return tree;
        }
        // 按远端名分组，保持 Core 返回的 refname 排序。
        let mut by_remote: BTreeMap<String, Vec<&CoreReference>> = BTreeMap::new();
        for reference in remotes {
            by_remote
                .entry(reference.remote_name().to_string())
                .or_default()
                .push(reference);
        }

        let collapsed = self.collapsed_groups.contains("Remote");
        tree = tree.child(
            h_flex()
                .id("git-log-group:Remote")
                .w_full()
                .h(px(20.0))
                .mt(px(4.0))
                .items_center()
                .justify_between()
                .px(px(4.0))
                .child(
                    h_flex()
                        .gap(px(4.0))
                        .items_center()
                        .child(group_chevron(collapsed, tokens))
                        .child(
                            div()
                                .text_size(px(12.0))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(tokens.primary_text)
                                .child(tr("Remote")),
                        ),
                )
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(tokens.tertiary_text)
                        .child(remotes.len().to_string()),
                ),
        );
        if collapsed {
            return tree;
        }

        for (remote, branches) in by_remote {
            let group_key = format!("remote/{remote}");
            let remote_collapsed = self.collapsed_groups.contains(&group_key);
            tree = tree.child(
                h_flex()
                    .id(SharedString::from(format!("git-log-remote:{remote}")))
                    .w_full()
                    .h(px(20.0))
                    .pl(px(10.0))
                    .pr(px(4.0))
                    .rounded(px(3.0))
                    .items_center()
                    .gap(px(4.0))
                    .cursor_pointer()
                    .hover(|s| s.bg(tokens.hover))
                    .child(group_chevron(remote_collapsed, tokens))
                    .child(remote_folder_icon(remote_collapsed, tokens))
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(tokens.primary_text)
                            .child(remote.clone()),
                    )
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        this.toggle_group(&group_key.clone(), cx);
                    })),
            );
            if remote_collapsed {
                continue;
            }
            for branch in branches {
                tree = self.render_reference_row(tree, branch, false, tokens, cx);
            }
        }
        tree
    }

    /// 引用树的单行：分支图标 + 短名 + 当前分支标记 / 领先落后计数。
    fn render_reference_row(
        &self,
        tree: Stateful<Div>,
        reference: &CoreReference,
        show_current: bool,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        let name = reference.short_name.clone();
        let is_current = show_current && reference.is_current;
        let is_selected = is_current || self.selected_reference.as_deref() == Some(name.as_str());
        let ahead_behind = if reference.ahead > 0 || reference.behind > 0 {
            format!("↑{} ↓{}", reference.ahead, reference.behind)
        } else {
            String::new()
        };
        let indent = px(24.0);
        let name_for_menu = name.clone();
        let reference_for_menu = reference.clone();

        tree.child(
            h_flex()
                .id(SharedString::from(format!("git-log-ref-row:{name}")))
                .w_full()
                .h(px(21.0))
                .px(px(6.0))
                .pl(indent)
                .rounded(px(4.0))
                .items_center()
                .justify_between()
                .when(is_selected, |this| this.bg(tokens.selection))
                .when(!is_selected, |this| this.hover(|s| s.bg(tokens.hover)))
                .cursor_pointer()
                .child(
                    h_flex()
                        .items_center()
                        .gap(px(4.0))
                        .min_w(px(0.0))
                        .child(if is_current {
                            Icon::new(gpui_kit::assets::IconName::Check)
                                .with_size(px(11.0))
                                .text_color(if is_selected {
                                    tokens.tool_window_selected_text
                                } else {
                                    tokens.success
                                })
                        } else if reference.is_tag() {
                            Icon::new(gpui_kit::assets::IconName::Tag)
                                .with_size(px(11.0))
                                .text_color(if is_selected {
                                    tokens.tool_window_selected_text
                                } else {
                                    tokens.secondary_text
                                })
                        } else {
                            Icon::new(gpui_kit::assets::IconName::GitBranch)
                                .with_size(px(11.0))
                                .text_color(if is_selected {
                                    tokens.tool_window_selected_text
                                } else {
                                    tokens.secondary_text
                                })
                        })
                        .child(
                            div()
                                .truncate()
                                .text_size(px(12.0))
                                .text_color(if is_selected {
                                    tokens.tool_window_selected_text
                                } else {
                                    tokens.primary_text
                                })
                                .child(name.clone()),
                        ),
                )
                .child(
                    h_flex()
                        .items_center()
                        .gap(px(4.0))
                        .when(is_current, |this| {
                            this.child(
                                div()
                                    .px(px(4.0))
                                    .py(px(0.5))
                                    .rounded(px(3.0))
                                    .bg(tokens.raised)
                                    .text_size(px(10.0))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(tokens.accent)
                                    .child(tr("Current")),
                            )
                        })
                        .when(!ahead_behind.is_empty(), |this| {
                            this.child(
                                div()
                                    .text_size(px(10.5))
                                    .font_family(MONO_FONT_FAMILY)
                                    .text_color(tokens.tertiary_text)
                                    .child(ahead_behind),
                            )
                        }),
                )
                .on_click(cx.listener(move |this, _, _window, cx| {
                    this.select_reference(name.clone(), cx);
                }))
                // 右键动作菜单：按引用类别给出可用动作，对齐 Tauri
                // `GitReferenceContextMenu` 的分组。
                .on_mouse_down(
                    gpui_kit::MouseButton::Right,
                    cx.listener(move |this, event: &gpui_kit::MouseDownEvent, window, cx| {
                        // 右键先选中该行，动作以它为目标（对齐 Tauri onContextSelect）。
                        this.select_reference(name_for_menu.clone(), cx);
                        this.open_reference_menu(
                            reference_for_menu.clone(),
                            event.position,
                            window,
                            cx,
                        );
                    }),
                ),
        )
    }

    /// 打开引用动作菜单。菜单条目来自 [`Self::actions_for_reference`]。
    fn open_reference_menu(
        &mut self,
        reference: CoreReference,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let busy = self.is_reference_busy();
        let owner = cx.weak_entity();
        let popup =
            gpui_kit::component::menu::PopupMenu::build(window, cx, move |menu, _window, _cx| {
                let mut menu = menu.min_w(px(200.0));
                let mut first_group = true;
                // 与 Tauri 相同的三段分组：检出/新建 → 比较/集成 → 更新/推送/重命名 → 删除。
                let groups: &[&[&str]] = if reference.is_local() {
                    if reference.is_current {
                        &[&["createBranch"], &["update", "push", "rename"]]
                    } else {
                        &[
                            &["checkout", "createBranch", "checkoutAndRebase"],
                            &[
                                "compareWithCurrent",
                                "rebaseCurrentOnto",
                                "mergeIntoCurrent",
                            ],
                            &["update", "push", "rename"],
                        ]
                    }
                } else if reference.is_remote() {
                    &[
                        &["checkout", "createBranch", "checkoutAndRebase"],
                        &[
                            "compareWithCurrent",
                            "rebaseCurrentOnto",
                            "mergeIntoCurrent",
                        ],
                        &["pullRebaseIntoCurrent", "pullMergeIntoCurrent"],
                    ]
                } else {
                    &[&["checkout", "createBranch", "compareWithCurrent"]]
                };

                for group in groups {
                    if first_group {
                        first_group = false;
                    } else {
                        menu = menu.separator();
                    }
                    for action in group.iter() {
                        // 删除类动作放在最后的独立分组（见下方）。
                        if matches!(*action, "deleteLocal" | "deleteRemote" | "deleteTag") {
                            continue;
                        }
                        // update / push 需要上游分支（对齐 Tauri 的禁用规则）。
                        let disabled = busy
                            || (*action == "update" && reference.upstream_short_name.is_none());
                        let label = reference_action_title(action);
                        let owner = owner.clone();
                        let action = *action;
                        menu = menu.item(PopupMenuItem::new(label).disabled(disabled).on_click(
                            move |_, _, cx| {
                                let _ = owner.update(cx, |this, cx| {
                                    this.run_reference_action(action, cx);
                                });
                            },
                        ));
                    }
                }

                // 复制分支名 + 删除（对齐 Tauri 菜单尾部分组）。
                menu = menu.separator();
                if reference.kind != "tag" {
                    let owner = owner.clone();
                    let label_for_copy = reference.short_name.clone();
                    menu = menu.item(PopupMenuItem::new(tr("Copy Branch Name")).on_click(
                        move |_, window, cx| {
                            let _ = owner.update(cx, |this, cx| {
                                this.copy_reference_name(&label_for_copy, window, cx);
                            });
                        },
                    ));
                }
                let delete_action = if reference.is_local() {
                    "deleteLocal"
                } else if reference.is_remote() {
                    "deleteRemote"
                } else {
                    "deleteTag"
                };
                let owner = owner.clone();
                let delete_label = reference_action_title(delete_action);
                menu = menu.item(
                    PopupMenuItem::new(delete_label)
                        .disabled(busy || (delete_action == "deleteLocal" && reference.is_current))
                        .on_click(move |_, _, cx| {
                            let _ = owner.update(cx, |this, cx| {
                                this.run_reference_action(delete_action, cx);
                            });
                        }),
                );
                menu
            });

        cx.subscribe_in(
            &popup,
            window,
            |this, _, _: &gpui_kit::DismissEvent, _window, cx| {
                this.reference_menu = None;
                cx.notify();
            },
        )
        .detach();
        self.reference_menu = Some((popup, position));
        cx.notify();
    }

    /// 复制引用名到剪贴板。
    fn copy_reference_name(&self, name: &str, _window: &mut Window, cx: &mut Context<Self>) {
        cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string(name.to_string()));
        cx.notify();
    }

    /// 选中引用并按它重载历史；空字符串 = 全部分支。
    fn select_reference(&mut self, short_name: String, cx: &mut Context<Self>) {
        let next = if short_name.is_empty() {
            None
        } else {
            Some(short_name)
        };
        if self.selected_reference == next {
            return;
        }
        self.selected_reference = next;
        // 引用变化必须重载历史；generation 由 reload_all 统一管理。
        self.generation = self.generation.wrapping_add(1);
        self.history.clear();
        self.selected_commit_hash = None;
        self.commit_files.clear();
        self.load_history(cx);
        cx.notify();
    }

    fn toggle_group(&mut self, key: &str, cx: &mut Context<Self>) {
        if !self.collapsed_groups.remove(key) {
            self.collapsed_groups.insert(key.to_string());
        }
        cx.notify();
    }

    fn collapse_all_groups(&mut self) {
        self.collapsed_groups.clear();
        self.collapsed_groups.insert(tr("Local").to_string());
        self.collapsed_groups.insert(tr("Remote").to_string());
        self.collapsed_groups.insert(tr("Tags").to_string());
    }

    // -----------------------------------------------------------------------
    // 引用动作（对齐 Tauri git-log-tool-window 的 runReferenceAction 系列）
    // -----------------------------------------------------------------------

    /// 选中的引用对象；引用动作都以它为目标。
    fn selected_reference_object(&self) -> Option<&CoreReference> {
        let short = self.selected_reference.as_deref()?;
        self.references
            .iter()
            .find(|reference| reference.short_name == short)
    }

    /// 当前分支引用对象。
    fn current_reference_object(&self) -> Option<&CoreReference> {
        self.references
            .iter()
            .find(|reference| reference.is_current)
    }

    /// 是否有引用写操作在执行。
    fn is_reference_busy(&self) -> bool {
        self.reference_mutation.is_some()
    }

    /// 发起一个引用写操作（Core `git.write`），成功后刷新并提示。
    ///
    /// `payload_extra` 由调用方按 operation 拼装（name / mode / strategy 等）。
    fn run_reference_write(
        &mut self,
        action: &'static str,
        operation: &'static str,
        reference: &CoreReference,
        mut payload: serde_json::Value,
        cx: &mut Context<Self>,
    ) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root_text(&root) else {
            return;
        };
        if self.is_reference_busy() {
            return;
        }

        // 对齐 Tauri `referencePayload`：新客户端统一发类型化 gitReference。
        payload["root"] = serde_json::Value::String(root_text);
        payload["operation"] = serde_json::Value::String(operation.to_string());
        payload["gitReference"] = serde_json::json!({
            "fullName": reference.full_name,
            "shortName": reference.short_name,
            "kind": reference.kind,
        });

        let generation = self.generation;
        let client = self.client;
        self.reference_mutation = Some(action);
        self.error = None;
        self.notice = None;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move { client.execute_raw("git.write", payload) })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.reference_mutation = None;
                match raw {
                    Ok(value) => {
                        // git.write 返回 GitCommandResponse；exitCode 非 0 视为失败。
                        let command = parse_command(&value).unwrap_or_default();
                        if command.exit_code == 0 {
                            this.reload_all(cx);
                            this.notice = Some(SharedString::from(reference_action_title(action)));
                        } else {
                            this.error = Some(SharedString::from(command_failure_detail(
                                &command,
                                reference_action_title(action),
                            )));
                        }
                    }
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 无确认直接执行的动作：本地 / 远程分支检出（对齐 Tauri：检出无二次确认，
    /// 成功与否由分支标签切换表达）。
    fn checkout_reference(&mut self, reference: &CoreReference, cx: &mut Context<Self>) {
        self.run_reference_write("checkout", "checkout", reference, serde_json::json!({}), cx);
    }

    /// 更新选中分支：等价 Tauri 的 updateGitLogBranch（fetch + 受保护快进）。
    fn update_reference(&mut self, reference: &CoreReference, cx: &mut Context<Self>) {
        if reference.upstream_short_name.is_none() {
            return;
        }
        self.run_reference_write(
            "update",
            "updateBranch",
            reference,
            serde_json::json!({}),
            cx,
        );
    }

    /// 推送选中分支。简单场景（无分歧）直接 push；失败信息留在状态行。
    fn push_reference(&mut self, reference: &CoreReference, cx: &mut Context<Self>) {
        if !reference.is_local() {
            return;
        }
        self.run_reference_write("push", "push", reference, serde_json::json!({}), cx);
    }

    /// 需要确认的集成动作：检出标签 / rebase / merge / pull。
    fn request_reference_confirm(
        &mut self,
        action: &'static str,
        operation: &'static str,
        reference: CoreReference,
        success: &'static str,
        cx: &mut Context<Self>,
    ) {
        let current = self
            .current_reference_object()
            .map(|reference| reference.short_name.clone())
            .unwrap_or_else(|| "HEAD".to_string());
        let title = reference_action_title(action);
        let message = match action {
            "rebaseCurrentOnto" => format!("{} → {}?", tr("Rebase"), reference.short_name),
            "mergeIntoCurrent" => format!("{} → {}?", reference.short_name, current),
            _ => format!("{}: {}?", title, reference.short_name),
        };
        self.reference_confirm = Some(ReferenceConfirm {
            operation,
            reference,
            title,
            message,
            success,
        });
        cx.notify();
    }

    /// 用户确认后执行挂起的引用动作。
    fn confirm_reference_action(&mut self, cx: &mut Context<Self>) {
        let Some(confirm) = self.reference_confirm.take() else {
            return;
        };
        self.run_reference_write(
            reference_action_key(confirm.operation),
            confirm.operation,
            &confirm.reference,
            serde_json::json!({}),
            cx,
        );
        self.notice = Some(SharedString::from(confirm.success));
        cx.notify();
    }

    fn cancel_reference_action(&mut self, cx: &mut Context<Self>) {
        if self.reference_confirm.take().is_some() {
            cx.notify();
        }
    }

    /// 删除本地分支。对齐 Tauri：不二次确认，删除后给「恢复」通知入口；
    /// GPUI 的通知系统暂无动作按钮，因此恢复走 Core 的 deleteBranch 返回值
    /// 记录到 notice，用户可从 reflog 找回（Core 侧 delete_branch 已保留该信息）。
    fn delete_local_reference(&mut self, reference: &CoreReference, cx: &mut Context<Self>) {
        if reference.is_current {
            return;
        }
        self.run_reference_write(
            "deleteLocal",
            "deleteBranch",
            reference,
            serde_json::json!({}),
            cx,
        );
    }

    /// 删除远程分支（带确认）。
    fn delete_remote_reference(&mut self, reference: &CoreReference, cx: &mut Context<Self>) {
        let title = reference_action_title("deleteRemote");
        self.reference_confirm = Some(ReferenceConfirm {
            operation: "deleteBranch",
            reference: reference.clone(),
            title,
            message: format!("{} ({})?", tr("Delete Remote Branch"), reference.short_name),
            success: tr("Branch deleted"),
        });
        cx.notify();
    }

    /// 打开新建分支输入框（起点 = 当前选中引用，缺省当前分支）。
    fn request_create_branch(&mut self, cx: &mut Context<Self>) {
        let Some(source) = self
            .selected_reference_object()
            .cloned()
            .or_else(|| self.current_reference_object().cloned())
        else {
            return;
        };
        self.branch_prompt = Some((BranchPromptAction::Create, source));
        self.branch_input = None;
        cx.notify();
    }

    /// 打开重命名分支输入框。
    fn request_rename_branch(&mut self, reference: &CoreReference, cx: &mut Context<Self>) {
        if !reference.is_local() {
            return;
        }
        self.branch_prompt = Some((BranchPromptAction::Rename, reference.clone()));
        self.branch_input = None;
        cx.notify();
    }

    /// 惰性创建分支输入框。`InputState::new` 需要 Window，只能在 render 期调用。
    fn ensure_branch_input(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some((action, source)) = self.branch_prompt.as_ref() else {
            return;
        };
        if self.branch_input.is_some() {
            return;
        }
        let initial = match action {
            BranchPromptAction::Create => String::new(),
            BranchPromptAction::Rename => source.short_name.clone(),
        };
        let input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(tr("Branch name"))
                .default_value(initial)
        });
        let subscription = cx.subscribe_in(
            &input,
            window,
            |this: &mut Self, _input, event: &InputEvent, _window, cx| match event {
                InputEvent::PressEnter { .. } => this.submit_branch_prompt(cx),
                InputEvent::Change | InputEvent::Focus | InputEvent::Blur => {}
            },
        );
        // 订阅随实体一起保活；这里只为简化字段而丢弃句柄是安全的，因为
        // `branch_input` 清空时弹窗已关闭，迟到的 Enter 事件找不到目标。
        let _ = subscription;
        self.branch_input = Some(input);
        cx.notify();
    }

    /// 分支输入框元素；render 期调用以完成惰性创建。
    fn branch_input_element(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        self.ensure_branch_input(window, cx);
        self.branch_input
            .clone()
            .map(|input| Input::new(&input).small().into_any_element())
    }

    /// 读取输入框当前内容并提交。
    fn submit_branch_prompt(&mut self, cx: &mut Context<Self>) {
        let Some(input) = self.branch_input.clone() else {
            return;
        };
        let value = input.read(cx).value().to_string();
        self.confirm_branch_prompt(value, cx);
    }

    /// 分支输入框确认：新建走 createBranch（`--no-track` 语义由 Core 保证），
    /// 重命名走 renameBranch。
    fn confirm_branch_prompt(&mut self, name: String, cx: &mut Context<Self>) {
        let Some((action, source)) = self.branch_prompt.take() else {
            return;
        };
        self.branch_input = None;
        let name = name.trim().to_string();
        if name.is_empty() {
            return;
        }
        match action {
            BranchPromptAction::Create => {
                self.run_reference_write(
                    "createBranch",
                    "createBranch",
                    &source,
                    serde_json::json!({ "name": name }),
                    cx,
                );
            }
            BranchPromptAction::Rename => {
                self.run_reference_write(
                    "rename",
                    "renameBranch",
                    &source,
                    serde_json::json!({ "name": name }),
                    cx,
                );
            }
        }
    }

    fn cancel_branch_prompt(&mut self, cx: &mut Context<Self>) {
        if self.branch_prompt.take().is_some() {
            self.branch_input = None;
            cx.notify();
        }
    }

    /// 引用行的右键 / 工具条动作统一入口，按引用类别分发（对齐 Tauri
    /// `getGitReferenceActions` 的可用集合）。
    fn run_reference_action(&mut self, action: &'static str, cx: &mut Context<Self>) {
        let Some(reference) = self.selected_reference_object().cloned() else {
            return;
        };
        match action {
            "checkout" => match reference.kind.as_str() {
                "tag" => self.request_reference_confirm(
                    "checkout",
                    "checkout",
                    reference,
                    tr("Checkout"),
                    cx,
                ),
                _ => self.checkout_reference(&reference, cx),
            },
            "createBranch" => self.request_create_branch(cx),
            "checkoutAndRebase" => self.request_reference_confirm(
                "checkoutAndRebase",
                "checkoutAndRebase",
                reference,
                tr("Checkout and Rebase"),
                cx,
            ),
            "compareWithCurrent" => {
                // 对齐 Tauri `viewBranchDiff`：打开选中引用与工作区的比较。
                // GPUI 的 diff 视图尚未接入，先按引用过滤历史作为最小可用行为。
                self.select_reference(reference.short_name.clone(), cx);
            }
            "rebaseCurrentOnto" => self.request_reference_confirm(
                "rebaseCurrentOnto",
                "rebase",
                reference,
                tr("Rebase Current onto Selected"),
                cx,
            ),
            "mergeIntoCurrent" => self.request_reference_confirm(
                "mergeIntoCurrent",
                "merge",
                reference,
                tr("Merge Selected into Current"),
                cx,
            ),
            "pullRebaseIntoCurrent" => self.request_reference_confirm(
                "pullRebaseIntoCurrent",
                "pull",
                reference,
                tr("Pull (Rebase) into Current"),
                cx,
            ),
            "pullMergeIntoCurrent" => self.request_reference_confirm(
                "pullMergeIntoCurrent",
                "pull",
                reference,
                tr("Pull (Merge) into Current"),
                cx,
            ),
            "update" => self.update_reference(&reference, cx),
            "push" => self.push_reference(&reference, cx),
            "rename" => self.request_rename_branch(&reference, cx),
            "deleteLocal" => self.delete_local_reference(&reference, cx),
            "deleteRemote" => self.delete_remote_reference(&reference, cx),
            "deleteTag" => {
                let title = reference_action_title("deleteTag");
                let message = format!("{}?", reference.short_name);
                self.reference_confirm = Some(ReferenceConfirm {
                    operation: "deleteTag",
                    reference,
                    title,
                    message,
                    success: tr("Tag deleted"),
                });
                cx.notify();
            }
            _ => {}
        }
    }

    // -----------------------------------------------------------------------
    // 提交动作（对齐 Tauri use-git-history-mutations）
    // -----------------------------------------------------------------------

    /// 打开提交动作菜单。条目对齐 Tauri `git-commit-table` 的右键内容。
    fn open_commit_menu(
        &mut self,
        commit: CoreCommit,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let busy = self.is_reference_busy() || self.loading_rewrite_preview;
        let owner = cx.weak_entity();
        let is_head = self
            .history
            .first()
            .is_some_and(|first| first.hash == commit.hash);

        let popup =
            gpui_kit::component::menu::PopupMenu::build(window, cx, move |menu, _window, _cx| {
                let short_hash: String = commit.hash.chars().take(8).collect();
                let subject = commit.subject.clone();

                let item = |menu: gpui_kit::component::menu::PopupMenu,
                            owner: &gpui_kit::WeakEntity<GitPanel>,
                            action: &'static str,
                            label: &'static str,
                            disabled: bool|
                 -> gpui_kit::component::menu::PopupMenu {
                    let owner = owner.clone();
                    menu.item(PopupMenuItem::new(label).disabled(disabled).on_click(
                        move |_, _, cx| {
                            let _ = owner.update(cx, |this, cx| {
                                this.run_commit_action(action, cx);
                            });
                        },
                    ))
                };

                // 打开提交差异 / 与 HEAD 比较：GPUI 的 diff 渲染面尚未接入，
                // 这里按 Tauri 行为降级为加载该提交的文件列表。
                let menu = item(menu, &owner, "openDiff", tr("Open Commit Diff"), false);
                let menu = item(
                    menu,
                    &owner,
                    "compareWithHead",
                    tr("Compare with HEAD"),
                    false,
                );
                let menu = menu.separator();

                // 历史改写（undo / edit / delete）需要预览确认；undo 仅限 HEAD。
                let menu = item(menu, &owner, "undo", tr("Undo Commit"), busy || !is_head);
                let menu = item(menu, &owner, "edit", tr("Edit Commit Message"), busy);
                let menu = item(menu, &owner, "delete", tr("Delete Commit"), busy);
                let menu = item(menu, &owner, "reset", tr("Reset to Commit"), busy);
                let menu = item(
                    menu,
                    &owner,
                    "cherryPick",
                    tr("Cherry-pick Commit"),
                    busy || is_head,
                );
                let menu = item(menu, &owner, "revert", tr("Revert Commit"), busy);
                let menu = menu.separator();

                let copy = |menu: gpui_kit::component::menu::PopupMenu,
                            owner: gpui_kit::WeakEntity<GitPanel>,
                            text: String|
                 -> gpui_kit::component::menu::PopupMenu {
                    menu.item(PopupMenuItem::new(tr("Copy Commit Hash")).on_click(
                        move |_, window, cx| {
                            let _ = owner.update(cx, |this, cx| {
                                this.copy_text(&text.clone(), window, cx);
                            });
                        },
                    ))
                };
                let menu = copy(menu, owner.clone(), commit.hash.clone());
                let menu = copy(menu, owner.clone(), short_hash.clone());
                let menu = copy(menu, owner, subject);
                menu
            });

        cx.subscribe_in(
            &popup,
            window,
            |this, _, _: &gpui_kit::DismissEvent, _window, cx| {
                this.commit_menu = None;
                cx.notify();
            },
        )
        .detach();
        self.commit_menu = Some((popup, position));
        cx.notify();
    }

    /// 提交动作统一入口。
    fn run_commit_action(&mut self, action: &str, cx: &mut Context<Self>) {
        let Some(commit) = self.selected_commit() else {
            return;
        };
        let hash = commit.hash.clone();
        let subject = commit.subject.clone();
        match action {
            // 差异视图未接入前，选中提交即加载文件列表（与点击行一致）。
            "openDiff" | "compareWithHead" => {
                self.select_commit(hash, cx);
            }
            "undo" => self.begin_rewrite(RewriteOperation::UndoCommit, hash, cx),
            "edit" => self.begin_rewrite(RewriteOperation::EditCommitMessage, hash, cx),
            "delete" => self.begin_rewrite(RewriteOperation::DeleteCommit, hash, cx),
            "reset" => {
                let short_hash: String = hash.chars().take(8).collect();
                self.commit_action = Some(CommitAction::Reset { revision: hash });
                self.notice = Some(SharedString::from(format!(
                    "{}: {}",
                    tr("Reset to Commit"),
                    short_hash
                )));
                cx.notify();
            }
            "cherryPick" => {
                self.commit_action = Some(CommitAction::Simple {
                    operation: "cherryPick",
                    revision: hash,
                    title: tr("Cherry-pick Commit"),
                    message: format!("{} \"{}\"?", tr("Cherry-pick Commit"), subject),
                });
                cx.notify();
            }
            "revert" => {
                self.commit_action = Some(CommitAction::Simple {
                    operation: "revert",
                    revision: hash,
                    title: tr("Revert Commit"),
                    message: format!("{} \"{}\"?", tr("Revert Commit"), subject),
                });
                cx.notify();
            }
            _ => {}
        }
    }

    /// 当前选中的提交对象。
    fn selected_commit(&self) -> Option<&CoreCommit> {
        let hash = self.selected_commit_hash.as_ref()?;
        self.history.iter().find(|commit| &commit.hash == hash)
    }

    /// 发起历史改写：先加载 `git.historyRewritePreview`，允许则进入确认，
    /// 编辑消息则进入输入步骤。
    fn begin_rewrite(
        &mut self,
        operation: RewriteOperation,
        revision: String,
        cx: &mut Context<Self>,
    ) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root_text(&root) else {
            return;
        };
        if self.loading_rewrite_preview || self.is_reference_busy() {
            return;
        }

        let generation = self.generation;
        let client = self.client;
        self.loading_rewrite_preview = true;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let payload = serde_json::json!({
                "root": root_text,
                "operation": operation.wire(),
                "revisions": [revision],
            });
            let raw = cx
                .background_spawn(async move {
                    client.execute_raw("git.historyRewritePreview", payload)
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.loading_rewrite_preview = false;
                match raw {
                    Ok(value) => {
                        let preview = parse_rewrite_preview(&value, operation);
                        if !preview.allowed || preview.expected_state.is_none() {
                            let detail = if preview.blockers.is_empty() {
                                tr("Git history operation failed").to_string()
                            } else {
                                preview.blockers.join("\n")
                            };
                            this.error = Some(SharedString::from(detail));
                        } else if operation == RewriteOperation::EditCommitMessage {
                            // 输入弹窗预填 Core 的 suggestedMessage。
                            this.pending_rewrite_preview = Some(Box::new(preview));
                            this.commit_action = Some(CommitAction::EditMessageInput { revision });
                        } else {
                            this.commit_action = Some(CommitAction::Rewrite {
                                operation,
                                revision,
                            });
                            // 预览数据随动作一起保存，确认时直接取。
                            this.pending_rewrite_preview = Some(Box::new(preview));
                        }
                    }
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 执行历史改写：把预览的 expectedState 原样回传 `git.write`（对齐 Tauri
    /// `executeGitHistoryRewrite`）。编辑消息附带用户修改后的 message。
    fn execute_rewrite(
        &mut self,
        preview: RewritePreview,
        message: Option<String>,
        cx: &mut Context<Self>,
    ) {
        let Some(expected) = preview.expected_state.clone() else {
            return;
        };
        let operation = expected
            .get("operation")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let revisions: Vec<String> = expected
            .get("revisions")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(Value::as_str)
                    .map(String::from)
                    .collect()
            })
            .unwrap_or_default();
        if operation.is_empty() || revisions.is_empty() {
            return;
        }

        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root_text(&root) else {
            return;
        };

        let mut payload = serde_json::json!({
            "root": root_text,
            "operation": operation,
            "expectedState": expected,
        });
        if operation == "squashCommits" {
            payload["revisions"] = serde_json::Value::Array(
                revisions
                    .iter()
                    .map(|r| serde_json::Value::String(r.clone()))
                    .collect(),
            );
        } else {
            payload["revision"] = serde_json::Value::String(revisions[0].clone());
        }
        if let Some(text) = message {
            payload["message"] = serde_json::Value::String(text);
        }

        let generation = self.generation;
        let client = self.client;
        self.reference_mutation = Some("historyRewrite");
        self.error = None;
        self.notice = None;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move { client.execute_raw("git.write", payload) })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.reference_mutation = None;
                match raw {
                    Ok(value) => {
                        let command = parse_command(&value).unwrap_or_default();
                        if command.exit_code == 0 {
                            this.reload_all(cx);
                            this.notice = Some(SharedString::from(tr("History rewritten")));
                        } else {
                            this.error = Some(SharedString::from(command_failure_detail(
                                &command,
                                tr("Git history operation failed"),
                            )));
                        }
                    }
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 执行 reset / cherry-pick / revert 这类直接写操作。
    fn run_simple_commit_write(
        &mut self,
        operation: &'static str,
        revision: &str,
        mode: Option<&str>,
        title: &'static str,
        cx: &mut Context<Self>,
    ) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root_text(&root) else {
            return;
        };
        if self.is_reference_busy() {
            return;
        }

        let mut payload = serde_json::json!({
            "root": root_text,
            "operation": operation,
            "revision": revision,
        });
        if let Some(mode) = mode {
            payload["mode"] = serde_json::Value::String(format!("--{mode}"));
        }

        let generation = self.generation;
        let client = self.client;
        self.reference_mutation = Some(title);
        self.error = None;
        self.notice = None;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move { client.execute_raw("git.write", payload) })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.reference_mutation = None;
                match raw {
                    Ok(value) => {
                        let command = parse_command(&value).unwrap_or_default();
                        if command.exit_code == 0 {
                            this.reload_all(cx);
                            this.notice = Some(SharedString::from(title));
                        } else {
                            this.error =
                                Some(SharedString::from(command_failure_detail(&command, title)));
                        }
                    }
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 确认当前挂起的提交动作。
    fn confirm_commit_action(&mut self, cx: &mut Context<Self>) {
        let Some(action) = self.commit_action.take() else {
            return;
        };
        self.pending_rewrite_preview = None;
        match action {
            CommitAction::Rewrite { .. } => {
                // 预览在 begin_rewrite 里已暂存。
                if let Some(preview) = self.pending_rewrite_preview.take() {
                    self.execute_rewrite(*preview, None, cx);
                }
            }
            CommitAction::Reset { revision } => {
                self.run_simple_commit_write(
                    "reset",
                    &revision,
                    Some("mixed"),
                    tr("Reset to Commit"),
                    cx,
                );
            }
            CommitAction::Simple {
                operation,
                revision,
                title,
                ..
            } => {
                self.run_simple_commit_write(operation, &revision, None, title, cx);
            }
            CommitAction::EditMessageInput { .. } => {
                // 输入步骤由专门弹窗处理；这里不应到达。
            }
        }
        cx.notify();
    }

    fn cancel_commit_action(&mut self, cx: &mut Context<Self>) {
        if self.commit_action.take().is_some() {
            self.pending_rewrite_preview = None;
            cx.notify();
        }
    }

    /// Git Log 中栏：过滤搜索工具栏 + 彩色分支图轨提交表（对齐截图中间）。
    fn render_log_table(
        &mut self,
        window: &mut Window,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // 文本过滤：按作用域大小写不敏感匹配（对齐 Tauri matchesGitLogCommit）。
        let filter = self.commit_filter.trim().to_lowercase();
        let scope = self.commit_filter_scope;
        let visible: Vec<&CoreCommit> = self
            .history
            .iter()
            .filter(|commit| scope.matches(commit, &filter))
            .collect();

        // 分支筛选标签：All branches 或当前选中的引用短名。
        let branch_label = self
            .selected_reference
            .clone()
            .unwrap_or_else(|| tr("All branches").to_string());

        // 惰性创建过滤输入框（InputState 需要 Window）。
        if self.filter_input.is_none() {
            let input = cx.new(|cx| InputState::new(window, cx).placeholder(tr("Filter by text…")));
            cx.subscribe_in(
                &input,
                window,
                |_this, _input, event: &InputEvent, _window, cx| {
                    if matches!(event, InputEvent::Change) {
                        // 由输入框自身持有文本；过滤读它，因此只需重绘。
                        cx.notify();
                    }
                },
            )
            .detach();
            self.filter_input = Some(input);
        }
        let filter_input = self.filter_input.clone();
        // 输入框是过滤关键字的真源：每次渲染同步回状态，过滤与计数都基于它。
        if let Some(input) = filter_input.as_ref() {
            self.commit_filter = input.read(cx).value().to_string();
        }
        let committed_filter = self.commit_filter.clone();
        let scope_for_menu = scope;
        let owner = cx.weak_entity();

        // 顶部过滤工具条（对齐 Tauri `GitCommitTable` 顶部工具条）。
        let filter_toolbar = h_flex()
            .w_full()
            .h(px(32.0))
            .items_center()
            .gap(px(8.0))
            .px(px(8.0))
            .bg(tokens.editor)
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                div().w(px(180.0)).child(
                    filter_input
                        .clone()
                        .map(|input| Input::new(&input).small().into_any_element())
                        .unwrap_or_else(|| div().into_any_element()),
                ),
            )
            // 过滤作用域选择（Text / Author / Branch，对齐 Tauri 的 scope 下拉）。
            .child(
                Button::new("git-log:filter-scope")
                    .ghost()
                    .small()
                    .rounded(px(4.0))
                    .label(scope.label())
                    .tooltip(tr("Filter scope"))
                    .dropdown_menu_with_anchor(Anchor::TopLeft, move |menu, _window, _cx| {
                        let mut menu = menu.min_w(px(140.0));
                        for (value, label) in [
                            (CommitFilterScope::Text, tr("Text")),
                            (CommitFilterScope::Author, tr("Author")),
                            (CommitFilterScope::Branch, tr("Branch")),
                        ] {
                            let owner = owner.clone();
                            menu = menu.item(
                                PopupMenuItem::new(label)
                                    .checked(value == scope_for_menu)
                                    .on_click(move |_, _, cx| {
                                        let _ = owner.update(cx, |this, cx| {
                                            this.commit_filter_scope = value;
                                            cx.notify();
                                        });
                                    }),
                            );
                        }
                        menu
                    }),
            )
            // 分支筛选选择（All branches + 每个引用）。
            .child({
                let owner = cx.weak_entity();
                let references: Vec<CoreReference> = self.references.clone();
                let selected = self.selected_reference.clone();
                Button::new("git-log:branch-filter")
                    .ghost()
                    .small()
                    .rounded(px(4.0))
                    .label(branch_label)
                    .tooltip(tr("Branch filter"))
                    .dropdown_menu_with_anchor(Anchor::TopLeft, move |menu, _window, _cx| {
                        let mut menu = menu.min_w(px(200.0));
                        let owner_all = owner.clone();
                        let is_all = selected.is_none();
                        menu = menu.item(
                            PopupMenuItem::new(tr("All branches"))
                                .checked(is_all)
                                .on_click(move |_, _, cx| {
                                    let _ = owner_all.update(cx, |this, cx| {
                                        this.select_reference(String::new(), cx);
                                    });
                                }),
                        );
                        for reference in references.iter() {
                            let owner = owner.clone();
                            let name = reference.short_name.clone();
                            let checked = selected.as_deref() == Some(name.as_str());
                            menu = menu.item(
                                PopupMenuItem::new(name.clone()).checked(checked).on_click(
                                    move |_, _, cx| {
                                        let name = name.clone();
                                        let _ = owner.update(cx, |this, cx| {
                                            this.select_reference(name, cx);
                                        });
                                    },
                                ),
                            );
                        }
                        menu
                    })
            })
            .child(div().flex_1())
            // 视图选项：装饰胶囊开关等（对齐 Tauri showDecorations）。
            .child({
                let owner = cx.weak_entity();
                let decorations_on = self.show_decorations;
                Button::new("git-log:view-options")
                    .ghost()
                    .with_size(px(24.0))
                    .rounded(px(4.0))
                    .tooltip(tr("View options"))
                    .child(Icon::new(gpui_kit::assets::IconName::Eye).with_size(px(14.0)))
                    .dropdown_menu_with_anchor(Anchor::TopRight, move |menu, _window, _cx| {
                        let owner = owner.clone();
                        menu.min_w(px(200.0)).item(
                            PopupMenuItem::new(tr("Show decorations"))
                                .checked(decorations_on)
                                .on_click(move |_, _, cx| {
                                    let _ = owner.update(cx, |this, cx| {
                                        this.show_decorations = !this.show_decorations;
                                        cx.notify();
                                    });
                                }),
                        )
                    })
            })
            .child(
                Button::new("git-log:locate-head")
                    .ghost()
                    .with_size(px(24.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Go to HEAD"))
                    .child(
                        Icon::new(gpui_kit::assets::IconName::ArrowDownToLine).with_size(px(14.0)),
                    )
                    // 定位 HEAD：选中当前分支的历史，与左栏的 HEAD 按钮同一条路径。
                    .on_click(cx.listener(|this, _, _window, cx| {
                        if let Some(current) = this
                            .references
                            .iter()
                            .find(|reference| reference.is_current)
                        {
                            this.select_reference(current.short_name.clone(), cx);
                        }
                    })),
            )
            .child(
                div()
                    .px(px(4.0))
                    .text_size(px(12.0))
                    .font_family(MONO_FONT_FAMILY)
                    .text_color(tokens.secondary_text)
                    // 真实计数：过滤后条数 / 缓冲区总条数。
                    .child(format!("{}/{}", visible.len(), self.history.len())),
            );
        let _ = committed_filter;

        // 提交数据表行（带彩色分支线和胶囊 Badge）
        let mut commit_list = v_flex()
            .id("lithe-git-log-table")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .bg(tokens.editor);

        let selected_hash = self
            .selected_commit_hash
            .clone()
            .or_else(|| self.history.first().map(|c| c.hash.clone()));

        // 彩色轨道颜色池（对齐 IntelliJ 图谱：绿、紫、蓝、橙）
        let graph_palette = [
            hex(0x57965C), // 绿色
            hex(0x9E6BD6), // 紫色
            hex(0x3871E1), // 蓝色
            hex(0xE8A033), // 橙色
        ];

        for (index, commit) in visible.iter().enumerate() {
            let is_selected = selected_hash.as_deref() == Some(&commit.hash);
            let track_color = graph_palette[index % graph_palette.len()];
            let hash = commit.hash.clone();
            let date_str = commit.date.clone();
            let commit_for_menu = (*commit).clone();

            commit_list = commit_list.child(
                h_flex()
                    .id(SharedString::from(format!(
                        "git-commit-row:{}",
                        commit.hash
                    )))
                    .w_full()
                    .h(px(22.0))
                    .px(px(6.0))
                    .items_center()
                    .gap(px(4.0))
                    .when(is_selected, |this| this.bg(tokens.subtle_selection))
                    .when(!is_selected, |this| this.hover(|s| s.bg(tokens.hover)))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        this.select_commit(hash.clone(), cx);
                    }))
                    // 右键：先选中该提交再打开动作菜单（对齐 Tauri onContextSelect）。
                    .on_mouse_down(
                        gpui_kit::MouseButton::Right,
                        cx.listener(move |this, event: &gpui_kit::MouseDownEvent, window, cx| {
                            this.select_commit(commit_for_menu.hash.clone(), cx);
                            this.open_commit_menu(
                                commit_for_menu.clone(),
                                event.position,
                                window,
                                cx,
                            );
                        }),
                    )
                    // 彩色图轨单元格
                    .child(
                        div()
                            .w(px(18.0))
                            .h_full()
                            .relative()
                            .flex()
                            .items_center()
                            .justify_center()
                            // 垂直轨道连线
                            .child(div().absolute().w(px(2.0)).h_full().bg(track_color))
                            // 节点实心圆圈
                            .child(
                                div()
                                    .size(px(6.0))
                                    .rounded_full()
                                    .border_1()
                                    .border_color(tokens.editor)
                                    .bg(track_color),
                            ),
                    )
                    // 提交标题正文
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(px(12.0))
                            .font_weight(if is_selected {
                                FontWeight::SEMIBOLD
                            } else {
                                FontWeight::NORMAL
                            })
                            .text_color(tokens.primary_text)
                            .child(commit.subject.clone()),
                    )
                    // 分支胶囊 Badge（紧凑药丸形）
                    .when(
                        self.show_decorations && !commit.decorations.is_empty(),
                        |this| {
                            this.child(
                                div()
                                    .px(px(4.0))
                                    .py(px(0.5))
                                    .rounded(px(3.0))
                                    .border_1()
                                    .border_color(track_color)
                                    .bg(track_color.alpha(0.18))
                                    .text_size(px(10.5))
                                    .text_color(track_color)
                                    .child(commit.decorations.clone()),
                            )
                        },
                    )
                    // 作者
                    .child(
                        div()
                            .w(px(90.0))
                            .px(px(6.0))
                            .truncate()
                            .text_size(px(11.5))
                            .text_color(tokens.secondary_text)
                            .child(commit.author_name.clone()),
                    )
                    // 日期（单行不折行）
                    .child(
                        div()
                            .w(px(120.0))
                            .truncate()
                            .text_size(px(11.5))
                            .text_color(tokens.tertiary_text)
                            .child(date_str),
                    ),
            );
        }

        v_flex()
            .flex_1()
            .h_full()
            .min_w_0()
            .child(filter_toolbar)
            .child(commit_list)
            .into_any_element()
    }

    /// Git Log 右栏：改动文件树（上半部分） + 提交详细说明（下半部分）。
    fn render_log_inspector(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let selected_commit = self
            .selected_commit_hash
            .as_ref()
            .and_then(|hash| self.history.iter().find(|c| &c.hash == hash))
            .or_else(|| self.history.first());

        let file_count = self.commit_files.len();

        // 上半部分：提交文件树
        let mut file_tree = v_flex()
            .id("lithe-git-log-file-tree")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .p(px(6.0))
            .gap(px(2.0));

        if self.commit_files.is_empty() {
            file_tree = file_tree.child(
                div()
                    .p(px(12.0))
                    .text_size(px(12.0))
                    .text_color(tokens.secondary_text)
                    .child(if self.loading_commit_files {
                        tr("Loading…")
                    } else {
                        tr("Select a commit to see its files.")
                    }),
            );
        } else {
            // 目录树：按 `/` 拆段建树，逐层缩进渲染文件夹与文件；
            // 折叠状态存于 `collapsed_commit_dirs`（对齐 Tauri 文件树的目录折叠）。
            let tree_root = build_commit_file_tree(&self.commit_files);
            file_tree = render_commit_tree_nodes(
                &tree_root,
                0,
                &self.collapsed_commit_dirs,
                self.selected_commit_file.as_deref(),
                tokens,
                cx,
                file_tree,
            );
        }

        let files_header = h_flex()
            .w_full()
            .h(px(28.0))
            .items_center()
            .justify_between()
            .px(px(8.0))
            .bg(tokens.sidebar)
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                div()
                    .text_size(px(12.0))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.primary_text)
                    .child(tr("Commit files")),
            )
            .child(
                div()
                    .text_size(px(11.0))
                    .text_color(tokens.secondary_text)
                    .child(format!("{} {}", file_count, tr("files"))),
            );

        let files_half = v_flex()
            .flex_1()
            .min_h_0()
            .border_b_1()
            .border_color(tokens.divider)
            .child(files_header)
            .child(file_tree);

        // 下半部分：提交正文与元数据。差异本身在**中央编辑区**打开
        //（`CommitDiffView`），右栏只保留文件树与说明，避免把 diff 挤在窄栏里。
        let message_half = v_flex()
            .id("lithe-git-log-message-half")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .p(px(12.0))
            .gap(px(8.0))
            .when_some(selected_commit, |this, commit| {
                this.child(
                    div()
                        .text_size(px(13.0))
                        .font_weight(FontWeight::BOLD)
                        .text_color(tokens.primary_text)
                        .child(commit.subject.clone()),
                )
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(tokens.secondary_text)
                        .child(format!("{} · {}", commit.author_name, commit.date)),
                )
                .child(
                    div()
                        .pt(px(4.0))
                        .text_size(px(12.0))
                        .font_family(MONO_FONT_FAMILY)
                        .text_color(tokens.tertiary_text)
                        .child(format!("commit {}", commit.hash)),
                )
            });

        v_flex()
            .id("lithe-git-log-inspector")
            .w(px(460.0))
            .h_full()
            .flex_shrink_0()
            .bg(tokens.editor)
            .border_l_1()
            .border_color(tokens.divider)
            .child(files_half)
            .child(message_half)
            .into_any_element()
    }
}

impl Render for GitPanel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 构造期不能 spawn：cx.new 还在 App 的可变借用内。把首帧输入创建和
        // 根目录加载排到借用释放之后。
        if self.pending_input_init || self.pending_initial_load {
            let init_input = self.pending_input_init;
            let initial_load = self.pending_initial_load;
            self.pending_input_init = false;
            self.pending_initial_load = false;
            cx.defer_in(window, move |this, window, cx| {
                if init_input {
                    this.ensure_commit_input(window, cx);
                }
                if initial_load && this.root.is_some() {
                    this.reload_all(cx);
                    cx.notify();
                }
            });
        }

        // 提交成功时在拿到 window 的帧里清空输入。
        if self.pending_clear_message {
            self.pending_clear_message = false;
            if let Some(input) = self.commit_input.clone() {
                cx.defer_in(window, move |_this, window, cx| {
                    input.update(cx, |state, cx| state.set_value("", window, cx));
                });
            }
        }

        let tokens = current_tokens(cx);
        let mut panel = v_flex()
            .id("lithe-git-panel")
            .size_full()
            .min_w_0()
            .min_h_0()
            .bg(tokens.sidebar)
            .text_color(tokens.primary_text);

        // 提交记录模式复用同一个实体类型，但只渲染历史列表。
        if self.mode == GitPanelMode::Log {
            if self.root.is_none() {
                return self.with_floating_menu(
                    panel
                        .child(
                            div()
                                .flex_1()
                                .min_h_0()
                                .child(empty_state(tokens, tr("No project open"))),
                        )
                        .into_any_element(),
                    cx,
                );
            }
            let log_view = self.render_log_view(window, tokens, cx);
            return self.with_floating_menu(panel.child(log_view).into_any_element(), cx);
        }

        panel = panel.child(self.render_changes_toolbar(tokens, cx));

        if let Some(error) = self.error.clone() {
            panel = panel.child(status_line(tokens.error, error));
        } else if let Some(notice) = self.notice.clone() {
            panel = panel.child(status_line(tokens.success, notice));
        }

        if self.root.is_none() {
            return self.with_floating_menu(
                panel
                    .child(
                        div()
                            .flex_1()
                            .min_h_0()
                            .child(empty_state(tokens, tr("No project open"))),
                    )
                    .into_any_element(),
                cx,
            );
        }

        let content = panel
            .child(self.render_body(tokens, cx))
            .child(self.render_bottom(tokens, cx));

        let Some((path, group)) = self.pending_discard.clone() else {
            return self.with_floating_menu(content.into_any_element(), cx);
        };

        self.with_floating_menu(
            div()
                .relative()
                .size_full()
                .child(content)
                .child(self.render_discard_confirm(path, group, tokens, cx))
                .into_any_element(),
            cx,
        )
    }
}

impl GitPanel {
    /// 把右键创建的 PopupMenu 渲染到窗口前景层。
    ///
    /// 之前菜单实体只创建不渲染，引用/提交的右键菜单从未显示过。
    fn with_floating_menu(&self, element: AnyElement, cx: &mut Context<Self>) -> AnyElement {
        let mut wrapper = div().relative().size_full().child(element);
        if let Some((popup, position)) = &self.reference_menu {
            wrapper = wrapper.child(self.floating_popup(popup.clone(), *position, cx));
        }
        if let Some((popup, position)) = &self.commit_menu {
            wrapper = wrapper.child(self.floating_popup(popup.clone(), *position, cx));
        }
        wrapper.into_any_element()
    }

    /// 单个弹出菜单：按触发时的窗口坐标锚定，点击外部关闭。
    fn floating_popup(
        &self,
        popup: Entity<gpui_kit::component::menu::PopupMenu>,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let owner = cx.weak_entity();
        deferred(
            anchored().position(position).snap_to_window().child(
                div()
                    .occlude()
                    .on_mouse_down_out(cx.listener(move |this, _, _, cx| {
                        if this.reference_menu.take().is_some() || this.commit_menu.take().is_some()
                        {
                            cx.notify();
                        }
                    }))
                    .child(popup),
            ),
        )
        .into_any_element()
    }
}

impl GitPanel {
    /// 丢弃确认覆盖层。
    fn render_discard_confirm(
        &self,
        path: String,
        group: ChangeGroup,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let cancel_path = path.clone();
        let confirm_path = path.clone();
        let display = split_path(&path).0;

        div()
            .id("lithe-git-discard-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .on_click(cx.listener(move |this, _, _, cx| {
                this.pending_discard = None;
                let _ = &cancel_path;
                cx.notify();
            }))
            .child(
                v_flex()
                    .id("lithe-git-discard-dialog")
                    .w(px(420.0))
                    .rounded(px(LitheMetrics::MENU_RADIUS))
                    .border_1()
                    .border_color(tokens.panel_border)
                    .bg(tokens.raised)
                    .p(px(16.0))
                    .gap(px(10.0))
                    .on_click(cx.listener(|_, _, _, cx| cx.stop_propagation()))
                    .child(
                        div()
                            .text_size(px(14.0))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.primary_text)
                            .child(tr("Discard changes?")),
                    )
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(format!(
                                "{}: {display}",
                                tr("This action cannot be undone by Lithe.")
                            )),
                    )
                    .child(
                        h_flex()
                            .w_full()
                            .justify_end()
                            .gap(px(8.0))
                            .child(
                                Button::new("lithe-git-discard-cancel")
                                    .ghost()
                                    .small()
                                    .label(tr("Cancel"))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.pending_discard = None;
                                        cx.notify();
                                    })),
                            )
                            .child(
                                Button::new("lithe-git-discard-confirm")
                                    .danger()
                                    .small()
                                    .label(tr("Discard"))
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.apply_change_action(
                                            confirm_path.clone(),
                                            group,
                                            ChangeAction::Discard,
                                            cx,
                                        );
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }
}

// --- 渲染辅助 --------------------------------------------------------------

/// 提交文件树的节点：目录（含子节点）或文件。
struct CommitTreeEntry {
    /// 展示名（目录的一段名或文件名）。
    name: String,
    /// 相对仓库根的完整路径；目录与文件都用它作为折叠/选中 key。
    path: String,
    /// 目录的子节点；文件为空。
    children: Vec<CommitTreeEntry>,
    /// 是否为目录。
    is_dir: bool,
}

/// 把扁平的提交文件列表按 `/` 拆成目录树。
///
/// 目录节点排在文件之前，同类按名字排序，结果稳定可复现。
fn build_commit_file_tree(files: &[String]) -> Vec<CommitTreeEntry> {
    fn insert(nodes: &mut Vec<CommitTreeEntry>, file: &str, segments: &[&str], prefix: &str) {
        let Some((head, rest)) = segments.split_first() else {
            return;
        };
        let path = if prefix.is_empty() {
            (*head).to_string()
        } else {
            format!("{prefix}/{head}")
        };
        if rest.is_empty() {
            nodes.push(CommitTreeEntry {
                name: (*head).to_string(),
                path,
                children: Vec::new(),
                is_dir: false,
            });
            return;
        }
        let index = match nodes
            .iter()
            .position(|node| node.is_dir && node.name == *head)
        {
            Some(index) => index,
            None => {
                nodes.push(CommitTreeEntry {
                    name: (*head).to_string(),
                    path: path.clone(),
                    children: Vec::new(),
                    is_dir: true,
                });
                nodes.len() - 1
            }
        };
        insert(&mut nodes[index].children, file, rest, &path);
    }

    fn sort(nodes: &mut Vec<CommitTreeEntry>) {
        nodes.sort_by(|a, b| {
            b.is_dir
                .cmp(&a.is_dir)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });
        for node in nodes.iter_mut() {
            sort(&mut node.children);
        }
    }

    let mut root = Vec::new();
    for file in files {
        let segments: Vec<&str> = file.split('/').filter(|s| !s.is_empty()).collect();
        insert(&mut root, file, &segments, "");
    }
    sort(&mut root);
    root
}

/// 递归渲染提交文件树节点。`Div` 的构建器是消费式的，因此按值进出。
fn render_commit_tree_nodes(
    nodes: &[CommitTreeEntry],
    depth: usize,
    collapsed: &ExpandedSet,
    selected_file: Option<&str>,
    tokens: LitheTokens,
    cx: &mut Context<GitPanel>,
    mut out: Stateful<Div>,
) -> Stateful<Div> {
    for node in nodes {
        let indent = px(6.0 + depth as f32 * 12.0);
        if node.is_dir {
            let is_collapsed = collapsed.contains(&node.path);
            let path = node.path.clone();
            out = out.child(
                h_flex()
                    .id(SharedString::from(format!("git-log-dir-row:{}", node.path)))
                    .w_full()
                    .h(px(22.0))
                    .pl(indent)
                    .pr(px(6.0))
                    .rounded(px(4.0))
                    .items_center()
                    .gap(px(4.0))
                    .hover(|s| s.bg(tokens.hover))
                    .cursor_pointer()
                    .child(
                        Icon::new(if is_collapsed {
                            gpui_kit::assets::IconName::ChevronRight
                        } else {
                            gpui_kit::assets::IconName::ChevronDown
                        })
                        .with_size(px(10.0))
                        .text_color(tokens.secondary_text),
                    )
                    .child(
                        Icon::new(gpui_kit::assets::IconName::Folder)
                            .with_size(px(13.0))
                            .text_color(tokens.secondary_text),
                    )
                    .child(
                        div()
                            .truncate()
                            .text_size(px(12.0))
                            .text_color(tokens.secondary_text)
                            .child(node.name.clone()),
                    )
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        if !this.collapsed_commit_dirs.remove(&path) {
                            this.collapsed_commit_dirs.insert(path.clone());
                        }
                        cx.notify();
                    })),
            );
            if !is_collapsed {
                out = render_commit_tree_nodes(
                    &node.children,
                    depth + 1,
                    collapsed,
                    selected_file,
                    tokens,
                    cx,
                    out,
                );
            }
        } else {
            let path_str = node.path.clone();
            let path_for_open = node.path.clone();
            let is_selected = selected_file == Some(node.path.as_str());
            let icon_kind = if node.name.ends_with(".java") {
                icon(LitheIcon::Java).with_size(px(13.0))
            } else if node.name.ends_with(".xml") {
                Icon::new(gpui_kit::assets::IconName::Code).with_size(px(13.0))
            } else {
                icon(LitheIcon::File).with_size(px(13.0))
            };
            out = out.child(
                h_flex()
                    .id(SharedString::from(format!(
                        "git-log-file-row:{}",
                        node.path
                    )))
                    .w_full()
                    .h(px(22.0))
                    .pl(indent + px(14.0))
                    .pr(px(6.0))
                    .rounded(px(4.0))
                    .items_center()
                    .gap(px(6.0))
                    // 单击选中加载 diff；双击在编辑器打开工作区文件
                    //（对齐 Tauri onOpen / onDoubleClick 分工）。
                    .when(is_selected, |this| this.bg(tokens.subtle_selection))
                    .when(!is_selected, |this| this.hover(|s| s.bg(tokens.hover)))
                    .cursor_pointer()
                    .child(icon_kind)
                    .child(
                        div()
                            .truncate()
                            .text_size(px(12.0))
                            .text_color(tokens.primary_text)
                            .child(node.name.clone()),
                    )
                    .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                        if event.click_count() >= 2 {
                            // 双击：在编辑器打开工作区的真实文件。
                            this.open_change(&path_for_open.clone(), window, cx);
                        } else {
                            // 单击：在中央编辑区打开该提交的差异。
                            this.select_commit_file(path_str.clone(), window, cx);
                        }
                    })),
            );
        }
    }
    out
}

fn normalize_root(root: PathBuf) -> Option<PathBuf> {
    if root.as_os_str().is_empty() {
        None
    } else {
        Some(root)
    }
}

fn root_text(root: &Path) -> Option<String> {
    root.to_str().map(ToString::to_string)
}

// --- Core `data` 解析 ------------------------------------------------------
//
// 所有字段都按 camelCase 读取；缺失字段回落为空/0，只有顶层形状不对才报错，
// 这样单个可选字段的变化不会让整个面板变成错误页。

fn parse_status(value: &Value) -> Result<CoreStatus, String> {
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

fn parse_change(value: &Value) -> CoreChange {
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

fn parse_history_page(value: &Value) -> Result<CoreHistoryPage, String> {
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
fn parse_references(value: &Value) -> Vec<CoreReference> {
    value
        .get("references")
        .and_then(Value::as_array)
        .map(|items| items.iter().map(parse_reference).collect())
        .unwrap_or_default()
}

/// 解析 `git.historyRewritePreview` 响应。
fn parse_rewrite_preview(value: &Value, operation: RewriteOperation) -> RewritePreview {
    let _ = operation;
    let blockers = value
        .get("blockers")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.get("message").and_then(Value::as_str))
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();
    let selected_count = value
        .get("selectedCommits")
        .and_then(Value::as_array)
        .map(|items| items.len())
        .unwrap_or(0);

    RewritePreview {
        allowed: bool_field(value.get("allowed")),
        blockers,
        selected_count,
        suggested_message: string_field(value.get("suggestedMessage")),
        expected_state: value.get("expectedState").cloned(),
    }
}

fn parse_reference(value: &Value) -> CoreReference {
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

fn parse_commit(value: &Value) -> CoreCommit {
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

fn parse_command(value: &Value) -> Result<CoreCommand, String> {
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
fn command_failure_detail(command: &CoreCommand, fallback: &str) -> String {
    let stderr = command.stderr.trim();
    let output = command.output.trim();
    let detail = if stderr.is_empty() { output } else { stderr };
    if detail.is_empty() {
        fallback.to_string()
    } else {
        detail.to_string()
    }
}

fn string_field(value: Option<&Value>) -> String {
    value
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn optional_string(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).map(str::to_string)
}

fn bool_field(value: Option<&Value>) -> bool {
    value.and_then(Value::as_bool).unwrap_or(false)
}

fn usize_field(value: Option<&Value>) -> usize {
    value
        .and_then(Value::as_u64)
        .map(|number| usize::try_from(number).unwrap_or(usize::MAX))
        .unwrap_or(0)
}

fn in_group(change: &CoreChange, group: ChangeGroup) -> bool {
    match group {
        ChangeGroup::Staged => change.staged,
        ChangeGroup::Worktree => change.worktree,
        ChangeGroup::Untracked => change.untracked,
    }
}

/// 分组内每一行可用的动作。
///
/// 未跟踪项只给 Stage：Discard 对它们等于删除用户文件，不能放在一键操作里。
/// 已暂存行只给 Unstage；工作区组才提供 Stage / Discard（同一条目可能同时
/// 出现在两个组里，索引与工作区是两个独立维度）。
fn actions_for(change: &CoreChange, group: ChangeGroup) -> &'static [ChangeAction] {
    match group {
        ChangeGroup::Staged => &[ChangeAction::Unstage],
        ChangeGroup::Worktree if !change.untracked => &[ChangeAction::Stage, ChangeAction::Discard],
        ChangeGroup::Worktree | ChangeGroup::Untracked => &[ChangeAction::Stage],
    }
}

fn group_header(group: ChangeGroup, count: usize, tokens: LitheTokens) -> AnyElement {
    h_flex()
        .w_full()
        .flex_shrink_0()
        .h(px(GROUP_HEADER_HEIGHT))
        .gap(px(6.0))
        .px(px(ACTION_HORIZONTAL_PADDING))
        .child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(tokens.secondary_text)
                .child(group.title()),
        )
        .child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.tertiary_text)
                .child(count.to_string()),
        )
        .into_any_element()
}

fn render_change_row(
    change: &CoreChange,
    group: ChangeGroup,
    selected: bool,
    pending: Option<&PendingAction>,
    busy: bool,
    tokens: LitheTokens,
    cx: &mut Context<GitPanel>,
) -> AnyElement {
    let (file_name, directory) = split_path(&change.path);
    let letter = status_letter(change, group);
    let letter_color = if selected {
        white()
    } else {
        status_color(letter, change.untracked, tokens)
    };
    // 重命名在 Git 中同时提供旧路径；展示成 `old → new` 比只显示新路径更容易
    // 对应到用户改动的文件。
    let detail = match change.original_path.as_deref() {
        Some(original) if !original.is_empty() && original != change.path => {
            format!("{original} → {}", change.path)
        }
        _ => directory,
    };
    let detail = match change.untracked_file_count {
        Some(count) => format!("{detail} · {count}"),
        None => detail,
    };

    let click_selection = Selection {
        path: change.path.clone(),
        group,
    };
    let click_path = change.path.clone();
    // 复选框表示「纳入本次提交」。Core 只有索引这一个可写状态，因此勾选等价
    // 于暂存、取消勾选等价于取消暂存——与 IntelliJ 提交面板的语义一致。
    let checkbox_path = change.path.clone();
    let checkbox_checked = group == ChangeGroup::Staged;

    let mut row = div()
        .id(format!("lithe-git:change:{}:{}", group.id(), change.path))
        .w_full()
        .flex_shrink_0()
        .h(px(CHANGE_ROW_HEIGHT))
        .px(px(ACTION_HORIZONTAL_PADDING))
        .flex()
        .flex_row()
        .items_center()
        .gap(px(6.0))
        .when(selected, |this| this.bg(tokens.selection))
        .when(!selected, |this| this.hover(|style| style.bg(tokens.hover)))
        .cursor_pointer()
        .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
            this.select_change(click_selection.clone(), cx);
            if event.click_count() >= 2 {
                this.open_change(&click_path, window, cx);
            }
        }))
        .child(
            // IntelliJ 把「包含在提交里」的复选框放在状态字母之前。
            Checkbox::new(format!("lithe-git:include:{}:{}", group.id(), change.path))
                .small()
                .flex_shrink_0()
                .checked(checkbox_checked)
                .disabled(busy || !change.can_toggle_staging)
                .on_change(cx.listener(move |this, checked: &bool, _window, cx| {
                    let action = if *checked {
                        ChangeAction::Stage
                    } else {
                        ChangeAction::Unstage
                    };
                    this.apply_change_action(checkbox_path.clone(), group, action, cx);
                })),
        )
        .child(
            div()
                .w(px(LitheMetrics::TREE_ICON_SIZE))
                .flex_shrink_0()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .font_weight(FontWeight::BOLD)
                .text_color(letter_color)
                .child(letter.to_string()),
        )
        .child(
            v_flex()
                .min_w(px(0.0))
                .flex_1()
                .gap(px(1.0))
                .child(
                    div()
                        .min_w(px(0.0))
                        .truncate()
                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                        .text_color(if selected {
                            white()
                        } else {
                            tokens.primary_text
                        })
                        .child(file_name),
                )
                .when(!detail.is_empty(), |this| {
                    this.child(
                        div()
                            .min_w(px(0.0))
                            .truncate()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(if selected {
                                white()
                            } else {
                                tokens.secondary_text
                            })
                            .child(detail),
                    )
                }),
        );

    // 按钮始终显示（悬停显隐需要行级 group 状态，收益不值得额外复杂度）。
    for action in actions_for(change, group) {
        row = row.child(render_action_button(
            change, group, *action, selected, pending, busy, cx,
        ));
    }
    row.into_any_element()
}

/// 行内动作按钮。
///
/// 按钮嵌在可点击的变更行里，因此必须在自己的点击回调里 `stop_propagation`，
/// 否则一次点击会同时改变选中项，双击还会顺带打开文件。
fn render_action_button(
    change: &CoreChange,
    group: ChangeGroup,
    action: ChangeAction,
    selected: bool,
    pending: Option<&PendingAction>,
    busy: bool,
    cx: &mut Context<GitPanel>,
) -> AnyElement {
    let path = change.path.clone();
    let in_progress = matches!(
        pending,
        Some(PendingAction::Change {
            path: pending_path,
            group: pending_group,
            action: pending_action,
        }) if *pending_group == group
            && *pending_action == action
            && pending_path.as_str() == path.as_str()
    );
    // 子模块父 gitlink 无法安全切换暂存状态；Core 用 can_toggle_staging 标明。
    let staging_blocked =
        !change.can_toggle_staging && matches!(action, ChangeAction::Stage | ChangeAction::Unstage);

    Button::new(format!(
        "lithe-git:change:{}:{}:{}",
        group.id(),
        change.path,
        action.id()
    ))
    .ghost()
    .xsmall()
    .label(action.label())
    .loading(in_progress)
    .disabled(busy || staging_blocked)
    // 选中行是强调色背景，幽灵按钮需要换成白字才看得清。
    .when(selected, |this| this.text_color(white()))
    .on_click(cx.listener(move |this, _, _window, cx| {
        cx.stop_propagation();
        if action == ChangeAction::Discard {
            this.request_discard(path.clone(), group, cx);
        } else {
            this.apply_change_action(path.clone(), group, action, cx);
        }
    }))
    .into_any_element()
}

#[allow(dead_code)]
fn render_log_row(commit: &CoreCommit, tokens: LitheTokens) -> AnyElement {
    let short_hash = if commit.short_hash.is_empty() {
        commit.hash.chars().take(8).collect::<String>()
    } else {
        commit.short_hash.clone()
    };
    let subject = if commit.subject.is_empty() {
        tr("(No subject)").to_string()
    } else {
        commit.subject.clone()
    };
    let meta = if commit.author_name.is_empty() {
        commit.date.clone()
    } else {
        format!("{} · {}", commit.author_name, commit.date)
    };

    v_flex()
        .id(format!("lithe-git:log:{}", commit.hash))
        .w_full()
        .flex_shrink_0()
        .h(px(LOG_ROW_HEIGHT))
        .justify_center()
        .gap(px(2.0))
        .px(px(ACTION_HORIZONTAL_PADDING))
        .hover(|style| style.bg(tokens.hover))
        .child(
            h_flex()
                .w_full()
                .min_w(px(0.0))
                .gap(px(6.0))
                .child(
                    div()
                        .flex_shrink_0()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .font_family(MONO_FONT_FAMILY)
                        .text_color(tokens.link)
                        .child(short_hash),
                )
                .child(
                    div()
                        .min_w(px(0.0))
                        .flex_1()
                        .truncate()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.primary_text)
                        .child(subject),
                ),
        )
        .child(
            div()
                .min_w(px(0.0))
                .truncate()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.tertiary_text)
                .child(meta),
        )
        .into_any_element()
}

/// 引用树分组行的折叠箭头。
fn group_chevron(collapsed: bool, tokens: LitheTokens) -> AnyElement {
    Icon::new(if collapsed {
        gpui_kit::assets::IconName::ChevronRight
    } else {
        gpui_kit::assets::IconName::ChevronDown
    })
    .with_size(px(10.0))
    .text_color(tokens.secondary_text)
    .into_any_element()
}

/// 远程分组行的文件夹图标，随折叠状态切换开合。
fn remote_folder_icon(collapsed: bool, tokens: LitheTokens) -> AnyElement {
    Icon::new(if collapsed {
        gpui_kit::assets::IconName::Folder
    } else {
        gpui_kit::assets::IconName::FolderOpen
    })
    .with_size(px(12.0))
    .text_color(tokens.secondary_text)
    .into_any_element()
}

fn status_line(color: gpui_kit::Hsla, message: SharedString) -> AnyElement {
    div()
        .w_full()
        .flex_shrink_0()
        .h(px(STATUS_LINE_HEIGHT))
        .px(px(ACTION_HORIZONTAL_PADDING))
        .flex()
        .items_center()
        .child(
            div()
                .min_w(px(0.0))
                .flex_1()
                .truncate()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(color)
                .child(message),
        )
        .into_any_element()
}

fn empty_state(tokens: LitheTokens, message: &str) -> AnyElement {
    v_flex()
        .size_full()
        .items_center()
        .justify_center()
        .gap(px(8.0))
        .px(px(16.0))
        .child(
            Icon::new(gpui_kit::assets::IconName::FileSearch)
                .with_size(px(44.0))
                .text_color(tokens.tertiary_text),
        )
        .child(
            div()
                .text_size(px(14.0))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(tokens.primary_text)
                .child(if message == tr("No changes") {
                    tr("Select a file to review").to_string()
                } else {
                    message.to_string()
                }),
        )
        .child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(if message == tr("No changes") {
                    tr("Changes from external tools will appear automatically.").to_string()
                } else {
                    String::new()
                }),
        )
        .into_any_element()
}

fn split_path(path: &str) -> (String, String) {
    match path.rsplit_once('/') {
        Some((directory, file_name)) => (file_name.to_string(), directory.to_string()),
        None => (path.to_string(), String::new()),
    }
}

/// 单字母状态。porcelain v2 的两位码里，暂存组看第一位，工作区组看第二位。
fn status_letter(change: &CoreChange, group: ChangeGroup) -> char {
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

fn status_color(letter: char, untracked: bool, tokens: LitheTokens) -> gpui_kit::Hsla {
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
