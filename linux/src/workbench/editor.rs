use gpui_kit::assets::IconName;
use gpui_kit::component::input::{Editor, EditorState, InputEvent, Position};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, relative, AppContext as _, ClipboardItem, Context, Entity, FontWeight,
    InteractiveElement as _, IntoElement, ParentElement as _, Render,
    StatefulInteractiveElement as _, Styled as _, Subscription, Window,
};

use crate::core::CoreClient;
use crate::settings;
use crate::theme::ThemeColors;

#[derive(Debug, Clone)]
pub struct EditorTab {
    pub path: String,
    pub title: String,
    pub content: String,
    pub is_dirty: bool,
    #[allow(dead_code)]
    pub cursor_line: usize,
    #[allow(dead_code)]
    pub cursor_col: usize,
}

/// 多标签代码编辑器组件（对齐 macOS LitheTheme / IntelliJ 视觉规范）
///
/// 正文复用上游 `gpui_kit::component::input::Editor`，由它负责滚动、
/// 文本选择与语法高亮；本组件只管理标签栏、面包屑与文件读写。
pub struct EditorView {
    pub workspace_root: String,
    pub tabs: Vec<EditorTab>,
    pub active_tab_index: Option<usize>,
    #[allow(dead_code)]
    pub encoding: String,
    /// 当前活动标签对应的上游编辑器状态，随视图生命周期常驻并复用。
    editor_state: Entity<EditorState>,
    /// 自动换行开关镜像（上游无 getter，本地持有后取反下发）。
    soft_wrap: bool,
    /// 行号显示开关镜像。
    show_line_numbers: bool,
    /// 空白字符显示开关镜像。
    show_whitespace: bool,
    /// 已同步到 `editor_state` 的标签索引。
    synced_tab: Option<usize>,
    /// 活动标签内容被外部替换（重新打开文件）时置位，渲染时重新灌入编辑器。
    sync_needed: bool,
    /// 监听编辑器文本变化以回写标签内容与脏标记。
    _editor_subscription: Subscription,
    client: CoreClient,
    /// 撤销/重做历史（全文快照，栈顶恒等于编辑器当前值）。
    undo_stack: Vec<String>,
    redo_stack: Vec<String>,
    /// 已关闭标签（标签快照，原索引），后进先出供恢复。
    closed_stack: Vec<(EditorTab, usize)>,
}

impl EditorView {
    pub fn new(workspace_root: String, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let soft_wrap = settings::get(cx).word_wrap;
        let show_line_numbers = settings::get(cx).line_numbers;
        let editor_state = cx.new(|cx| {
            EditorState::new(window, cx)
                .line_number(show_line_numbers)
                .soft_wrap(soft_wrap)
        });
        let _editor_subscription = cx.subscribe_in(
            &editor_state,
            window,
            |this, _state, event: &InputEvent, _window, cx| {
                if matches!(event, InputEvent::Change) {
                    this.on_editor_change(cx);
                }
            },
        );

        Self {
            workspace_root,
            tabs: Vec::new(),
            active_tab_index: None,
            encoding: "UTF-8".to_string(),
            editor_state,
            soft_wrap,
            show_line_numbers,
            show_whitespace: false,
            synced_tab: None,
            sync_needed: false,
            _editor_subscription,
            client: CoreClient::new(),
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            closed_stack: Vec::new(),
        }
    }

    /// 打开文件，如果已在标签中则切换，否则新增标签
    pub fn open_file(&mut self, path: String, content: String, cx: &mut Context<Self>) {
        if let Some(pos) = self.tabs.iter().position(|t| t.path == path) {
            if let Some(tab) = self.tabs.get_mut(pos) {
                if tab.content != content {
                    tab.content = content;
                    tab.is_dirty = false;
                    self.sync_needed = true;
                }
            }
            self.active_tab_index = Some(pos);
            cx.notify();
            return;
        }

        let title = path
            .rsplit_once('/')
            .map(|(_, name)| name.to_string())
            .unwrap_or_else(|| path.clone());

        self.tabs.push(EditorTab {
            path,
            title,
            content,
            is_dirty: false,
            cursor_line: 1,
            cursor_col: 1,
        });

        self.active_tab_index = Some(self.tabs.len() - 1);
        self.sync_needed = true;
        cx.notify();
    }

    /// 关闭指定索引的标签页
    pub fn close_tab(&mut self, index: usize, cx: &mut Context<Self>) {
        if index < self.tabs.len() {
            self.record_closed(index);
            self.tabs.remove(index);
            if self.tabs.is_empty() {
                self.active_tab_index = None;
            } else if let Some(current) = self.active_tab_index {
                if current >= self.tabs.len() {
                    self.active_tab_index = Some(self.tabs.len() - 1);
                } else if current > index {
                    self.active_tab_index = Some(current - 1);
                }
            }
            self.sync_needed = true;
            cx.notify();
        }
    }

    /// 把当前活动标签的文本与语言灌入上游编辑器。
    fn sync_active_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let active_index = self.active_tab_index;

        if self.synced_tab == active_index && !self.sync_needed {
            return;
        }

        let Some(index) = active_index else {
            self.synced_tab = None;
            self.sync_needed = false;
            return;
        };

        let Some(tab) = self.tabs.get(index).cloned() else {
            return;
        };

        let language = Self::language_name(&tab.path).to_lowercase();
        let content = tab.content.clone();
        self.editor_state.update(cx, |editor, cx| {
            editor.set_value(content, window, cx);
            editor.set_highlighter(language, cx);
        });

        self.synced_tab = Some(index);
        self.sync_needed = false;
    }

    /// 编辑器文本变化后回写标签内容并标记为已修改。
    fn on_editor_change(&mut self, cx: &mut Context<Self>) {
        let Some(index) = self.active_tab_index else {
            return;
        };

        let value = self.editor_state.read(cx).value().to_string();
        if let Some(tab) = self.tabs.get_mut(index) {
            if tab.content != value {
                tab.content = value.clone();
                tab.is_dirty = true;
            }
        }
        if self.undo_stack.last().is_none_or(|top| *top != value) {
            self.undo_stack.push(value);
            if self.undo_stack.len() > 100 {
                let overflow = self.undo_stack.len() - 100;
                self.undo_stack.drain(..overflow);
            }
            self.redo_stack.clear();
        }
        cx.notify();
    }

    /// 保存当前活动的标签页至磁盘（对接 `file.write`）
    pub fn save_active(&mut self, cx: &mut Context<Self>) {
        let Some(idx) = self.active_tab_index else {
            return;
        };
        let Some(tab) = self.tabs.get(idx) else {
            return;
        };

        // 以编辑器内的实时文本为准，避免依赖事件回写的时序。
        let text = self.editor_state.read(cx).value().to_string();

        let root = self.workspace_root.clone();
        let path = tab.path.clone();
        let client = self.client.clone();

        cx.spawn(async move |this, cx| {
            let task = client.write_file(&cx, &root, &path, &text);
            if task.await.is_ok() {
                let _ = this.update(cx, |ed, cx| {
                    if let Some(active_idx) = ed.active_tab_index {
                        if let Some(t) = ed.tabs.get_mut(active_idx) {
                            if t.path == path {
                                t.is_dirty = false;
                                cx.notify();
                            }
                        }
                    }
                });
            }
        })
        .detach();
    }

    /// 全文替换并记入撤销历史（`set_value` 不触发 Change，需手动维护历史与标签同步）。
    fn commit_full_text(&mut self, new_text: String, window: &mut Window, cx: &mut Context<Self>) {
        let current = self.editor_state.read(cx).value().to_string();
        if current == new_text {
            return;
        }
        self.undo_stack.push(current);
        self.undo_stack.push(new_text.clone());
        if self.undo_stack.len() > 100 {
            let overflow = self.undo_stack.len() - 100;
            self.undo_stack.drain(..overflow);
        }
        self.redo_stack.clear();
        self.editor_state.update(cx, |editor, cx| {
            editor.set_value(new_text.clone(), window, cx);
        });
        if let Some(index) = self.active_tab_index {
            if let Some(tab) = self.tabs.get_mut(index) {
                tab.content = new_text;
                tab.is_dirty = true;
            }
        }
        cx.notify();
    }

    /// 撤销到上一个历史快照（空栈或无更早状态直接返回）。
    pub fn undo(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let current = self.editor_state.read(cx).value().to_string();
        if self.undo_stack.last().is_none_or(|top| *top != current) {
            return;
        }
        self.undo_stack.pop();
        let Some(prev) = self.undo_stack.last().cloned() else {
            self.undo_stack.push(current);
            return;
        };
        self.redo_stack.push(current);
        if self.redo_stack.len() > 100 {
            self.redo_stack.remove(0);
        }
        self.editor_state.update(cx, |editor, cx| {
            editor.set_value(prev.clone(), window, cx);
        });
        if let Some(index) = self.active_tab_index {
            if let Some(tab) = self.tabs.get_mut(index) {
                tab.content = prev;
                tab.is_dirty = true;
            }
        }
        cx.notify();
    }

    /// 重做上一次撤销（空栈直接返回）。
    pub fn redo(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(next) = self.redo_stack.pop() else {
            return;
        };
        let current = self.editor_state.read(cx).value().to_string();
        if current == next {
            self.redo_stack.push(next);
            return;
        }
        self.undo_stack.push(next.clone());
        if self.undo_stack.len() > 100 {
            let overflow = self.undo_stack.len() - 100;
            self.undo_stack.drain(..overflow);
        }
        self.editor_state.update(cx, |editor, cx| {
            editor.set_value(next.clone(), window, cx);
        });
        if let Some(index) = self.active_tab_index {
            if let Some(tab) = self.tabs.get_mut(index) {
                tab.content = next;
                tab.is_dirty = true;
            }
        }
        cx.notify();
    }

    /// 全选当前编辑器文本。
    pub fn select_all(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.active_tab_index.is_none() {
            return;
        }
        self.editor_state.update(cx, |editor, cx| {
            editor.select_all(window, cx);
        });
    }

    /// 复制选区到剪贴板（空选区直接返回）。
    pub fn copy(&mut self, cx: &mut Context<Self>) {
        if self.active_tab_index.is_none() {
            return;
        }
        let text = self.editor_state.read(cx).selected_value().to_string();
        if text.is_empty() {
            return;
        }
        cx.write_to_clipboard(ClipboardItem::new_string(text));
    }

    /// 剪切选区到剪贴板（空选区直接返回）。
    pub fn cut(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.active_tab_index.is_none() {
            return;
        }
        let text = self.editor_state.read(cx).selected_value().to_string();
        if text.is_empty() {
            return;
        }
        cx.write_to_clipboard(ClipboardItem::new_string(text));
        self.editor_state.update(cx, |editor, cx| {
            editor.replace("", window, cx);
        });
    }

    /// 粘贴剪贴板文本（无内容直接返回；有选区则替换，否则在光标处插入）。
    pub fn paste(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.active_tab_index.is_none() {
            return;
        }
        let Some(item) = cx.read_from_clipboard() else {
            return;
        };
        let text = item.text().unwrap_or_default().to_string();
        if text.is_empty() {
            return;
        }
        let range = self.editor_state.read(cx).selected_range();
        if range.start != range.end {
            self.editor_state.update(cx, |editor, cx| {
                editor.replace(text, window, cx);
            });
        } else {
            self.editor_state.update(cx, |editor, cx| {
                editor.insert(text, window, cx);
            });
        }
    }

    /// 当前光标行（0-based）与编辑器全文。
    fn active_row(&mut self, cx: &mut Context<Self>) -> Option<(usize, String)> {
        if self.active_tab_index.is_none() {
            return None;
        }
        let state = self.editor_state.read(cx);
        let row = state.cursor_position().line as usize;
        let value = state.value().to_string();
        Some((row, value))
    }

    /// 全文替换后把光标移到指定行首。
    fn move_cursor_to_row(&mut self, row: usize, window: &mut Window, cx: &mut Context<Self>) {
        self.editor_state.update(cx, |editor, cx| {
            editor.set_cursor_position(Position::new(row as u32, 0), window, cx);
        });
    }

    /// 复制当前行到下一行。
    pub fn duplicate_line(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some((row, value)) = self.active_row(cx) else {
            return;
        };
        let mut lines: Vec<String> = value.split('\n').map(str::to_string).collect();
        if lines.is_empty() {
            return;
        }
        let row = row.min(lines.len() - 1);
        lines.insert(row + 1, lines[row].clone());
        self.commit_full_text(lines.join("\n"), window, cx);
        self.move_cursor_to_row(row + 1, window, cx);
    }

    /// 删除当前行（含换行，末行特殊处理）。
    pub fn delete_line(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some((row, value)) = self.active_row(cx) else {
            return;
        };
        let mut lines: Vec<String> = value.split('\n').map(str::to_string).collect();
        if lines.is_empty() {
            return;
        }
        let row = row.min(lines.len() - 1);
        lines.remove(row);
        self.commit_full_text(lines.join("\n"), window, cx);
        if !lines.is_empty() {
            self.move_cursor_to_row(row.min(lines.len() - 1), window, cx);
        }
    }

    /// 当前行与上一行交换（首行直接返回）。
    pub fn move_line_up(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some((row, value)) = self.active_row(cx) else {
            return;
        };
        let mut lines: Vec<String> = value.split('\n').map(str::to_string).collect();
        if lines.is_empty() {
            return;
        }
        let row = row.min(lines.len() - 1);
        if row == 0 {
            return;
        }
        lines.swap(row, row - 1);
        self.commit_full_text(lines.join("\n"), window, cx);
        self.move_cursor_to_row(row - 1, window, cx);
    }

    /// 当前行与下一行交换（末行直接返回）。
    pub fn move_line_down(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some((row, value)) = self.active_row(cx) else {
            return;
        };
        let mut lines: Vec<String> = value.split('\n').map(str::to_string).collect();
        if lines.is_empty() {
            return;
        }
        let row = row.min(lines.len() - 1);
        if row + 1 >= lines.len() {
            return;
        }
        lines.swap(row, row + 1);
        self.commit_full_text(lines.join("\n"), window, cx);
        self.move_cursor_to_row(row + 1, window, cx);
    }

    /// 切换当前行注释（已注释则去注释，保留缩进）。
    pub fn toggle_comment(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(index) = self.active_tab_index else {
            return;
        };
        let path = self
            .tabs
            .get(index)
            .map(|tab| tab.path.clone())
            .unwrap_or_default();
        let Some((row, value)) = self.active_row(cx) else {
            return;
        };
        let mut lines: Vec<String> = value.split('\n').map(str::to_string).collect();
        if lines.is_empty() {
            return;
        }
        let row = row.min(lines.len() - 1);
        let line = lines[row].clone();
        let indent_len = line.len() - line.trim_start().len();
        let (indent, body) = line.split_at(indent_len);
        let new_line = match Self::comment_style(&path) {
            CommentStyle::Line(prefix) => {
                if let Some(rest) = body.strip_prefix(prefix) {
                    let rest = rest
                        .strip_prefix(' ')
                        .or_else(|| rest.strip_prefix('\t'))
                        .unwrap_or(rest);
                    format!("{indent}{rest}")
                } else {
                    format!("{indent}{prefix} {body}")
                }
            }
            CommentStyle::Block => {
                let trimmed = line.trim();
                if let Some(inner) = trimmed
                    .strip_prefix("<!--")
                    .and_then(|s| s.strip_suffix("-->"))
                {
                    format!("{indent}{}", inner.trim())
                } else {
                    format!("{indent}<!-- {body} -->")
                }
            }
        };
        lines[row] = new_line;
        self.commit_full_text(lines.join("\n"), window, cx);
        self.move_cursor_to_row(row, window, cx);
    }

    /// 记录关闭的标签以供恢复（上限 30，超限去头；脏标签直接关，与 `close_tab` 一致）。
    fn record_closed(&mut self, index: usize) {
        if let Some(tab) = self.tabs.get(index).cloned() {
            self.closed_stack.push((tab, index));
            if self.closed_stack.len() > 30 {
                let overflow = self.closed_stack.len() - 30;
                self.closed_stack.drain(..overflow);
            }
        }
    }

    /// 关闭全部标签（逐个进恢复栈）。
    pub fn close_all_tabs(&mut self, cx: &mut Context<Self>) {
        if self.tabs.is_empty() {
            return;
        }
        for (index, tab) in self.tabs.iter().enumerate() {
            self.closed_stack.push((tab.clone(), index));
        }
        if self.closed_stack.len() > 30 {
            let overflow = self.closed_stack.len() - 30;
            self.closed_stack.drain(..overflow);
        }
        self.tabs.clear();
        self.active_tab_index = None;
        self.sync_needed = true;
        cx.notify();
    }

    /// 关闭除活动标签外的全部标签。
    pub fn close_other_tabs(&mut self, cx: &mut Context<Self>) {
        let Some(active) = self.active_tab_index else {
            return;
        };
        if active >= self.tabs.len() {
            return;
        }
        let mut kept = None;
        for (index, tab) in self.tabs.drain(..).enumerate() {
            if index == active {
                kept = Some(tab);
            } else {
                self.closed_stack.push((tab, index));
            }
        }
        if self.closed_stack.len() > 30 {
            let overflow = self.closed_stack.len() - 30;
            self.closed_stack.drain(..overflow);
        }
        if let Some(tab) = kept {
            self.tabs.push(tab);
            self.active_tab_index = Some(0);
        } else {
            self.active_tab_index = None;
        }
        self.sync_needed = true;
        cx.notify();
    }

    /// 关闭全部未修改（`is_dirty == false`）的标签。
    pub fn close_saved_tabs(&mut self, cx: &mut Context<Self>) {
        if self.tabs.is_empty() {
            return;
        }
        let active_path = self
            .active_tab_index
            .and_then(|index| self.tabs.get(index))
            .map(|tab| tab.path.clone());
        let mut kept = Vec::new();
        for (index, tab) in self.tabs.drain(..).enumerate() {
            if tab.is_dirty {
                kept.push(tab);
            } else {
                self.closed_stack.push((tab, index));
            }
        }
        if self.closed_stack.len() > 30 {
            let overflow = self.closed_stack.len() - 30;
            self.closed_stack.drain(..overflow);
        }
        self.tabs = kept;
        self.active_tab_index =
            active_path.and_then(|path| self.tabs.iter().position(|tab| tab.path == path));
        self.sync_needed = true;
        cx.notify();
    }

    /// 关闭活动标签左侧的全部标签。
    pub fn close_tabs_to_left(&mut self, cx: &mut Context<Self>) {
        let Some(active) = self.active_tab_index else {
            return;
        };
        if active == 0 || active >= self.tabs.len() {
            return;
        }
        for index in 0..active {
            if let Some(tab) = self.tabs.get(index).cloned() {
                self.closed_stack.push((tab, index));
            }
        }
        if self.closed_stack.len() > 30 {
            let overflow = self.closed_stack.len() - 30;
            self.closed_stack.drain(..overflow);
        }
        self.tabs.drain(..active);
        self.active_tab_index = Some(0);
        self.sync_needed = true;
        cx.notify();
    }

    /// 关闭活动标签右侧的全部标签。
    pub fn close_tabs_to_right(&mut self, cx: &mut Context<Self>) {
        let Some(active) = self.active_tab_index else {
            return;
        };
        if active >= self.tabs.len() || active + 1 >= self.tabs.len() {
            return;
        }
        for index in active + 1..self.tabs.len() {
            if let Some(tab) = self.tabs.get(index).cloned() {
                self.closed_stack.push((tab, index));
            }
        }
        if self.closed_stack.len() > 30 {
            let overflow = self.closed_stack.len() - 30;
            self.closed_stack.drain(..overflow);
        }
        self.tabs.truncate(active + 1);
        self.sync_needed = true;
        cx.notify();
    }

    /// 恢复最近关闭的标签到原位（后进先出，活动标签指向恢复项）。
    pub fn reopen_closed_tab(&mut self, cx: &mut Context<Self>) {
        let Some((tab, index)) = self.closed_stack.pop() else {
            return;
        };
        if let Some(pos) = self.tabs.iter().position(|t| t.path == tab.path) {
            self.active_tab_index = Some(pos);
        } else {
            let insert_at = index.min(self.tabs.len());
            self.tabs.insert(insert_at, tab);
            self.active_tab_index = Some(insert_at);
        }
        self.sync_needed = true;
        cx.notify();
    }

    /// 保存全部脏标签至磁盘（仿 `save_active` 的落盘写法）。
    pub fn save_all_tabs(&mut self, cx: &mut Context<Self>) {
        if self.tabs.is_empty() {
            return;
        }
        // 以编辑器内的实时文本为准，避免依赖事件回写的时序。
        let live = self.editor_state.read(cx).value().to_string();
        let mut jobs: Vec<(String, String)> = Vec::new();
        for (index, tab) in self.tabs.iter().enumerate() {
            if !tab.is_dirty {
                continue;
            }
            let text = if Some(index) == self.active_tab_index {
                live.clone()
            } else {
                tab.content.clone()
            };
            jobs.push((tab.path.clone(), text));
        }
        if jobs.is_empty() {
            return;
        }
        let root = self.workspace_root.clone();
        let client = self.client.clone();
        cx.spawn(async move |this, cx| {
            for (path, text) in jobs {
                if client.write_file(&cx, &root, &path, &text).await.is_ok() {
                    let _ = this.update(cx, |ed, cx| {
                        if let Some(tab) = ed.tabs.iter_mut().find(|tab| tab.path == path) {
                            tab.is_dirty = false;
                        }
                        cx.notify();
                    });
                }
            }
        })
        .detach();
    }

    /// 切换到下一个标签（循环）。
    pub fn goto_next_tab(&mut self, cx: &mut Context<Self>) {
        if self.tabs.is_empty() {
            return;
        }
        let next = match self.active_tab_index {
            Some(index) => (index + 1) % self.tabs.len(),
            None => 0,
        };
        self.active_tab_index = Some(next);
        self.sync_needed = true;
        cx.notify();
    }

    /// 切换到上一个标签（循环）。
    pub fn goto_prev_tab(&mut self, cx: &mut Context<Self>) {
        if self.tabs.is_empty() {
            return;
        }
        let prev = match self.active_tab_index {
            Some(0) | None => self.tabs.len() - 1,
            Some(index) => (index - 1) % self.tabs.len(),
        };
        self.active_tab_index = Some(prev);
        self.sync_needed = true;
        cx.notify();
    }

    /// 跳到指定行（1-based，钳制到总行数；不置同步标记以免覆盖光标）。
    pub fn go_to_line(&mut self, line: u32, window: &mut Window, cx: &mut Context<Self>) {
        if self.active_tab_index.is_none() {
            return;
        }
        let total = self
            .editor_state
            .read(cx)
            .value()
            .to_string()
            .split('\n')
            .count()
            .max(1) as u32;
        let clamped = line.max(1).min(total);
        self.editor_state.update(cx, |editor, cx| {
            editor.set_cursor_position(Position::new(clamped - 1, 0), window, cx);
        });
        self.sync_needed = false;
    }

    /// 取反自动换行并同步设置落盘。
    pub fn toggle_wrap(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.soft_wrap = !self.soft_wrap;
        let wrap = self.soft_wrap;
        self.editor_state.update(cx, |editor, cx| {
            editor.set_soft_wrap(wrap, window, cx);
        });
        settings::update(cx, |s| s.word_wrap = wrap);
    }

    /// 取反行号显示并同步设置落盘。
    pub fn toggle_line_numbers(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.show_line_numbers = !self.show_line_numbers;
        let show = self.show_line_numbers;
        self.editor_state.update(cx, |editor, cx| {
            editor.set_line_number(show, window, cx);
        });
        settings::update(cx, |s| s.line_numbers = show);
    }

    /// 取反空白字符显示（无对应设置项，仅编辑器侧生效）。
    pub fn toggle_whitespace(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.show_whitespace = !self.show_whitespace;
        let show = self.show_whitespace;
        self.editor_state.update(cx, |editor, cx| {
            editor.set_show_whitespaces(show, window, cx);
        });
    }

    /// 获取推断的代码语言名称
    pub fn language_name(path: &str) -> &'static str {
        if path.ends_with(".rs") {
            "Rust"
        } else if path.ends_with(".json") {
            "JSON"
        } else if path.ends_with(".toml") {
            "TOML"
        } else if path.ends_with(".md") {
            "Markdown"
        } else if path.ends_with(".ts") {
            "TypeScript"
        } else if path.ends_with(".js") {
            "JavaScript"
        } else if path.ends_with(".java") {
            "Java"
        } else if path.ends_with(".xml") {
            "XML"
        } else if path.ends_with(".yaml") || path.ends_with(".yml") {
            "YAML"
        } else if path.ends_with(".sh") {
            "Shell"
        } else if path.ends_with(".sql") {
            "SQL"
        } else {
            "Plain Text"
        }
    }

    /// 按文件扩展名推断行注释风格（`language_name` 缺少 py/html/c 等分支，故直接匹配扩展名）。
    fn comment_style(path: &str) -> CommentStyle {
        let ext = path.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
        match ext.as_str() {
            "py" | "sh" | "sql" | "toml" | "yaml" | "yml" | "rb" | "pl" => CommentStyle::Line("#"),
            "html" | "xml" => CommentStyle::Block,
            _ => CommentStyle::Line("//"),
        }
    }
}

/// 行注释风格：行前缀或行级块包裹。

/// 行注释风格：行前缀或行级块包裹。
enum CommentStyle {
    Line(&'static str),
    Block,
}

fn is_code_file(name: &str) -> bool {
    let lower = name.to_lowercase();
    lower.ends_with(".rs")
        || lower.ends_with(".js")
        || lower.ends_with(".ts")
        || lower.ends_with(".jsx")
        || lower.ends_with(".tsx")
        || lower.ends_with(".json")
        || lower.ends_with(".toml")
        || lower.ends_with(".html")
        || lower.ends_with(".css")
        || lower.ends_with(".java")
        || lower.ends_with(".c")
        || lower.ends_with(".cpp")
        || lower.ends_with(".h")
        || lower.ends_with(".hpp")
        || lower.ends_with(".py")
        || lower.ends_with(".go")
        || lower.ends_with(".swift")
        || lower.ends_with(".sh")
        || lower.ends_with(".xml")
        || lower.ends_with(".yaml")
        || lower.ends_with(".yml")
        || lower.ends_with(".sql")
}

impl Render for EditorView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.sync_active_editor(window, cx);

        let active_tab = self
            .active_tab_index
            .and_then(|idx| self.tabs.get(idx).cloned());

        let editor_state = self.editor_state.clone();

        v_flex()
            .size_full()
            .bg(ThemeColors::bg_editor())
            .child(
                // 1. 顶部标签栏（Tab Bar，高 34px）
                h_flex()
                    .h(px(34.0))
                    .w_full()
                    .bg(ThemeColors::bg_tab_bar())
                    .border_b_1()
                    .border_color(ThemeColors::border())
                    .items_center()
                    .overflow_x_scrollbar()
                    .children(self.tabs.iter().enumerate().map(|(idx, tab)| {
                        let is_active = self.active_tab_index == Some(idx);
                        let title = tab.title.clone();
                        let is_dirty = tab.is_dirty;
                        let icon_name = if is_code_file(&title) {
                            IconName::FileCode
                        } else {
                            IconName::FileText
                        };

                        h_flex()
                            .id(idx)
                            .h(px(34.0))
                            .items_center()
                            .gap_2()
                            .px_3()
                            .relative()
                            .cursor_pointer()
                            .when(is_active, |t| t.bg(ThemeColors::bg_editor()))
                            .when(!is_active, |t| {
                                t.bg(ThemeColors::bg_tab_bar())
                                    .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                            })
                            .on_click(cx.listener(move |this, _event, _window, cx| {
                                this.active_tab_index = Some(idx);
                                cx.notify();
                            }))
                            .child(
                                Icon::new(icon_name)
                                    .size(px(14.0))
                                    .text_color(if is_active {
                                        ThemeColors::accent_blue()
                                    } else {
                                        ThemeColors::text_muted()
                                    }),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(if is_active {
                                        ThemeColors::text_primary()
                                    } else {
                                        ThemeColors::text_muted()
                                    })
                                    .child(title),
                            )
                            .when(is_dirty, |t| {
                                t.child(
                                    div()
                                        .w(px(6.0))
                                        .h(px(6.0))
                                        .rounded_full()
                                        .bg(ThemeColors::accent_blue()),
                                )
                            })
                            .child(
                                div()
                                    .id(("close-tab", idx))
                                    .p(px(2.0))
                                    .rounded_sm()
                                    .cursor_pointer()
                                    .hover(|h| {
                                        h.bg(ThemeColors::bg_tab_hover())
                                            .text_color(ThemeColors::accent_red())
                                    })
                                    .child(
                                        Icon::new(IconName::Close)
                                            .size(px(12.0))
                                            .text_color(ThemeColors::text_muted()),
                                    )
                                    .on_click(cx.listener(move |this, _event, _window, cx| {
                                        this.close_tab(idx, cx);
                                    })),
                            )
                            // 激活 Tab 底部 2px 高亮条（对齐 macOS tabUnderline）
                            .when(is_active, |t| {
                                t.child(
                                    div()
                                        .absolute()
                                        .bottom_0()
                                        .left_0()
                                        .right_0()
                                        .h(px(2.0))
                                        .bg(ThemeColors::accent_blue()),
                                )
                            })
                    })),
            )
            .when_some(active_tab.as_ref(), |this, tab| {
                // 2. 面包屑导航栏（Breadcrumb Bar，高 24px）
                let segments: Vec<&str> = tab.path.split('/').filter(|s| !s.is_empty()).collect();
                let last_idx = segments.len().saturating_sub(1);

                this.child(
                    h_flex()
                        .h(px(24.0))
                        .w_full()
                        .bg(ThemeColors::bg_tab_active())
                        .border_b_1()
                        .border_color(ThemeColors::border())
                        .items_center()
                        .px_3()
                        .gap_1p5()
                        .text_xs()
                        .text_color(ThemeColors::text_muted())
                        .child(
                            Icon::new(IconName::Folder)
                                .size(px(12.0))
                                .text_color(ThemeColors::text_muted()),
                        )
                        .children(segments.into_iter().enumerate().flat_map(|(idx, seg)| {
                            let is_last = idx == last_idx;
                            let seg_element = div()
                                .text_xs()
                                .text_color(if is_last {
                                    ThemeColors::text_primary()
                                } else {
                                    ThemeColors::text_muted()
                                })
                                .child(seg.to_string())
                                .into_any_element();

                            if is_last {
                                vec![seg_element]
                            } else {
                                vec![
                                    seg_element,
                                    Icon::new(IconName::ChevronRight)
                                        .size(px(10.0))
                                        .text_color(ThemeColors::text_muted())
                                        .into_any_element(),
                                ]
                            }
                        })),
                )
            })
            .child(
                // 3. 中央代码内容区（滚动与文本选择由上游 Editor 负责）
                div()
                    .flex_1()
                    .w_full()
                    .overflow_hidden()
                    .when_some(
                        active_tab.as_ref().map(|_| editor_state.clone()),
                        |this, state| {
                            this.child(
                                Editor::new(&state)
                                    .h(relative(1.0))
                                    .bordered(false)
                                    .readonly(false)
                                    .text_size(px(crate::settings::get(cx).font_size)),
                            )
                        },
                    )
                    .when(active_tab.is_none(), |this| {
                        // 无打开文件空态，对齐 Tauri `EmptyEditorState`：
                        // 文件图标 + 右下角放大镜叠加，标题与描述使用 i18n 同款文案。
                        this.child(
                            h_flex()
                                .size_full()
                                .items_center()
                                .justify_center()
                                .bg(ThemeColors::bg_editor())
                                .px_6()
                                .py_8()
                                .child(
                                    v_flex()
                                        .max_w(px(448.0))
                                        .items_center()
                                        .gap_3()
                                        .child(
                                            div()
                                                .relative()
                                                .size(px(48.0))
                                                .flex()
                                                .items_center()
                                                .justify_center()
                                                .text_color(ThemeColors::text_muted())
                                                .child(Icon::new(IconName::FileText).size(px(40.0)))
                                                .child(
                                                    div().absolute().bottom_0().right_0().child(
                                                        Icon::new(IconName::Search).size(px(20.0)),
                                                    ),
                                                ),
                                        )
                                        .child(
                                            div()
                                                .text_base()
                                                .font_weight(FontWeight::MEDIUM)
                                                .text_color(ThemeColors::text_primary())
                                                .child("选择文件以查看"),
                                        )
                                        .child(
                                            div()
                                                .text_sm()
                                                .text_color(ThemeColors::text_muted())
                                                .child("外部工具产生的更改会自动显示。"),
                                        ),
                                ),
                        )
                    }),
            )
    }
}
