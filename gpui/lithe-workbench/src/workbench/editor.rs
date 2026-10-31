use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Icon, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, AppContext as _, Context, InteractiveElement as _, IntoElement, ParentElement as _,
    RenderOnce as _, SharedString, Styled as _, Task, Window, div, px,
};
use lithe_features::EditorSurface;
use lithe_features::editor::EditorEvent;
use lithe_ui::components::editor_tabs::{EditorTabItem, EditorTabs};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens, current_tokens};

use crate::layout::MARKDOWN_TOOLBAR_HEIGHT;

use super::Workbench;
use super::tabs::is_markdown_path;

impl Workbench {
    pub(super) fn render_editor_area(
        &self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tokens = current_tokens(cx);

        let has_secondary = self.editor_secondary.is_some();
        let mut area = v_flex()
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .bg(tokens.editor);

        if !has_secondary {
            area = area
                .rounded(px(LitheMetrics::PANE_RADIUS))
                .overflow_hidden()
                .border_1()
                .border_color(tokens.panel_border);
        }

        if !self.tabs.is_empty() {
            let items: Vec<EditorTabItem> = self
                .tabs
                .iter()
                .map(|tab| {
                    let mut item = EditorTabItem::new(tab.id.clone(), tab.title.clone());
                    item.icon = Some(tab.icon);
                    item.modified = tab.modified;
                    item
                })
                .collect();

            let select = cx.processor(|this, id: SharedString, window, cx| {
                this.select_tab(id.as_ref(), window, cx)
            });
            let close = cx.processor(|this, id: SharedString, window, cx| {
                this.close_tab(id.as_ref(), window, cx)
            });

            area = area.child(
                EditorTabs::new("lithe-editor-tabs")
                    .tabs(items)
                    .active(self.active_tab.clone().unwrap_or_default())
                    .on_select(select)
                    .on_close(close)
                    .render(window, cx),
            );
        }

        if self.active_is_markdown() {
            area = area.child(self.render_markdown_toolbar(cx));
        }

        let content = if self.commit_diff_visible {
            // 提交差异是中央编辑区的一页（对齐 Tauri 的 diff 编辑器页），
            // 优先于普通文件内容显示。
            self.commit_diff.clone().into_any_element()
        } else if self.project_root.is_none() && self.tabs.is_empty() {
            self.welcome.clone().into_any_element()
        } else if self.tabs.is_empty() {
            render_empty_editor(tokens)
        } else if self.preview_visible && self.active_is_markdown() {
            self.preview.clone().into_any_element()
        } else {
            self.editor.clone().into_any_element()
        };

        let primary = area
            .child(div().flex_1().min_h(px(0.)).min_w(px(0.)).child(content))
            .into_any_element();

        let Some(secondary) = self.editor_secondary.clone() else {
            return primary;
        };

        let split_owner = cx.weak_entity();
        let file_name = self
            .current_tab()
            .map(|tab| tab.title.clone())
            .unwrap_or_default();
        let header = h_flex()
            .id("lithe-editor-split-header")
            .flex_shrink_0()
            .h(px(24.))
            .w_full()
            .items_center()
            .justify_between()
            .px(px(8.))
            .bg(tokens.tool_header)
            .border_b(px(1.))
            .border_color(tokens.divider)
            .child(
                div()
                    .truncate()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(format!("{file_name} ({})", tr("Read-Only Split"))),
            )
            .child(
                Button::new("lithe-editor-split-close")
                    .ghost()
                    .with_size(px(20.))
                    .rounded(px(4.))
                    .icon(Icon::new(IconName::X).with_size(px(12.)))
                    .tooltip(tr("Close Split"))
                    .accessibility_label(tr("Close Split"))
                    .on_click(move |_, _window, cx| {
                        let _ = split_owner.update(cx, |this, cx| this.close_editor_split(cx));
                    }),
            );

        h_flex()
            .size_full()
            .min_w(px(0.))
            .min_h(px(0.))
            .rounded(px(LitheMetrics::PANE_RADIUS))
            .overflow_hidden()
            .border_1()
            .border_color(tokens.panel_border)
            .child(div().flex_1().min_w(px(0.)).min_h(px(0.)).child(primary))
            .child(div().flex_shrink_0().w(px(1.)).bg(tokens.divider))
            .child(
                v_flex()
                    .flex_1()
                    .min_w(px(0.))
                    .min_h(px(0.))
                    .bg(tokens.editor)
                    .child(header)
                    .child(div().flex_1().min_h(px(0.)).min_w(px(0.)).child(secondary)),
            )
            .into_any_element()
    }

    /// 在中央编辑区打开某个提交里某个文件的差异。
    ///
    /// 对齐 Tauri `openCommitDiff`：差异是编辑区的一页，而不是 Log 右栏内容。
    pub(super) fn open_commit_diff(
        &mut self,
        commit: String,
        path: String,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let root = self.project_root.clone();
        let diff = self.commit_diff.clone();
        diff.update(cx, |view, diff_cx| {
            view.set_root(root, diff_cx);
            view.show(commit, path, diff_cx);
        });
        self.commit_diff_visible = true;
        cx.notify();
    }

    /// 关闭差异页，回到普通编辑器内容。
    pub(super) fn close_commit_diff(&mut self, cx: &mut Context<Self>) {
        if self.commit_diff_visible {
            self.commit_diff_visible = false;
            cx.notify();
        }
    }

    pub(super) fn render_markdown_toolbar(&self, cx: &mut Context<Self>) -> AnyElement {
        let tokens = current_tokens(cx);
        let preview_visible = self.preview_visible;
        let owner = cx.weak_entity();

        h_flex()
            .id("lithe-markdown-toolbar")
            .flex_shrink_0()
            .h(MARKDOWN_TOOLBAR_HEIGHT)
            .w_full()
            .items_center()
            .justify_between()
            .px(px(8.))
            .bg(tokens.tool_header)
            .border_b(px(1.))
            .border_color(tokens.divider)
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr("Markdown")),
            )
            .child(
                h_flex()
                    .items_center()
                    .gap(px(4.))
                    .child(
                        Button::new("lithe-markdown-edit")
                            .ghost()
                            .small()
                            .rounded(px(4.))
                            .label(tr("Editor"))
                            .when(!preview_visible, |this| this.bg(tokens.selection))
                            .on_click({
                                let owner = owner.clone();
                                move |_, _window, cx| {
                                    let _ = owner.update(cx, |this, cx| {
                                        this.preview_visible = false;
                                        cx.notify();
                                    });
                                }
                            }),
                    )
                    .child(
                        Button::new("lithe-markdown-preview")
                            .ghost()
                            .small()
                            .rounded(px(4.))
                            .label(tr("Preview"))
                            .when(preview_visible, |this| this.bg(tokens.selection))
                            .on_click(move |_, _window, cx| {
                                let _ = owner.update(cx, |this, cx| {
                                    this.preview_visible = true;
                                    this.sync_preview_with_active_tab(cx);
                                    cx.notify();
                                });
                            }),
                    ),
            )
            .into_any_element()
    }

    pub(super) fn active_is_markdown(&self) -> bool {
        self.active_tab_path()
            .as_deref()
            .is_some_and(is_markdown_path)
    }

    pub(super) fn sync_preview_with_active_tab(&mut self, cx: &mut Context<Self>) {
        let Some(path) = self.active_tab_path() else {
            self.hide_preview();
            return;
        };
        if !is_markdown_path(&path) {
            self.hide_preview();
            return;
        }
        if !self.preview_visible {
            return;
        }

        let preview = self.preview.clone();
        let target_path = path.clone();
        self.preview_generation = self.preview_generation.wrapping_add(1);
        let generation = self.preview_generation;

        self._preview_task = cx.spawn(async move |this, cx| {
            let text = cx
                .background_spawn(async move {
                    std::fs::read_to_string(&target_path).unwrap_or_default()
                })
                .await;

            let _ = this.update(cx, move |this, cx| {
                if this.preview_generation != generation {
                    return;
                }
                preview.update(cx, |preview, preview_cx| {
                    preview.set_text(text, preview_cx);
                });
            });
        });
    }

    pub(super) fn hide_preview(&mut self) {
        self.preview_visible = false;
        self.preview_generation = self.preview_generation.wrapping_add(1);
        self._preview_task = Task::ready(());
    }

    pub(super) fn split_editor_right(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.editor_secondary.is_none() {
            let secondary = cx.new(|editor_cx| EditorSurface::new(window, editor_cx));
            self.editor_secondary = Some(secondary);
        }
        self.sync_editor_secondary(window, cx);
        cx.notify();
    }

    pub(super) fn toggle_editor_split(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.editor_secondary.is_some() {
            self.close_editor_split(cx);
        } else {
            self.split_editor_right(window, cx);
        }
    }

    pub(super) fn close_editor_split(&mut self, cx: &mut Context<Self>) {
        if let Some(secondary) = self.editor_secondary.take() {
            secondary.update(cx, |editor, editor_cx| {
                editor.set_webview_visible(false, editor_cx);
            });
            self.editor_secondary_webview_visible = None;
            cx.notify();
        }
    }

    pub(super) fn sync_editor_secondary(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(secondary) = self.editor_secondary.clone() else {
            return;
        };
        let Some(tab) = self.current_tab() else {
            secondary.update(cx, |editor, editor_cx| editor.clear(window, editor_cx));
            return;
        };

        let root = self.project_root.clone().unwrap_or_default();
        let absolute = tab.absolute_path.clone();
        let text = tab.text.clone();
        secondary.update(cx, |editor, editor_cx| {
            editor.open_file(root, absolute, text, window, editor_cx);
        });
    }

    pub(super) fn apply_editor_preferences(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let settings = &self.settings;
        let font_size = settings.editor_font_size;
        let wrap = settings.editor_wrap;
        let minimap = settings.editor_minimap;
        let line_numbers = settings.editor_line_numbers;
        let scroll_beyond_last_line = settings.editor_scroll_beyond_last_line;
        let render_whitespace = settings.editor_render_whitespace;
        let font_ligatures = settings.editor_font_ligatures;
        let code_lens = settings.editor_code_lens;
        let tab_size = settings.editor_tab_size;

        self.editor.update(cx, |editor, editor_cx| {
            editor.set_preferences(
                font_size,
                wrap,
                minimap,
                line_numbers,
                scroll_beyond_last_line,
                window,
                editor_cx,
            );
            editor.set_render_whitespace(render_whitespace, editor_cx);
            editor.set_editor_extras(font_ligatures, code_lens, tab_size, editor_cx);
        });

        if let Some(secondary) = self.editor_secondary.clone() {
            secondary.update(cx, |editor, editor_cx| {
                editor.set_preferences(
                    font_size,
                    wrap,
                    minimap,
                    line_numbers,
                    scroll_beyond_last_line,
                    window,
                    editor_cx,
                );
                editor.set_render_whitespace(render_whitespace, editor_cx);
                editor.set_editor_extras(font_ligatures, code_lens, tab_size, editor_cx);
            });
        }
    }

    pub(super) fn commit_editor_preferences(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.apply_editor_preferences(window, cx);
        self.settings.save();
        self.sync_settings_view(cx);
        cx.notify();
    }

    pub(super) fn toggle_wrap(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.settings.editor_wrap = !self.settings.editor_wrap;
        self.apply_editor_preferences(window, cx);
        self.settings.save();
        self.sync_settings_view(cx);
        cx.notify();
    }

    pub(super) fn toggle_editor_minimap(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.settings.editor_minimap = !self.settings.editor_minimap;
        self.commit_editor_preferences(window, cx);
    }

    pub(super) fn toggle_editor_line_numbers(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.settings.editor_line_numbers = !self.settings.editor_line_numbers;
        self.commit_editor_preferences(window, cx);
    }

    pub(super) fn toggle_editor_render_whitespace(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.settings.editor_render_whitespace = !self.settings.editor_render_whitespace;
        self.commit_editor_preferences(window, cx);
    }

    pub(super) fn nudge_editor_zoom(
        &mut self,
        delta: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.nudge_editor_font_size(delta) {
            self.commit_editor_preferences(window, cx);
        }
    }

    pub(super) fn reset_editor_zoom(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.settings.reset_editor_font_size() {
            self.commit_editor_preferences(window, cx);
        }
    }

    pub(super) fn revert_active_file(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(root) = self.project_root.clone() else {
            return;
        };
        let Some(path) = self.active_tab_path() else {
            return;
        };

        match std::fs::read_to_string(&path) {
            Ok(text) => {
                self.editor.update(cx, |editor, editor_cx| {
                    editor.reload_current(root, path.clone(), text.clone(), window, editor_cx);
                });
                if let Some(tab) = self.tabs.iter_mut().find(|tab| tab.absolute_path == path) {
                    tab.text = text;
                    tab.modified = false;
                }
                self.status_message = Some(tr("Saved").into());
                cx.notify();
            }
            Err(error) => {
                self.push_notification(
                    tr("Revert"),
                    Some(SharedString::from(error.to_string())),
                    super::notifications::NotificationKind::Error,
                );
                cx.notify();
            }
        }
    }

    pub(super) fn handle_editor_event(&mut self, event: &EditorEvent, cx: &mut Context<Self>) {
        match event {
            EditorEvent::CursorChanged { line, column } => {
                self.cursor_line = *line;
                self.cursor_column = *column;
                cx.notify();
            }
            EditorEvent::Diagnostics { items } => {
                self.problems = items.clone();
                cx.notify();
            }
            EditorEvent::DirtyChanged { path, dirty } => {
                let identity = super::tabs::file_identity(path);
                if let Some(tab) = self
                    .tabs
                    .iter_mut()
                    .find(|tab| super::tabs::file_identity(&tab.absolute_path) == identity)
                {
                    tab.modified = *dirty;
                    cx.notify();
                }
            }
            EditorEvent::Saved { path } => {
                let identity = super::tabs::file_identity(path);
                if let Some(tab) = self
                    .tabs
                    .iter_mut()
                    .find(|tab| super::tabs::file_identity(&tab.absolute_path) == identity)
                {
                    tab.modified = false;
                }
                self.status_message = Some(tr("Saved").into());
                self.push_notification(
                    tr("Saved"),
                    Some(
                        path.file_name()
                            .and_then(|n| n.to_str())
                            .unwrap_or("file")
                            .to_string()
                            .into(),
                    ),
                    super::notifications::NotificationKind::Success,
                );
                cx.notify();
            }
            EditorEvent::SaveFailed { path, message } => {
                self.push_notification(
                    tr("Save Failed"),
                    Some(format!("{}: {message}", path.display()).into()),
                    super::notifications::NotificationKind::Error,
                );
                cx.notify();
            }
            EditorEvent::SavedAs { from, to } => {
                self.pending_save_as = Some((from.clone(), to.clone()));
                self.push_notification(
                    tr("Saved As"),
                    Some(
                        to.file_name()
                            .and_then(|n| n.to_str())
                            .unwrap_or("file")
                            .to_string()
                            .into(),
                    ),
                    super::notifications::NotificationKind::Success,
                );
                cx.notify();
            }
        }
    }
}

/// 空编辑器提示视图（对齐 Tauri 侧空卡片）。
fn render_empty_editor(tokens: LitheTokens) -> AnyElement {
    v_flex()
        .size_full()
        .items_center()
        .justify_center()
        .gap(px(8.0))
        .px(px(16.0))
        .bg(tokens.editor)
        .child(
            Icon::new(IconName::FileSearch)
                .with_size(px(48.0))
                .text_color(tokens.tertiary_text),
        )
        .child(
            div()
                .text_size(px(14.0))
                .font_weight(gpui_kit::FontWeight::SEMIBOLD)
                .text_color(tokens.primary_text)
                .child(tr("Select a file to review")),
        )
        .child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(tr("Changes from external tools will appear automatically.")),
        )
        .into_any_element()
}
