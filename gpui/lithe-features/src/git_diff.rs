//! 提交差异预览视图。
//!
//! 对齐 Tauri 的提交差异：点 Git Log 里的改动文件时，差异显示在**中央编辑区**
//! （Tauri 是打开一个 diff 编辑器页），而不是挤在 Log 右栏里。Log 右栏只保留
//! 改动文件树与提交说明。
//!
//! 数据来自 Core `git.diff { root, commit, pathspecs }`，返回 `rows` 已按
//! 渲染语义分好类（context / changed / insertion / deletion / information），
//! 这里只负责画出来。

use std::path::PathBuf;
use std::rc::Rc;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Icon, Sizable as _, h_flex, v_flex};
use gpui_kit::{
    AnyElement, AppContext as _, Context, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, SharedString, StatefulInteractiveElement as _, Styled as _, Window,
    div, px,
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
    rows: Vec<DiffRow>,
    loading: bool,
    error: Option<SharedString>,
    /// 丢弃过期异步结果。
    generation: u64,
    /// 关闭请求：由工作台注册，用于回到原编辑器。
    on_close: Option<Rc<dyn Fn(&mut Window, &mut gpui_kit::App)>>,
}

impl CommitDiffView {
    pub fn new(client: CoreClient, cx: &mut Context<Self>) -> Self {
        let _ = cx;
        Self {
            client,
            root: None,
            commit: String::new(),
            path: String::new(),
            rows: Vec::new(),
            loading: false,
            error: None,
            generation: 0,
            on_close: None,
        }
    }

    /// 注册关闭回调。工作台在构造时接线。
    pub fn on_close(&mut self, handler: impl Fn(&mut Window, &mut gpui_kit::App) + 'static) {
        self.on_close = Some(Rc::new(handler));
    }

    /// 切换项目根。
    pub fn set_root(&mut self, root: Option<PathBuf>, cx: &mut Context<Self>) {
        self.root = root;
        self.generation = self.generation.wrapping_add(1);
        self.rows.clear();
        self.error = None;
        cx.notify();
    }

    /// 展示某个提交里某个文件的差异（对齐 Tauri `getCommitDiff`）。
    pub fn show(&mut self, commit: String, path: String, cx: &mut Context<Self>) {
        if self.commit == commit && self.path == path && !self.rows.is_empty() {
            cx.notify();
            return;
        }
        self.commit = commit;
        self.path = path;
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
        if self.commit.is_empty() {
            return;
        }

        self.generation = self.generation.wrapping_add(1);
        let generation = self.generation;
        self.loading = true;
        self.error = None;
        self.rows.clear();
        cx.notify();

        let client = self.client;
        let commit = self.commit.clone();
        let path = self.path.clone();
        cx.spawn(async move |this, cx| {
            let payload = serde_json::json!({
                "root": root_text,
                "commit": commit,
                "pathspecs": [path],
            });
            let raw = cx
                .background_spawn(async move { client.execute_raw("git.diff", payload) })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.loading = false;
                match raw {
                    Ok(value) => {
                        this.rows = parse_diff_rows(&value);
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

    fn render_header(&self, cx: &mut Context<Self>) -> AnyElement {
        let tokens = current_tokens(cx);
        let short_commit: String = self.commit.chars().take(8).collect();
        let title = if self.path.is_empty() {
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

        for row in &self.rows {
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
                .h(px(18.0))
                .flex_shrink_0()
                .items_center()
                .font_family(MONO_FONT_FAMILY)
                .text_size(px(12.0));
            if let Some(background) = background {
                line = line.bg(background);
            }
            body = body.child(
                line.child(
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
                ),
            );
        }

        body.into_any_element()
    }
}

impl Render for CommitDiffView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let tokens = current_tokens(cx);
        let header = self.render_header(cx);
        let body = self.render_body(cx);
        let _ = LitheMetrics::PANE_RADIUS;

        v_flex()
            .id("lithe-commit-diff-view")
            .size_full()
            .min_w(px(0.0))
            .min_h(px(0.0))
            .bg(tokens.editor)
            .child(header)
            .child(body)
    }
}
