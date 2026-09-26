//! Git 面板：变更列表 + diff 视图。
//!
//! 分工（与"部分引入上游引擎"的方案一致）：
//! - **数据**全部来自共享 core 的 `git.*`（`git.status` / `git.diff`），与 macOS/Windows
//!   同一契约；
//! - **diff 呈现**复用 vendored `rgitui` 的 `DiffViewer`，本文件只负责把 core 的结构化
//!   行/块适配成 `rgitui_git::FileDiff` 并驱动视图，不自己写 diff 渲染。
//!
//! Note: 引擎引入边界与适配原因见
//! `.agents/notes/implemented/architecture/2026-09-26-linux-rgitui-diff-engine-reuse.md`。

use std::path::PathBuf;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, AppContext as _, Context, Entity, EventEmitter, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, StatefulInteractiveElement as _, Styled as _,
};
use rgitui_diff::{DiffSource, DiffViewer};
use rgitui_git::{DiffHunk, DiffLine, FileChangeKind, FileDiff};

use crate::core::CoreClient;
use crate::theme::ThemeColors;

/// 面板事件：宿主据此关闭面板。
pub enum GitPanelEvent {
    Close,
}

/// 一条工作区变更（来自 `git.status`）。
#[derive(Clone)]
struct GitPanelChange {
    path: String,
    status: String,
    staged: bool,
}

pub struct GitPanelView {
    changes: Vec<GitPanelChange>,
    /// 当前展示的文件路径（相对仓库根）。
    selected: Option<String>,
    /// 选中的文件是否来自暂存区。
    selected_staged: bool,
    /// diff 视图（上游引擎）。
    diff: Entity<DiffViewer>,
    /// 仓库根；由宿主在打开面板时设置。
    root: String,
    /// 变更列表代号：状态刷新后丢弃过期结果。
    status_seq: u64,
    /// diff 代号：切换文件后丢弃过期结果。
    diff_seq: u64,
    loading: bool,
    error: Option<String>,
    client: CoreClient,
}

impl GitPanelView {
    pub fn new(cx: &mut Context<Self>) -> Self {
        Self {
            changes: Vec::new(),
            selected: None,
            selected_staged: false,
            diff: cx.new(DiffViewer::new),
            root: String::new(),
            status_seq: 0,
            diff_seq: 0,
            loading: false,
            error: None,
            client: CoreClient::new(),
        }
    }

    /// 打开面板：设置仓库根、刷新变更列表，并尽量展示第一个文件。
    pub fn open(
        &mut self,
        root: String,
        path: Option<String>,
        staged: bool,
        cx: &mut Context<Self>,
    ) {
        let root_changed = root != self.root;
        self.root = root;
        if root_changed {
            self.selected = None;
        }
        self.refresh_status(cx);
        match path {
            Some(path) => self.show_file(path, staged, cx),
            None => {
                if let Some(first) = self.changes.first().cloned() {
                    self.show_file(first.path, first.staged, cx);
                }
            }
        }
        cx.notify();
    }

    /// 刷新变更列表（`git.status`）。
    pub fn refresh_status(&mut self, cx: &mut Context<Self>) {
        if self.root.trim().is_empty() {
            return;
        }
        self.status_seq += 1;
        let seq = self.status_seq;
        let client = self.client.clone();
        let root = self.root.clone();
        cx.spawn(async move |this, cx| {
            let result = client.git_status(&cx, &root).await;
            let _ = this.update(cx, |panel, cx| {
                if panel.status_seq != seq {
                    return;
                }
                panel.loading = false;
                match result {
                    Ok(value) => {
                        let mut changes = Vec::new();
                        if let Some(array) = value.get("changes").and_then(|v| v.as_array()) {
                            for item in array {
                                let path = item
                                    .get("path")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or_default()
                                    .to_string();
                                if path.is_empty() {
                                    continue;
                                }
                                changes.push(GitPanelChange {
                                    path,
                                    status: item
                                        .get("status")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or("M")
                                        .to_string(),
                                    staged: item
                                        .get("staged")
                                        .and_then(|v| v.as_bool())
                                        .unwrap_or(false),
                                });
                            }
                        }
                        panel.changes = changes;
                        panel.error = None;
                    }
                    Err(error) => panel.error = Some(error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 展示某个文件的 diff（`git.diff` → 上游 `FileDiff` → `DiffViewer`）。
    pub fn show_file(&mut self, path: String, staged: bool, cx: &mut Context<Self>) {
        self.selected = Some(path.clone());
        self.selected_staged = staged;
        self.diff_seq += 1;
        let seq = self.diff_seq;
        let client = self.client.clone();
        let root = self.root.clone();
        let diff = self.diff.clone();
        // 变更类型取自最近一次 git.status，缺失时按 Modified 处理。
        let kind = self
            .changes
            .iter()
            .find(|change| change.path == path)
            .map(|change| file_change_kind(&change.status))
            .unwrap_or(FileChangeKind::Modified);
        let display_path = path.clone();
        cx.spawn(async move |this, cx| {
            let result = client
                .execute::<serde_json::Value, serde_json::Value>(
                    &cx,
                    "git.diff",
                    serde_json::json!({
                        "root": root,
                        "pathspecs": [path],
                        "staged": staged,
                    }),
                )
                .await;
            let _ = this.update(cx, |panel, cx| {
                if panel.diff_seq != seq {
                    return;
                }
                match result {
                    Ok(value) => {
                        let file_diff = adapt_file_diff(&display_path, kind, &value);
                        let source = if staged {
                            DiffSource::Index
                        } else {
                            DiffSource::Worktree
                        };
                        diff.update(cx, |view, cx| {
                            view.set_diff(file_diff, display_path, source, cx);
                        });
                        panel.error = None;
                    }
                    Err(error) => panel.error = Some(error),
                }
                cx.notify();
            });
        })
        .detach();
    }
}

impl EventEmitter<GitPanelEvent> for GitPanelView {}

impl Render for GitPanelView {
    fn render(
        &mut self,
        _window: &mut gpui_kit::Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let rows: Vec<gpui_kit::AnyElement> = self
            .changes
            .iter()
            .map(|change| {
                let selected = self.selected.as_deref() == Some(change.path.as_str())
                    && self.selected_staged == change.staged;
                let path = change.path.clone();
                let staged = change.staged;
                let status_color = match change.status.as_str() {
                    "A" | "??" => ThemeColors::accent_green(),
                    "D" => ThemeColors::accent_red(),
                    "R" | "C" => ThemeColors::accent_blue(),
                    _ => ThemeColors::accent_yellow(),
                };
                h_flex()
                    .id(format!("git-panel-{}-{}", change.path, change.staged))
                    .h(px(24.0))
                    .w_full()
                    .items_center()
                    .justify_between()
                    .gap_2()
                    .px_2()
                    .rounded_sm()
                    .cursor_pointer()
                    .text_xs()
                    .when(selected, |row| row.bg(ThemeColors::bg_tab_hover()))
                    .hover(|row| row.bg(ThemeColors::bg_tab_hover()))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_color(ThemeColors::text_primary())
                            .child(change.path.clone()),
                    )
                    .child(
                        div()
                            .flex_shrink_0()
                            .font_weight(gpui_kit::FontWeight::BOLD)
                            .text_color(status_color)
                            .child(change.status.clone()),
                    )
                    .on_click(cx.listener(move |this, _event, _window, cx| {
                        this.show_file(path.clone(), staged, cx);
                    }))
                    .into_any_element()
            })
            .collect();

        let body: gpui_kit::AnyElement = if self.selected.is_none() {
            v_flex()
                .flex_1()
                .items_center()
                .justify_center()
                .text_sm()
                .text_color(ThemeColors::text_muted())
                .child(crate::i18n::menu_text(cx, "git.panel.selectFile"))
                .into_any_element()
        } else {
            div()
                .flex_1()
                .min_h_0()
                .child(self.diff.clone())
                .into_any_element()
        };

        v_flex()
            .size_full()
            .bg(ThemeColors::background())
            .child(
                h_flex()
                    .flex_shrink_0()
                    .w_full()
                    .items_center()
                    .justify_between()
                    .px_3()
                    .py_2()
                    .border_b_1()
                    .border_color(ThemeColors::border())
                    .child(
                        h_flex()
                            .items_center()
                            .gap_2()
                            .child(Icon::new(gpui_kit::assets::IconName::GitBranch).size(px(14.0)))
                            .child(
                                div()
                                    .text_sm()
                                    .text_color(ThemeColors::text_primary())
                                    .child(crate::i18n::menu_text(cx, "workbench.changes")),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::text_muted())
                                    .child(self.changes.len().to_string()),
                            ),
                    )
                    .child(
                        Button::new("git-panel-close")
                            .small()
                            .ghost()
                            .icon(gpui_kit::assets::IconName::X)
                            .on_click(cx.listener(|this, _event, _window, cx| {
                                this.selected = None;
                                cx.emit(GitPanelEvent::Close);
                                cx.notify();
                            })),
                    ),
            )
            .child(
                h_flex()
                    .flex_1()
                    .w_full()
                    .min_h_0()
                    .child(
                        div()
                            .flex_shrink_0()
                            .w(px(240.0))
                            .h_full()
                            .overflow_y_scrollbar()
                            .border_r_1()
                            .border_color(ThemeColors::border())
                            .py_1()
                            .children(rows),
                    )
                    .child(body),
            )
            .into_any_element()
    }
}

/// Core 的状态码 → 引擎的变更类型。
fn file_change_kind(status: &str) -> FileChangeKind {
    match status {
        "A" => FileChangeKind::Added,
        "D" => FileChangeKind::Deleted,
        "R" => FileChangeKind::Renamed,
        "C" => FileChangeKind::Copied,
        "T" => FileChangeKind::TypeChange,
        "U" | "UU" | "AA" | "DD" => FileChangeKind::Conflicted,
        "??" | "?" => FileChangeKind::Untracked,
        _ => FileChangeKind::Modified,
    }
}

/// 解析 `@@ -old,count +new,count @@` 的起始行；失败时回退 0。
fn parse_hunk_header(header: &str) -> Option<(u32, u32)> {
    let mut columns = header.split_whitespace();
    if columns.next()? != "@@" {
        return None;
    }
    let old_start = columns
        .next()?
        .strip_prefix('-')?
        .split(',')
        .next()?
        .parse()
        .ok()?;
    let new_start = columns
        .next()?
        .strip_prefix('+')?
        .split(',')
        .next()?
        .parse()
        .ok()?;
    Some((old_start, new_start))
}

/// 把 `git.diff` 的结构化行/块适配成上游引擎的 [`FileDiff`]。
///
/// Core 的 `rows` 按 `hunkID` 归属到 `hunks`；`changed` 行同时带左右两侧，引擎模型
/// 只有增/删，因此拆成一条删除（左）加一条新增（右）。
fn adapt_file_diff(path: &str, kind: FileChangeKind, value: &serde_json::Value) -> FileDiff {
    let rows = value
        .get("rows")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let hunks = value
        .get("hunks")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    let mut out_hunks = Vec::new();
    let mut additions = 0usize;
    let mut deletions = 0usize;

    for hunk in &hunks {
        let id = hunk.get("id").and_then(|v| v.as_str()).unwrap_or_default();
        let header = hunk
            .get("header")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        let (old_start, new_start) = parse_hunk_header(&header).unwrap_or((0, 0));
        let mut lines = Vec::new();
        let mut old_lines = 0u32;
        let mut new_lines = 0u32;
        for row in &rows {
            if row
                .get("hunkID")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                != id
            {
                continue;
            }
            let left = row.get("left").and_then(|v| v.as_str()).unwrap_or_default();
            let right = row.get("right").and_then(|v| v.as_str());
            match row
                .get("kind")
                .and_then(|v| v.as_str())
                .unwrap_or("context")
            {
                "addition" => {
                    lines.push(DiffLine::Addition(right.unwrap_or(left).to_string()));
                    additions += 1;
                    new_lines += 1;
                }
                "removal" => {
                    lines.push(DiffLine::Deletion(left.to_string()));
                    deletions += 1;
                    old_lines += 1;
                }
                "changed" => {
                    lines.push(DiffLine::Deletion(left.to_string()));
                    lines.push(DiffLine::Addition(right.unwrap_or_default().to_string()));
                    deletions += 1;
                    additions += 1;
                    old_lines += 1;
                    new_lines += 1;
                }
                // 文件头等信息行不参与逐行渲染。
                "information" => {}
                _ => {
                    lines.push(DiffLine::Context(left.to_string()));
                    old_lines += 1;
                    new_lines += 1;
                }
            }
        }
        out_hunks.push(DiffHunk {
            old_start,
            old_lines,
            new_start,
            new_lines,
            header,
            lines,
        });
    }

    FileDiff {
        path: PathBuf::from(path),
        hunks: out_hunks,
        additions,
        deletions,
        kind,
    }
}
