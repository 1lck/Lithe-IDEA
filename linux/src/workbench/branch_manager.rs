//! 分支管理器弹窗：对齐 Tauri `GitBranchManager`（`GitCommandSurface` 弹窗）
//! 与 macOS `BranchSwitcherPopover` 的共同可见行为。
//!
//! 三个 tab（仓库 / 分支 / 工作树）：
//! - 顶部 tab 行切换分区，搜索框占位与计数随之变化；搜索框为真实 `Input`，
//!   支持 IME 组字与剪贴板粘贴。
//! - 分支 tab：当前分支置顶、其余按名称排序；查询无精确匹配时首行可建分支并
//!   切过去；上下键移动选中、回车执行。
//! - 工作树 tab：过滤掉 bare / prunable，当前工作树置顶；无分支时按
//!   detached / no branch 文案显示；查询非空且不重复时首行可创建工作树。
//! - 仓库 tab：列出工作区内发现的仓库（当前仓库置顶），点击切换。
//! - 底部动作行：按 tab 提供 新建分支 / 创建工作树 / 添加仓库 与 刷新。
//!
//! 排序、过滤、标签与建名规则集中在 `branch_manager_logic`（纯逻辑，可单测）；
//! core 调用模式沿用 `sidebar.rs`（`CoreClient` + `cx.spawn`）。

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Disableable as _, Icon, Selectable as _, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, rgba, AppContext as _, Context, Entity, EventEmitter, FocusHandle, FontWeight,
    InteractiveElement as _, IntoElement, KeyDownEvent, ParentElement as _, Render,
    StatefulInteractiveElement as _, Styled as _, Subscription, Window,
};

use super::branch_manager_logic::{
    clamp_index, create_branch_name, create_worktree_path, filtered_branches,
    filtered_repositories, filtered_worktrees, folder_name, move_index, query_matches,
    relative_path, worktree_label, WorktreeInfo,
};
use crate::core::CoreClient;
use crate::theme::ThemeColors;

/// 管理器顶部的三个分区（对齐 Tauri `CommandTabs`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BranchTab {
    Repositories,
    Branches,
    Worktrees,
}

impl BranchTab {
    /// 分区标题文案键（与 Tauri `git.repositories/branches/worktrees` 对齐）。
    fn title_key(self) -> &'static str {
        match self {
            BranchTab::Repositories => "git.repositories",
            BranchTab::Branches => "git.branches",
            BranchTab::Worktrees => "git.worktrees",
        }
    }

    /// 搜索框占位文案键（按 tab 切换）。
    fn placeholder_key(self) -> &'static str {
        match self {
            BranchTab::Repositories => "git.filterRepositories",
            BranchTab::Branches => "git.searchBranches",
            BranchTab::Worktrees => "git.searchWorktrees",
        }
    }
}

/// 分支管理器对外事件。
#[derive(Debug, Clone)]
pub enum BranchManagerEvent {
    /// 检出或建分支成功：父级负责刷新 git 状态并关闭弹窗。
    CheckoutDone,
    /// 请求打开指定工作树路径的项目（父级关弹窗后打开）。
    OpenWorktree(String),
    /// 请求切换到指定仓库路径（父级关弹窗后打开）。
    SelectRepository(String),
    /// 请求关闭弹窗（遮罩点击 / Esc）。
    Close,
}

/// 居中的分支管理器弹窗（宽 560、高 420，仿 `project_dialog` 卡片）。
pub struct BranchManagerView {
    repo_path: String,
    /// 工作区根路径：仓库行的副行显示相对此根的路径（对齐 `getRelativePath`）。
    workspace_root: String,
    current_branch: Option<String>,
    active_tab: BranchTab,
    query: String,
    branches: Vec<String>,
    worktrees: Vec<WorktreeInfo>,
    repositories: Vec<String>,
    is_discovering_repos: bool,
    is_loading_worktrees: bool,
    /// 键盘导航：命令列表中的选中下标。
    selected_index: usize,
    error: Option<String>,
    busy: bool,
    /// 弹窗打开后需要在下一帧把焦点交给搜索框（只做一次，避免每帧抢焦点）。
    pending_search_focus: bool,
    search_input: Entity<InputState>,
    _search_subscription: Subscription,
    focus_handle: FocusHandle,
    client: CoreClient,
}

impl EventEmitter<BranchManagerEvent> for BranchManagerView {}

impl BranchManagerView {
    pub fn new(repo_path: String, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search_input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(crate::i18n::menu_text(cx, "git.searchBranches"))
        });
        let input_source = search_input.clone();
        let _search_subscription = cx.subscribe(
            &search_input,
            move |this: &mut Self, _, event: &InputEvent, cx| match event {
                InputEvent::Change => {
                    this.query = input_source.read(cx).value().to_string();
                    this.selected_index = 0;
                    this.error = None;
                    cx.notify();
                }
                InputEvent::PressEnter { shift, .. } => {
                    // 回车执行当前选中项；Shift+回车回退一格（列表导航习惯）。
                    if *shift {
                        this.move_selection(-1, cx);
                    } else {
                        this.activate_selection(cx);
                    }
                }
                _ => {}
            },
        );

        let mut view = Self {
            repo_path,
            workspace_root: String::new(),
            current_branch: None,
            active_tab: BranchTab::Branches,
            query: String::new(),
            branches: Vec::new(),
            worktrees: Vec::new(),
            repositories: Vec::new(),
            is_discovering_repos: false,
            is_loading_worktrees: false,
            selected_index: 0,
            error: None,
            busy: false,
            pending_search_focus: true,
            search_input,
            _search_subscription,
            focus_handle: cx.focus_handle(),
            client: CoreClient::new(),
        };
        view.reload(cx);
        view
    }

    /// 更新仓库并重载分支、工作树与仓库列表（打开弹窗时由父级调用）。
    pub fn set_repo(&mut self, path: String, current: Option<String>, cx: &mut Context<Self>) {
        self.repo_path = path.clone();
        if self.workspace_root.is_empty() {
            self.workspace_root = path;
        }
        self.current_branch = current;
        self.query.clear();
        self.branches.clear();
        self.worktrees.clear();
        self.repositories.clear();
        self.error = None;
        self.busy = false;
        self.selected_index = 0;
        // 下一次渲染时把焦点交给搜索框。
        self.pending_search_focus = true;
        // 清空搜索框显示值（`InputState::set_value` 需要 `Window`）。
        if let Some(handle) = cx.active_window() {
            let input = self.search_input.clone();
            handle
                .update(cx, |_, window, cx| {
                    input.update(cx, |state, cx| state.set_value("", window, cx));
                })
                .ok();
        }
        self.reload(cx);
    }

    /// 设置工作区根（仓库副行显示相对此根的路径）。
    pub fn set_workspace_root(&mut self, workspace_root: String) {
        self.workspace_root = workspace_root;
    }

    /// 弹窗打开时把焦点交给搜索输入框（否则根节点不持有焦点，键盘无法输入）。
    pub fn focus_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.search_input
            .update(cx, |state, cx| state.focus(window, cx));
    }
    /// 并发拉取分支、工作树与仓库列表。
    pub fn reload(&mut self, cx: &mut Context<Self>) {
        self.load_branches(cx);
        self.load_worktrees(cx);
        self.load_repositories(cx);
    }

    fn load_branches(&mut self, cx: &mut Context<Self>) {
        let client = self.client.clone();
        let root = self.repo_path.clone();
        cx.spawn(async move |this, cx| {
            let task = client.execute::<serde_json::Value, serde_json::Value>(
                &cx,
                "git.references",
                serde_json::json!({ "root": root }),
            );
            let value = task.await.unwrap_or(serde_json::Value::Null);
            // 分支解析照抄 view.rs observer：kind == local 的 shortName。
            let mut branches: Vec<String> = value
                .get("references")
                .and_then(|r| r.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter(|item| item.get("kind").and_then(|k| k.as_str()) == Some("local"))
                        .filter_map(|item| {
                            item.get("shortName")
                                .and_then(|n| n.as_str())
                                .map(|s| s.to_string())
                        })
                        .collect()
                })
                .unwrap_or_default();
            branches.sort();
            branches.dedup();
            let _ = this.update(cx, |view, cx| {
                view.branches = branches;
                cx.notify();
            });
        })
        .detach();
    }

    fn load_worktrees(&mut self, cx: &mut Context<Self>) {
        self.is_loading_worktrees = true;
        let client = self.client.clone();
        let root = self.repo_path.clone();
        cx.spawn(async move |this, cx| {
            // 真源命令名为 `git.worktrees`（core `CoreCommand::GitWorktrees`）。
            let task = client.execute::<serde_json::Value, serde_json::Value>(
                &cx,
                "git.worktrees",
                serde_json::json!({ "root": root }),
            );
            let value = task.await.unwrap_or(serde_json::Value::Null);
            let worktrees: Vec<WorktreeInfo> = value
                .get("worktrees")
                .and_then(|w| w.as_array())
                .map(|arr| arr.iter().filter_map(parse_worktree).collect())
                .unwrap_or_default();
            let _ = this.update(cx, |view, cx| {
                view.worktrees = worktrees;
                view.is_loading_worktrees = false;
                cx.notify();
            });
        })
        .detach();
    }

    fn load_repositories(&mut self, cx: &mut Context<Self>) {
        self.is_discovering_repos = true;
        let client = self.client.clone();
        let root = self.repo_path.clone();
        cx.spawn(async move |this, cx| {
            let task = client.execute::<serde_json::Value, serde_json::Value>(
                &cx,
                "workspace.repositories",
                serde_json::json!({ "root": root }),
            );
            let value = task.await.unwrap_or(serde_json::Value::Null);
            let mut repositories: Vec<String> = value
                .get("repositories")
                .and_then(|r| r.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|item| {
                            item.get("path")
                                .and_then(|p| p.as_str())
                                .map(|s| s.to_string())
                        })
                        .collect()
                })
                .unwrap_or_default();
            repositories.sort();
            repositories.dedup();
            let _ = this.update(cx, |view, cx| {
                view.repositories = repositories;
                view.is_discovering_repos = false;
                cx.notify();
            });
        })
        .detach();
    }

    /// 检出指定本地分支：`git.write` 成功即 `CheckoutDone`，失败只显示错误行。
    fn checkout(&mut self, branch: String, cx: &mut Context<Self>) {
        if self.busy || Some(branch.as_str()) == self.current_branch.as_deref() {
            return;
        }
        self.busy = true;
        self.error = None;
        cx.notify();
        let client = self.client.clone();
        let payload = git_write_payload(
            &self.repo_path,
            "checkout",
            serde_json::json!({
                "reference": format!("refs/heads/{branch}"),
                "referenceKind": "local",
            }),
        );
        cx.spawn(async move |this, cx| {
            let task =
                client.execute::<serde_json::Value, serde_json::Value>(&cx, "git.write", payload);
            match task.await {
                Ok(_) => {
                    let _ = this.update(cx, |view, cx| {
                        view.busy = false;
                        cx.emit(BranchManagerEvent::CheckoutDone);
                    });
                }
                Err(err) => {
                    let _ = this.update(cx, |view, cx| {
                        view.busy = false;
                        view.error = Some(err);
                        cx.notify();
                    });
                }
            }
        })
        .detach();
    }

    /// 建分支后切过去：`createBranch`（`reference: "HEAD"`）成功再调一次 checkout。
    fn create_and_checkout(&mut self, name: String, cx: &mut Context<Self>) {
        let name = name.trim().to_string();
        if self.busy || name.is_empty() {
            return;
        }
        self.busy = true;
        self.error = None;
        cx.notify();
        let client = self.client.clone();
        let root = self.repo_path.clone();
        let checkout_ref = format!("refs/heads/{name}");
        let create_payload = git_write_payload(
            &root,
            "createBranch",
            serde_json::json!({ "name": name, "reference": "HEAD" }),
        );
        let checkout_payload = git_write_payload(
            &root,
            "checkout",
            serde_json::json!({ "reference": checkout_ref, "referenceKind": "local" }),
        );
        cx.spawn(async move |this, cx| {
            let create_task = client.execute::<serde_json::Value, serde_json::Value>(
                &cx,
                "git.write",
                create_payload,
            );
            let create_result = create_task.await;
            let final_result = match create_result {
                Ok(_) => {
                    let checkout_task = client.execute::<serde_json::Value, serde_json::Value>(
                        &cx,
                        "git.write",
                        checkout_payload,
                    );
                    checkout_task.await.map(|_| ())
                }
                Err(err) => Err(err),
            };
            match final_result {
                Ok(()) => {
                    let _ = this.update(cx, |view, cx| {
                        view.busy = false;
                        cx.emit(BranchManagerEvent::CheckoutDone);
                    });
                }
                Err(err) => {
                    let _ = this.update(cx, |view, cx| {
                        view.busy = false;
                        view.error = Some(err);
                        cx.notify();
                    });
                }
            }
        })
        .detach();
    }

    /// 创建工作树（新分支模式）。失败只显示错误行。
    fn create_worktree(&mut self, destination: String, cx: &mut Context<Self>) {
        let destination = destination.trim().to_string();
        if self.busy || destination.is_empty() {
            return;
        }
        self.busy = true;
        self.error = None;
        cx.notify();
        let client = self.client.clone();
        // 对齐 Windows：无显式分支时用 newBranch 模式，名称取目标目录名。
        let name = folder_name(&destination);
        let payload = git_write_payload(
            &self.repo_path,
            "createWorktree",
            serde_json::json!({
                "destination": destination,
                "worktreeMode": "newBranch",
                "noCheckout": false,
                "name": name,
            }),
        );
        cx.spawn(async move |this, cx| {
            let task =
                client.execute::<serde_json::Value, serde_json::Value>(&cx, "git.write", payload);
            match task.await {
                Ok(_) => {
                    let _ = this.update(cx, |view, cx| {
                        view.busy = false;
                        view.load_worktrees(cx);
                    });
                }
                Err(err) => {
                    let _ = this.update(cx, |view, cx| {
                        view.busy = false;
                        view.error = Some(err);
                        cx.notify();
                    });
                }
            }
        })
        .detach();
    }

    /// 当前 tab 下命令列表的条目数（含首行“创建”项）。
    fn command_len(&self) -> usize {
        match self.active_tab {
            BranchTab::Branches => {
                let create = usize::from(self.create_branch_name().is_some());
                self.filtered_branches().len() + create
            }
            BranchTab::Worktrees => {
                let create = usize::from(self.create_worktree_path().is_some());
                self.filtered_worktrees().len() + create
            }
            BranchTab::Repositories => self.repo_rows().len(),
        }
    }

    /// 上下移动选择：夹紧在 `[0, len-1]`，不循环（对齐 `moveCommandListIndex`）。
    fn move_selection(&mut self, delta: i32, cx: &mut Context<Self>) {
        let len = self.command_len();
        self.selected_index = if delta > 0 {
            move_index(self.selected_index, len, true)
        } else {
            self.selected_index = clamp_index(self.selected_index, len);
            move_index(self.selected_index, len, false)
        };
        cx.notify();
    }

    /// 执行当前选中项（对齐 `handleCommandSelect`）。
    fn activate_selection(&mut self, cx: &mut Context<Self>) {
        let index = self.selected_index;
        match self.active_tab {
            BranchTab::Branches => {
                let has_create = self.create_branch_name().is_some();
                if has_create && index == 0 {
                    if let Some(name) = self.create_branch_name() {
                        self.create_and_checkout(name, cx);
                    }
                    return;
                }
                let offset = index.saturating_sub(usize::from(has_create));
                if let Some(branch) = self.filtered_branches().get(offset).cloned() {
                    self.checkout(branch, cx);
                }
            }
            BranchTab::Worktrees => {
                let has_create = self.create_worktree_path().is_some();
                if has_create && index == 0 {
                    if let Some(path) = self.create_worktree_path() {
                        self.create_worktree(path, cx);
                    }
                    return;
                }
                let offset = index.saturating_sub(usize::from(has_create));
                if let Some(info) = self.filtered_worktrees().get(offset).cloned() {
                    self.open_worktree(info, cx);
                }
            }
            BranchTab::Repositories => {
                if let Some(path) = self.repo_rows().get(index).cloned() {
                    self.select_repository(path, cx);
                }
            }
        }
    }

    fn open_worktree(&mut self, info: WorktreeInfo, cx: &mut Context<Self>) {
        if info.path == self.repo_path {
            return;
        }
        cx.emit(BranchManagerEvent::OpenWorktree(info.path));
    }

    fn select_repository(&mut self, path: String, cx: &mut Context<Self>) {
        if path == self.repo_path {
            return;
        }
        cx.emit(BranchManagerEvent::SelectRepository(path));
    }

    fn filtered_branches(&self) -> Vec<String> {
        let current = self.current_branch.clone().unwrap_or_default();
        filtered_branches(&self.branches, &current, &self.query)
    }

    fn filtered_worktrees(&self) -> Vec<WorktreeInfo> {
        filtered_worktrees(&self.worktrees, &self.repo_path, &self.query)
    }

    /// 仓库列表：core 未返回时退回展示当前仓库（单仓库场景）。
    fn repo_rows(&self) -> Vec<String> {
        let rows = filtered_repositories(&self.repositories, Some(&self.repo_path), &self.query);
        if rows.is_empty()
            && self.repositories.is_empty()
            && !self.repo_path.is_empty()
            && query_matches(&self.query, &[&folder_name(&self.repo_path)])
        {
            return vec![self.repo_path.clone()];
        }
        rows
    }

    fn create_branch_name(&self) -> Option<String> {
        let current = self.current_branch.clone().unwrap_or_default();
        create_branch_name(&self.branches, &current, &self.query)
    }

    fn create_worktree_path(&self) -> Option<String> {
        create_worktree_path(&self.worktrees, &self.query)
    }

    /// 计数行文案（`{count}` 占位在渲染时替换，单复数按英文区分键）。
    fn count_text(&self, cx: &gpui_kit::App) -> String {
        let (key, count) = match self.active_tab {
            BranchTab::Repositories => {
                let n = self
                    .repositories
                    .len()
                    .max(usize::from(!self.repo_path.is_empty()));
                (
                    if n == 1 {
                        "git.repositoryCount"
                    } else {
                        "git.repositoriesCount"
                    },
                    n,
                )
            }
            BranchTab::Branches => {
                let n = self.branches.len();
                (
                    if n == 1 {
                        "git.branchCount"
                    } else {
                        "git.branchesCount"
                    },
                    n,
                )
            }
            BranchTab::Worktrees => {
                let n = self.worktrees.len();
                (
                    if n == 1 {
                        "git.worktreeCount"
                    } else {
                        "git.worktreesCount"
                    },
                    n,
                )
            }
        };
        crate::i18n::menu_text(cx, key).replace("{count}", &count.to_string())
    }
}

/// 解析 core `git.worktrees` 的单条记录；path 缺失时返回 `None`。
fn parse_worktree(item: &serde_json::Value) -> Option<WorktreeInfo> {
    let path = item.get("path").and_then(|p| p.as_str())?.to_string();
    if path.is_empty() {
        return None;
    }
    let branch = item
        .get("branch")
        .and_then(|b| b.as_str())
        .map(|s| s.trim_start_matches("refs/heads/").to_string());
    let bool_of = |key: &str| item.get(key).and_then(|b| b.as_bool()).unwrap_or(false);
    Some(WorktreeInfo {
        path,
        head: item
            .get("head")
            .and_then(|h| h.as_str())
            .unwrap_or("")
            .to_string(),
        branch,
        is_current: bool_of("isCurrent"),
        is_primary: bool_of("isPrimary"),
        is_bare: bool_of("isBare"),
        is_detached: bool_of("isDetached"),
        is_locked: bool_of("isLocked"),
        // prunable：core 用 isPrunable + pruneReason，任一存在即视为不可打开。
        is_prunable: bool_of("isPrunable")
            || item
                .get("pruneReason")
                .and_then(|r| r.as_str())
                .map(|s| !s.trim().is_empty())
                .unwrap_or(false),
    })
}

/// 构造 `git.write` 全字段 camelCase payload（String 无值传 null，bool 传 false）。
fn git_write_payload(root: &str, operation: &str, extra: serde_json::Value) -> serde_json::Value {
    let mut payload = serde_json::json!({
        "root": root,
        "operation": operation,
        "paths": [],
        "reference": null,
        "gitReference": null,
        "referenceKind": null,
        "revision": null,
        "name": null,
        "message": null,
        "remote": null,
        "destination": null,
        "mode": null,
        "worktreeMode": null,
        "noCheckout": false,
        "includeUntracked": false,
        "checkout": false,
        "amend": false,
        "force": false,
        "autoStash": false,
    });
    if let (Some(obj), Some(patch)) = (payload.as_object_mut(), extra.as_object()) {
        for (key, value) in patch {
            obj.insert(key.clone(), value.clone());
        }
    }
    payload
}

impl Render for BranchManagerView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 注意：这里**不能**每帧 `window.focus(&self.focus_handle)`。
        // 根节点每帧抢回焦点会把焦点从搜索 `Input` 手里夺走，导致搜索分支 /
        // 筛选仓库的输入框无法输入（历史 bug）。弹窗打开时只聚焦输入框一次；
        // 上下键/Esc 经事件冒泡到达根节点的 `on_key_down`。
        if self.pending_search_focus {
            self.pending_search_focus = false;
            self.focus_search(window, cx);
        }
        let active_tab = self.active_tab;
        let count_text = self.count_text(cx);
        let busy = self.busy;

        // 首行“创建”项：分支 tab 用建名，工作树 tab 用建路径。
        let create_branch = self.create_branch_name();
        let create_branch_label = create_branch
            .as_ref()
            .map(|name| crate::i18n::menu_text(cx, "git.createNewBranch").replace("{name}", name))
            .unwrap_or_default();
        let create_worktree = self.create_worktree_path();
        let create_worktree_label = create_worktree
            .as_ref()
            .map(|path| crate::i18n::menu_text(cx, "git.createWorktree").replace("{path}", path))
            .unwrap_or_default();

        div()
            .id("branch-manager-backdrop")
            .track_focus(&self.focus_handle)
            .absolute()
            .inset_0()
            .bg(rgba(0x00000088))
            .flex()
            .items_center()
            .justify_center()
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                // 字符输入 / 退格由内层 `Input` 处理（含 IME 与粘贴）；
                // 这里接管方向键与 Esc。
                match event.keystroke.key.as_str() {
                    "escape" => cx.emit(BranchManagerEvent::Close),
                    "up" => this.move_selection(-1, cx),
                    "down" => this.move_selection(1, cx),
                    _ => {}
                }
            }))
            .on_mouse_down(
                gpui_kit::MouseButton::Left,
                cx.listener(|_this, _event, _window, cx| {
                    cx.emit(BranchManagerEvent::Close);
                }),
            )
            .child(
                v_flex()
                    .id("branch-manager-card")
                    .w(px(560.0))
                    .h(px(420.0))
                    .bg(ThemeColors::surface())
                    .border_1()
                    .border_color(ThemeColors::border())
                    .rounded_lg()
                    .shadow_lg()
                    .overflow_hidden()
                    .on_mouse_down(
                        gpui_kit::MouseButton::Left,
                        cx.listener(|_this, _event, _window, cx| {
                            cx.stop_propagation();
                        }),
                    )
                    .child(self.render_tabs(cx))
                    .child(self.render_search_row(cx))
                    .child(
                        div()
                            .w_full()
                            .px_4()
                            .py_1()
                            .text_xs()
                            .text_color(ThemeColors::subtle_foreground())
                            .child(count_text),
                    )
                    .child(self.render_list(create_branch_label, create_worktree_label, busy, cx))
                    .child(self.render_footer(active_tab, busy, cx))
                    .when(self.error.is_some(), |card| {
                        card.child(
                            div()
                                .w_full()
                                .px_4()
                                .py_2()
                                .border_t_1()
                                .border_color(ThemeColors::border())
                                .text_xs()
                                .text_color(ThemeColors::destructive())
                                .child(self.error.clone().unwrap_or_default()),
                        )
                    }),
            )
    }
}

impl BranchManagerView {
    /// 顶部三 tab 行（当前高亮）。
    fn render_tabs(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let tabs = [
            BranchTab::Repositories,
            BranchTab::Branches,
            BranchTab::Worktrees,
        ];
        h_flex()
            .w_full()
            .items_center()
            .gap_1()
            .px_3()
            .py_2()
            .border_b_1()
            .border_color(ThemeColors::border())
            .children(tabs.into_iter().enumerate().map(|(ix, tab)| {
                let label: String = crate::i18n::menu_text(cx, tab.title_key()).to_string();
                let selected = tab == self.active_tab;
                Button::new(format!("branch-manager-tab-{ix}"))
                    .small()
                    .ghost()
                    .label(label)
                    .selected(selected)
                    .on_click(cx.listener(move |this, _event, window, cx| {
                        this.active_tab = tab;
                        this.selected_index = 0;
                        // 切 tab 后刷新占位与焦点（对齐 `handleTabChange`）。
                        let placeholder: gpui_kit::SharedString =
                            crate::i18n::menu_text(cx, tab.placeholder_key()).into();
                        this.search_input.update(cx, |state, cx| {
                            state.set_placeholder(placeholder, window, cx);
                            state.focus(window, cx);
                        });
                        cx.notify();
                    }))
            }))
    }

    /// 搜索行：图标 + 真实 `Input`（IME / 粘贴由组件处理）。
    /// `appearance(false)` 关闭组件自带背景/边框/焦点环，保持与外层卡片一致。
    fn render_search_row(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let _ = cx;
        h_flex()
            .h(px(48.0))
            .w_full()
            .items_center()
            .gap_2p5()
            .px_4()
            .border_b_1()
            .border_color(ThemeColors::border())
            .child(
                Icon::new(IconName::Search)
                    .size(px(16.0))
                    .text_color(ThemeColors::primary()),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .text_sm()
                    .child(Input::new(&self.search_input).appearance(false)),
            )
    }

    /// 按当前 tab 渲染滚动列表。
    fn render_list(
        &self,
        create_branch_label: String,
        create_worktree_label: String,
        busy: bool,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let tab = self.active_tab;
        let query_empty = self.query.trim().is_empty();
        let selected_index = self.selected_index;
        div()
            .flex_1()
            .w_full()
            .overflow_y_scrollbar()
            .py_1()
            .when(tab == BranchTab::Branches, |list| {
                let filtered = self.filtered_branches();
                let has_create = !create_branch_label.is_empty();
                let empty_text: String = crate::i18n::menu_text(
                    cx,
                    if query_empty {
                        "git.noBranchesFound"
                    } else {
                        "git.noMatchingBranches"
                    },
                )
                .to_string();
                let current = self.current_branch.clone();
                let create_label = create_branch_label.clone();
                list.when(has_create, |list| {
                    list.child(create_row(
                        "branch-manager-create-branch",
                        create_label.clone(),
                        selected_index == 0,
                        busy,
                        cx,
                        |this, cx| {
                            if let Some(name) = this.create_branch_name() {
                                this.create_and_checkout(name, cx);
                            }
                        },
                    ))
                })
                .when(filtered.is_empty() && !has_create, |list| {
                    list.child(empty_row(empty_text.clone()))
                })
                .children(filtered.into_iter().enumerate().map(|(ix, name)| {
                    let row_index = ix + usize::from(has_create);
                    branch_row(
                        ix,
                        name,
                        current.clone(),
                        row_index == selected_index,
                        busy,
                        cx,
                    )
                }))
            })
            .when(tab == BranchTab::Worktrees, |list| {
                let filtered = self.filtered_worktrees();
                let has_create = !create_worktree_label.is_empty();
                let no_branch = crate::i18n::menu_text(cx, "git.noBranch").to_string();
                let detached = crate::i18n::menu_text(cx, "git.detachedHead").to_string();
                let empty_text: String = if self.is_loading_worktrees {
                    crate::i18n::menu_text(cx, "git.loadingWorktrees").to_string()
                } else if query_empty {
                    crate::i18n::menu_text(cx, "git.noWorktreesFound").to_string()
                } else {
                    crate::i18n::menu_text(cx, "git.noMatchingWorktrees").to_string()
                };
                let repo_path = self.repo_path.clone();
                let create_label = create_worktree_label.clone();
                list.when(has_create, |list| {
                    list.child(create_row(
                        "branch-manager-create-worktree",
                        create_label.clone(),
                        selected_index == 0,
                        busy || self.is_loading_worktrees,
                        cx,
                        |this, cx| {
                            if let Some(path) = this.create_worktree_path() {
                                this.create_worktree(path, cx);
                            }
                        },
                    ))
                })
                .when(filtered.is_empty() && !has_create, |list| {
                    list.child(empty_row(empty_text.clone()))
                })
                .children(filtered.into_iter().enumerate().map(|(ix, info)| {
                    let row_index = ix + usize::from(has_create);
                    worktree_row(
                        ix,
                        info,
                        &repo_path,
                        &detached,
                        &no_branch,
                        row_index == selected_index,
                        busy,
                        cx,
                    )
                }))
            })
            .when(tab == BranchTab::Repositories, |list| {
                let rows = self.repo_rows();
                let empty_text: String = if self.is_discovering_repos && rows.is_empty() {
                    crate::i18n::menu_text(cx, "git.detectingRepositories").to_string()
                } else if query_empty {
                    crate::i18n::menu_text(cx, "git.noRepositoriesFound").to_string()
                } else {
                    crate::i18n::menu_text(cx, "git.noMatchingRepositories").to_string()
                };
                if rows.is_empty() {
                    list.child(empty_row(empty_text))
                } else {
                    let workspace_root = self.workspace_root.clone();
                    list.children(rows.into_iter().enumerate().map(|(ix, path)| {
                        let is_current = path == self.repo_path;
                        repository_row(path, &workspace_root, is_current, ix == selected_index, cx)
                    }))
                }
            })
    }

    /// 底部动作行：按 tab 提供 新建 / 刷新 / 添加。
    fn render_footer(
        &self,
        tab: BranchTab,
        busy: bool,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let new_branch = crate::i18n::menu_text(cx, "git.newBranch").to_string();
        let refresh = crate::i18n::menu_text(cx, "git.refresh").to_string();
        let create_worktree = crate::i18n::menu_text(cx, "git.worktreeDialog.manage").to_string();
        let add = crate::i18n::menu_text(cx, "git.add").to_string();
        let can_create_branch = self.create_branch_name().is_some();
        let can_create_worktree = self.create_worktree_path().is_some();
        let loading_worktrees = self.is_loading_worktrees;
        let discovering = self.is_discovering_repos;
        h_flex()
            .w_full()
            .items_center()
            .gap_1()
            .px_3()
            .py_2()
            .border_t_1()
            .border_color(ThemeColors::border())
            .when(tab == BranchTab::Branches, |footer| {
                footer
                    .child(footer_action(
                        "branch-manager-footer-new",
                        IconName::Plus,
                        new_branch,
                        busy || !can_create_branch,
                        cx,
                        |this, cx| {
                            if let Some(name) = this.create_branch_name() {
                                this.create_and_checkout(name, cx);
                            }
                        },
                    ))
                    .child(footer_action(
                        "branch-manager-footer-refresh-branches",
                        IconName::RotateCw,
                        refresh.clone(),
                        busy,
                        cx,
                        |this, cx| this.load_branches(cx),
                    ))
            })
            .when(tab == BranchTab::Worktrees, |footer| {
                footer
                    .child(footer_action(
                        "branch-manager-footer-worktree",
                        IconName::Plus,
                        create_worktree,
                        busy || loading_worktrees || !can_create_worktree,
                        cx,
                        |this, cx| {
                            if let Some(path) = this.create_worktree_path() {
                                this.create_worktree(path, cx);
                            }
                        },
                    ))
                    .child(footer_action(
                        "branch-manager-footer-refresh-worktrees",
                        IconName::RotateCw,
                        refresh.clone(),
                        busy || loading_worktrees,
                        cx,
                        |this, cx| this.load_worktrees(cx),
                    ))
            })
            .when(tab == BranchTab::Repositories, |footer| {
                footer
                    .child(footer_action(
                        "branch-manager-footer-add",
                        IconName::Plus,
                        add,
                        busy || discovering,
                        cx,
                        |this, cx| this.load_repositories(cx),
                    ))
                    .child(footer_action(
                        "branch-manager-footer-refresh-repos",
                        IconName::RotateCw,
                        refresh.clone(),
                        busy || discovering,
                        cx,
                        |this, cx| this.load_repositories(cx),
                    ))
            })
    }
}

/// 底部动作按钮。
fn footer_action(
    id: &'static str,
    icon: IconName,
    label: String,
    disabled: bool,
    cx: &mut Context<BranchManagerView>,
    on_click: fn(&mut BranchManagerView, &mut Context<BranchManagerView>),
) -> impl IntoElement {
    Button::new(id)
        .small()
        .ghost()
        .disabled(disabled)
        .icon(icon)
        .label(label)
        .on_click(cx.listener(move |this, _event, _window, cx| {
            on_click(this, cx);
        }))
}

/// 首行“创建”项（分支 / 工作树共用）。
fn create_row(
    id: &'static str,
    label: String,
    selected: bool,
    busy: bool,
    cx: &mut Context<BranchManagerView>,
    on_click: fn(&mut BranchManagerView, &mut Context<BranchManagerView>),
) -> impl IntoElement {
    h_flex()
        .id(id)
        .h(px(32.0))
        .w_full()
        .mx_2()
        .px_2p5()
        .items_center()
        .gap_2()
        .rounded_md()
        .cursor_pointer()
        .when(selected, |row| row.bg(ThemeColors::accent()))
        .hover(|h| h.bg(ThemeColors::accent()))
        .child(
            Icon::new(IconName::Plus)
                .size(px(14.0))
                .text_color(if busy {
                    ThemeColors::muted_foreground()
                } else {
                    ThemeColors::primary()
                }),
        )
        .child(
            div()
                .flex_1()
                .truncate()
                .text_sm()
                .font_weight(FontWeight::MEDIUM)
                .text_color(ThemeColors::foreground())
                .child(label),
        )
        .on_click(cx.listener(move |this, _event, _window, cx| {
            if busy {
                return;
            }
            on_click(this, cx);
        }))
        .into_any_element()
}

/// 分支行：当前分支打勾、非当前显示分支图标，点击检出；选中态高亮。
fn branch_row(
    ix: usize,
    name: String,
    current: Option<String>,
    selected: bool,
    busy: bool,
    cx: &mut Context<BranchManagerView>,
) -> gpui_kit::AnyElement {
    let is_current = Some(name.as_str()) == current.as_deref();
    let target = name.clone();
    h_flex()
        .id(("branch-manager-branch", ix))
        .h(px(32.0))
        .w_full()
        .mx_2()
        .px_2p5()
        .items_center()
        .gap_2()
        .rounded_md()
        .cursor_pointer()
        .when(selected, |row| row.bg(ThemeColors::accent()))
        .hover(|h| h.bg(ThemeColors::accent()))
        .child(
            Icon::new(if is_current {
                IconName::Check
            } else {
                IconName::GitBranch
            })
            .size(px(14.0))
            .text_color(if is_current {
                ThemeColors::success()
            } else {
                ThemeColors::muted_foreground()
            }),
        )
        .child(
            div()
                .flex_1()
                .truncate()
                .text_sm()
                .font_weight(FontWeight::MEDIUM)
                .text_color(ThemeColors::foreground())
                .child(name),
        )
        .when(is_current, |row| {
            row.child(
                div()
                    .text_xs()
                    .text_color(ThemeColors::success())
                    .child(crate::i18n::menu_text(cx, "git.current").to_string()),
            )
        })
        .on_click(cx.listener(move |this, _event, _window, cx| {
            if busy {
                return;
            }
            this.checkout(target.clone(), cx);
        }))
        .into_any_element()
}

/// 工作树行：目录名 + 分支标签（无分支显示 detached / no branch）副行，当前打勾。
fn worktree_row(
    ix: usize,
    info: WorktreeInfo,
    repo_path: &str,
    detached: &str,
    no_branch: &str,
    selected: bool,
    busy: bool,
    cx: &mut Context<BranchManagerView>,
) -> gpui_kit::AnyElement {
    let path = info.path.clone();
    let title = folder_name(&info.path);
    let label = worktree_label(&info, detached, no_branch);
    let is_current = info.is_current || info.path == repo_path;
    h_flex()
        .id(("branch-manager-worktree", ix))
        .h(px(40.0))
        .w_full()
        .mx_2()
        .px_2p5()
        .items_center()
        .gap_2()
        .rounded_md()
        .cursor_pointer()
        .when(selected, |row| row.bg(ThemeColors::accent()))
        .hover(|h| h.bg(ThemeColors::accent()))
        .child(
            Icon::new(if is_current {
                IconName::Check
            } else {
                IconName::Folder
            })
            .size(px(14.0))
            .text_color(if is_current {
                ThemeColors::success()
            } else {
                ThemeColors::muted_foreground()
            }),
        )
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .child(
                    div()
                        .w_full()
                        .truncate()
                        .text_sm()
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(ThemeColors::foreground())
                        .child(title),
                )
                .child(
                    h_flex()
                        .gap_1()
                        .child(
                            Icon::new(IconName::GitBranch)
                                .size(px(12.0))
                                .text_color(ThemeColors::subtle_foreground()),
                        )
                        .child(
                            div()
                                .flex_1()
                                .truncate()
                                .text_xs()
                                .text_color(ThemeColors::subtle_foreground())
                                .child(label),
                        ),
                ),
        )
        .on_click(cx.listener(move |this, _event, _window, cx| {
            if busy || path == this.repo_path {
                return;
            }
            cx.emit(BranchManagerEvent::OpenWorktree(path.clone()));
        }))
        .into_any_element()
}

/// 仓库行：仓库名 + 相对路径 + 当前打勾，点击切换。
fn repository_row(
    full_path: String,
    workspace_root: &str,
    is_current: bool,
    selected: bool,
    cx: &mut Context<BranchManagerView>,
) -> gpui_kit::AnyElement {
    let title = folder_name(&full_path);
    // Windows 用 workspaceRootPath 计算相对路径；根为空时回退完整路径。
    let description = if workspace_root.is_empty() {
        full_path.clone()
    } else {
        let rel = relative_path(&full_path, workspace_root);
        if rel.is_empty() {
            full_path.clone()
        } else {
            rel
        }
    };
    h_flex()
        .id("branch-manager-repo")
        .h(px(40.0))
        .w_full()
        .mx_2()
        .px_2p5()
        .items_center()
        .gap_2()
        .rounded_md()
        .cursor_pointer()
        .when(selected, |row| row.bg(ThemeColors::accent()))
        .hover(|h| h.bg(ThemeColors::accent()))
        .child(
            Icon::new(if is_current {
                IconName::Check
            } else {
                IconName::Folder
            })
            .size(px(14.0))
            .text_color(if is_current {
                ThemeColors::success()
            } else {
                ThemeColors::muted_foreground()
            }),
        )
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .child(
                    div()
                        .w_full()
                        .truncate()
                        .text_sm()
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(ThemeColors::foreground())
                        .child(title),
                )
                .child(
                    div()
                        .w_full()
                        .truncate()
                        .text_xs()
                        .text_color(ThemeColors::subtle_foreground())
                        .child(description),
                ),
        )
        .when(is_current, |row| {
            row.child(
                div()
                    .text_xs()
                    .text_color(ThemeColors::success())
                    .child(crate::i18n::menu_text(cx, "git.current").to_string()),
            )
        })
        .on_click(cx.listener(move |this, _event, _window, cx| {
            if full_path == this.repo_path {
                return;
            }
            cx.emit(BranchManagerEvent::SelectRepository(full_path.clone()));
        }))
        .into_any_element()
}

/// 空态行。
fn empty_row(text: String) -> gpui_kit::AnyElement {
    div()
        .w_full()
        .py_8()
        .text_center()
        .text_sm()
        .text_color(ThemeColors::subtle_foreground())
        .child(text)
        .into_any_element()
}
