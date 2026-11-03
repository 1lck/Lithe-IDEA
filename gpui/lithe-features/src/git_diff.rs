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
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, h_flex, v_flex};
use gpui_kit::{
    AnyElement, AppContext as _, ClickEvent, Context, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, Render, SharedString, StatefulInteractiveElement as _,
    Styled as _, Window, div, px,
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
    pub header: String,
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
                        header: item
                            .get("header")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
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
    /// 工作区差异来源；`Some(staged)` 时请求 `git.diff { staged }` 而不是
    /// `git.show <commit>`（Core `GitDiffRequest` 的 staged / 默认工作区模式）。
    working_tree_staged: Option<bool>,
    rows: Vec<DiffRow>,
    /// Core 返回的可独立应用的变更块；`id` 与 `DiffRow::hunk_id` 关联。
    hunks: Vec<DiffHunk>,
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
    /// 关闭请求：由工作台注册，用于回到原编辑器。
    on_close: Option<Rc<dyn Fn(&mut Window, &mut gpui_kit::App)>>,
    /// 变更块写操作成功后的回调：工作台用它刷新 Git 面板。
    on_changed: Option<Rc<dyn Fn(&mut Window, &mut gpui_kit::App)>>,
}

impl CommitDiffView {
    pub fn new(client: CoreClient, cx: &mut Context<Self>) -> Self {
        let _ = cx;
        Self {
            client,
            root: None,
            commit: String::new(),
            path: String::new(),
            working_tree_staged: None,
            rows: Vec::new(),
            hunks: Vec::new(),
            pending_discard_hunk: None,
            busy: false,
            action_error: None,
            loading: false,
            error: None,
            generation: 0,
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
        self.rows.clear();
        self.hunks.clear();
        self.pending_discard_hunk = None;
        self.action_error = None;
        self.error = None;
        cx.notify();
    }

    /// 展示某个提交里某个文件的差异（对齐 Tauri `getCommitDiff`）。
    pub fn show(&mut self, commit: String, path: String, cx: &mut Context<Self>) {
        if self.commit == commit
            && self.path == path
            && self.working_tree_staged.is_none()
            && !self.rows.is_empty()
        {
            cx.notify();
            return;
        }
        self.commit = commit;
        self.path = path;
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
            && !self.rows.is_empty()
        {
            cx.notify();
            return;
        }
        self.commit = String::from("working-tree");
        self.path = path;
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
        self.rows.clear();
        self.hunks.clear();
        cx.notify();

        let client = self.client;
        let commit = self.commit.clone();
        let working_tree_staged = self.working_tree_staged;
        let path = self.path.clone();
        cx.spawn(async move |this, cx| {
            let payload = match working_tree_staged {
                Some(staged) => serde_json::json!({
                    "root": root_text,
                    "staged": staged,
                    "pathspecs": [path],
                }),
                None => serde_json::json!({
                    "root": root_text,
                    "commit": commit,
                    "pathspecs": [path],
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
                        this.rows = parse_diff_rows(&value);
                        this.hunks = parse_diff_hunks(&value);
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
    fn request_discard_hunk(&mut self, hunk: DiffHunk, cx: &mut Context<Self>) {
        if self.busy || self.loading {
            return;
        }
        self.pending_discard_hunk = Some(hunk);
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
                        .on_click(cx.listener(move |this, _, _window, cx| {
                            this.request_discard_hunk(discard_hunk.clone(), cx);
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
                                Button::new("lithe-hunk-discard-confirm")
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

        let mut body = v_flex()
            .id("lithe-commit-diff-body")
            .flex_1()
            .min_h(px(0.0))
            .overflow_y_scroll()
            .py(px(4.0))
            .bg(tokens.editor);

        // 每个 hunk 的第一行挂上该 hunk 的写操作按钮。Core 为每个 hunk 的
        // `@@` 表头行也带 `hunkId`，因此按钮落在 hunk 头这一行，与 macOS
        // 在 hunk 首行渲染 `DiffHunkActionsView` 的位置一致。
        let mut previous_hunk_id: Option<&str> = None;
        for (index, row) in self.rows.iter().enumerate() {
            let hunk = row
                .hunk_id
                .as_deref()
                .filter(|id| previous_hunk_id != Some(*id))
                .and_then(|id| self.hunks.iter().find(|hunk| hunk.id == id));
            previous_hunk_id = row.hunk_id.as_deref();

            let background = if row.is_addition() {
                Some(tokens.diff_inserted)
            } else if row.is_removal() {
                Some(tokens.diff_deleted)
            } else {
                None
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
                " "
            };

            let mut line = h_flex()
                .w_full()
                // hunk 首行要放 22px 图标按钮，行高稍抬高，其余行保持原高度。
                .h(px(if hunk.is_some() { 22.0 } else { 18.0 }))
                .flex_shrink_0()
                .items_center()
                .font_family(MONO_FONT_FAMILY)
                .text_size(px(12.0));
            if let Some(background) = background {
                line = line.bg(background);
            }
            line = line
                .child(
                    div()
                        .w(px(44.0))
                        .px(px(6.0))
                        .text_color(tokens.tertiary_text)
                        .child(old_number),
                )
                .child(
                    div()
                        .w(px(44.0))
                        .px(px(6.0))
                        .text_color(tokens.tertiary_text)
                        .child(new_number),
                )
                .child(
                    div()
                        .w(px(12.0))
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
                        .whitespace_nowrap()
                        .text_color(if row.is_information() {
                            tokens.tertiary_text
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
            body = body.child(line);
        }

        // 变更块操作失败的一行提示放在滚动态上方，不遮住差异正文。
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
        content = content.child(body);
        content.into_any_element()
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
