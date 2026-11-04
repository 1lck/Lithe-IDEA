//! Git 工具窗（实体与公开 API）。
//!
//! 交互对齐 Windows/Tauri 的实现（Windows 是提交界面的 SSOT）：
//!
//! - **提交面板**（`Changes`）：单栏纵向布局。顶部是变更工具栏，中间是
//!   按「已暂存 / 工作区 / 未跟踪」分组的变更树，底部是 IntelliJ 提交区
//!   （Amend 行 → 消息输入框 → 校验提示 → 提交 / 提交并推送按钮行）。
//!   「提交 / Stash」两个分段由工作台标题栏切换，本面板只消费
//!   [`GitPanel::set_stash_visible`]（`stash_view.rs`）。
//! - **提交记录**（`Git Log`）：同一个视图的日志模式，只渲染提交历史。
//!
//! # 本模块的组织（对齐 plan-02 §2 的拆分设计）
//!
//! 实体、共享状态与公开 API 只在这里；其余是 `impl GitPanel` 的分区文件：
//!
//! | 文件 | 内容 |
//! | --- | --- |
//! | `model` | Core 响应模型、尺寸常量、解析辅助 |
//! | `actions` | 写操作（暂存 / 丢弃 / Fetch / 提交流水线） |
//! | `changes_view` | 变更工具栏、changelist 栏、变更树、右键菜单 |
//! | `selection` | 多选、批量动作、Eye 预览、忽略 / 删除确认 |
//! | `commit_area` | IntelliJ 提交区 + 工作区提交会话覆盖层 |
//! | `stash_view` | Stash 分段页 |
//! | `log_view` | Git Log 三栏工作台 |
//! | `references` | Log 左栏引用树与引用动作 |
//! | `rewrite` | 历史改写与提交动作弹窗 |
//! | `ignore` | .gitignore / .local exclude 写入 |
//! | `changelists` | 本地 changelist 存储（`changelists.json`） |
//!
//! # 数据边界
//!
//! Git 的全部业务规则都在 `rust/lithe-core`。本视图只通过
//! `CoreClient::execute_raw` / `read_file` / `write_file` 读写仓库内的内容，
//! 并用本地 camelCase 结构体反序列化响应，不复制 Core 的规则，也不扩展
//! `lithe-core-client` 的公开 API。
//!
//! # 异步
//!
//! 所有 Core 调用都是阻塞的，必须在 `cx.background_spawn` 中执行，结果再经
//! `this.update` 回到视图线程。`generation` 在 `set_root` / `refresh` 时递增，
//! 用来丢弃旧工作区仍在飞行中的结果。构造期不发起任务，首次加载由 `Render`
//! 里的 `defer_in` 排到当前 App 借用释放之后。
//!
//! # 写操作互斥
//!
//! `pending_action` 既挡住重复点击，也是按钮的进行中标记；`committing` /
//! `fetching` / `stash_busy` / `commit_session` 分别对应提交、Fetch、stash 与
//! 工作区提交流水线的在飞状态。

use std::collections::VecDeque;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Mutex;

use gpui_kit::component::input::{InputEvent, TextareaState};
use gpui_kit::component::v_flex;
use gpui_kit::{
    App, AppContext as _, Context, Entity, FocusHandle, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, SharedString, Styled as _, Window, div,
};
use lithe_core_client::CoreClient;
use lithe_ui::current_tokens;
use lithe_ui::i18n::tr;
use serde_json::Value;

pub(crate) mod actions;
pub(crate) mod changelists;
pub(crate) mod changes_view;
pub(crate) mod commit_area;
pub(crate) mod commit_files_view;
pub(crate) mod graph;
pub(crate) mod ignore;
pub(crate) mod log_console;
pub(crate) mod log_view;
pub(crate) mod model;
pub(crate) mod references;
pub(crate) mod rewrite;
pub(crate) mod selection;
pub(crate) mod shelves;
pub(crate) mod stash_view;

pub(crate) use changelists::{ChangelistPrompt, ChangelistStore};
pub(crate) use commit_area::CommitSessionState;
pub(crate) use model::{ChangeStatusCounts, CommitFilesView, CoreStash, GitLogPanel, GitPanelMode};
pub(crate) use stash_view::StashPushScope;

/// 打开 Git 管理器对话框的意图（Push / Pull / Branch Manager / …）。
///
/// 面板只发出意图；真正创建 gpui-kit `Dialog` 的回调由工作台注册
/// （`on_open_dialog`），保持 GitPanel 不直接持有 Window 生命周期，
/// 照抄 `on_open_ai_settings` 的回调形态。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GitDialogKind {
    /// 推送对话框（对齐 Tauri `git-push-dialog.tsx`）。
    Push,
    /// 拉取对话框（对齐 Tauri `git-pull-dialog.tsx`）。
    Pull,
    /// 分支管理器（branches / worktrees / repositories，对齐 Tauri
    /// `git-branch-manager.tsx`）。
    Branches,
    /// 工作树对话框（对齐 Tauri `git-worktree-dialog.tsx`）。
    Worktrees,
    /// 远端管理器（对齐 Tauri `git-remote-manager.tsx`）。
    Remotes,
    /// 标签管理器（对齐 Tauri `git-tag-manager.tsx`）。
    Tags,
    /// 创建补丁（对齐 Tauri `git-patch-dialog.tsx` 的 export 模式）。
    CreatePatch,
    /// 应用补丁（对齐 Tauri `git-patch-dialog.tsx` 的 apply 模式）。
    ApplyPatch,
    /// Interactive Rebase 会话（对齐 Tauri `git-rebase-dialog.tsx`）。
    Rebase,
    /// 「选择差异来源」（对齐 Tauri `Choose Diff Source` 菜单）。
    ChooseDiffSource,
}

/// 差异来源：某个提交，或工作区 / 暂存维度的文件。
///
/// 对齐 Tauri `viewFileDiff`（`commitHash: "working-tree"` 差异页）与
/// `openCommitDiff`；Core `git.diff` 不带 commit/reference 时按 `staged` /
/// `untracked` 标志返回未提交差异。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GitDiffSource {
    /// 已提交的差异（`git.show <hash>`）。
    Commit(String),
    /// 两个引用之间的区间差异（`git.diff <base>..<target>`），用于
    /// 「Compare with HEAD」这类不是单一提交的场景。
    Comparison { base: String, target: String },
    /// 未提交的差异：`staged` 选择索引维度；`untracked` 让 Core 把未跟踪
    /// 路径展开为新增行。
    WorkingTree {
        staged: bool,
        untracked: bool,
    },
}

/// 「打开差异」回调：(来源, 相对路径)。
pub(crate) type OpenDiffSourceHandler =
    Rc<dyn Fn(GitDiffSource, String, &mut Window, &mut App) + 'static>;

// --- 共享类型（全模块通过 `super::` 引用） ----------------------------------

/// 变更树分组。展示名与 id 在 `model.rs` 的 `impl ChangeGroup`。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum ChangeGroup {
    Staged,
    Worktree,
    Untracked,
}

/// 变更行上可执行的写操作。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ChangeAction {
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

impl PendingAction {
    /// 批量动作的成功文案：`"Staged 3 files"` 等（对齐 Tauri 的批量提示）。
    pub(crate) fn batch_success_message(action: ChangeAction, count: usize) -> String {
        match action {
            ChangeAction::Stage => {
                tr("Staged {count} files").replace("{count}", &count.to_string())
            }
            ChangeAction::Unstage => {
                tr("Unstaged {count} files").replace("{count}", &count.to_string())
            }
            ChangeAction::Discard => {
                tr("Discarded {count} files").replace("{count}", &count.to_string())
            }
        }
    }
}

/// 正在进行中的写操作。既是重复点击的闸门，也是按钮的进行中标记。
///
/// `git.command` 的参数数组与 `git.write` 的类型化请求共用这一个枚举，
/// 由 `actions.rs` 的 `execute_action` 统一派发。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum PendingAction {
    /// 单文件暂存 / 取消暂存 / 丢弃。
    Change {
        path: String,
        group: ChangeGroup,
        action: ChangeAction,
    },
    /// 暂存全部工作区与未跟踪改动（`git add -A`）。
    StageAll,
    /// 取消暂存全部（`git reset HEAD`）。
    UnstageAll,
    /// 批量路径动作（多选、分组、右键批量）。参数数组把全部路径放在
    /// `--` 之后，一条命令完成，避免逐个 spawn。
    Paths {
        paths: Vec<String>,
        action: ChangeAction,
    },
    /// Core `git.write` 的类型化请求（discardAll / stash / fetch 等）。
    GitWrite {
        operation: &'static str,
        payload: Value,
        success: &'static str,
        failure: &'static str,
    },
}

/// 当前高亮的变更身份。同一个路径可能同时出现在 Staged 与 Worktree，
/// 因此分组也是身份的一部分。多选集合按行渲染顺序重建（见 `selection.rs`）。
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) struct Selection {
    pub(crate) path: String,
    pub(crate) group: ChangeGroup,
}

/// 分支输入弹窗的操作类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BranchPromptAction {
    Create,
    Rename,
}

/// 提交表文本过滤的作用域（对齐 Tauri `GitLogFilterScope`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CommitFilterScope {
    /// 匹配 subject / 哈希（默认）。
    Text,
    /// 匹配作者名与邮箱。
    Author,
    /// 匹配分支装饰。
    Branch,
}

impl CommitFilterScope {
    /// 工具栏下拉的展示名。
    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::Text => tr("Text"),
            Self::Author => tr("Author"),
            Self::Branch => tr("Branch"),
        }
    }

    /// 该作用域下提交是否命中关键字。空关键字一律命中。
    pub(crate) fn matches(self, commit: &model::CoreCommit, query: &str) -> bool {
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

/// `git.historyRewritePreview` 支持的历史改写操作。
///
/// `SquashCommits` 需要提交表多选状态，尚未接入；接入时补上 wire/title。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RewriteOperation {
    UndoCommit,
    EditCommitMessage,
    DeleteCommit,
}

impl RewriteOperation {
    /// Core `git.historyRewritePreview` / `git.write` 的 operation 字段。
    pub(crate) fn wire(self) -> &'static str {
        match self {
            Self::UndoCommit => "undoCommit",
            Self::EditCommitMessage => "editCommitMessage",
            Self::DeleteCommit => "deleteCommit",
        }
    }

    pub(crate) fn title(self) -> &'static str {
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
pub(crate) struct RewritePreview {
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
pub(crate) enum CommitAction {
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

/// 键盘提交失败的原因组合，对齐 Tauri `commitHint`。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CommitHint {
    pub(crate) no_changes: bool,
    pub(crate) no_message: bool,
}

// ---------------------------------------------------------------------------

/// Git 工具窗。
pub struct GitPanel {
    client: CoreClient,
    /// 本实体服务哪个工具窗；决定渲染提交面板还是提交记录。
    mode: GitPanelMode,
    /// 空路径表示「还没有打开项目」，与 `ProjectTree` 的语义一致。
    root: Option<PathBuf>,
    status: Option<model::CoreStatus>,
    /// 键盘 / 双击高亮的选中项（单选语义）。
    selected: Option<Selection>,
    /// 多选集合（Ctrl/Cmd 累加、Shift 范围）。渲染顺序以列表顺序为准。
    multi_selected: std::collections::HashSet<Selection>,
    /// Shift 范围选择的锚点行。
    anchor: Option<Selection>,
    history: Vec<model::CoreCommit>,
    /// 下一页历史的游标；`None` 表示还没加载或已经到底。Core 的游标是一次性的，
    /// 每取一页都会返回新的游标（对齐 macOS `feature.canLoadMoreGitHistory`）。
    history_cursor: Option<String>,
    /// Core 是否报告还有下一页。
    history_has_more: bool,
    /// 正在加载下一页；滚动事件会重复触发，用它挡住重入。
    loading_more_history: bool,
    /// 下一页加载失败：列表底部显示重试入口，已有提交保持可见。
    history_page_failed: bool,
    /// 提交列表的键盘焦点：上下选择、回车打开差异（对齐 macOS
    /// `onMoveCommand` + 选中行打开详情）。
    log_focus: FocusHandle,
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
    /// 等待确认的丢弃操作（单个路径）。破坏性操作必须先二次确认。
    pending_discard: Option<(String, ChangeGroup)>,
    /// 待确认的批量丢弃（选中其余路径）；与 `pending_discard` 的第一项共用
    /// 一份确认覆盖层（对齐 Tauri「一次确认 + 逐条执行」）。
    batch_discard: Vec<Selection>,
    /// 等待确认的「丢弃全部」（Core `git.write discardAll`）。
    pending_discard_all: bool,
    /// 等待确认的文件删除（右键 Delete N files）。
    pending_delete: Option<Vec<String>>,
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
    /// 变更列表展示方式：目录分组（true，默认）或平铺列表（false，对齐
    /// Tauri `gitChangesFolderView`）。
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
    collapsed_commit_dirs: model::ExpandedSet,
    /// 提交详情里改动文件的呈现方式：树状（默认）或平铺列表。
    commit_files_view: CommitFilesView,
    /// Git Log 顶部分段：提交日志 / Git 控制台。
    log_panel: GitLogPanel,
    /// 提交表的滚动句柄：定位分支 HEAD 与选中的提交时用。
    log_scroll: gpui_kit::ScrollHandle,
    /// 下一次渲染要滚动到的提交行下标（相对当前可见列表）。
    log_reveal_index: Option<usize>,
    /// 历史重载完成后把首行（分支 HEAD）选中并滚动到可视区。
    log_reveal_head_on_load: bool,
    /// Git Log 左侧选中的分支或引用名称。
    selected_reference: Option<String>,
    /// `git.references` 返回的全部引用；Log 模式的引用树真数据源。
    references: Vec<model::CoreReference>,
    /// 是否正在加载引用。
    loading_references: bool,
    /// 引用树折叠状态：折叠的分组名 / 远端名。
    collapsed_groups: model::ExpandedSet,
    /// 提交表文本过滤关键字。
    commit_filter: String,
    /// 提交表过滤作用域（Text / Author / Branch）。
    commit_filter_scope: CommitFilterScope,
    /// 提交表过滤输入框（惰性创建，需要 Window）。
    filter_input: Option<Entity<gpui_kit::component::input::InputState>>,
    /// 提交表是否显示分支/标签装饰胶囊。
    show_decorations: bool,
    /// 右栏（提交详情）是否折叠；对齐 macOS 列表工具栏的「Show/Hide commit
    /// details」按钮。折叠后提交列表独占宽度。
    details_collapsed: bool,
    /// 正在执行的引用 / 历史写操作名称；非空时禁用所有引用动作按钮。
    reference_mutation: Option<&'static str>,
    /// 等待输入的分支操作（新建 / 重命名）及其来源引用。
    branch_prompt: Option<(BranchPromptAction, model::CoreReference)>,
    /// 分支输入框状态。`branch_prompt` 打开后的下一帧创建（需要 Window）。
    branch_input: Option<Entity<gpui_kit::component::input::InputState>>,
    /// 等待确认的引用动作。破坏性 / 集成操作必须二次确认，对齐 Tauri
    /// `showConfirmDialog`。
    reference_confirm: Option<rewrite::ReferenceConfirm>,
    /// 右键创建的弹出菜单与其触发位置；渲染期用 `anchored` 挂到前景层。
    reference_menu: Option<(
        Entity<gpui_kit::component::menu::PopupMenu>,
        gpui_kit::Point<gpui_kit::Pixels>,
    )>,
    /// 提交表触发的提交动作（预览 / 确认 / 输入）。
    commit_action: Option<CommitAction>,
    /// 提交表动作菜单。
    commit_menu: Option<(
        Entity<gpui_kit::component::menu::PopupMenu>,
        gpui_kit::Point<gpui_kit::Pixels>,
    )>,
    /// 变更树右键菜单。
    change_menu: Option<(
        Entity<gpui_kit::component::menu::PopupMenu>,
        gpui_kit::Point<gpui_kit::Pixels>,
    )>,
    /// 正在加载历史改写预览。
    loading_rewrite_preview: bool,
    /// 暂存的改写预览（Rewrite 确认时取用）。
    pending_rewrite_preview: Option<Box<RewritePreview>>,
    // --- Stash 分段 ----------------------------------------------------------
    /// Stash 分段可见（工作台标题栏消费 `set_commit_tab(Stash)`）。
    stash_visible: bool,
    stashes: Vec<model::CoreStash>,
    loading_stashes: bool,
    stash_busy: bool,
    /// 按 stash 的稳定 oid 记录的 per-row loading（对齐 Tauri :510-549）。
    stash_action_loading: std::collections::HashSet<String>,
    /// 等待确认的 Drop。
    pending_stash_drop: Option<model::CoreStash>,
    /// 打开中的 Stash 弹窗（展开后的路径列表）。
    pending_stash_push: Option<(StashPushScope, Vec<String>)>,
    stash_message_input: Option<Entity<gpui_kit::component::input::InputState>>,
    stash_message_text: Option<String>,
    stash_include_untracked: bool,
    stash_filter: String,
    stash_filter_input: Option<Entity<gpui_kit::component::input::InputState>>,
    // --- Saved Changes（本地 shelves，复用 git.patch*） -----------------------
    /// 当前仓库的已保存更改（补丁快照）。
    shelves: Vec<shelves::SavedShelf>,
    /// 保存 / 恢复 / 删除 shelf 的在飞标记。
    shelf_busy: bool,
    /// 打开中的「保存更改」弹窗。
    pending_shelf_create: bool,
    shelf_name_input: Option<Entity<gpui_kit::component::input::InputState>>,
    /// 等待确认删除的 shelf id。
    pending_shelf_delete: Option<String>,
    // --- 未跟踪目录展开 ------------------------------------------------------
    /// 已展开的未跟踪目录（路径以 `/` 结尾）。
    untracked_expanded: std::collections::HashSet<String>,
    /// `git.untrackedDirectory` 的结果缓存：目录 → 文件列表。
    untracked_files: std::collections::BTreeMap<String, Vec<String>>,
    /// 正在加载的未跟踪目录。
    loading_untracked: std::collections::HashSet<String>,
    // --- Changelist ----------------------------------------------------------
    /// changelist 栏是否显示（设置 `showGitChangelists`，§4.C-3）。
    show_changelists: bool,
    changelists: ChangelistStore,
    changelist_prompt: Option<ChangelistPrompt>,
    changelist_input: Option<Entity<gpui_kit::component::input::InputState>>,
    /// 打开中的 Move to Changelist（所选路径）。
    pending_move_to_changelist: Option<Vec<String>>,
    move_target_id: Option<String>,
    /// 「更新父仓库引用」勾选（workspace commit 的 includeParentReferences）。
    update_parent_refs: bool,
    // --- 提交流水线 ----------------------------------------------------------
    /// 进行中的工作区提交会话（Review 卡 / 推送目标追问 / 结果列表）。
    commit_session: Option<CommitSessionState>,
    // --- 生成的补充状态 ------------------------------------------------------
    /// Fetch 是否进行中（菜单项与按钮的进行中标记）。
    fetching: bool,
    /// 等待确认的忽略写入：目标文件 + 规则路径。
    pending_ignore: Option<(ignore::IgnoreTarget, Vec<String>)>,
    /// 「Create Patch」右键所选的文件列表（工作台 patch 对话框初值）。
    patch_selection: Vec<String>,
    /// 打开 Git 管理器对话框的回调（工作台注册）。
    on_open_dialog: Option<model::OpenDialogHandler>,
    /// 打开工作区差异 / 提交差异的回调（工作台注册）。
    on_open_diff_source: Option<OpenDiffSourceHandler>,
    on_open_ai_settings: Option<model::OpenHandler>,
    /// 「设置」按钮：打开设置页的 Git 分类（对齐 Tauri `openSettingsDialog("git")`）。
    on_open_git_settings: Option<model::OpenHandler>,
    /// 点提交改动文件时，在中央编辑区打开该提交的差异。
    on_open_commit_diff: Option<model::CommitDiffHandler>,
    on_open_file: Option<model::OpenFileHandler>,
    /// 标题栏「最小化」按钮：收起本工具窗所在的 dock（工作台注册）。
    on_hide: Option<model::OpenHandler>,
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
        cx: &mut Context<Self>,
    ) -> Self {
        let root = model::normalize_root(root);
        Self {
            client,
            mode,
            pending_initial_load: root.is_some(),
            root,
            status: None,
            selected: None,
            multi_selected: std::collections::HashSet::new(),
            anchor: None,
            history: Vec::new(),
            history_cursor: None,
            history_has_more: false,
            loading_more_history: false,
            history_page_failed: false,
            log_focus: cx.focus_handle(),
            commit_input: None,
            loading_status: false,
            loading_history: false,
            committing: false,
            amend: false,
            pending_action: None,
            pending_discard: None,
            batch_discard: Vec::new(),
            pending_discard_all: false,
            pending_delete: None,
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
            collapsed_commit_dirs: model::ExpandedSet::new(),
            commit_files_view: CommitFilesView::Tree,
            log_panel: GitLogPanel::Log,
            log_scroll: gpui_kit::ScrollHandle::new(),
            log_reveal_index: None,
            log_reveal_head_on_load: false,
            selected_reference: None,
            references: Vec::new(),
            loading_references: false,
            collapsed_groups: model::ExpandedSet::new(),
            commit_filter: String::new(),
            commit_filter_scope: CommitFilterScope::Text,
            filter_input: None,
            show_decorations: true,
            details_collapsed: false,
            reference_mutation: None,
            branch_prompt: None,
            branch_input: None,
            reference_confirm: None,
            reference_menu: None,
            commit_action: None,
            commit_menu: None,
            change_menu: None,
            loading_rewrite_preview: false,
            pending_rewrite_preview: None,
            stash_visible: false,
            stashes: Vec::new(),
            loading_stashes: false,
            stash_busy: false,
            stash_action_loading: std::collections::HashSet::new(),
            pending_stash_drop: None,
            pending_stash_push: None,
            stash_message_input: None,
            stash_message_text: None,
            stash_include_untracked: false,
            stash_filter: String::new(),
            stash_filter_input: None,
            shelves: Vec::new(),
            shelf_busy: false,
            pending_shelf_create: false,
            shelf_name_input: None,
            pending_shelf_delete: None,
            untracked_expanded: std::collections::HashSet::new(),
            untracked_files: std::collections::BTreeMap::new(),
            loading_untracked: std::collections::HashSet::new(),
            show_changelists: true,
            changelists: ChangelistStore::load(),
            changelist_prompt: None,
            changelist_input: None,
            pending_move_to_changelist: None,
            move_target_id: None,
            update_parent_refs: false,
            commit_session: None,
            fetching: false,
            pending_ignore: None,
            patch_selection: Vec::new(),
            on_open_dialog: None,
            on_open_diff_source: None,
            on_open_ai_settings: None,
            on_open_git_settings: None,
            on_open_commit_diff: None,
            on_open_file: None,
            on_hide: None,
        }
    }

    /// 切换工作区根。空路径表示关闭项目。
    pub fn set_root(&mut self, root: PathBuf, _window: &mut Window, cx: &mut Context<Self>) {
        self.root = model::normalize_root(root);
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

    /// 注册标题栏「最小化」回调：收起本工具窗所在的 dock。
    ///
    /// 与 Maven Output 的 `on_hide` 同形；GitPanel 不直接持有 dock 状态，
    /// 由工作台接成 `set_dock_visible(<tool anchor>, false)`。
    pub fn on_hide(&mut self, handler: impl Fn(&mut Window, &mut App) + 'static) {
        self.on_hide = Some(Rc::new(handler));
    }

    /// 点提交区「AI 设置」齿轮时跳转设置页 AI & Commit。
    pub fn on_open_ai_settings(&mut self, handler: impl Fn(&mut Window, &mut App) + 'static) {
        self.on_open_ai_settings = Some(Rc::new(handler));
    }

    /// 点 Git Log 标题栏「设置」时跳转设置页的 Git 分类。
    pub fn on_open_git_settings(&mut self, handler: impl Fn(&mut Window, &mut App) + 'static) {
        self.on_open_git_settings = Some(Rc::new(handler));
    }

    /// 注册「打开 Git 管理器对话框」的回调（Push / Pull / Branch / …）。
    ///
    /// 对话框本体在工作台覆盖层实现；GitPanel 只发意图，避免直接持有
    /// Window 生命周期（照抄 `on_open_ai_settings` 的回调形态）。
    pub fn on_open_dialog(
        &mut self,
        handler: impl Fn(GitDialogKind, &mut Window, &mut App) + 'static,
    ) {
        self.on_open_dialog = Some(Rc::new(handler));
    }

    /// 注册「打开工作区 / 提交差异」的回调（Eye 预览、Choose Diff Source）。
    pub fn on_open_diff_source(
        &mut self,
        handler: impl Fn(GitDiffSource, String, &mut Window, &mut App) + 'static,
    ) {
        self.on_open_diff_source = Some(Rc::new(handler));
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

    /// 注入「changelist 栏可见性」（Tauri `showGitChangelists`）。
    pub fn set_changelist_preferences(&mut self, show: bool, cx: &mut Context<Self>) {
        if self.show_changelists == show {
            return;
        }
        self.show_changelists = show;
        cx.notify();
    }

    /// 重置派生状态并并发加载 status / history。
    ///
    /// `generation` 只在这里递增；三个请求共用同一个代数，早于本次刷新返回的
    /// 旧结果都会被丢弃。
    pub(crate) fn reload_all(&mut self, cx: &mut Context<Self>) {
        self.generation = self.generation.wrapping_add(1);
        // 旧游标不再消费：先释放，避免 Core 保留一个没人读取的历史会话。
        self.close_history_cursor(cx);
        self.status = None;
        self.selected = None;
        self.history.clear();
        self.history_cursor = None;
        self.history_has_more = false;
        self.loading_more_history = false;
        self.history_page_failed = false;
        self.loading_status = false;
        self.loading_history = false;
        // 若刷新发生在提交请求飞行期间，旧结果会因 generation 不匹配被丢弃；
        // 这里同时解除锁定，避免按钮永久禁用。
        self.committing = false;
        self.fetching = false;
        self.pending_action = None;
        self.pending_discard = None;
        self.batch_discard.clear();
        self.pending_discard_all = false;
        self.pending_delete = None;
        self.stash_action_loading.clear();
        self.loading_stashes = false;
        self.loading_untracked.clear();
        self.error = None;
        self.notice = None;
        // 刷新后旧的滚动定位目标已失效。
        self.log_reveal_index = None;
        self.log_reveal_head_on_load = false;

        if self.root.is_none() {
            return;
        }
        self.load_status(cx);
        self.load_references(cx);
        self.load_history(cx);
        if self.stash_visible {
            self.load_stashes(cx);
        }
    }

    fn load_status(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = model::root_text(&root) else {
            self.error = Some(SharedString::from(tr("Project path is not valid UTF-8")));
            return;
        };

        let generation = self.generation;
        let client = self.client;
        self.loading_status = true;
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, "git.status", serde_json::json!({ "root": root_text }))
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.loading_status = false;
                match raw {
                    Ok(value) => match model::parse_status(&value) {
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
        let Some(root_text) = model::root_text(&root) else {
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
                "limit": model::HISTORY_PAGE_SIZE,
            });
            // 选中引用时按它过滤历史；空 = 全部分支，Core 的 reference 可选。
            if let Some(full_name) = reference {
                payload["reference"] = serde_json::Value::String(full_name);
            }
            let raw = cx
                .background_spawn(async move { execute_git_command(&client, "git.historyPage", payload) })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.loading_history = false;
                match raw {
                    Ok(value) => match model::parse_history_page(&value) {
                        Ok(page) => {
                            this.history = page.commits;
                            this.history_cursor = page.next_cursor;
                            this.history_has_more = page.has_more;
                            this.loading_more_history = false;
                            this.history_page_failed = false;
                            // 「导航到所选分支 HEAD」在引用变化后等这一批历史回来，
                            // 再把首行（该引用的 HEAD）选中并滚动到可视区。
                            if this.log_reveal_head_on_load {
                                this.log_reveal_head_on_load = false;
                                if let Some(head) =
                                    this.history.first().map(|commit| commit.hash.clone())
                                {
                                    this.log_reveal_index = Some(0);
                                    this.select_commit(head, cx);
                                }
                            }
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

    /// 加载下一页历史（对齐 macOS `loadMoreGitHistory`）。
    ///
    /// Core 的游标是一次性的：请求成功返回新的 `nextCursor`，失败时保留
    /// 当前页并把 `history_page_failed` 置位，由列表底部给出重试入口。
    /// 滚动监听会反复触发，这里用 `loading_more_history` 挡住重入。
    pub(crate) fn load_more_history(&mut self, cx: &mut Context<Self>) {
        if self.loading_more_history || self.loading_history || !self.history_has_more {
            return;
        }
        let Some(cursor) = self.history_cursor.clone() else {
            return;
        };
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = model::root_text(&root) else {
            return;
        };
        let reference = self
            .selected_reference
            .as_ref()
            .and_then(|short| self.full_reference_name(short));

        let generation = self.generation;
        let client = self.client;
        self.loading_more_history = true;
        self.history_page_failed = false;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let mut payload = serde_json::json!({
                "root": root_text,
                "order": "date",
                "limit": model::HISTORY_PAGE_SIZE,
                "cursor": cursor,
            });
            if let Some(full_name) = reference {
                payload["reference"] = serde_json::Value::String(full_name);
            }
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, "git.historyPage", payload)
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.loading_more_history = false;
                match raw {
                    Ok(value) => match model::parse_history_page(&value) {
                        Ok(page) => {
                            // 去重：Core 可能因为引用移动在两页之间返回同一提交。
                            let mut known: std::collections::HashSet<String> = this
                                .history
                                .iter()
                                .map(|commit| commit.hash.clone())
                                .collect();
                            for commit in page.commits {
                                if known.insert(commit.hash.clone()) {
                                    this.history.push(commit);
                                }
                            }
                            this.history_cursor = page.next_cursor;
                            this.history_has_more = page.has_more;
                            this.history_page_failed = false;
                        }
                        Err(message) => {
                            this.history_page_failed = true;
                            this.error = Some(SharedString::from(message));
                        }
                    },
                    Err(error) => {
                        this.history_page_failed = true;
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 释放不再消费的历史游标；失败只影响 Core 的会话回收，不回显给用户。
    fn close_history_cursor(&mut self, cx: &mut Context<Self>) {
        let Some(cursor) = self.history_cursor.take() else {
            return;
        };
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = model::root_text(&root) else {
            return;
        };
        let client = self.client;
        cx.spawn(async move |_this, cx| {
            let _ = cx
                .background_spawn(async move {
                    execute_git_command(
                        &client,
                        "git.historyCursorClose",
                        serde_json::json!({ "root": root_text, "cursor": cursor }),
                    )
                })
                .await;
        })
        .detach();
    }

    /// 把引用树的短名映射回 Core 需要的完整引用名。
    /// `git.references` 同时返回 `fullName`（refs/heads/test）和
    /// `shortName`（test），树的行 key 用短名，请求历史时换回全名。
    pub(crate) fn full_reference_name(&self, short_name: &str) -> Option<String> {
        self.references
            .iter()
            .find(|reference| reference.short_name == short_name)
            .map(|reference| reference.full_name.clone())
    }

    /// 读取全部引用（本地 / 远程 / 标签），供引用树渲染。
    pub(crate) fn load_references(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = model::root_text(&root) else {
            return;
        };

        let generation = self.generation;
        let client = self.client;
        self.loading_references = true;
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, "git.references", serde_json::json!({ "root": root_text }))
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.loading_references = false;
                match raw {
                    Ok(value) => {
                        this.references = model::parse_references(&value);
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

    /// 打开一个变更文件：把绝对路径交给上层编辑器（工作区相对 → 绝对）。
    pub(crate) fn open_change(&mut self, path: &str, window: &mut Window, cx: &mut Context<Self>) {
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

    /// 首帧创建提交输入。`TextareaState::new` 需要 window，因此不能放在 `new`。
    ///
    /// 用多行输入对齐 Tauri 的 `Textarea`：提交说明允许换行，`Ctrl/Cmd+Enter`
    /// 才提交，`Enter` 只换行。gpui-base 的 `Enter` 动作把 `cmd-enter`（macOS）
    /// / `ctrl-enter`（其它平台）绑成 `secondary: true`，正好对应这里的判断。
    pub(crate) fn ensure_commit_input(&mut self, window: &mut Window, cx: &mut Context<Self>) {
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

    /// 聚焦提交消息输入（右键「Commit 所选」的焦点转移入口）。
    ///
    /// `TextareaState` 实现了 `focus(window, cx)`：把焦点真正交给提交输入框，
    /// 用户可以直接输入提交信息，而不是只把视线落回提交区。
    pub(crate) fn focus_commit_message(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.notice = None;
        if let Some(input) = self.commit_input.clone() {
            input.update(cx, |state, cx| state.focus(window, cx));
        }
        cx.notify();
    }

    /// 把「右键 Create Patch」所选的文件列表存起来，交给工作台的 patch
    /// 对话框读取（对齐 Tauri `showGitPatchDialog(repoPath, { mode: "export" })`
    /// 的初值）。
    pub(crate) fn set_patch_selection(&mut self, paths: Vec<String>) {
        self.patch_selection = paths;
    }

    /// 读 patch 对话框的初值（工作台在打开 CreatePatch 对话框时查询）。
    pub fn patch_selection(&self) -> &[String] {
        &self.patch_selection
    }

    /// 面板侧的对话框入口：所有菜单 / 右键都经这里转发到工作台。
    pub(crate) fn open_dialog(&self, kind: GitDialogKind, window: &mut Window, cx: &mut App) {
        let Some(handler) = self.on_open_dialog.clone() else {
            return;
        };
        handler(kind, window, cx);
    }

    /// 当前工作区根（Git 对话框需要 root 调 Core 命令）。
    pub fn repository_root(&self) -> Option<PathBuf> {
        self.root.clone()
    }

    /// 标题栏菜单的可用性判断：项目根存在且 Core 报告这是 Git 仓库
    /// （`status.branch` 非 None）。加载中的None按「无仓库」处理，
    /// 与 Tauri `hasGitRepo` 的状态语义一致。
    pub fn has_repository(&self) -> bool {
        self.root.is_some()
            && self
                .status
                .as_ref()
                .is_some_and(|status| status.branch.is_some())
    }

    /// 工作台 / 对话框操作后的统一刷新入口（reload_all 的公开别名）。
    pub fn refresh_data(&mut self, cx: &mut Context<Self>) {
        self.reload_all(cx);
    }

    /// 「无项目 / 无仓库」空状态。
    pub(crate) fn render_log_empty(&self, tokens: lithe_ui::LitheTokens) -> gpui_kit::AnyElement {
        changes_view::empty_state(tokens, tr("No project open"))
    }

    /// 把右键创建的 PopupMenu 渲染到窗口前景层。
    ///
    /// 之前菜单实体只创建不渲染，引用/提交/变更的右键菜单从未显示过。
    pub(crate) fn with_floating_menu(
        &self,
        element: gpui_kit::AnyElement,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let mut wrapper = gpui_kit::div().relative().size_full().child(element);
        if let Some((popup, position)) = &self.reference_menu {
            wrapper = wrapper.child(self.floating_popup(popup.clone(), *position, cx));
        }
        if let Some((popup, position)) = &self.commit_menu {
            wrapper = wrapper.child(self.floating_popup(popup.clone(), *position, cx));
        }
        if let Some((popup, position)) = &self.change_menu {
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
    ) -> gpui_kit::AnyElement {
        gpui_kit::deferred(
            gpui_kit::anchored()
                .position(position)
                .snap_to_window()
                .child(
                    gpui_kit::div()
                        .occlude()
                        .on_mouse_down_out(cx.listener(move |this, _, _, cx| {
                            if this.reference_menu.take().is_some()
                                || this.commit_menu.take().is_some()
                                || this.change_menu.take().is_some()
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
                                .child(self.render_log_empty(tokens)),
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
            panel = panel.child(changes_view::status_line(tokens.error, error));
        } else if let Some(notice) = self.notice.clone() {
            panel = panel.child(changes_view::status_line(tokens.success, notice));
        }

        if self.root.is_none() {
            return self.with_floating_menu(
                panel
                    .child(
                        div()
                            .flex_1()
                            .min_h_0()
                            .child(self.render_log_empty(tokens)),
                    )
                    .into_any_element(),
                cx,
            );
        }

        if self.stash_visible {
            let content = panel.child(self.render_stash_view(window, tokens, cx));
            // 先完成可变借用的覆盖层包装，再调用只读的 with_floating_menu；
            // 不能把两个 self 借用写在同一个调用表达式里（E0502）。
            let wrapped = self.wrap_overlays(content.into_any_element(), tokens, window, cx);
            return self.with_floating_menu(wrapped, cx);
        }

        let content = panel
            .child(self.render_body(tokens, cx))
            .child(self.render_bottom(tokens, cx));

        let wrapped = self.wrap_overlays(content.into_any_element(), tokens, window, cx);
        self.with_floating_menu(wrapped, cx)
    }
}

/// 提交面板的确认与流程覆盖层分发；每层都有独立的取消路径，
/// 同一时刻只展示一层（不打断用户）。
impl GitPanel {
    fn wrap_overlays(
        &mut self,
        content: gpui_kit::AnyElement,
        tokens: lithe_ui::LitheTokens,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let decorated = div().relative().size_full().child(content);

        // 1. 提交流水线的覆盖层优先：会话进行中时不再叠加其它确认。
        if let Some(overlay) = self.render_commit_session_overlay(tokens, cx) {
            return decorated.child(overlay).into_any_element();
        }
        // 2. 破坏性确认（丢弃单个 / 批量 / 全部、删除、忽略）。
        if self.pending_discard.is_some() || !self.batch_discard.is_empty() {
            let (path, group) = self
                .pending_discard
                .clone()
                .or_else(|| {
                    self.batch_discard
                        .first()
                        .map(|selection| (selection.path.clone(), selection.group))
                })
                .expect("guarded by the branch above");
            return decorated
                .child(self.render_discard_confirm(path, group, tokens, cx))
                .into_any_element();
        }
        if self.pending_discard_all {
            return decorated
                .child(self.render_discard_all_confirm(tokens, cx))
                .into_any_element();
        }
        if let Some(paths) = self.pending_delete.clone() {
            return decorated
                .child(self.render_delete_confirm(&paths, tokens, cx))
                .into_any_element();
        }
        // 3. Stash 的 Drop 确认与 Stash 弹窗。
        if let Some(stash) = self.pending_stash_drop.clone() {
            return decorated
                .child(self.render_stash_drop_confirm(&stash, tokens, cx))
                .into_any_element();
        }
        if let Some(overlay) = self.render_stash_push_overlay(window, tokens, cx) {
            return decorated.child(overlay).into_any_element();
        }
        // 3b. Saved Changes（shelf）：保存命名 / 删除确认。
        if let Some(overlay) = self.render_shelf_overlays(window, tokens, cx) {
            return decorated.child(overlay).into_any_element();
        }
        // 4. 忽略确认与 changelist 输入 / Move 弹窗。
        if let Some((target, paths)) = self.pending_ignore.clone() {
            return decorated
                .child(self.render_ignore_confirm(target, &paths, tokens, cx))
                .into_any_element();
        }
        if let Some(overlay) = self.render_changelist_overlays(tokens, cx) {
            return decorated.child(overlay).into_any_element();
        }
        decorated.into_any_element()
    }
}

// ---------------------------------------------------------------------------
// Git 执行信封（Core `CoreRequest.gitExecution`）
// ---------------------------------------------------------------------------

/// 从应用设置构造 Core 的 Git 执行信封。
///
/// 只注入设置页里真实存在、用户可配置的字段：
/// - `fetchDefaults`：Fetch 的 prune / submodules / tags 默认值（设置页 Git 页）；
/// - `source`：本面板的命令都由用户显式发起，供 Core 控制台区分来源。
///
/// 可执行文件路径与凭据助手在 gpui 设置页是 Core 的只读回显（由 Core 自己
/// 解析），这里不发送未经用户配置的假值。
///
/// `interactive` 也保持 false（即不发送）：gpui 的进程内 `CoreClient` 走
/// `lithe_core::execute_json`，没有 `execute_json_with_events` 的 event sink，
/// 因此收不到 AskPass 的 `requestId`，也无法调用 `git.authRespond`（#71）。
/// 若置 true，Core 会进入认证重试并在确认上等待，却没有 UI 能回答它。同样
/// 原因，`git.consolePresentation` 需要的执行记录（流式行 / 进度 / 截断标记）
/// 在 gpui 侧没有采集通道（#72），控制台因此保持诚实占位。
///
/// 设置文件在后台线程读取（本函数只应在 `background_spawn` 内调用），因此
/// 每次 git 调用都能读到最新设置，不需要额外的失效通知。
pub fn git_execution_envelope() -> serde_json::Value {
    let settings = crate::settings::AppSettings::load();
    serde_json::json!({
        "fetchDefaults": {
            "prune": settings.git_fetch_prune,
            // 设置值必须落在 Core 的枚举内；仓储里的旧值/未知值按 inherit
            // 处理，避免整个 Git 请求因反序列化失败而不可用。
            "submodules": fetch_submodule_id(&settings.git_fetch_submodules),
            "tags": fetch_tags_id(&settings.git_fetch_tags),
        },
        "source": "user",
    })
}

/// 归一化 Fetch submodules 设置到 Core `GitFetchSubmodules` 的 wire 值。
fn fetch_submodule_id(value: &str) -> &'static str {
    match value {
        "no" => "no",
        "onDemand" => "onDemand",
        "yes" => "yes",
        _ => "inherit",
    }
}

/// 归一化 Fetch tags 设置到 Core `GitFetchTags` 的 wire 值。
fn fetch_tags_id(value: &str) -> &'static str {
    match value {
        "all" => "all",
        "none" => "none",
        "prune" => "prune",
        _ => "inherit",
    }
}

// ---------------------------------------------------------------------------
// Git 执行控制台（Git Log → Console）
// ---------------------------------------------------------------------------

/// 控制台保留的最大记录条数：环形缓冲，超出后丢弃最旧的一条。
const GIT_CONSOLE_CAPACITY: usize = 200;
/// 单条记录保留的输出行数 / 字节上限，避免长时间运行占住内存。
const GIT_CONSOLE_OUTPUT_LINES: usize = 200;
const GIT_CONSOLE_OUTPUT_BYTES: usize = 16 * 1024;

/// 一条 Git 写命令的执行记录（Git Log → Console 的数据源）。
///
/// 只记录用户显式发起的写操作；高频只读查询（status / diff / history /
/// references …）不进入控制台，避免刷屏。
#[derive(Debug, Clone)]
pub struct GitConsoleEntry {
    /// 本地时间（`HH:MM:SS`）。
    pub time: String,
    /// Core 命令名，如 `git.write`。
    pub command: String,
    /// 仓库目录的最后一段（不展示完整路径）。
    pub repository: String,
    /// 参数摘要（patch 只显示长度）。
    pub arguments: String,
    /// 进程退出码；请求本身失败时为 -1。
    pub exit_code: i32,
    pub succeeded: bool,
    /// 输出尾部，最多 200 行 / 16 KiB。
    pub output: String,
}

/// 进程级环形缓冲：Core 调用来自后台线程，因此用 `Mutex` 串行化写入。
static GIT_CONSOLE: Mutex<VecDeque<GitConsoleEntry>> = Mutex::new(VecDeque::new());

/// 读取控制台快照（旧记录在前）。返回副本，调用方无需持锁。
pub fn git_console_entries() -> Vec<GitConsoleEntry> {
    match GIT_CONSOLE.lock() {
        Ok(entries) => entries.iter().cloned().collect(),
        Err(poisoned) => poisoned.into_inner().iter().cloned().collect(),
    }
}

/// 是否为需要进入控制台的写命令。
///
/// 白名单而不是黑名单：新增只读命令默认不会污染控制台。
fn is_git_write_command(command: &str) -> bool {
    matches!(
        command,
        "git.write"
            | "git.command"
            | "git.apply"
            | "git.patchApply"
            | "git.initialize"
            | "git.workspaceCommitPrepare"
            | "git.workspaceCommitStep"
    )
}

/// 仓库目录只保留最后一段（对齐控制台截图里的仓库名而不是完整路径）。
fn git_console_repository(payload: &Value) -> String {
    payload
        .get("root")
        .and_then(Value::as_str)
        .map(|root| {
            root.replace('\\', "/")
                .rsplit('/')
                .next()
                .filter(|segment| !segment.is_empty())
                .unwrap_or(root)
                .to_string()
        })
        .unwrap_or_default()
}

/// 参数摘要：root 不展示；patch 只显示字节数；数组最多 3 项。
fn git_console_arguments(payload: &Value) -> String {
    let Some(object) = payload.as_object() else {
        return String::new();
    };
    let mut parts = Vec::new();
    for (key, value) in object {
        if key == "root" {
            continue;
        }
        let rendered = if key == "patch" || key == "patchText" {
            match value.as_str() {
                Some(patch) => format!("<{} bytes>", patch.len()),
                None => continue,
            }
        } else {
            summarize_git_console_value(value)
        };
        if rendered.is_empty() {
            continue;
        }
        parts.push(format!("{key}={rendered}"));
    }
    truncate_git_console_text(&parts.join(" "), 600)
}

fn summarize_git_console_value(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::Bool(flag) => flag.to_string(),
        Value::Number(number) => number.to_string(),
        Value::String(text) => truncate_git_console_text(
            &text.replace('\r', " ").replace('\n', " "),
            120,
        ),
        Value::Array(items) => {
            let mut rendered: Vec<String> = items
                .iter()
                .take(3)
                .map(summarize_git_console_value)
                .filter(|item| !item.is_empty())
                .collect();
            if items.len() > 3 {
                rendered.push(format!("(+{} more)", items.len() - 3));
            }
            rendered.join(", ")
        }
        Value::Object(_) => truncate_git_console_text(&value.to_string(), 120),
    }
}

fn truncate_git_console_text(text: &str, max_chars: usize) -> String {
    let mut truncated: String = text.chars().take(max_chars).collect();
    if text.chars().count() > max_chars {
        truncated.push('…');
    }
    truncated
}

/// 命令输出：`output` 与 `stderr` 合并后只保留尾部。
fn git_console_output(value: &Value) -> String {
    let mut text = value
        .get("output")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let stderr = value
        .get("stderr")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if !stderr.trim().is_empty() {
        if !text.is_empty() {
            text.push('\n');
        }
        text.push_str(stderr);
    }
    git_console_output_tail(&text)
}

fn git_console_output_tail(text: &str) -> String {
    let lines: Vec<&str> = text.lines().collect();
    let start = lines.len().saturating_sub(GIT_CONSOLE_OUTPUT_LINES);
    let mut tail = lines[start..].join("\n");
    if tail.len() > GIT_CONSOLE_OUTPUT_BYTES {
        let mut cut = tail.len() - GIT_CONSOLE_OUTPUT_BYTES;
        // 不能切在 UTF-8 字符中间。
        while cut < tail.len() && !tail.is_char_boundary(cut) {
            cut += 1;
        }
        tail = tail[cut..].to_string();
    }
    tail
}

fn record_git_console(
    command: &str,
    repository: String,
    arguments: String,
    result: &Result<Value, lithe_core_client::CoreError>,
) {
    let (exit_code, succeeded, output) = match result {
        Ok(value) => {
            // 部分写命令（workspace commit）返回的不是 GitCommandResponse，
            // 没有 exitCode 时按请求成功处理。
            let exit_code = value
                .get("exitCode")
                .and_then(Value::as_i64)
                .and_then(|code| i32::try_from(code).ok())
                .unwrap_or(0);
            (exit_code, exit_code == 0, git_console_output(value))
        }
        Err(error) => (-1, false, git_console_output_tail(&error.to_string())),
    };
    let entry = GitConsoleEntry {
        time: chrono::Local::now().format("%H:%M:%S").to_string(),
        command: command.to_string(),
        repository,
        arguments,
        exit_code,
        succeeded,
        output,
    };
    let mut entries = match GIT_CONSOLE.lock() {
        Ok(entries) => entries,
        Err(poisoned) => poisoned.into_inner(),
    };
    if entries.len() >= GIT_CONSOLE_CAPACITY {
        entries.pop_front();
    }
    entries.push_back(entry);
}

/// 统一的 Git 命令执行入口：把执行信封附加到 Core 请求上。
///
/// 与 `CoreClient::execute_raw` 一样是阻塞调用，必须在
/// `cx.background_spawn` 中执行。写命令会进入 Git 控制台的环形缓冲。
pub fn execute_git_command(
    client: &CoreClient,
    command: &str,
    payload: Value,
) -> Result<Value, lithe_core_client::CoreError> {
    // 参数摘要要在 payload 被移动前算好；只读命令不记录。
    let console_context = is_git_write_command(command)
        .then(|| (git_console_repository(&payload), git_console_arguments(&payload)));
    let result = client.execute_raw_with_options(command, payload, Some(git_execution_envelope()));
    if let Some((repository, arguments)) = console_context {
        record_git_console(command, repository, arguments, &result);
    }
    result
}
