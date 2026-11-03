//! Git 管理器对话框（提交工具窗标题栏菜单的对话框家族）。
//!
//! 对齐 Tauri `git-push-dialog.tsx` / `git-pull-dialog.tsx` /
//! `git-remote-manager.tsx` / `git-tag-manager.tsx`（本文件）与
//! `git-branch-manager.tsx` / `git-patch-dialog.tsx` / `git-rebase-dialog.tsx`
//! （`git_dialogs_manage.rs`）。gpui-kit 的 `open_dialog` builder 会在层重建
//! 时重放，所以对话框实体与输入框实体必须在 builder 外、又在拿到 `Window`
//! 的 `open()` 里创建并捕获句柄；全部数据从 Core `execute_raw` 拉取，动作
//! 成功后通知 `GitPanel::refresh_data` 并自动关闭。

use std::path::PathBuf;

use gpui_kit::component::button::Button;
use gpui_kit::component::button::ButtonVariants as _;
use gpui_kit::component::checkbox::Checkbox;
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AppContext as _, Context, Entity, InteractiveElement as _, IntoElement, ParentElement as _,
    Render, SharedString, StatefulInteractiveElement as _, Styled as _, WeakEntity, div, px,
};
use lithe_core_client::CoreClient;
use lithe_features::git::{GitDialogKind, execute_git_command};
use lithe_ui::current_tokens;
use lithe_ui::i18n::tr;
use lithe_ui::MONO_FONT_FAMILY;
use serde_json::Value;

use crate::workbench::Workbench;

/// 一个 Git 管理器对话框的完整视图状态（全部 kind 共用同一定义，动作与
/// 渲染按 `kind` 分发到本文件与 `git_dialogs_manage.rs` 的 `impl` 块）。
pub(crate) struct GitDialogView {
    pub(crate) kind: GitDialogKind,
    pub(crate) client: CoreClient,
    pub(crate) root: Option<PathBuf>,
    pub(crate) panel: WeakEntity<lithe_features::git::GitPanel>,
    pub(crate) workbench: WeakEntity<Workbench>,
    /// 成功后自动关闭的标记（成功回包后设置，下一帧 render 里执行）。
    pub(crate) pending_close: bool,
    pub(crate) busy: bool,
    pub(crate) loading: bool,
    pub(crate) error: Option<String>,
    /// 列表操作选中的行索引（各管理器共用一份光标）。
    pub(crate) selected: usize,
    pub(crate) entries: Vec<ReferenceEntry>,
    pub(crate) worktrees: Vec<WorktreeEntry>,
    // --- Push ---
    pub(crate) push_force: bool,
    pub(crate) push_tags: PushTags,
    pub(crate) push_remote: String,
    // --- Pull ---
    pub(crate) pull_mode: PullMode,
    pub(crate) pull_auto_stash: bool,
    /// `git.pullPreflight` 的实际结果：上游、领先 / 落后、是否分叉、本地脏改动。
    /// 有结果后对话框回显真实的分支状态，而不是只把错误丢到状态行。
    pub(crate) pull_preview: Option<PullPreviewData>,
    // --- 输入框（在 open() 里创建，带 Window；各 kind 按需显示） ---
    pub(crate) name_input: Entity<InputState>,
    pub(crate) url_input: Entity<InputState>,
    pub(crate) message_input: Entity<InputState>,
    pub(crate) branch_input: Entity<InputState>,
    // --- Patch ---
    pub(crate) patch_source: PatchSource,
    pub(crate) patch_paths: Vec<String>,
    pub(crate) patch_include_untracked: bool,
    pub(crate) patch_text: Option<String>,
    pub(crate) patch_file_name: Option<String>,
    pub(crate) patch_expected_state: Option<String>,
    /// `git.pushPreview` 的已审阅目标（对齐 Tauri push dialog 的 preview）：
    /// 远端 / 目标分支 / 领先提交数 / 待推送标签，同时作为 `expectedPush`
    /// 快照的来源，推送前由 Core 复核。
    pub(crate) push_preview: Option<PushPreviewData>,
    /// 等待用户确认的 checkout（checkoutPreflight 报告了阻断路径）。
    pub(crate) pending_checkout: Option<CheckoutConfirm>,
    // --- Rebase ---
    pub(crate) rebase_plan: Option<RebasePlan>,
    /// 查询到的进行中会话 (session_id, status)。
    pub(crate) rebase_session: Option<(String, String)>,
}

/// Push 的 tags 范围（对齐 Core `push_tags`：`none` / `all` / `reachable`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PushTags {
    None,
    Reachable,
    All,
}

impl PushTags {
    pub(crate) fn wire(self) -> &'static str {
        match self {
            PushTags::None => "none",
            PushTags::Reachable => "reachable",
            PushTags::All => "all",
        }
    }

    pub(crate) fn label(self) -> &'static str {
        match self {
            PushTags::None => tr("Push no tags"),
            PushTags::Reachable => tr("Push reachable tags"),
            PushTags::All => tr("Push all tags"),
        }
    }
}

/// Pull 的合并策略（Core `pull` 的 `mode`：ffOnly / merge / rebase）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PullMode {
    FfOnly,
    Merge,
    Rebase,
}

impl PullMode {
    pub(crate) fn wire(self) -> &'static str {
        match self {
            PullMode::FfOnly => "ffOnly",
            PullMode::Merge => "merge",
            PullMode::Rebase => "rebase",
        }
    }

    pub(crate) fn label(self) -> &'static str {
        match self {
            PullMode::FfOnly => tr("Fast-forward only"),
            PullMode::Merge => tr("Merge"),
            PullMode::Rebase => tr("Rebase"),
        }
    }
}

/// Patch 的导出来源（对齐 Core `PatchSource` 的 camelCase）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PatchSource {
    WorkingTree,
    Staged,
}

impl PatchSource {
    pub(crate) fn wire(self) -> &'static str {
        match self {
            PatchSource::WorkingTree => "workingTree",
            PatchSource::Staged => "staged",
        }
    }

    pub(crate) fn label(self) -> &'static str {
        match self {
            PatchSource::WorkingTree => tr("Working tree"),
            PatchSource::Staged => tr("Staged"),
        }
    }
}

/// `git.references` 里的一个条目（分支 / 远程 / 标签管理共用）。
#[derive(Debug, Clone, Default)]
pub(crate) struct ReferenceEntry {
    pub(crate) full_name: String,
    pub(crate) short_name: String,
    pub(crate) kind: String,
    pub(crate) is_current: bool,
    pub(crate) upstream: Option<String>,
}

impl ReferenceEntry {
    pub(crate) fn remote_name(&self) -> &str {
        self.full_name
            .strip_prefix("refs/remotes/")
            .and_then(|rest| rest.split('/').next())
            .unwrap_or("")
    }
}

/// `git.pushPreview` 的已审阅目标（Core `GitPushPreviewResponse` 的最小消费字段）。
///
/// 对齐 Tauri `git-push-dialog.tsx`：打开时先解析真实远端与目标分支并把提交
/// 摘要展示给用户，确认时用同一快照作为 `expectedPush`，Core 在推送前复核
/// （本地分支 / 远端 / 目标分支 / 标签任一变化都会拒绝）。
#[derive(Debug, Clone, Default)]
pub(crate) struct PushPreviewData {
    pub(crate) local_branch: String,
    pub(crate) local_head: String,
    pub(crate) remote: String,
    pub(crate) remote_branch: String,
    /// `publish` / `tracking` / `divergent`。
    pub(crate) target_kind: String,
    pub(crate) creates_remote_branch: bool,
    pub(crate) remote_tracking_oid: Option<String>,
    /// 待推送标签：(fullName, objectId)。
    pub(crate) tags: Vec<(String, String)>,
    /// 本地领先提交数（预览被截断时仍是边界内的条数）。
    pub(crate) ahead: usize,
    pub(crate) has_more: bool,
}

/// `git.pullPreflight` 的已解析结果（Core `GitPullPreflightResponse`）。
///
/// 对齐 Tauri `git-pull-dialog.tsx`：打开对话框时展示真实的上游、领先 / 落后、
/// 是否分叉与本地脏改动，让用户在选策略前看到实际状态。
#[derive(Debug, Clone, Default)]
pub(crate) struct PullPreviewData {
    /// 上游短名；`None` 表示当前分支没有跟踪任何上游（无法直接 pull）。
    pub(crate) upstream: Option<String>,
    pub(crate) ahead: usize,
    pub(crate) behind: usize,
    /// 双方各有对方缺失的提交：`--ff-only` 会拒绝，需要选择 merge / rebase。
    pub(crate) diverged: bool,
    /// 本地有未提交改动：直接 pull 可能失败或与 auto-stash 交互。
    pub(crate) has_local_changes: bool,
}

/// 待确认的 checkout：Core `checkoutPreflight` 报告的阻断路径。
///
/// 阻断路径 = 工作区有改动、且 HEAD 与目标引用之间也确实改过的文件；直接
/// 切换会覆盖这些改动，因此先展示确认（对齐 Tauri 的切换前检查），而不是
/// 让 Core 用本地化的 stderr 报错。
#[derive(Debug, Clone, Default)]
pub(crate) struct CheckoutConfirm {
    pub(crate) full_name: String,
    pub(crate) short_name: String,
    pub(crate) kind: String,
    pub(crate) blocking_paths: Vec<String>,
}

/// 一条 checkout 的类型化 `git.write` 请求（Core 只接受完整引用身份）。
pub(crate) fn checkout_write_payload(full_name: &str, short_name: &str, kind: &str) -> Value {
    serde_json::json!({
        "operation": "checkout",
        "gitReference": {
            "fullName": full_name,
            "shortName": short_name,
            "kind": kind,
        },
    })
}

/// worktree 条目（Core `git.worktrees` 的最小消费字段）。
#[derive(Debug, Clone, Default)]
pub(crate) struct WorktreeEntry {
    pub(crate) path: String,
    pub(crate) head: String,
    pub(crate) branch: Option<String>,
    pub(crate) bare: bool,
    pub(crate) detached: bool,
    /// 当前工作区；Core 拒绝移除当前 / 主 worktree。
    pub(crate) is_current: bool,
    /// 仓库的主 worktree；同样不可移除。
    pub(crate) is_primary: bool,
    /// Git 判定可清理（`git worktree prune` 会删除该注册）。
    pub(crate) prunable: bool,
    pub(crate) locked: Option<String>,
}

/// Interactive Rebase 预览计划（Core `git.rebasePreview` 的最小消费字段）。
#[derive(Debug, Clone, Default)]
pub(crate) struct RebasePlan {
    pub(crate) allowed: bool,
    pub(crate) blockers: Vec<String>,
    pub(crate) branch: Option<String>,
    pub(crate) base: Option<String>,
    /// 将重放的提交（hash + subject）。
    pub(crate) commits: Vec<(String, String)>,
    /// 原样回传 `git.rebaseStart` 的 plan 快照。
    pub(crate) expected_state: Option<Value>,
    /// 由 plan 生成的默认 `pick` 步骤（`steps` 数组，回传 rebaseStart）。
    pub(crate) steps: Option<Value>,
}

impl GitDialogView {
    /// 打开对话框：实体与输入框在 `open_dialog` 之前创建（builder 重放安全，
    /// `InputState::new` 需要 Window）。
    pub(crate) fn open(
        kind: GitDialogKind,
        client: CoreClient,
        root: Option<PathBuf>,
        patch_paths: Vec<String>,
        panel: WeakEntity<lithe_features::git::GitPanel>,
        workbench: WeakEntity<Workbench>,
        window: &mut gpui_kit::Window,
        cx: &mut Context<Workbench>,
    ) {
        use gpui_kit::component::WindowExt as _;
        let name_input = cx.new(|cx| InputState::new(window, cx).placeholder(tr("Name")));
        let url_input = cx.new(|cx| InputState::new(window, cx).placeholder(tr("URL")));
        let message_input =
            cx.new(|cx| InputState::new(window, cx).placeholder(tr("Annotated message")));
        let branch_input = cx.new(|cx| {
            // ApplyPatch 用该输入框粘贴 patch 文本；其余 kind 作为新名字输入。
            if kind == GitDialogKind::ApplyPatch {
                InputState::new(window, cx).placeholder(tr("Paste patch here"))
            } else {
                InputState::new(window, cx).placeholder(tr("Name"))
            }
        });
        let view = cx.new(|cx| {
            Self::new(
                kind,
                client,
                root,
                patch_paths,
                panel,
                workbench,
                name_input.clone(),
                url_input.clone(),
                message_input.clone(),
                branch_input.clone(),
                cx,
            )
        });
        let dialog_view = view.clone();
        window.open_dialog(cx, move |dialog, _window, cx| {
            let title = dialog_view.read(cx).dialog_title();
            dialog.title(title).w(px(560.0)).child(dialog_view.clone())
        });
    }

    pub(crate) fn new(
        kind: GitDialogKind,
        client: CoreClient,
        root: Option<PathBuf>,
        patch_paths: Vec<String>,
        panel: WeakEntity<lithe_features::git::GitPanel>,
        workbench: WeakEntity<Workbench>,
        name_input: Entity<InputState>,
        url_input: Entity<InputState>,
        message_input: Entity<InputState>,
        branch_input: Entity<InputState>,
        cx: &mut Context<Self>,
    ) -> Self {
        let mut view = Self {
            kind,
            client,
            root,
            panel,
            workbench,
            pending_close: false,
            busy: false,
            loading: false,
            error: None,
            selected: 0,
            entries: Vec::new(),
            worktrees: Vec::new(),
            push_force: false,
            push_tags: PushTags::Reachable,
            push_remote: String::new(),
            push_preview: None,
            pending_checkout: None,
            pull_mode: PullMode::FfOnly,
            pull_auto_stash: false,
            pull_preview: None,
            name_input,
            url_input,
            message_input,
            branch_input,
            patch_source: PatchSource::WorkingTree,
            patch_paths,
            patch_include_untracked: true,
            patch_text: None,
            patch_file_name: None,
            patch_expected_state: None,
            rebase_plan: None,
            rebase_session: None,
        };
        match kind {
            // 这些对话框开窗即拉数据（对齐 Tauri 的 useEffect 首拉）。
            GitDialogKind::Branches
            | GitDialogKind::Worktrees
            | GitDialogKind::Remotes
            | GitDialogKind::Tags => view.load_references(cx),
            // Push 需要已审阅的远端 / 目标分支 / 提交摘要（pushPreview）；
            // 预览自身会解析远端，不再单独拉引用列表。
            GitDialogKind::Push => view.load_push_preview(cx),
            GitDialogKind::Pull => view.run_pull_preflight(cx),
            GitDialogKind::Rebase => view.run_rebase_preview(cx),
            _ => {}
        }
        view
    }

    pub(crate) fn dialog_title(&self) -> &'static str {
        match self.kind {
            GitDialogKind::Push => tr("Push Changes"),
            GitDialogKind::Pull => tr("Pull Changes"),
            GitDialogKind::Branches => tr("Manage Branches"),
            GitDialogKind::Worktrees => tr("Manage Worktrees…"),
            GitDialogKind::Remotes => tr("Manage Remotes"),
            GitDialogKind::Tags => tr("Manage Tags"),
            GitDialogKind::CreatePatch => tr("Create Patch…"),
            GitDialogKind::ApplyPatch => tr("Apply Patch…"),
            GitDialogKind::Rebase => tr("Interactive Rebase Session…"),
            GitDialogKind::ChooseDiffSource => tr("Choose Diff Source"),
        }
    }

    /// kind 需要的引用子集（按 `kind` 字段过滤）。
    pub(crate) fn entries_of(&self, kind: &'static str) -> Vec<ReferenceEntry> {
        self.entries
            .iter()
            .filter(|entry| entry.kind == kind)
            .cloned()
            .collect()
    }

    /// 远端名列表（远端管理 / Push 对话框共用）。
    pub(crate) fn remote_names(&self) -> Vec<String> {
        let mut names: Vec<String> = self
            .entries
            .iter()
            .filter(|entry| entry.kind == "remote")
            .map(|entry| entry.remote_name().to_string())
            .collect();
        names.sort();
        names.dedup();
        names
    }
}

// --- 数据与命令通道 --------------------------------------------------------

impl GitDialogView {
    /// `git.references` 是全部 kind 的列表真源。
    pub(crate) fn load_references(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root.to_str().map(str::to_string) else {
            return;
        };
        self.loading = true;
        let client = self.client;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, "git.references", serde_json::json!({ "root": root_text }))
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.loading = false;
                match raw {
                    Ok(value) => {
                        this.entries = parse_reference_entries(&value);
                        if this.push_remote.is_empty() {
                            this.push_remote = this
                                .remote_names()
                                .first()
                                .cloned()
                                .unwrap_or_default();
                        }
                    }
                    Err(error) => {
                        this.error = Some(error.to_string());
                    }
                }
                if matches!(this.kind, GitDialogKind::Branches | GitDialogKind::Worktrees) {
                    this.load_worktrees(cx);
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(crate) fn load_worktrees(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root.to_str().map(str::to_string) else {
            return;
        };
        self.loading = true;
        let client = self.client;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, "git.worktrees", serde_json::json!({ "root": root_text }))
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.loading = false;
                match raw {
                    Ok(value) => {
                        this.worktrees = parse_worktrees(&value);
                    }
                    Err(error) => {
                        this.error = Some(error.to_string());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 通知 GitPanel 刷新面板数据（写操作成功后调用）。
    pub(crate) fn notify_panel_refresh(&self, cx: &mut Context<Self>) {
        if let Some(panel) = self.panel.upgrade() {
            panel.update(cx, |panel, panel_cx| panel.refresh_data(panel_cx));
        }
    }

    /// 成功后自动关闭对话框（下一帧 render 里执行，拿到 Window）。
    pub(crate) fn request_close(&mut self) {
        self.pending_close = true;
    }

    /// `git.pushPreview`：解析真实远端 / 目标分支 / 待推送提交与标签。
    /// 缺省引用 = 当前分支（Core `resolve_push_target` 的默认）。
    pub(crate) fn load_push_preview(&mut self, cx: &mut Context<Self>) {
        if self.loading {
            return;
        }
        let Some(root) = self.root.clone() else {
            return;
        };
        let root_text = root.to_string_lossy().to_string();
        let client = self.client;
        self.loading = true;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, 
                        "git.pushPreview",
                        serde_json::json!({
                            "root": root_text,
                            "limit": 200,
                            "pushTags": "reachable",
                        }),
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.loading = false;
                match raw {
                    Ok(value) => {
                        this.push_preview = Some(Self::parse_push_preview(&value));
                        if let Some(preview) = this.push_preview.as_ref() {
                            this.push_remote = preview.remote.clone();
                        }
                    }
                    Err(error) => {
                        this.error = Some(error.to_string());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 已审阅的推送快照（Core `GitPushExpectationRequest`）；没有预览时返回
    /// `None`，让 Core 退回普通的无快照推送。
    pub(crate) fn expected_push_payload(&self) -> Option<Value> {
        let preview = self.push_preview.as_ref()?;
        if preview.local_branch.is_empty() || preview.remote.is_empty() {
            return None;
        }
        let tags = preview
            .tags
            .iter()
            .map(|(full_name, object_id)| {
                serde_json::json!({
                    "fullName": full_name,
                    "objectId": object_id,
                })
            })
            .collect::<Vec<_>>();
        Some(serde_json::json!({
            "localBranch": preview.local_branch,
            "localHead": preview.local_head,
            "remote": preview.remote,
            "remoteBranch": preview.remote_branch,
            "targetKind": preview.target_kind,
            "remoteTrackingOid": preview.remote_tracking_oid,
            "tags": tags,
        }))
    }

    /// 通用 `git.write` 执行；`exitCode != 0` 视为失败（对齐 plan-00 §6-4）。
    pub(crate) fn run_write(&mut self, mut payload: Value, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some(root) = self.root.clone() else {
            return;
        };
        if let Some(root_text) = root.to_str() {
            payload["root"] = Value::String(root_text.to_string());
        }
        self.busy = true;
        self.error = None;
        let client = self.client;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move { execute_git_command(&client, "git.write", payload) })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.busy = false;
                match raw {
                    Ok(value) => {
                        let failed = value
                            .get("exitCode")
                            .and_then(Value::as_i64)
                            .map(|code| code != 0)
                            .unwrap_or(false);
                        if failed {
                            this.error = Some(failure_detail(&value));
                        } else {
                            this.notify_panel_refresh(cx);
                            this.request_close();
                        }
                    }
                    Err(error) => {
                        this.error = Some(error.to_string());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 通用 `git.command` 执行（remote add/remove/rename/set-url、tag -d、
    /// branch -m 等没有专用 operation 的调用）。
    pub(crate) fn run_command(&mut self, arguments: Vec<String>, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some(root) = self.root.as_ref().and_then(|root| root.to_str()) else {
            return;
        };
        let payload = serde_json::json!({
            "root": root,
            "arguments": arguments,
        });
        self.busy = true;
        self.error = None;
        let client = self.client;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move { execute_git_command(&client, "git.command", payload) })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.busy = false;
                match raw {
                    Ok(value) => {
                        let failed = value
                            .get("exitCode")
                            .and_then(Value::as_i64)
                            .map(|code| code != 0)
                            .unwrap_or(false);
                        if failed {
                            this.error = Some(failure_detail(&value));
                        } else {
                            // 成功后重读列表（remotes / tags / 分支的数据源都
                            // 是引用），不关闭对话框，用户可以继续管理。
                            this.load_references(cx);
                            this.notify_panel_refresh(cx);
                        }
                    }
                    Err(error) => {
                        this.error = Some(error.to_string());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
}

/// `git.write` / `git.command` 失败时的可见文本（stderr 优先）。
pub(crate) fn failure_detail(value: &Value) -> String {
    let stderr = value
        .get("stderr")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let output = value
        .get("output")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let stderr = stderr.trim();
    let output = output.trim();
    let detail = if stderr.is_empty() { output } else { stderr };
    if detail.is_empty() {
        tr("Git operation failed").to_string()
    } else {
        detail.to_string()
    }
}

/// 解析 `git.references` 的本地 / 远程 / 标签条目。
pub(crate) fn parse_reference_entries(value: &Value) -> Vec<ReferenceEntry> {
    value
        .get("references")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .map(|item| ReferenceEntry {
                    full_name: item
                        .get("fullName")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    short_name: item
                        .get("shortName")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    kind: item
                        .get("kind")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    is_current: item
                        .get("isCurrent")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                    upstream: item
                        .get("upstreamShortName")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 解析 `git.worktrees` 的条目。
pub(crate) fn parse_worktrees(value: &Value) -> Vec<WorktreeEntry> {
    value
        .get("worktrees")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .map(|item| WorktreeEntry {
                    path: item
                        .get("path")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    head: item
                        .get("head")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    branch: item
                        .get("branch")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    // Core 的布尔字段一律以 `is` 前缀 + camelCase 序列化。
                    bare: item.get("isBare").and_then(Value::as_bool).unwrap_or(false),
                    detached: item
                        .get("isDetached")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                    is_current: item
                        .get("isCurrent")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                    is_primary: item
                        .get("isPrimary")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                    prunable: item
                        .get("isPrunable")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                    locked: item
                        .get("lockReason")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                })
                .collect()
        })
        .unwrap_or_default()
}

// --- Render ---------------------------------------------------------------

impl Render for GitDialogView {
    fn render(&mut self, window: &mut gpui_kit::Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 成功回包后下一帧关闭（run_write 成功 → request_close）。
        if self.pending_close {
            self.pending_close = false;
            use gpui_kit::component::WindowExt as _;
            window.close_dialog(cx);
        }

        let tokens = current_tokens(cx);
        let body = match self.kind {
            GitDialogKind::Push => self.render_push(tokens, cx),
            GitDialogKind::Pull => self.render_pull(tokens, cx),
            GitDialogKind::Remotes => self.render_remotes(tokens, cx),
            GitDialogKind::Tags => self.render_tags(tokens, cx),
            GitDialogKind::ChooseDiffSource => self.render_choose_diff_source(tokens, cx),
            _ => self.render_manage(window, tokens, cx),
        };

        v_flex()
            .id("lithe-git-dialog")
            .size_full()
            .min_h(px(140.0))
            .gap(px(10.0))
            .child(self.render_dialog_status(tokens, cx))
            .child(body)
    }
}

impl GitDialogView {
    /// 对话框通用状态行：加载中 / 错误 stderr。
    fn render_dialog_status(
        &self,
        tokens: lithe_ui::LitheTokens,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let _ = cx;
        v_flex()
            .w_full()
            .gap(px(2.0))
            .when(self.loading, |this| {
                this.child(
                    div()
                        .text_size(px(11.0))
                        .text_color(tokens.tertiary_text)
                        .child(tr("Loading…")),
                )
            })
            .when_some(self.error.clone(), |this, error| {
                this.child(
                    h_flex()
                        .items_center()
                        .gap(px(6.0))
                        .max_w(px(500.0))
                        .child(
                            Icon::new(gpui_kit::assets::IconName::CircleAlert)
                                .with_size(px(12.0))
                                .text_color(tokens.error),
                        )
                        .child(
                            div()
                                .min_w(px(0.0))
                                .flex_1()
                                .truncate()
                                .text_size(px(11.0))
                                .font_family(MONO_FONT_FAMILY)
                                .text_color(tokens.error)
                                .child(error),
                        ),
                )
            })
            .into_any_element()
    }

    /// 确认按钮的通用 disabled 语义：没有 root 或正在执行时不可点。
    pub(crate) fn action_disabled(&self) -> bool {
        self.busy || self.root.is_none()
    }

    /// 单选行（mode / tags / source 这类小集合的共用渲染）。
    pub(crate) fn radio_row(
        id: &'static str,
        selected: bool,
        label: &'static str,
        tokens: lithe_ui::LitheTokens,
    ) -> gpui_kit::AnyElement {
        h_flex()
            .items_center()
            .gap(px(6.0))
            .child(Checkbox::new(SharedString::from(id)).small().checked(selected))
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(if selected {
                        tokens.primary_text
                    } else {
                        tokens.secondary_text
                    })
                    .child(label),
            )
            .into_any_element()
    }

    /// 底部按钮行（Cancel + 若干动作按钮）。
    pub(crate) fn cancel_button(
        id: &'static str,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        Button::new(SharedString::from(id))
            .ghost()
            .small()
            .label(tr("Cancel"))
            .on_click(cx.listener(|this, _, _, _cx| this.request_close()))
            .into_any_element()
    }

    /// 字段标签。
    pub(crate) fn field_label(&self, label: &'static str) -> gpui_kit::AnyElement {
        div().text_size(px(11.0)).child(label).into_any_element()
    }
}

// --- Push 对话框（对齐 Tauri git-push-dialog） -------------------------------

impl GitDialogView {
    pub(crate) fn render_push(
        &mut self,
        tokens: lithe_ui::LitheTokens,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let preview = self.push_preview.clone();
        if preview.is_none() && !self.loading && self.error.is_none() {
            // 首帧尚未开始加载（builder 重放安全）：补一次请求。
            self.load_push_preview(cx);
        }
        let target = preview
            .as_ref()
            .map(|preview| preview.local_branch.clone())
            .unwrap_or_default();

        let mut form = v_flex().gap(px(8.0));
        // 远端与目标分支由 Core 按分支上游 / 仓库默认值解析（对齐 Tauri
        // push dialog 的 reviewed preview）。这里只回显，不提供假的可编辑
        // 远端选择：Core 的受审阅推送以解析结果为准。
        match preview.as_ref() {
            Some(preview) => {
                form = form
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(tokens.primary_text)
                            .child(format!("{}:{}", preview.remote, preview.remote_branch)),
                    )
                    .child(
                        div()
                            .text_size(px(11.5))
                            .text_color(tokens.tertiary_text)
                            .child(
                                tr("{count} commits to push")
                                    .replace("{count}", &preview.ahead.to_string()),
                            ),
                    );
                if preview.creates_remote_branch {
                    form = form.child(
                        div()
                            .text_size(px(11.5))
                            .text_color(tokens.accent)
                            .child(tr("Creates the remote branch")),
                    );
                }
            }
            None => {
                form = form.child(
                    div()
                        .text_size(px(11.5))
                        .text_color(tokens.tertiary_text)
                        .child(if self.loading {
                            tr("Resolving push target…")
                        } else {
                            tr("No remotes configured")
                        }),
                );
            }
        }

        form = form
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(tokens.secondary_text)
                    .child(tr("Branch: {branch}").replace("{branch}", &target)),
            )
            .child(
                Checkbox::new("lithe-git-dialog:push-force")
                    .small()
                    .checked(self.push_force)
                    .label(tr("Force push"))
                    .on_change(cx.listener(|this, checked: &bool, _window, cx| {
                        this.push_force = *checked;
                        cx.notify();
                    })),
            )
            .child(
                Checkbox::new("lithe-git-dialog:push-tags")
                    .small()
                    .checked(self.push_tags == PushTags::Reachable)
                    .label(tr("Push reachable tags"))
                    .on_change(cx.listener(|this, checked: &bool, _window, cx| {
                        this.push_tags = if *checked {
                            PushTags::Reachable
                        } else {
                            PushTags::None
                        };
                        cx.notify();
                    })),
            )
            .child(
                Checkbox::new("lithe-git-dialog:push-tags-all")
                    .small()
                    .checked(self.push_tags == PushTags::All)
                    .label(tr("Push all tags"))
                    .on_change(cx.listener(|this, checked: &bool, _window, cx| {
                        this.push_tags = if *checked {
                            PushTags::All
                        } else {
                            PushTags::None
                        };
                        cx.notify();
                    })),
            )
            .child(
                h_flex()
                    .justify_end()
                    .gap(px(8.0))
                    .child(Self::cancel_button(
                        "lithe-git-dialog:push-cancel",
                        cx,
                    ))
                    .child(
                        Button::new("lithe-git-dialog:push-confirm")
                            .primary()
                            .small()
                            .label(tr("Push"))
                            .disabled(
                                self.action_disabled()
                                    || self.push_remote.is_empty()
                                    || target.is_empty(),
                            )
                            .on_click(cx.listener(move |this, _, _, cx| {
                                // Core `GitWriteRequest` 是 camelCase：`pushTags`
                                // 才生效；`expectedPush` 让 Core 在推送前复核
                                // 预览快照（分支/远端在对话框打开后被改动时拒绝）。
                                let mut payload = serde_json::json!({
                                    "operation": "push",
                                    "pushTags": this.push_tags.wire(),
                                });
                                if this.push_force {
                                    payload["force"] = Value::Bool(true);
                                }
                                if !target.is_empty() {
                                    payload["reference"] = Value::String(target.clone());
                                }
                                if let Some(expected) = this.expected_push_payload() {
                                    payload["expectedPush"] = expected;
                                }
                                this.run_write(payload, cx);
                            })),
                    ),
            );
        form.into_any_element()
    }

}

// --- Remotes 管理器（对齐 Tauri git-remote-manager） -------------------------

impl GitDialogView {
    pub(crate) fn render_remotes(
        &mut self,
        tokens: lithe_ui::LitheTokens,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let remotes = self.remote_names();
        if !remotes.is_empty() && self.selected >= remotes.len() {
            self.selected = remotes.len() - 1;
        }
        let selected_remote = remotes.get(self.selected).cloned().unwrap_or_default();

        let mut list = v_flex().gap(px(2.0));
        for (index, remote) in remotes.iter().enumerate() {
            let is_selected = index == self.selected;
            // listener 要求 'static 闭包：行循环里先把借用到的远端名克隆成
            // owned 值，避免捕获 `&String`。
            let remote_for_click = remote.clone();
            list = list.child(
                h_flex()
                    .id(SharedString::from(format!(
                        "lithe-git-dialog:remote-{index}"
                    )))
                    .w_full()
                    .rounded(px(4.0))
                    .px(px(8.0))
                    .py(px(3.0))
                    .gap(px(8.0))
                    .cursor_pointer()
                    .when(is_selected, |this| this.bg(tokens.subtle_selection))
                    .when(!is_selected, |this| this.hover(|style| style.bg(tokens.hover)))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.selected = index;
                        // 选中行同步 Name 输入框（set_value 需要 Window，
                        // listener 的第三参正好是它）。
                        let remote = remote_for_click.clone();
                        this.name_input.update(cx, |state, cx| {
                            state.set_value(remote.as_str(), window, cx);
                        });
                        cx.notify();
                    }))
                    .child(
                        Icon::new(gpui_kit::assets::IconName::HardDrive)
                            .with_size(px(13.0))
                            .text_color(tokens.secondary_text),
                    )
                    .child(
                        div()
                            .text_size(px(12.0))
                            .font_family(MONO_FONT_FAMILY)
                            .child(remote.clone()),
                    ),
            );
        }

        v_flex()
            .gap(px(10.0))
            .child(list)
            .child(self.field_label(tr("Name")))
            .child(Input::new(&self.name_input).small().w_full())
            .child(self.field_label(tr("URL")))
            .child(Input::new(&self.url_input).small().w_full())
            .child(
                h_flex()
                    .justify_end()
                    .gap(px(6.0))
                    .child(
                        Button::new("lithe-git-dialog:remote-add")
                            .secondary()
                            .small()
                            .label(tr("Add remote"))
                            .disabled(self.action_disabled())
                            .on_click(cx.listener(move |this, _, _, cx| {
                                let name = this.name_input.read(cx).value().trim().to_string();
                                let url = this.url_input.read(cx).value().trim().to_string();
                                if name.is_empty() || url.is_empty() {
                                    this.error =
                                        Some(tr("Name and URL are required").to_string());
                                    cx.notify();
                                    return;
                                }
                                this.run_command(
                                    vec!["remote".into(), "add".into(), name, url],
                                    cx,
                                );
                            })),
                    )
                    .child(
                        Button::new("lithe-git-dialog:remote-rename")
                            .secondary()
                            .small()
                            .label(tr("Rename remote"))
                            .disabled(self.action_disabled() || selected_remote.is_empty())
                            .on_click(cx.listener({
                                // 每个按钮的 move 闭包各自持有一份远端名。
                                let remote = selected_remote.clone();
                                move |this, _, _, cx| {
                                    let name = this.name_input.read(cx).value().trim().to_string();
                                    if name.is_empty() || name == remote {
                                        cx.notify();
                                        return;
                                    }
                                    this.run_command(
                                        vec![
                                            "remote".into(),
                                            "rename".into(),
                                            remote.clone(),
                                            name,
                                        ],
                                        cx,
                                    );
                                }
                            })),
                    )
                    .child(
                        Button::new("lithe-git-dialog:remote-set-url")
                            .secondary()
                            .small()
                            .label(tr("Update URL"))
                            .disabled(self.action_disabled() || selected_remote.is_empty())
                            .on_click(cx.listener({
                                let remote = selected_remote.clone();
                                move |this, _, _, cx| {
                                    let url = this.url_input.read(cx).value().trim().to_string();
                                    if url.is_empty() {
                                        cx.notify();
                                        return;
                                    }
                                    this.run_command(
                                        vec![
                                            "remote".into(),
                                            "set-url".into(),
                                            remote.clone(),
                                            url,
                                        ],
                                        cx,
                                    );
                                }
                            })),
                    )
                    .child(
                        Button::new("lithe-git-dialog:remote-remove")
                            .danger()
                            .small()
                            .label(tr("Remove remote"))
                            .disabled(self.action_disabled() || selected_remote.is_empty())
                            .on_click(cx.listener({
                                let remote = selected_remote.clone();
                                move |this, _, _, cx| {
                                    this.run_command(
                                        vec!["remote".into(), "remove".into(), remote.clone()],
                                        cx,
                                    );
                                }
                            })),
                    ),
            )
            .into_any_element()
    }
}

// --- Tags 管理器（对齐 Tauri git-tag-manager） -------------------------------

impl GitDialogView {
    pub(crate) fn render_tags(
        &mut self,
        tokens: lithe_ui::LitheTokens,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let tags = self.entries_of("tag");
        if !tags.is_empty() && self.selected >= tags.len() {
            self.selected = tags.len() - 1;
        }
        let selected_name = tags
            .get(self.selected)
            .map(|tag| tag.short_name.clone())
            .unwrap_or_default();

        let mut list = v_flex().gap(px(2.0));
        for (index, tag) in tags.iter().enumerate() {
            let is_selected = index == self.selected;
            let name = tag.short_name.clone();
            list = list.child(
                h_flex()
                    .id(SharedString::from(format!(
                        "lithe-git-dialog:tag-{index}"
                    )))
                    .w_full()
                    .rounded(px(4.0))
                    .px(px(8.0))
                    .py(px(3.0))
                    .gap(px(8.0))
                    .cursor_pointer()
                    .when(is_selected, |this| this.bg(tokens.subtle_selection))
                    .when(!is_selected, |this| this.hover(|style| style.bg(tokens.hover)))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.selected = index;
                        this.name_input.update(cx, |state, cx| {
                            state.set_value(name.as_str(), window, cx);
                        });
                        cx.notify();
                    }))
                    .child(
                        Icon::new(gpui_kit::assets::IconName::Tag)
                            .with_size(px(13.0))
                            .text_color(tokens.secondary_text),
                    )
                    .child(
                        div()
                            .text_size(px(12.0))
                            .font_family(MONO_FONT_FAMILY)
                            .child(tag.short_name.clone()),
                    ),
            );
        }

        v_flex()
            .gap(px(10.0))
            .child(list)
            .child(self.field_label(tr("Tag name")))
            .child(Input::new(&self.name_input).small().w_full())
            .child(self.field_label(tr("Annotated message")))
            .child(Input::new(&self.message_input).small().w_full())
            .child(
                h_flex()
                    .justify_end()
                    .gap(px(6.0))
                    .child(
                        Button::new("lithe-git-dialog:tag-create")
                            .secondary()
                            .small()
                            .label(tr("Create tag"))
                            .disabled(self.action_disabled())
                            .on_click(cx.listener(move |this, _, _, cx| {
                                let name = this.name_input.read(cx).value().trim().to_string();
                                if name.is_empty() {
                                    cx.notify();
                                    return;
                                }
                                let message =
                                    this.message_input.read(cx).value().trim().to_string();
                                // HEAD 作为缺省目标；带注解消息时 Core 拼
                                // `-a <name> -m <msg>`，为空时是轻量 tag
                                // （对齐 git-tag-manager 的两种形态）。
                                let mut payload = serde_json::json!({
                                    "operation": "createTag",
                                    "name": name,
                                    "revision": "HEAD",
                                });
                                if !message.is_empty() {
                                    payload["message"] = Value::String(message);
                                }
                                this.run_write(payload, cx);
                            })),
                    )
                    .child(
                        Button::new("lithe-git-dialog:tag-delete")
                            .danger()
                            .small()
                            .label(tr("Delete"))
                            .disabled(self.action_disabled() || selected_name.is_empty())
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.run_command(
                                    vec!["tag".into(), "-d".into(), selected_name.clone()],
                                    cx,
                                );
                            })),
                    ),
            )
            .into_any_element()
    }
}

// --- Choose Diff Source（对齐 Tauri 的 diff picker 选项） --------------------

impl GitDialogView {
    pub(crate) fn render_choose_diff_source(
        &mut self,
        tokens: lithe_ui::LitheTokens,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        use crate::commit_header::CommitTab;
        use crate::workbench::ToolWindow;
        let options = [
            ("working-tree", tr("Working tree")),
            ("commit", tr("Commit…")),
            ("branch", tr("Branch…")),
            ("stash", tr("Stash…")),
        ];
        let mut list = v_flex().gap(px(4.0));
        for (id, label) in options {
            list = list.child(
                Button::new(SharedString::from(format!(
                    "lithe-git-dialog:diff-source-{id}"
                )))
                .secondary()
                .small()
                .w_full()
                .label(label)
                .on_click(cx.listener(move |this, _, window, cx| {
                    // 对齐 Tauri 的 diff picker 动作：Commit / Branch 源打开
                    // Git Log 工具窗（Log 引用树就是分支与提交对比入口），
                    // Stash 源切到 Stash 分段；当前提交面板本身就是 Working
                    // tree 源（变更行双击 / Eye 已就地预览）。
                    match id {
                        "working-tree" => {}
                        "stash" => {
                            let _ = this.workbench.update(cx, |this, cx| {
                                this.set_commit_tab(CommitTab::Stash, cx);
                            });
                        }
                        _ => {
                            let _ = this.workbench.update(cx, |this, cx| {
                                this.show_tool(ToolWindow::GitLog, window, cx);
                            });
                        }
                    }
                    this.request_close();
                })),
            );
        }
        v_flex()
            .gap(px(8.0))
            .child(
                div()
                    .text_size(px(11.5))
                    .text_color(tokens.tertiary_text)
                    .child(tr("Choose the source for the diff view.")),
            )
            .child(list)
            .into_any_element()
    }
}
