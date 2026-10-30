//! Git 工具窗。
//!
//! 交互对齐 Windows/Tauri 的实现（Windows 是提交界面的 SSOT）：
//!
//! - **提交面板**（`Changes`）：单栏纵向布局。顶部是变更工具栏，中间是
//!   按「已暂存 / 工作区 / 未跟踪」分组的变更树，底部是 IntelliJ 提交区
//!   （Amend 行 → 消息输入框 → 提交 / 提交并推送按钮行）。点击文件把
//!   diff 交给上层在编辑器中打开，不在面板内再分一栏。
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

use std::path::{Path, PathBuf};
use std::rc::Rc;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::checkbox::Checkbox;
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::{Disableable as _, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, ClickEvent, Context, Entity, FontWeight,
    InteractiveElement as _, IntoElement, ParentElement, Render, SharedString,
    StatefulInteractiveElement as _, Styled, Window, div, px, white,
};
use lithe_core_client::CoreClient;
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, MONO_FONT_FAMILY, current_tokens, icon};
use serde_json::Value;

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
const LOG_ROW_HEIGHT: f32 = 40.0;
/// 刷新 / 提交等动作的横向内边距。
const ACTION_HORIZONTAL_PADDING: f32 = 10.0;
/// 变更工具栏高度（对应 Tauri `h-10`）。
const CHANGES_TOOLBAR_HEIGHT: f32 = 40.0;
/// 变更工具栏里的图标按钮尺寸（对应 Tauri `size-[22px]`）。
const CHANGES_TOOLBAR_BUTTON_SIZE: f32 = 22.0;

/// 一次「打开文件」回调。与 `ProjectTree` 保持同一形态。
type OpenFileHandler = Rc<dyn Fn(PathBuf, &mut Window, &mut App) + 'static>;

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
struct CoreCommit {
    hash: String,
    short_hash: String,
    date: String,
    subject: String,
    author_name: String,
}

#[derive(Debug, Clone, Default)]
struct CoreHistoryPage {
    commits: Vec<CoreCommit>,
}

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
    /// 提交消息输入。`InputState::new` 需要 `&mut Window`，而公开构造签名
    /// 没有 window，因此延迟到首帧用 `defer_in` 创建。
    commit_input: Option<Entity<InputState>>,
    loading_status: bool,
    loading_history: bool,
    committing: bool,
    /// 下一次提交是否追加 `--amend`；提交成功后复位。
    amend: bool,
    /// 正在执行的暂存 / 取消暂存 / 丢弃；非空时所有写操作按钮禁用。
    pending_action: Option<PendingAction>,
    /// 等待确认的丢弃操作。破坏性操作必须先二次确认，不能一键执行。
    pending_discard: Option<(String, ChangeGroup)>,
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
    on_open_file: Option<OpenFileHandler>,
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
            error: None,
            notice: None,
            generation: 0,
            pending_input_init: true,
            pending_clear_message: false,
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

    /// 双击（或上层主动调用）变更行时回调绝对路径。
    pub fn on_open_file(&mut self, handler: impl Fn(PathBuf, &mut Window, &mut App) + 'static) {
        self.on_open_file = Some(Rc::new(handler));
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

        let generation = self.generation;
        let client = self.client;
        self.loading_history = true;
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    client.execute_raw(
                        "git.historyPage",
                        serde_json::json!({
                            "root": root_text,
                            "order": "date",
                            "limit": 50,
                        }),
                    )
                })
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

    /// 丢弃是破坏性操作：先记录待确认项，由覆盖层二次确认。
    fn request_discard(&mut self, path: String, group: ChangeGroup, cx: &mut Context<Self>) {
        if self.pending_action.is_some() || self.committing {
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
        if message.is_empty() {
            self.error = Some(SharedString::from(tr("Commit message is required")));
            self.notice = None;
            cx.notify();
            return;
        }
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

    /// 首帧创建提交输入。`InputState::new` 需要 window，因此不能放在 `new`。
    fn ensure_commit_input(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.commit_input.is_some() {
            return;
        }
        self.commit_input =
            Some(cx.new(|cx| InputState::new(window, cx).placeholder(tr("Commit message"))));
        cx.notify();
    }

    /// 变更区工具栏：对齐 Tauri `GitStatusPanel` 的 `SidebarToolbar`
    /// （40px 高、图标按钮 22px、右侧显示当前分支）。
    ///
    /// 面板标题由工作台的提交工具窗标题栏负责（提交 / Stash 分段），
    /// 因此这里不再重复标题，只保留变更操作。
    fn render_changes_toolbar(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
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
        let unstage_all_pending = matches!(
            self.pending_action.as_ref(),
            Some(PendingAction::UnstageAll)
        );
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
                    .rounded(px(4.0))
                    .icon(icon(LitheIcon::Refresh))
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
                    .rounded(px(4.0))
                    .icon(gpui_kit::component::Icon::new(
                        gpui_kit::assets::IconName::RotateCcw,
                    ))
                    .tooltip(tr("Discard selected changes"))
                    .disabled(!has_selection || busy)
                    .on_click(cx.listener(|this, _, _window, cx| this.discard_selected_change(cx))),
            )
            .child(
                Button::new("lithe-git:stage-all")
                    .ghost()
                    .with_size(px(CHANGES_TOOLBAR_BUTTON_SIZE))
                    .rounded(px(4.0))
                    .icon(gpui_kit::component::Icon::new(
                        gpui_kit::assets::IconName::ArrowDownToLine,
                    ))
                    .tooltip(tr("Stage all changes"))
                    .loading(stage_all_pending)
                    .disabled(!can_stage_all)
                    .on_click(cx.listener(|this, _, _window, cx| this.stage_all_changes(cx))),
            )
            .child(
                Button::new("lithe-git:unstage-all")
                    .ghost()
                    .with_size(px(CHANGES_TOOLBAR_BUTTON_SIZE))
                    .rounded(px(4.0))
                    .icon(gpui_kit::component::Icon::new(
                        gpui_kit::assets::IconName::Undo2,
                    ))
                    .tooltip(tr("Unstage all changes"))
                    .loading(unstage_all_pending)
                    .disabled(!can_unstage_all)
                    .on_click(cx.listener(|this, _, _window, cx| this.unstage_all_changes(cx))),
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

    fn render_body(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        // Tauri 的提交面板是单栏：变更树占满剩余高度，提交区固定在底部。
        v_flex()
            .w_full()
            .flex_1()
            .min_h_0()
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
        for group in ChangeGroup::ALL {
            let changes = status
                .changes
                .iter()
                .filter(|change| in_group(change, group))
                .collect::<Vec<_>>();
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

    /// IntelliJ 提交区：分隔线之上是变更树，之下依次是 Amend 行、消息输入框
    /// 与提交按钮行。几何对齐 Tauri `git-commit-panel`（gap 6px、内边距
    /// `3px 11px 6px`），不为它再套一层卡片边框。
    fn render_bottom(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let message = self
            .commit_input
            .as_ref()
            .map(|input| input.read(cx).value())
            .unwrap_or_default();
        // 提交与索引写操作同一时刻只允许一个；Amend 开关同样在期间锁定。
        let busy = self.committing || self.pending_action.is_some();
        let can_commit = self.root.is_some()
            && self
                .status
                .as_ref()
                .is_some_and(|status| status.branch.is_some())
            && !busy
            && !message.trim().is_empty();
        // Tauri 统计的是「包含在本次提交里的文件数」，即已暂存条目。
        let staged_count = self.status.as_ref().map_or(0, |status| {
            status
                .changes
                .iter()
                .filter(|change| change.staged && change.can_toggle_staging)
                .count()
        });

        // --- Amend 行：[x] Amend last commit ................ AI   N files ---
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
            .child(
                div()
                    .flex_shrink_0()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(format!("{staged_count}")),
            );

        // --- 消息输入框：1px 中性边框，聚焦时换成强调色。 ---
        let input = match self.commit_input.as_ref() {
            Some(input) => Input::new(input)
                .w_full()
                .aria_label(tr("Commit message"))
                .into_any_element(),
            None => div()
                .w_full()
                .h(px(LitheMetrics::TREE_ROW_HEIGHT))
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
            .rounded(px(COMMIT_INPUT_RADIUS))
            .border_1()
            .border_color(tokens.panel_border)
            .bg(tokens.editor)
            .child(input);

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
                    .label(tr("Commit"))
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
            .child(div().flex_1());

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
            .child(actions_row)
            .into_any_element()
    }

    /// 提交记录模式：只渲染历史列表，供 `ToolWindow::GitLog` 使用。
    fn render_history(&self, tokens: LitheTokens) -> AnyElement {
        let mut list = v_flex()
            .id("lithe-git-log-scroll")
            .w_full()
            .flex_1()
            .min_h_0()
            .overflow_y_scroll();

        if self.history.is_empty() {
            list = list.child(empty_state(
                tokens,
                if self.loading_history {
                    tr("Loading log…")
                } else {
                    tr("No commits")
                },
            ));
        } else {
            for commit in &self.history {
                list = list.child(render_log_row(commit, tokens));
            }
        }
        list.into_any_element()
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
                return panel
                    .child(
                        div()
                            .flex_1()
                            .min_h_0()
                            .child(empty_state(tokens, tr("No project open"))),
                    )
                    .into_any_element();
            }
            return panel
                .child(self.render_history(tokens))
                .into_any_element();
        }

        panel = panel.child(self.render_changes_toolbar(tokens, cx));

        if let Some(error) = self.error.clone() {
            panel = panel.child(status_line(tokens.error, error));
        } else if let Some(notice) = self.notice.clone() {
            panel = panel.child(status_line(tokens.success, notice));
        }

        if self.root.is_none() {
            return panel
                .child(
                    div()
                        .flex_1()
                        .min_h_0()
                        .child(empty_state(tokens, tr("No project open"))),
                )
                .into_any_element();
        }

        let content = panel
            .child(self.render_body(tokens, cx))
            .child(self.render_bottom(tokens, cx));

        let Some((path, group)) = self.pending_discard.clone() else {
            return content.into_any_element();
        };

        div()
            .relative()
            .size_full()
            .child(content)
            .child(self.render_discard_confirm(path, group, tokens, cx))
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

fn parse_commit(value: &Value) -> CoreCommit {
    CoreCommit {
        hash: string_field(value.get("hash")),
        short_hash: string_field(value.get("shortHash")),
        date: string_field(value.get("date")),
        subject: string_field(value.get("subject")),
        author_name: string_field(value.get("authorName")),
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
            Checkbox::new(format!(
                "lithe-git:include:{}:{}",
                group.id(),
                change.path
            ))
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
        .px(px(12.0))
        .child(
            div()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(message.to_string()),
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
