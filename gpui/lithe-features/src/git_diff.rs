//! 提交差异预览视图。
//!
//! 对齐 Tauri 的提交差异：点 Git Log 里的改动文件时，差异显示在**中央编辑区**
//! （Tauri 是打开一个 diff 编辑器页），而不是挤在 Log 右栏里。Log 右栏只保留
//! 改动文件树与提交说明。
//!
//! 数据来自 Core `git.diff { root, commit, pathspecs }`，返回 `rows` 已按
//! 渲染语义分好类（context / changed / insertion / deletion / information），
//! `hunks` 是可独立应用的变更块补丁，这里只负责画出来。
//!
//! 工作区差异的每个变更块首行提供 Stage / Discard（未暂存）或 Unstage
//! （已暂存）按钮，行为对齐 macOS `DiffHunkActionsView`：写操作一律交给
//! Core `git.apply` 的 `stage` / `unstage` / `discard` 模式，丢弃前先确认。

use std::path::PathBuf;
use std::rc::Rc;

use crate::git::execute_git_command;
use crate::git::model::{command_failure_detail, parse_command};

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{
    Disableable as _, Icon, Sizable as _, VirtualListScrollHandle, h_flex, v_flex, v_virtual_list,
};
use gpui_kit::{
    AnyElement, AppContext as _, ClickEvent, Context, FocusHandle, FontWeight,
    InteractiveElement as _, IntoElement, KeyDownEvent, ParentElement as _, Pixels, Render, Size,
    SharedString, StatefulInteractiveElement as _, Styled as _, Window, div, px, size,
};
use lithe_core_client::CoreClient;
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, MONO_FONT_FAMILY, current_tokens};
use serde_json::Value;

/// 一条 diff 行（Core `GitDiffRowResponse` 的视图镜像）。
#[derive(Debug, Clone, Default)]
pub struct DiffRow {
    pub old_line: Option<usize>,
    pub new_line: Option<usize>,
    /// `context` / `information` 行只有 `left`，两侧文本相同。
    pub left: String,
    pub right: Option<String>,
    /// `context` / `changed` / `addition` / `removal` / `information`。
    pub kind: String,
    /// 该行所属的变更块 id（Core `GitDiffRowResponse.hunkId`）；文件头等行没有。
    pub hunk_id: Option<String>,
}

impl DiffRow {
    pub fn is_addition(&self) -> bool {
        self.kind == "addition"
    }

    pub fn is_removal(&self) -> bool {
        self.kind == "removal"
    }

    pub fn is_information(&self) -> bool {
        self.kind == "information"
    }

    /// 该行展示的正文：优先 `right`（`left` 为空时回落）。
    fn text(&self) -> String {
        match self.right.as_deref() {
            Some(right) if !right.is_empty() => right.to_string(),
            _ => self.left.clone(),
        }
    }
}

/// 解析 `git.diff` 响应的 `rows`。
pub fn parse_diff_rows(value: &Value) -> Vec<DiffRow> {
    value
        .get("rows")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .map(|item| DiffRow {
                    old_line: item
                        .get("oldLine")
                        .and_then(Value::as_u64)
                        .map(|value| value as usize),
                    new_line: item
                        .get("newLine")
                        .and_then(Value::as_u64)
                        .map(|value| value as usize),
                    left: item
                        .get("left")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    right: item
                        .get("right")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    kind: item
                        .get("kind")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    hunk_id: item
                        .get("hunkId")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 一个可独立应用的差异块（Core `GitDiffHunkResponse` 的视图镜像）。
///
/// `patch` 是该块带文件头的完整补丁，直接交给 Core `git.apply` 的
/// `stage` / `unstage` / `discard` 模式，不在视图里重建补丁。
#[derive(Debug, Clone, Default)]
pub struct DiffHunk {
    pub id: String,
    pub patch: String,
}

/// 解析 `git.diff` 响应的 `hunks`；没有补丁文本的块无法应用，直接跳过。
pub fn parse_diff_hunks(value: &Value) -> Vec<DiffHunk> {
    value
        .get("hunks")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    let id = item.get("id").and_then(Value::as_str)?;
                    let patch = item.get("patch").and_then(Value::as_str)?;
                    Some(DiffHunk {
                        id: id.to_string(),
                        patch: patch.to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 中央编辑区的提交差异视图。
pub struct CommitDiffView {
    client: CoreClient,
    root: Option<PathBuf>,
    /// 当前展示的提交哈希与文件路径。
    commit: String,
    path: String,
    /// 区间比较的基准引用（如 `HEAD`）。`Some` 时请求
    /// `git.diff { reference: "<base>..<commit>" }`，用于 Compare with HEAD。
    compare_base: Option<String>,
    /// 工作区差异来源；`Some(staged)` 时请求 `git.diff { staged }` 而不是
    /// `git.show <commit>`（Core `GitDiffRequest` 的 staged / 默认工作区模式）。
    working_tree_staged: Option<bool>,
    rows: Vec<DiffRow>,
    /// Core 返回的可独立应用的变更块；`id` 与 `DiffRow::hunk_id` 关联。
    hunks: Vec<DiffHunk>,
    /// 差异行的虚拟列表滚动句柄。
    scroll_handle: VirtualListScrollHandle,
    /// 每行高度（hunk 头 24，其余 20），`v_virtual_list` 用它定位可视行。
    item_sizes: Rc<Vec<Size<Pixels>>>,
    /// 每个 hunk 首行记录其 id，其余为 `None`；渲染时不必每帧扫描 hunks。
    row_hunk_ids: Vec<Option<String>>,
    /// 等待用户确认丢弃的变更块（对齐 macOS `pendingDiscardHunk`）。
    pending_discard_hunk: Option<DiffHunk>,
    /// 变更块写操作在飞：按钮全部禁用，避免重复提交。
    busy: bool,
    /// 变更块操作失败时显示在头部下方的一行错误。
    action_error: Option<SharedString>,
    loading: bool,
    error: Option<SharedString>,
    /// 丢弃过期异步结果。
    generation: u64,
    /// 丢弃确认层的键盘焦点；Esc 关闭确认层。
    confirm_focus: FocusHandle,
    /// 关闭请求：由工作台注册，用于回到原编辑器。
    on_close: Option<Rc<dyn Fn(&mut Window, &mut gpui_kit::App)>>,
    /// 变更块写操作成功后的回调：工作台用它刷新 Git 面板。
    on_changed: Option<Rc<dyn Fn(&mut Window, &mut gpui_kit::App)>>,
}

impl CommitDiffView {
    pub fn new(client: CoreClient, cx: &mut Context<Self>) -> Self {
        Self {
            client,
            root: None,
            commit: String::new(),
            path: String::new(),
            compare_base: None,
            working_tree_staged: None,
            rows: Vec::new(),
            hunks: Vec::new(),
            scroll_handle: VirtualListScrollHandle::new(),
            item_sizes: Rc::new(Vec::new()),
            row_hunk_ids: Vec::new(),
            pending_discard_hunk: None,
            busy: false,
            action_error: None,
            loading: false,
            error: None,
            generation: 0,
            confirm_focus: cx.focus_handle(),
            on_close: None,
            on_changed: None,
        }
    }

    /// 注册关闭回调。工作台在构造时接线。
    pub fn on_close(&mut self, handler: impl Fn(&mut Window, &mut gpui_kit::App) + 'static) {
        self.on_close = Some(Rc::new(handler));
    }

    /// 注册变更块写操作成功后的回调（工作台刷新 Git 面板）。
    pub fn on_changed(&mut self, handler: impl Fn(&mut Window, &mut gpui_kit::App) + 'static) {
        self.on_changed = Some(Rc::new(handler));
    }

    /// 切换项目根。
    pub fn set_root(&mut self, root: Option<PathBuf>, cx: &mut Context<Self>) {
        self.root = root;
        self.generation = self.generation.wrapping_add(1);
        self.clear_rows();
        self.pending_discard_hunk = None;
        self.action_error = None;
        self.error = None;
        cx.notify();
    }

    /// 清空行数据、虚拟列表尺寸与滚动位置。
    fn clear_rows(&mut self) {
        self.rows.clear();
        self.hunks.clear();
        self.item_sizes = Rc::new(Vec::new());
        self.row_hunk_ids.clear();
        self.scroll_handle
            .set_offset(gpui_kit::point(px(0.0), px(0.0)));
    }

    /// 装入新的差异行，并为虚拟列表预计算行高与 hunk 首行索引。
    fn set_rows(&mut self, rows: Vec<DiffRow>, hunks: Vec<DiffHunk>) {
        self.rows = rows;
        self.hunks = hunks;
        let mut sizes: Vec<Size<Pixels>> = Vec::with_capacity(self.rows.len());
        let mut row_hunk_ids: Vec<Option<String>> = Vec::with_capacity(self.rows.len());
        let mut previous: Option<&str> = None;
        for row in &self.rows {
            let first = row
                .hunk_id
                .as_deref()
                .filter(|id| previous != Some(*id));
            previous = row.hunk_id.as_deref();
            // 只有 Core 同时返回了 patch 的 hunk 才能渲染操作按钮；与旧实现
            // 一致，缺失 patch 的 hunk 仍按普通行高度处理。
            let hunk_id = first
                .filter(|id| self.hunks.iter().any(|hunk| hunk.id == *id))
                .map(str::to_string);
            let height = if hunk_id.is_some() { 24.0 } else { 20.0 };
            sizes.push(size(px(0.0), px(height)));
            row_hunk_ids.push(hunk_id);
        }
        self.item_sizes = Rc::new(sizes);
        self.row_hunk_ids = row_hunk_ids;
        self.scroll_handle
            .set_offset(gpui_kit::point(px(0.0), px(0.0)));
    }

    /// 清空差异页的全部内容与在途请求，但保留根目录。
    ///
    /// 工作台在关闭差异页（切项目、关项目、打开普通文件）时调用：不能只把
    /// 可见性置 false，否则再次打开同一路径时旧的确认层、错误行和过期读盘
    /// 结果会复活。
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.generation = self.generation.wrapping_add(1);
        self.commit.clear();
        self.path.clear();
        self.compare_base = None;
        self.working_tree_staged = None;
        self.clear_rows();
        self.pending_discard_hunk = None;
        self.busy = false;
        self.loading = false;
        self.action_error = None;
        self.error = None;
        cx.notify();
    }

    /// 展示某个提交里某个文件的差异（对齐 Tauri `getCommitDiff`）。
    pub fn show(&mut self, commit: String, path: String, cx: &mut Context<Self>) {
        if self.commit == commit
            && self.path == path
            && self.working_tree_staged.is_none()
            && self.compare_base.is_none()
            && !self.rows.is_empty()
        {
            cx.notify();
            return;
        }
        self.commit = commit;
        self.path = path;
        self.compare_base = None;
        self.working_tree_staged = None;
        self.reload(cx);
    }

    /// 展示两个引用之间的区间差异（对齐 Tauri `viewBranchDiff`）。
    ///
    /// `path` 为空表示该区间的全部文件，`reload` 会把它折算成 `"."`
    /// pathspec（Core 要求 pathspec 非空）。
    pub fn show_comparison(
        &mut self,
        base: String,
        target: String,
        path: String,
        cx: &mut Context<Self>,
    ) {
        if self.compare_base.as_deref() == Some(base.as_str())
            && self.commit == target
            && self.path == path
            && !self.rows.is_empty()
        {
            cx.notify();
            return;
        }
        self.commit = target;
        self.path = path;
        self.compare_base = Some(base);
        self.working_tree_staged = None;
        self.reload(cx);
    }

    /// 展示工作区（staged / 未暂存）维度的文件差异。
    ///
    /// 对齐 Tauri `viewFileDiff` 的 `working-tree` 差异页（commitHash =
    /// `"working-tree"`）：Core `git.diff` 不带 commit/reference 时按
    /// `staged` 标志返回已暂存或未暂存的工作区差异。
    pub fn show_working_tree(&mut self, staged: bool, path: String, cx: &mut Context<Self>) {
        if self.working_tree_staged == Some(staged)
            && self.path == path
            && self.compare_base.is_none()
            && !self.rows.is_empty()
        {
            cx.notify();
            return;
        }
        self.commit = String::from("working-tree");
        self.path = path;
        self.compare_base = None;
        self.working_tree_staged = Some(staged);
        self.reload(cx);
    }

    /// 当前展示的提交哈希；工作台用它判断是否已是同一页。
    pub fn commit(&self) -> &str {
        &self.commit
    }

    /// 当前展示的文件路径。
    pub fn path(&self) -> &str {
        &self.path
    }

    /// 重新读取当前差异。
    pub fn reload(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root.to_str().map(str::to_string) else {
            return;
        };
        if self.commit.is_empty() && self.working_tree_staged.is_none() {
            return;
        }

        self.generation = self.generation.wrapping_add(1);
        let generation = self.generation;
        self.loading = true;
        self.error = None;
        self.action_error = None;
        self.pending_discard_hunk = None;
        self.clear_rows();
        cx.notify();

        let client = self.client;
        let commit = self.commit.clone();
        let compare_base = self.compare_base.clone();
        let working_tree_staged = self.working_tree_staged;
        let path = self.path.clone();
        cx.spawn(async move |this, cx| {
            // Core 要求 pathspec 非空；空路径 = 整个差异页的所有文件，
            // 用仓库根 "." 表达。
            let pathspec = if path.is_empty() {
                ".".to_string()
            } else {
                path
            };
            let payload = match (working_tree_staged, compare_base) {
                (Some(staged), _) => serde_json::json!({
                    "root": root_text,
                    "staged": staged,
                    "pathspecs": [pathspec],
                }),
                (None, Some(base)) => serde_json::json!({
                    "root": root_text,
                    // Core 的 reference 区间：git diff <base>..<target>。
                    "reference": format!("{base}..{commit}"),
                    "pathspecs": [pathspec],
                }),
                (None, None) => serde_json::json!({
                    "root": root_text,
                    "commit": commit,
                    "pathspecs": [pathspec],
                }),
            };
            let raw = cx
                .background_spawn(async move { execute_git_command(&client, "git.diff", payload) })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.loading = false;
                match raw {
                    Ok(value) => {
                        this.set_rows(
                            parse_diff_rows(&value),
                            parse_diff_hunks(&value),
                        );
                        if this.rows.is_empty() {
                            // 空 rows 通常是二进制文件。
                            this.error = Some(SharedString::from(tr("No textual changes")));
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

    // --- 变更块（hunk）操作 ----------------------------------------------
    //
    // 对齐 macOS `DiffHunkActionsView` / `GitFeatureModel`：
    // - 工作区未暂存差异：Stage + Discard；
    // - 已暂存差异：Unstage；
    // - 提交差异：不提供变更块操作。
    //
    // 三者都只发送 Core `git.apply`，模式交给 Core 选择 `git apply` 参数，
    // 视图不重建补丁。

    /// 暂存一个变更块（Core `git.apply { mode: "stage" }`）。
    fn stage_hunk(&mut self, hunk: DiffHunk, window: &mut Window, cx: &mut Context<Self>) {
        self.apply_hunk(hunk, "stage", tr("Stage failed"), window, cx);
    }

    /// 取消暂存一个变更块（Core `git.apply { mode: "unstage" }`）。
    fn unstage_hunk(&mut self, hunk: DiffHunk, window: &mut Window, cx: &mut Context<Self>) {
        self.apply_hunk(hunk, "unstage", tr("Unstage failed"), window, cx);
    }

    /// 请求丢弃一个变更块：先进入确认态，不立即执行（对齐 macOS
    /// `requestDiscardHunk`）。
    fn request_discard_hunk(
        &mut self,
        hunk: DiffHunk,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.busy || self.loading {
            return;
        }
        self.pending_discard_hunk = Some(hunk);
        // 确认层自己接管键盘：Esc 关闭，按钮点击与焦点都落在这个面板上。
        window.focus(&self.confirm_focus, cx);
        cx.notify();
    }

    /// 取消丢弃（对齐 macOS `cancelDiscardHunk`）。
    fn cancel_discard_hunk(&mut self, cx: &mut Context<Self>) {
        if self.pending_discard_hunk.take().is_some() {
            cx.notify();
        }
    }

    /// 确认丢弃：先清空 pending 再执行（对齐 macOS `confirmDiscardHunk`）。
    fn confirm_discard_hunk(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy || self.loading {
            return;
        }
        let Some(hunk) = self.pending_discard_hunk.take() else {
            cx.notify();
            return;
        };
        self.apply_hunk(hunk, "discard", tr("Discard failed"), window, cx);
    }

    /// 执行变更块写操作：成功后重读当前差异并通知工作台刷新 Git 面板。
    fn apply_hunk(
        &mut self,
        hunk: DiffHunk,
        mode: &'static str,
        failure: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.busy || self.loading {
            return;
        }
        let Some(root_text) = self
            .root
            .as_ref()
            .and_then(|root| root.to_str())
            .map(str::to_string)
        else {
            return;
        };
        if hunk.patch.is_empty() {
            return;
        }

        let client = self.client;
        let generation = self.generation;
        self.busy = true;
        self.action_error = None;
        cx.notify();

        cx.spawn_in(window, async move |this, cx| {
            let patch = hunk.patch;
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(
                        &client,
                        "git.apply",
                        serde_json::json!({
                            "root": root_text,
                            "patch": patch,
                            "mode": mode,
                        }),
                    )
                })
                .await;

            let _ = this.update_in(cx, |this, window, cx| {
                this.busy = false;
                // 写操作已经生效时，即使视图已切到别处，也要让 Git 面板重读；
                // 只有当前仍展示同一份差异时才刷新正文与显示错误。
                let stale = this.generation != generation;
                match raw {
                    Ok(value) => match parse_command(&value) {
                        Ok(command) if command.exit_code == 0 => {
                            if !stale {
                                this.reload(cx);
                            }
                            if let Some(handler) = this.on_changed.clone() {
                                handler(window, cx);
                            }
                        }
                        Ok(command) => {
                            if !stale {
                                this.action_error = Some(SharedString::from(
                                    command_failure_detail(&command, failure),
                                ));
                            }
                        }
                        Err(message) => {
                            if !stale {
                                this.action_error = Some(SharedString::from(message));
                            }
                        }
                    },
                    Err(error) => {
                        if !stale {
                            this.action_error = Some(SharedString::from(error.to_string()));
                        }
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 单个 hunk 首行的操作按钮（对齐 macOS `DiffHunkActionsView`）。
    fn render_hunk_actions(
        &self,
        hunk: &DiffHunk,
        row_index: usize,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let busy = self.busy || self.loading;
        let mut actions = h_flex()
            .flex_shrink_0()
            .items_center()
            .gap(px(2.0))
            .pr(px(6.0));

        match self.working_tree_staged {
            // 工作区未暂存差异：Stage（下箭头入索引）+ Discard（回退箭头）。
            Some(false) => {
                let stage_hunk = hunk.clone();
                actions = actions.child(
                    Button::new(SharedString::from(format!("lithe-hunk-stage-{row_index}")))
                        .ghost()
                        .with_size(px(22.0))
                        .rounded(px(4.0))
                        .icon(
                            Icon::new(gpui_kit::assets::IconName::ArrowDownToLine)
                                .with_size(px(12.0)),
                        )
                        .tooltip(tr("Stage"))
                        .disabled(busy)
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.stage_hunk(stage_hunk.clone(), window, cx);
                        })),
                );
                let discard_hunk = hunk.clone();
                actions = actions.child(
                    Button::new(SharedString::from(format!("lithe-hunk-discard-{row_index}")))
                        .ghost()
                        .with_size(px(22.0))
                        .rounded(px(4.0))
                        .icon(Icon::new(gpui_kit::assets::IconName::Undo2).with_size(px(12.0)))
                        .tooltip(tr("Discard"))
                        .disabled(busy)
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.request_discard_hunk(discard_hunk.clone(), window, cx);
                        })),
                );
            }
            // 已暂存差异：Unstage（上箭头出索引）。
            Some(true) => {
                let unstage_hunk = hunk.clone();
                actions = actions.child(
                    Button::new(SharedString::from(format!("lithe-hunk-unstage-{row_index}")))
                        .ghost()
                        .with_size(px(22.0))
                        .rounded(px(4.0))
                        .icon(
                            Icon::new(gpui_kit::assets::IconName::ArrowUpToLine)
                                .with_size(px(12.0)),
                        )
                        .tooltip(tr("Unstage"))
                        .disabled(busy)
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.unstage_hunk(unstage_hunk.clone(), window, cx);
                        })),
                );
            }
            // 提交差异不提供变更块写操作。
            None => {}
        }

        actions.into_any_element()
    }

    /// 丢弃变更块的确认层：半透明背板 + 居中面板（视觉对齐工作台的关闭确认）。
    fn render_discard_confirm(&self, cx: &mut Context<Self>) -> AnyElement {
        let tokens = current_tokens(cx);
        let path = if self.path.is_empty() {
            self.commit.clone()
        } else {
            self.path.clone()
        };
        div()
            .id("lithe-hunk-discard-confirm")
            .absolute()
            .inset_0()
            .size_full()
            .flex()
            .items_center()
            .justify_center()
            .occlude()
            .child(
                div()
                    .id("lithe-hunk-discard-backdrop")
                    .absolute()
                    .inset_0()
                    .size_full()
                    .occlude()
                    .bg(tokens.window.alpha(0.62))
                    .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                        this.cancel_discard_hunk(cx);
                    })),
            )
            .child(
                v_flex()
                    .id("lithe-hunk-discard-panel")
                    .occlude()
                    .track_focus(&self.confirm_focus)
                    .on_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                        if event.keystroke.key == "escape" && !this.busy {
                            this.cancel_discard_hunk(cx);
                        }
                    }))
                    .w(px(360.0))
                    .rounded(px(LitheMetrics::PANE_RADIUS))
                    .overflow_hidden()
                    .bg(tokens.raised)
                    .border_1()
                    .border_color(tokens.panel_border)
                    .p(px(16.0))
                    .gap(px(10.0))
                    .child(
                        div()
                            .w_full()
                            .text_size(px(LitheMetrics::UI_FONT_SIZE))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.primary_text)
                            .child(tr("Discard changes?")),
                    )
                    .child(
                        div()
                            .w_full()
                            .min_w(px(0.0))
                            .truncate()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(path),
                    )
                    .child(div().flex_1())
                    .child(
                        h_flex()
                            .w_full()
                            .justify_end()
                            .gap(px(8.0))
                            .child(
                                Button::new("lithe-hunk-discard-cancel")
                                    .ghost()
                                    .small()
                                    .label(tr("Cancel"))
                                    .tooltip(tr("Cancel"))
                                    .accessibility_label(tr("Cancel"))
                                    .on_click(cx.listener(|this, _, _window, cx| {
                                        this.cancel_discard_hunk(cx);
                                    })),
                            )
                            .child(
                                Button::new("lithe-hunk-discard-confirm-button")
                                    .danger()
                                    .small()
                                    .label(tr("Discard"))
                                    .tooltip(tr("Discard"))
                                    .accessibility_label(tr("Discard"))
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.confirm_discard_hunk(window, cx);
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }

    fn render_header(&self, cx: &mut Context<Self>) -> AnyElement {
        let tokens = current_tokens(cx);
        let short_commit: String = self.commit.chars().take(8).collect();
        let title = if let Some(staged) = self.working_tree_staged {
            if self.path.is_empty() {
                if staged {
                    tr("Staged Diff").to_string()
                } else {
                    tr("Working Tree Diff").to_string()
                }
            } else if staged {
                format!("{} · {}", self.path, tr("Staged"))
            } else {
                format!("{} · {}", self.path, tr("Working tree"))
            }
        } else if let Some(base) = self.compare_base.as_deref() {
            // 区间比较：标题与 Tauri `viewBranchDiff` 一致，用 base..target。
            let base_short: String = base.chars().take(8).collect();
            let range = format!("{base_short}..{short_commit}");
            if self.path.is_empty() {
                range
            } else {
                format!("{} · {range}", self.path)
            }
        } else if self.path.is_empty() {
            tr("Commit Diff").to_string()
        } else {
            format!("{} · {short_commit}", self.path)
        };

        h_flex()
            .id("lithe-commit-diff-header")
            .w_full()
            .h(px(30.0))
            .flex_shrink_0()
            .items_center()
            .justify_between()
            .gap(px(8.0))
            .px(px(8.0))
            .bg(tokens.tool_header)
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                h_flex()
                    .min_w(px(0.0))
                    .flex_1()
                    .items_center()
                    .gap(px(6.0))
                    .child(
                        Icon::new(gpui_kit::assets::IconName::Code)
                            .with_size(px(13.0))
                            .text_color(tokens.secondary_text),
                    )
                    .child(
                        div()
                            .min_w(px(0.0))
                            .truncate()
                            .text_size(px(12.0))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.primary_text)
                            .child(title),
                    ),
            )
            .child(
                h_flex()
                    .flex_shrink_0()
                    .items_center()
                    .gap(px(4.0))
                    .child(
                        Button::new("lithe-commit-diff-refresh")
                            .ghost()
                            .with_size(px(22.0))
                            .rounded(px(4.0))
                            .icon(
                                Icon::new(gpui_kit::assets::IconName::RotateCw).with_size(px(12.0)),
                            )
                            .tooltip(tr("Refresh"))
                            .on_click(cx.listener(|this, _, _window, cx| this.reload(cx))),
                    )
                    .child(
                        Button::new("lithe-commit-diff-close")
                            .ghost()
                            .with_size(px(22.0))
                            .rounded(px(4.0))
                            .icon(Icon::new(gpui_kit::assets::IconName::X).with_size(px(12.0)))
                            .tooltip(tr("Close"))
                            .on_click(cx.listener(|this, _, window, cx| {
                                if let Some(handler) = this.on_close.clone() {
                                    handler(window, cx);
                                }
                            })),
                    ),
            )
            .into_any_element()
    }

    fn render_body(&self, cx: &mut Context<Self>) -> AnyElement {
        let tokens = current_tokens(cx);

        if self.loading {
            return div()
                .flex_1()
                .p(px(16.0))
                .text_size(px(12.0))
                .text_color(tokens.secondary_text)
                .child(tr("Loading…"))
                .into_any_element();
        }
        if let Some(error) = self.error.clone() {
            return v_flex()
                .flex_1()
                .items_center()
                .justify_center()
                .gap(px(8.0))
                .child(
                    Icon::new(gpui_kit::assets::IconName::FileSearch)
                        .with_size(px(28.0))
                        .text_color(tokens.tertiary_text),
                )
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(tokens.secondary_text)
                        .child(error),
                )
                .into_any_element();
        }

        // 虚拟列表：只构建可视行。此前每帧都为整份 diff 创建全部行元素，
        // 几千行的提交 diff 会明显卡顿；行高在 `set_rows` 里预计算，
        // `v_virtual_list` 按滚动位置只取当前视口附近的行。
        let mut content = v_flex().flex_1().min_w(px(0.0)).min_h(px(0.0));
        if let Some(error) = self.action_error.clone() {
            content = content.child(
                div()
                    .flex_shrink_0()
                    .w_full()
                    .px(px(8.0))
                    .py(px(4.0))
                    .border_b_1()
                    .border_color(tokens.divider)
                    .text_size(px(11.0))
                    .text_color(tokens.error)
                    .child(error),
            );
        }
        let item_sizes = self.item_sizes.clone();
        let handle = self.scroll_handle.clone();
        content = content.child(
            div()
                .relative()
                .flex_1()
                .min_w(px(0.0))
                .min_h(px(0.0))
                .child(
                    v_virtual_list(
                        cx.entity(),
                        "lithe-commit-diff-lines",
                        item_sizes,
                        move |this, range, _window, cx| {
                            range
                                .map(|index| this.render_row(index, cx))
                                .collect::<Vec<_>>()
                        },
                    )
                    .track_scroll(&handle)
                    .size_full(),
                )
                .child(crate::console::console_scrollbar(
                    &self.scroll_handle,
                    "lithe-commit-diff-scrollbar",
                )),
        );
        content.into_any_element()
    }

    /// 渲染虚拟列表中的一行（行高由 `set_rows` 预计算）。
    fn render_row(&self, index: usize, cx: &mut Context<Self>) -> AnyElement {
        let tokens = current_tokens(cx);
        let Some(row) = self.rows.get(index) else {
            return div().into_any_element();
        };
        let hunk = self
            .row_hunk_ids
            .get(index)
            .and_then(|id| id.as_deref())
            .and_then(|id| self.hunks.iter().find(|hunk| hunk.id == id));
        let is_hunk_header = hunk.is_some();
        let line_height = self
            .item_sizes
            .get(index)
            .map(|size| size.height.as_f32())
            .unwrap_or(20.0);

        // 行底色按语义分档：新增 / 删除用主题的 diff 色，hunk 头用
        // 修改色，"changed"（整行替换）用修改色的淡底，其余保持透明。
        let background = if row.is_addition() {
            Some(tokens.diff_inserted)
        } else if row.is_removal() {
            Some(tokens.diff_deleted)
        } else if is_hunk_header {
            Some(tokens.diff_modified)
        } else if row.kind == "changed" {
            Some(tokens.diff_modified.alpha(0.45))
        } else {
            None
        };
        // 行首的 2px 竖条：新增 / 删除的强提示，其余行用透明占位保持
        // 文本列与行号列对齐。
        let rail = if row.is_addition() {
            tokens.success
        } else if row.is_removal() {
            tokens.error
        } else if is_hunk_header {
            tokens.link
        } else {
            tokens.divider.alpha(0.0)
        };
        let text = row.text();
        let old_number = row
            .old_line
            .map(|value| value.to_string())
            .unwrap_or_default();
        let new_number = row
            .new_line
            .map(|value| value.to_string())
            .unwrap_or_default();
        let sign = if row.is_addition() {
            "+"
        } else if row.is_removal() {
            "-"
        } else {
            ""
        };
        let gutter_text = if row.is_information() {
            tokens.tertiary_text
        } else {
            tokens.secondary_text
        };
        let number_color = if row.is_addition() || row.is_removal() {
            gutter_text
        } else {
            tokens.tertiary_text
        };

        let mut line = h_flex()
            // 虚拟列表按视口宽度布局；长行在可视区内裁剪，避免为整份
            // diff 计算横向宽度而重新引入全量测量。
            .w_full()
            .h(px(line_height))
            .flex_shrink_0()
            .items_center()
            .font_family(MONO_FONT_FAMILY)
            .text_size(px(12.0))
            .line_height(px(line_height));
        if let Some(background) = background {
            line = line.bg(background);
        }
        line = line
            // 左侧强调竖条。
            .child(div().w(px(2.0)).h_full().flex_shrink_0().bg(rail))
            // 旧行号（右对齐，等宽）。
            .child(
                div()
                    .w(px(52.0))
                    .h_full()
                    .flex_shrink_0()
                    .flex()
                    .items_center()
                    .justify_end()
                    .pr(px(8.0))
                    .text_color(number_color)
                    .child(old_number),
            )
            // 新行号（右对齐，等宽）。
            .child(
                div()
                    .w(px(52.0))
                    .h_full()
                    .flex_shrink_0()
                    .flex()
                    .items_center()
                    .justify_end()
                    .pr(px(8.0))
                    .border_r_1()
                    .border_color(tokens.divider)
                    .text_color(number_color)
                    .child(new_number),
            )
            // +/- 符号列：固定宽度，保证正文左缘在每一行对齐。
            .child(
                div()
                    .w(px(18.0))
                    .h_full()
                    .flex_shrink_0()
                    .flex()
                    .items_center()
                    .justify_center()
                    .font_weight(FontWeight::BOLD)
                    .text_color(if row.is_addition() {
                        tokens.success
                    } else if row.is_removal() {
                        tokens.error
                    } else {
                        tokens.tertiary_text
                    })
                    .child(sign),
            )
            .child(
                div()
                    .min_w(px(0.0))
                    .pr(px(8.0))
                    .whitespace_nowrap()
                    .text_color(if row.is_information() && !is_hunk_header {
                        tokens.tertiary_text
                    } else if is_hunk_header {
                        tokens.secondary_text
                    } else {
                        tokens.primary_text
                    })
                    .child(text),
            );
        if let Some(hunk) = hunk {
            // 文本在前、按钮贴右：用弹性占位把按钮推到行尾。
            line = line
                .child(div().flex_1())
                .child(self.render_hunk_actions(hunk, index, cx));
        }
        line.into_any_element()
    }
}

impl Render for CommitDiffView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let tokens = current_tokens(cx);
        let header = self.render_header(cx);
        let body = self.render_body(cx);
        // 丢弃确认层覆盖整个差异页；它属于本视图，不占用工作台的覆盖层。
        let confirm = self
            .pending_discard_hunk
            .as_ref()
            .map(|_| self.render_discard_confirm(cx));
        let _ = LitheMetrics::PANE_RADIUS;

        v_flex()
            .id("lithe-commit-diff-view")
            .relative()
            .size_full()
            .min_w(px(0.0))
            .min_h(px(0.0))
            .bg(tokens.editor)
            .child(header)
            .child(body)
            .children(confirm)
    }
}
