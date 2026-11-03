//! 编辑区：用 gpui-kit 原生 `Editor` 承载代码编辑。
//!
//! 这里不再有 WebView 或 Monaco：文本模型、语法高亮、折叠、多光标和查找替换
//! 都由 GPUI 组件绘制。Rust 侧只维护当前文档的路径、保存语义和工作台需要的事件。
//!
//! # 与工作台的边界
//!
//! 工作台拥有标签页与未保存文本缓存；`EditorSurface` 只显示当前文件。切换文件
//! 时先缓存当前文本，再为目标文件创建编辑状态，避免把未保存内容写进另一个文件。
//!
//! # 语言服务
//!
//! GPUI 宿主没有常驻 LSP 会话，补全、悬停和跳转继续调用 Core 的同文档兜底命令
//! （`lsp.builtinCompletions` / `lsp.builtinHover` / `lsp.builtinNavigation`），
//! 通过 gpui-kit 的 provider trait 接入编辑器。

use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};
use std::rc::Rc;
use std::time::{Duration, Instant};

use anyhow::Result;
use gpui_kit::component::input::{
    CompletionProvider, DefinitionProvider, Editor, EditorState, HoverProvider, InputEvent,
    Rope, RopeExt, TabSize,
};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, AppContext as _, Context, Entity, EventEmitter, IntoElement, ParentElement as _, Render,
    SharedString, Styled as _, Subscription, Task, Window, div, px,
};
use lsp_types::{
    CompletionItem, CompletionItemKind, CompletionResponse, Hover, HoverContents, LocationLink,
    MarkupContent, MarkupKind, Position,
};
use lithe_core_client::CoreClient;
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens, MONO_FONT_FAMILY, current_tokens};
use serde_json::{Value, json};

/// 一个已打开文档的 Rust 侧状态。
#[derive(Clone)]
struct DocumentState {
    id: String,
    /// 调用方传入的路径；事件里回传它，工作台按绝对路径匹配标签。
    absolute_path: PathBuf,
    /// 最近一次 `open_file`/`save` 提供的工作区根。
    root: PathBuf,
    /// 传给 Core 的工作区相对路径，始终 `/` 分隔。
    relative: String,
    readonly: bool,
    dirty: bool,
}

/// 一条编辑器诊断。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiagnosticItem {
    pub path: PathBuf,
    pub severity: u8,
    pub message: String,
    pub line: u32,
    pub column: u32,
    pub source: Option<String>,
}

/// 编辑器向工作台广播的事件。
#[derive(Clone, Debug)]
pub enum EditorEvent {
    DirtyChanged {
        path: PathBuf,
        dirty: bool,
    },
    Saved {
        path: PathBuf,
    },
    SaveFailed {
        path: PathBuf,
        message: String,
    },
    /// 另存为成功。`from` 是写盘前的路径，工作台据此关闭旧标签并打开 `to`。
    SavedAs {
        from: PathBuf,
        to: PathBuf,
    },
    CursorChanged {
        line: u32,
        column: u32,
    },
    Diagnostics {
        items: Vec<DiagnosticItem>,
    },
}

impl EventEmitter<EditorEvent> for EditorSurface {}

/// 一次外部磁盘变更的处理结果。
///
/// 工作台据此决定是否同步标签缓存、是否在状态栏提示；真正的提示文案与
/// 冲突状态由 [`EditorSurface`] 自己维护。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DiskChangeOutcome {
    /// 不是当前文档、内容没有实质变化，或文档正在保存：不处理。
    Ignored,
    /// 未修改的文档已被磁盘内容替换。
    Reloaded,
    /// 有未保存修改：编辑区保持不变，等待用户保存覆盖或还原。
    Conflict,
}

/// 本进程写入磁盘后，多久之内的同路径事件判定为「自己保存」。
///
/// `notify` 事件不携带写入者身份，保存成功后磁盘事件会立刻回来；没有这个
/// 窗口，一次 Ctrl+S 就会把自己刚写的内容当成外部修改（脏文档直接弹冲突）。
const SELF_WRITE_WINDOW: Duration = Duration::from_secs(1);

/// 基于 gpui-kit `Editor` 的编辑区。
pub struct EditorSurface {
    editor: Option<Entity<EditorState>>,
    subscription: Option<Subscription>,
    document: Option<DocumentState>,
    /// 未保存文本缓存。工作台切换标签时重新 `open_file`，不能丢掉编辑中的内容。
    texts: HashMap<String, String>,
    dirty: bool,
    /// 磁盘内容与编辑区里的未保存内容冲突，等待用户选择。
    disk_conflict: bool,
    /// 本进程最近写盘的文件身份与时间，用于过滤自己保存产生的 watcher 事件。
    recent_writes: Vec<(String, Instant)>,
    cursor_line: u32,
    cursor_column: u32,
    diagnostics: Vec<DiagnosticItem>,
    error: Option<SharedString>,
    editor_font_size: f32,
    /// 编辑器字体族；`None` 使用内置等宽字体。
    editor_font_family: Option<String>,
    editor_wrap: bool,
    editor_line_numbers: bool,
    editor_scroll_beyond_last_line: bool,
    editor_render_whitespace: bool,
    editor_tab_size: u32,
    auto_completion: bool,
}

impl EditorSurface {
    pub fn new(_window: &mut Window, _cx: &mut Context<Self>) -> Self {
        Self {
            editor: None,
            subscription: None,
            document: None,
            texts: HashMap::new(),
            dirty: false,
            disk_conflict: false,
            recent_writes: Vec::new(),
            cursor_line: 0,
            cursor_column: 0,
            diagnostics: Vec::new(),
            error: None,
            editor_font_size: LitheMetrics::CODE_FONT_SIZE,
            editor_font_family: None,
            editor_wrap: false,
            editor_line_numbers: true,
            editor_scroll_beyond_last_line: false,
            editor_render_whitespace: false,
            editor_tab_size: 4,
            auto_completion: true,
        }
    }

    /// 更新编辑器外观。`minimap`、`ligatures`、`code_lens` 和语义高亮由
    /// gpui-kit 编辑器自行决定是否支持，这里保留参数以兼容设置页。
    #[allow(clippy::too_many_arguments)]
    pub fn set_preferences(
        &mut self,
        font_size: f32,
        wrap: bool,
        _minimap: bool,
        line_numbers: bool,
        scroll_beyond_last_line: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.editor_font_size = font_size.clamp(9.0, 32.0);
        self.editor_wrap = wrap;
        self.editor_line_numbers = line_numbers;
        self.editor_scroll_beyond_last_line = scroll_beyond_last_line;
        self.apply_view_options(window, cx);
        cx.notify();
    }

    /// 设置编辑器字体族；`None` 回到内置等宽字体。字体名是系统标识，
    /// 不经过 i18n。
    pub fn set_font_family(&mut self, family: Option<String>, cx: &mut Context<Self>) {
        let family = family.filter(|value| !value.trim().is_empty());
        if self.editor_font_family == family {
            return;
        }
        self.editor_font_family = family;
        cx.notify();
    }

    /// 切换空白字符渲染（View > Render Whitespace）。
    pub fn set_render_whitespace(
        &mut self,
        visible: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.editor_render_whitespace == visible {
            return;
        }
        self.editor_render_whitespace = visible;
        if let Some(editor) = self.editor.clone() {
            editor.update(cx, |state, cx| {
                state.set_show_whitespaces(visible, window, cx);
            });
        }
        cx.notify();
    }

    /// 字体连字、Code Lens 与 Tab 宽度；gpui-kit 只使用 Tab 宽度。
    pub fn set_editor_extras(
        &mut self,
        _ligatures: bool,
        _code_lens: bool,
        tab_size: u32,
        cx: &mut Context<Self>,
    ) {
        let tab_size = tab_size.clamp(1, 8);
        if self.editor_tab_size == tab_size {
            return;
        }
        self.editor_tab_size = tab_size;
        let tab_size = self.editor_tab_size;
        if let Some(editor) = self.editor.clone() {
            editor.update(cx, |state, cx| {
                state.set_tab_size(
                    TabSize {
                        tab_size: tab_size as usize,
                        hard_tabs: false,
                    },
                    cx,
                );
            });
        }
        cx.notify();
    }

    /// 语言服务开关；GPUI 编辑器内置补全菜单，这里只控制是否挂载 provider。
    pub fn set_language_service_preferences(
        &mut self,
        auto_completion: bool,
        _parameter_hints: bool,
        _semantic_tokens: bool,
        cx: &mut Context<Self>,
    ) {
        if self.auto_completion == auto_completion {
            return;
        }
        self.auto_completion = auto_completion;
        let path = path_text(&self.document);
        let enabled = self.auto_completion;
        if let Some(editor) = self.editor.clone() {
            editor.update(cx, |state, cx| {
                if enabled {
                    state.lsp_mut().completion_provider =
                        Some(Rc::new(CoreLspProvider::new(path)));
                } else {
                    state.lsp_mut().completion_provider = None;
                }
                cx.notify();
            });
        }
    }

    /// 打开（或重新激活）一个文件。
    pub fn open_file(
        &mut self,
        root: PathBuf,
        path: PathBuf,
        text: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let (id, relative, absolute_path) = document_identity(&root, &path);
        if self.document.as_ref().is_some_and(|document| document.id == id) {
            // 同一文件再次打开：只有缓存文本与编辑区不同且没有未保存修改时才同步。
            let current = self.editor_value(cx);
            if !self.dirty && current != text {
                self.set_editor_value(text, window, cx);
            }
            // 冲突提示要留到用户保存/还原为止，重复点击同一标签不能把它擦掉。
            if !self.disk_conflict {
                self.error = None;
            }
            cx.notify();
            return;
        }

        self.flush_current_text(cx);
        let initial_text = self.texts.get(&id).cloned().unwrap_or(text);
        let readonly = self
            .document
            .as_ref()
            .map(|document| document.id == id && document.readonly)
            .unwrap_or(false);

        self.document = Some(DocumentState {
            id: id.clone(),
            absolute_path: absolute_path.clone(),
            root,
            relative,
            readonly,
            dirty: false,
        });
        self.error = None;
        // 冲突提示属于上一个文档，换成新文档时必须清掉，避免错误条挂错对象。
        self.disk_conflict = false;
        self.dirty = false;
        self.create_editor(&absolute_path, initial_text, readonly, window, cx);
        cx.notify();
    }

    /// 清空编辑区与所有文档状态。
    pub fn clear(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        self.flush_current_text(cx);
        self.subscription = None;
        self.editor = None;
        self.document = None;
        self.texts.clear();
        self.diagnostics.clear();
        self.dirty = false;
        self.disk_conflict = false;
        self.cursor_line = 0;
        self.cursor_column = 0;
        self.error = None;
        cx.notify();
    }

    /// 当前活动文件路径。
    pub fn current_path(&self) -> Option<&Path> {
        self.document
            .as_ref()
            .map(|document| document.absolute_path.as_path())
    }

    /// 原生编辑器没有覆盖式原生子视图；保留该入口让工作台无需感知实现变化。
    pub fn set_webview_visible(&mut self, _visible: bool, _cx: &mut Context<Self>) {}

    /// 原生编辑器没有 DevTools。
    pub fn open_devtools(&mut self, _cx: &mut Context<Self>) {}

    /// 关闭一个文件；关闭的是当前文件时清空编辑区。
    pub fn close_file(&mut self, path: PathBuf, _window: &mut Window, cx: &mut Context<Self>) {
        let Some(document) = self.document.as_ref() else {
            return;
        };
        if !same_path(&document.absolute_path, &path) {
            return;
        }
        let id = document.id.clone();
        self.flush_current_text(cx);
        self.texts.remove(&id);
        self.subscription = None;
        self.editor = None;
        self.document = None;
        self.dirty = false;
        self.disk_conflict = false;
        cx.notify();
    }

    /// 用磁盘上的最新内容替换当前文件。
    pub fn reload_current(
        &mut self,
        root: PathBuf,
        path: PathBuf,
        text: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let (id, relative, absolute_path) = document_identity(&root, &path);
        self.document = Some(DocumentState {
            id: id.clone(),
            absolute_path: absolute_path.clone(),
            root,
            relative,
            readonly: false,
            dirty: false,
        });
        self.texts.insert(id, text.clone());
        self.dirty = false;
        // 还原之后冲突已经解决，错误条不能继续挂着旧提示。
        self.disk_conflict = false;
        self.error = None;
        if self.editor.is_some() {
            self.set_editor_value(text, window, cx);
            self.update_view_options(window, cx);
        } else {
            self.create_editor(&absolute_path, text, false, window, cx);
        }
        cx.notify();
    }

    /// 处理一次外部磁盘变更（工作台的 watcher 去抖后调用）。
    ///
    /// 语义对齐 macOS `DocumentFeatureModel.processExternalChanges`：
    ///
    /// - 路径不是当前文档，或磁盘文本与编辑区一致（无实质变化）→ 忽略；
    /// - 当前文档没有未保存修改 → 用磁盘文本替换编辑区，仍保持未修改状态；
    /// - 当前文档有未保存修改 → **不覆盖**编辑区，只标记冲突并提示用户
    ///   保存覆盖或用 File > Revert 加载磁盘版本，绝不自动合并。
    pub fn handle_disk_change(
        &mut self,
        root: &Path,
        path: &Path,
        disk_text: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> DiskChangeOutcome {
        let Some(document) = self.document.as_ref() else {
            return DiskChangeOutcome::Ignored;
        };
        if !same_path(&document.absolute_path, path) {
            return DiskChangeOutcome::Ignored;
        }

        // 内容相同就不算变化：保存刚完成、格式重写但结果一致等都在这里收敛。
        if self.editor_value(cx) == disk_text {
            if self.disk_conflict {
                self.disk_conflict = false;
                self.error = None;
                cx.notify();
            }
            return DiskChangeOutcome::Ignored;
        }

        if self.dirty {
            // 未保存内容归编辑器所有：只提示冲突，不覆盖、不合并。文案同时
            // 说明两条出路，对齐 macOS 让用户显式选择保存或加载磁盘版本。
            self.disk_conflict = true;
            self.error = Some(SharedString::from(format!(
                "{} {}",
                tr("This file changed outside Lithe while you had unsaved edits."),
                tr("Save to overwrite the file, or use File > Revert to load the disk version."),
            )));
            cx.notify();
            return DiskChangeOutcome::Conflict;
        }

        self.reload_current(
            root.to_path_buf(),
            path.to_path_buf(),
            disk_text,
            window,
            cx,
        );
        DiskChangeOutcome::Reloaded
    }

    /// 该路径的 watcher 事件是否来自本进程刚刚完成的保存。
    ///
    /// 只覆盖保存后 [`SELF_WRITE_WINDOW`] 之内的同路径事件；窗口之外的写入
    /// 仍按外部修改处理，不会把真正的外部编辑静默吃掉。
    pub fn is_recent_self_write(&self, path: &Path) -> bool {
        let identity = path_identity(path);
        self.recent_writes
            .iter()
            .any(|(written, at)| *written == identity && at.elapsed() < SELF_WRITE_WINDOW)
    }

    /// 记录一次成功的写盘，并顺手清理过期的记录。
    fn record_self_write(&mut self, path: &Path) {
        self.recent_writes
            .retain(|(_, at)| at.elapsed() < SELF_WRITE_WINDOW);
        self.recent_writes.push((path_identity(path), Instant::now()));
    }

    /// 切换标签后校准当前文档的未保存状态。
    ///
    /// `open_file` 会按缓存文本重建文档并把脏标记清零，但缓存文本可能仍带
    /// 未保存修改；工作台的标签状态才是这份信息的来源。这里静默同步，不广播
    /// `DirtyChanged`：事件只用于「编辑器 → 工作台」的方向。
    pub fn restore_dirty(&mut self, dirty: bool) {
        self.dirty = dirty;
        if let Some(document) = self.document.as_mut() {
            document.dirty = dirty;
        }
    }

    /// 更新当前文档的脏状态。
    pub fn mark_dirty(&mut self, dirty: bool, _window: &mut Window, cx: &mut Context<Self>) {
        if self.dirty == dirty {
            return;
        }
        self.dirty = dirty;
        if let Some(document) = self.document.as_mut() {
            document.dirty = dirty;
            let path = document.absolute_path.clone();
            cx.emit(EditorEvent::DirtyChanged { path, dirty });
        }
        cx.notify();
    }

    /// 执行工作台菜单或命令面板转发的命令。
    pub fn run_command(
        &mut self,
        command: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        use gpui_kit::base::input::{
            Copy, Cut, GoToDefinition, Paste, Redo, Replace, Search, SelectAll, ToggleCodeActions,
            Undo,
        };

        // 行级编辑操作：gpui-kit 编辑器没有对应 action，这里用
        // InputBaseState 的公开文本 API（selected_range / replace / insert）
        // 原生实现，每次操作在 undo 栈里算一步。
        match command {
            "editor.action.commentLine" => return self.toggle_line_comment(window, cx),
            "editor.action.copyLinesDownAction" => return self.duplicate_lines(window, cx),
            "editor.action.deleteLines" => return self.delete_lines(window, cx),
            "editor.action.moveLinesUpAction" => return self.move_lines(true, window, cx),
            "editor.action.moveLinesDownAction" => return self.move_lines(false, window, cx),
            _ => {}
        }

        let action: Option<Box<dyn gpui_kit::Action>> = match command {
            "undo" => Some(Box::new(Undo)),
            "redo" => Some(Box::new(Redo)),
            "editor.action.clipboardCutAction" => Some(Box::new(Cut)),
            "editor.action.clipboardCopyAction" => Some(Box::new(Copy)),
            "editor.action.clipboardPasteAction" => Some(Box::new(Paste)),
            "editor.action.selectAll" => Some(Box::new(SelectAll)),
            "actions.find" => Some(Box::new(Search)),
            "editor.action.startFindReplaceAction" => Some(Box::new(Replace)),
            "editor.action.revealDefinition" => Some(Box::new(GoToDefinition)),
            "editor.action.quickFix" => Some(Box::new(ToggleCodeActions)),
            _ => None,
        };
        let Some(action) = action else {
            return false;
        };
        self.focus(window, cx);
        window.dispatch_action(action, cx);
        true
    }

    /// 当前编辑器与选中行范围（0 起始，含端点）。
    /// 选区结尾恰好落在下一行行首时按 Monaco 语义排除该行。
    fn selected_line_range(&self, cx: &App) -> Option<(Entity<EditorState>, usize, usize)> {
        let editor = self.editor.clone()?;
        let (start_row, end_row) = editor.read_with(cx, |state, _| {
            let text = state.text();
            let selection = state.selected_range();
            let start = text.offset_to_point(text.offset_utf16_to_offset(selection.start));
            let mut end = text.offset_to_point(text.offset_utf16_to_offset(selection.end));
            if end.column == 0 && end.row > start.row {
                end.row -= 1;
            }
            (start.row as usize, end.row as usize)
        });
        Some((editor, start_row, end_row))
    }

    /// 用一次编辑替换字节区间；选区随后由调用方按需要恢复。
    fn replace_byte_range(
        editor: &Entity<EditorState>,
        range: std::ops::Range<usize>,
        replacement: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        editor.update(cx, |state, cx| {
            let start = state.text().offset_to_offset_utf16(range.start);
            let end = state.text().offset_to_offset_utf16(range.end);
            state.set_selected_range(start..end, cx);
            state.replace(replacement, window, cx);
        });
    }

    /// Edit > Toggle Comment：对选中行切换行注释。
    /// 全为非空白行已注释时去掉注释，否则统一加上；返回 false 表示该文件
    /// 类型没有可识别的行注释前缀。
    fn toggle_line_comment(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        let Some(prefix) = self.current_path().and_then(line_comment_prefix) else {
            return false;
        };
        let Some((editor, start_row, end_row)) = self.selected_line_range(cx) else {
            return false;
        };

        let (range, replacement, any_code) = editor.read_with(cx, |state, _| {
            let text = state.text();
            let lines: Vec<String> = (start_row..=end_row)
                .map(|row| text.slice_line(row).to_string())
                .collect();
            let any_code = lines.iter().any(|line| !line.trim().is_empty());
            let all_commented = any_code
                && lines.iter().all(|line| {
                    let body = line.trim_start();
                    body.is_empty() || body.starts_with(prefix)
                });
            let new_lines: Vec<String> = lines
                .iter()
                .map(|line| {
                    let indent_len = line.len() - line.trim_start().len();
                    let (indent, body) = line.split_at(indent_len);
                    if body.is_empty() {
                        return line.clone();
                    }
                    if all_commented {
                        // 去掉前缀与其后一个空格（如果有）。
                        let rest = &body[prefix.len()..];
                        let rest = rest.strip_prefix(' ').unwrap_or(rest);
                        format!("{indent}{rest}")
                    } else {
                        format!("{indent}{prefix} {body}")
                    }
                })
                .collect();
            let start = text.line_start_offset(start_row);
            let end = text.line_end_offset(end_row);
            (start..end, new_lines.join("\n"), any_code)
        });
        if !any_code {
            return true;
        }

        self.focus(window, cx);
        Self::replace_byte_range(&editor, range.clone(), &replacement, window, cx);
        // 恢复选中行，方便连续切换。
        editor.update(cx, |state, cx| {
            let start = state.text().offset_to_offset_utf16(range.start);
            let end = state
                .text()
                .offset_to_offset_utf16(range.start + replacement.len());
            state.set_selected_range(start..end, cx);
        });
        true
    }

    /// Edit > Duplicate Line：把选中行复制到原块正下方并选中副本。
    fn duplicate_lines(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        let Some((editor, start_row, end_row)) = self.selected_line_range(cx) else {
            return false;
        };
        let (insert_at, text_to_insert, copy_len) = editor.read_with(cx, |state, _| {
            let text = state.text();
            let block = text.slice_lines(start_row..end_row + 1).to_string();
            let end = text.line_end_offset(end_row);
            if block.ends_with('\n') {
                // 块自带换行：副本从下一行行首开始。
                (end + 1, block.clone(), block.len())
            } else {
                // 末行没有换行符：先补一个换行再接副本。
                (end, format!("\n{block}"), block.len())
            }
        });

        self.focus(window, cx);
        editor.update(cx, |state, cx| {
            let at = state.text().offset_to_offset_utf16(insert_at);
            state.set_selected_range(at..at, cx);
            state.insert(text_to_insert.as_str(), window, cx);
        });
        // 选中刚插入的副本（跳过为末行补上的换行符）。
        editor.update(cx, |state, cx| {
            let copy_start = insert_at + usize::from(text_to_insert.len() > copy_len);
            let start = state.text().offset_to_offset_utf16(copy_start);
            let end = state.text().offset_to_offset_utf16(copy_start + copy_len);
            state.set_selected_range(start..end, cx);
        });
        true
    }

    /// Edit > Delete Line：删除选中行（含换行），光标留在原行号处。
    fn delete_lines(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        let Some((editor, start_row, end_row)) = self.selected_line_range(cx) else {
            return false;
        };
        let range = editor.read_with(cx, |state, _| {
            let text = state.text();
            let lines_len = text.lines_len();
            if end_row + 1 < lines_len {
                text.line_start_offset(start_row)..text.line_start_offset(end_row + 1)
            } else if start_row > 0 {
                // 删到文件末尾：连同前一行的换行符一起删，不留空尾行。
                text.line_end_offset(start_row - 1)..text.len()
            } else {
                0..text.len()
            }
        });

        self.focus(window, cx);
        Self::replace_byte_range(&editor, range, "", window, cx);
        editor.update(cx, |state, cx| {
            let row = start_row.min(state.text().lines_len().saturating_sub(1));
            let offset = state.text().offset_to_offset_utf16(state.text().line_start_offset(row));
            state.set_selected_range(offset..offset, cx);
        });
        true
    }

    /// Edit > Move Line Up/Down：把选中行整体上移/下移一行并保持选中。
    fn move_lines(&mut self, up: bool, window: &mut Window, cx: &mut Context<Self>) -> bool {
        let Some((editor, start_row, end_row)) = self.selected_line_range(cx) else {
            return false;
        };
        let Some((range, replacement, block_len_rows, new_start_row)) = editor.read_with(cx, |state, _| {
            let text = state.text();
            let lines_len = text.lines_len();
            if up && start_row == 0 {
                return None;
            }
            if !up && end_row + 1 >= lines_len {
                return None;
            }
            let (region_start, region_end) = if up {
                (start_row - 1, end_row)
            } else {
                (start_row, end_row + 1)
            };
            let region = text.slice_lines(region_start..region_end + 1).to_string();
            let trailing_newline = region.ends_with('\n');
            let body = region.strip_suffix('\n').unwrap_or(&region);
            let lines: Vec<&str> = body.split('\n').collect();
            let block_rows = end_row - start_row + 1;
            let rotated: Vec<&str> = if up {
                // [prev, block...] -> [block..., prev]
                lines[1..].iter().chain(lines[..1].iter()).copied().collect()
            } else {
                // [block..., next] -> [next, block...]
                lines[block_rows..]
                    .iter()
                    .chain(lines[..block_rows].iter())
                    .copied()
                    .collect()
            };
            let mut replacement = rotated.join("\n");
            if trailing_newline {
                replacement.push('\n');
            }
            let start = text.line_start_offset(region_start);
            let end = if region_end + 1 < lines_len {
                text.line_start_offset(region_end + 1)
            } else {
                text.len()
            };
            let new_start = if up { start_row - 1 } else { start_row + 1 };
            Some((start..end, replacement, block_rows, new_start))
        }) else {
            // 已在首行/末行：边界 no-op 也算处理过。
            return true;
        };

        self.focus(window, cx);
        Self::replace_byte_range(&editor, range, &replacement, window, cx);
        editor.update(cx, |state, cx| {
            let text = state.text();
            let new_end_row = new_start_row + block_len_rows - 1;
            let start = text.offset_to_offset_utf16(text.line_start_offset(new_start_row));
            let end = text.offset_to_offset_utf16(text.line_end_offset(new_end_row));
            state.set_selected_range(start..end, cx);
        });
        true
    }

    /// Edit > Find Next（⌘G）：跳到当前查找会话的下一个匹配。
    ///
    /// 查找面板没有打开时直接返回：与 macOS「查找条可见才可查找下一个」
    /// 的语义一致，避免把编辑区凭空滚到某个不可见的匹配上。
    pub fn find_next(&mut self, cx: &mut Context<Self>) {
        self.navigate_search(true, cx);
    }

    /// Edit > Find Previous（⇧⌘G）：跳到当前查找会话的上一个匹配。
    pub fn find_previous(&mut self, cx: &mut Context<Self>) {
        self.navigate_search(false, cx);
    }

    /// 在两个查找导航方向之间共用同一套会话判断。
    fn navigate_search(&mut self, forward: bool, cx: &mut Context<Self>) {
        let Some(editor) = self.editor.clone() else {
            return;
        };
        editor.update(cx, |state, cx| {
            if !state.search_session().is_active() {
                return;
            }
            if forward {
                let _ = state.next_search_match(cx);
            } else {
                let _ = state.previous_search_match(cx);
            }
            cx.notify();
        });
        cx.notify();
    }

    /// Go to Line：把光标移到目标行行首（1 起始，超界收拢）并滚动到可见。
    pub fn go_to_line(&mut self, line: u32, window: &mut Window, cx: &mut Context<Self>) {
        let Some(editor) = self.editor.clone() else {
            return;
        };
        self.focus(window, cx);
        editor.update(cx, |state, cx| {
            let row = line
                .max(1)
                .saturating_sub(1)
                .min(state.text().lines_len().saturating_sub(1) as u32);
            state.set_cursor_position(Position::new(row, 0), window, cx);
        });
        self.reveal_line(line, window, cx);
    }

    /// 滚动到指定行（1-based）。
    pub fn reveal_line(&mut self, line: u32, _window: &mut Window, cx: &mut Context<Self>) {
        let Some(editor) = self.editor.clone() else {
            return;
        };
        let row_height = self.editor_font_size * 1.5;
        let offset = px(-((line.saturating_sub(1) as f32) * row_height));
        editor.update(cx, |state, cx| {
            state.set_scroll_offset(gpui_kit::point(px(0.0), offset), cx);
        });
    }

    /// 保存当前文件（File > Save）。
    pub fn save(&mut self, cx: &mut Context<Self>) {
        let text = self.editor_value(cx);
        self.save_text(text, cx, false);
    }

    /// 当前编辑器里的最新文本（包含尚未保存的修改）。
    pub fn current_text(&self, cx: &Context<Self>) -> String {
        self.editor_value(cx)
    }

    /// 读取任意已打开文档的未保存文本。
    ///
    /// 当前活动文档直接从编辑区取值，保证拿到最新输入；后台标签使用
    /// `texts` 缓存。`root` 必须与 `open_file` 时传入的工作区根一致，
    /// 文档身份才与缓存 key 相同。工作台的「保存全部」和关闭确认靠它
    /// 写盘，避免把后台标签的修改丢掉。
    pub fn cached_text(&self, root: &Path, path: &Path, cx: &Context<Self>) -> Option<String> {
        let (id, _, _) = document_identity(root, path);
        if self
            .document
            .as_ref()
            .is_some_and(|document| document.id == id)
        {
            return Some(self.editor_value(cx));
        }
        self.texts.get(&id).cloned()
    }

    /// 文档已写盘后同步编辑器状态，不触发“Saved”通知。
    ///
    /// 当前活动文档会清除脏标记；后台标签不在编辑区，只能更新它的文本
    /// 缓存，不能误改当前文档的脏状态。
    pub fn mark_saved(&mut self, path: &Path, text: String) {
        // 后台批保存（Save All / 关闭确认）也走这里：先登记自己的写盘，
        // 随后的 watcher 事件才不会被当成外部修改。
        self.record_self_write(path);
        let Some(document) = self.document.as_ref() else {
            return;
        };
        let root = document.root.clone();
        let (id, _, _) = document_identity(&root, path);
        if document.id != id {
            self.texts.insert(id, text);
            return;
        }
        if let Some(document) = self.document.as_mut() {
            document.dirty = false;
            let id = document.id.clone();
            self.dirty = false;
            // 成功的写盘要清掉上一次保存失败留下的错误条，也意味着用户选择
            // 了「保存覆盖」，磁盘冲突随之解决。
            self.disk_conflict = false;
            self.error = None;
            self.texts.insert(id, text);
        }
    }

    /// 另存为。
    pub fn save_as(&mut self, target: PathBuf, cx: &mut Context<Self>) {
        let text = self.editor_value(cx);
        let Some(document) = self.document.clone() else {
            return;
        };
        let from = document.absolute_path.clone();
        let write_target = target.clone();
        let write_text = text.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move {
                    (|| -> std::io::Result<()> {
                        if let Some(parent) = write_target
                            .parent()
                            .filter(|path| !path.as_os_str().is_empty())
                        {
                            std::fs::create_dir_all(parent)?;
                        }
                        std::fs::write(&write_target, write_text.as_bytes())
                    })()
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                match result {
                    Ok(()) => {
                        if let Some(document) = this.document.as_mut() {
                            document.absolute_path = target.clone();
                            document.dirty = false;
                        }
                        this.dirty = false;
                        this.disk_conflict = false;
                        this.error = None;
                        this.record_self_write(&target);
                        crate::local_history::record(&target, &text);
                        cx.emit(EditorEvent::SavedAs { from, to: target.clone() });
                    }
                    Err(error) => {
                        let message = error.to_string();
                        this.error = Some(SharedString::from(format!(
                            "{}: {message}",
                            tr("Save failed")
                        )));
                        cx.emit(EditorEvent::SaveFailed {
                            path: from,
                            message,
                        });
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 把键盘焦点交给编辑器。
    pub fn focus(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(editor) = self.editor.clone() {
            editor.update(cx, |state, cx| state.focus(window, cx));
        }
    }

    /// 切换只读模式（分屏副窗格用）。
    pub fn set_readonly(&mut self, readonly: bool, cx: &mut Context<Self>) {
        if let Some(document) = self.document.as_mut() {
            document.readonly = readonly;
        }
        if let Some(editor) = self.editor.clone() {
            editor.update(cx, |state, cx| state.set_readonly(readonly, cx));
        }
        cx.notify();
    }

    fn create_editor(
        &mut self,
        path: &Path,
        text: String,
        readonly: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let language = language_for(path);
        let value = text.clone();
        let line_numbers = self.editor_line_numbers;
        let soft_wrap = self.editor_wrap;
        let show_whitespaces = self.editor_render_whitespace;
        let tab_size = self.editor_tab_size;
        let scroll_beyond = self.editor_scroll_beyond_last_line;
        let auto_completion = self.auto_completion;

        let state = cx.new(|cx| {
            let mut state = EditorState::new(window, cx)
                .line_number(line_numbers)
                .folding(true)
                .soft_wrap(soft_wrap)
                .show_whitespaces(show_whitespaces)
                .scroll_beyond_last_line(scroll_beyond.then_some(1))
                .tab_size(TabSize {
                    tab_size: tab_size as usize,
                    hard_tabs: false,
                })
                .default_value(value);
            if let Some(language) = language {
                state = state.language(language);
            }
            state
        });

        let path_text = path.to_string_lossy().into_owned();
        state.update(cx, |state, cx| {
            if auto_completion {
                state.lsp_mut().completion_provider =
                    Some(Rc::new(CoreLspProvider::new(path_text.clone())));
            }
            state.lsp_mut().hover_provider = Some(Rc::new(CoreLspProvider::new(path_text.clone())));
            state.lsp_mut().definition_provider =
                Some(Rc::new(CoreLspProvider::new(path_text.clone())));
            state.set_readonly(readonly, cx);
            cx.notify();
        });

        let subscription = cx.subscribe(
            &state,
            |this: &mut EditorSurface, state, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) {
                    this.dirty = true;
                    if let Some(document) = this.document.as_mut() {
                        document.dirty = true;
                        let path = document.absolute_path.clone();
                        cx.emit(EditorEvent::DirtyChanged { path, dirty: true });
                    }
                    if let Some((line, column)) = cursor_position(&state, cx) {
                        this.cursor_line = line;
                        this.cursor_column = column;
                        cx.emit(EditorEvent::CursorChanged { line, column });
                    }
                    cx.notify();
                }
            },
        );

        self.editor = Some(state);
        self.subscription = Some(subscription);
        if let Some(document) = self.document.as_ref() {
            let id = document.id.clone();
            self.texts.insert(id, text);
        }
    }

    fn set_editor_value(&mut self, text: String, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(editor) = self.editor.clone() {
            editor.update(cx, |state, cx| state.set_value(text, window, cx));
        }
    }

    fn editor_value(&self, cx: &Context<Self>) -> String {
        self.editor
            .as_ref()
            .map(|editor| editor.read(cx).value().to_string())
            .unwrap_or_default()
    }

    fn flush_current_text(&mut self, cx: &Context<Self>) {
        let Some(document) = self.document.as_ref() else {
            return;
        };
        let id = document.id.clone();
        let text = self.editor_value(cx);
        if !text.is_empty() || self.texts.contains_key(&id) {
            self.texts.insert(id, text);
        }
    }

    fn apply_view_options(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(editor) = self.editor.clone() {
            let wrap = self.editor_wrap;
            let line_numbers = self.editor_line_numbers;
            let show_whitespaces = self.editor_render_whitespace;
            let scroll_beyond = self.editor_scroll_beyond_last_line;
            editor.update(cx, |state, cx| {
                state.set_soft_wrap(wrap, window, cx);
                state.set_line_number(line_numbers, window, cx);
                state.set_show_whitespaces(show_whitespaces, window, cx);
                state.set_scroll_beyond_last_line(scroll_beyond.then_some(1), window, cx);
            });
        }
        cx.notify();
    }

    fn update_view_options(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.apply_view_options(window, cx);
    }

    fn save_text(&mut self, text: String, cx: &mut Context<Self>, _save_as: bool) {
        let Some(document) = self.document.clone() else {
            return;
        };
        let root = document.root.clone();
        let relative = document.relative.clone();
        let path = document.absolute_path.clone();
        cx.spawn(async move |this, cx| {
            let (result, text) = cx
                .background_spawn(async move {
                    let result = CoreClient::new().write_file(&root, &relative, &text);
                    (result, text)
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                match result {
                    Ok(_) => {
                        if let Some(document) = this.document.as_mut() {
                            document.dirty = false;
                        }
                        this.dirty = false;
                        this.disk_conflict = false;
                        this.error = None;
                        this.record_self_write(&path);
                        crate::local_history::record(&path, &text);
                        cx.emit(EditorEvent::Saved { path: path.clone() });
                    }
                    Err(error) => {
                        let message = error.to_string();
                        this.error = Some(SharedString::from(format!(
                            "{}: {message}",
                            tr("Save failed")
                        )));
                        cx.emit(EditorEvent::SaveFailed {
                            path: path.clone(),
                            message,
                        });
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
}

impl Render for EditorSurface {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let tokens = current_tokens(cx);
        let error = self.error.clone();
        let font_size = self.editor_font_size;
        let font_family = self
            .editor_font_family
            .clone()
            .map(SharedString::from)
            .unwrap_or_else(|| SharedString::from(MONO_FONT_FAMILY));

        let content = match self.editor.as_ref() {
            Some(editor) => Editor::new(editor)
                .font_family(font_family)
                .text_size(px(font_size))
                .h_full()
                .into_any_element(),
            None => div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .px(px(16.0))
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(tr("No file open"))
                .into_any_element(),
        };

        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(tokens.editor)
            .when_some(error, |this, error| this.child(error_strip(error, tokens)))
            .child(div().flex_1().min_h(px(0.0)).child(content))
    }
}

/// 构建期/运行期错误条。
fn error_strip(message: SharedString, tokens: LitheTokens) -> impl IntoElement {
    div()
        .w_full()
        .flex_shrink_0()
        .px(px(10.0))
        .py(px(6.0))
        .bg(tokens.raised)
        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
        .text_color(tokens.error)
        .child(message)
}

/// Core 轻量 LSP 的 GPUI provider。
#[derive(Clone)]
struct CoreLspProvider {
    path: String,
}

impl CoreLspProvider {
    fn new(path: String) -> Self {
        Self { path }
    }
}

impl CompletionProvider for CoreLspProvider {
    fn completions(
        &self,
        text: &Rope,
        offset: usize,
        _trigger: lsp_types::CompletionContext,
        _window: &mut Window,
        cx: &mut App,
    ) -> Task<Result<CompletionResponse>> {
        let path = self.path.clone();
        let source = text.to_string();
        let (line, column) = core_position(text, offset);
        cx.background_spawn(async move {
            let value = CoreClient::new()
                .execute_raw(
                    "lsp.builtinCompletions",
                    json!({
                        "filePath": path,
                        "text": source,
                        "position": { "line": line, "utf16Column": column },
                    }),
                )
                .map_err(|error| anyhow::anyhow!(error.to_string()))?;
            let items = value
                .get("items")
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(completion_item)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            Ok(CompletionResponse::Array(items))
        })
    }

    fn is_completion_trigger(&self, _offset: usize, new_text: &str, _cx: &mut App) -> bool {
        new_text
            .chars()
            .last()
            .is_some_and(|character| character.is_alphanumeric() || character == '_' || character == '.')
    }
}

impl HoverProvider for CoreLspProvider {
    fn hover(
        &self,
        text: &Rope,
        offset: usize,
        _window: &mut Window,
        cx: &mut App,
    ) -> Task<Result<Option<Hover>>> {
        let path = self.path.clone();
        let source = text.to_string();
        let (line, column) = core_position(text, offset);
        cx.background_spawn(async move {
            let value = CoreClient::new()
                .execute_raw(
                    "lsp.builtinHover",
                    json!({
                        "filePath": path,
                        "text": source,
                        "position": { "line": line, "utf16Column": column },
                    }),
                )
                .map_err(|error| anyhow::anyhow!(error.to_string()))?;
            let Some(hover) = value.get("hover").filter(|value| !value.is_null()) else {
                return Ok(None);
            };
            let contents = hover
                .get("contents")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            let is_markdown = hover
                .get("isMarkdown")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            Ok(Some(Hover {
                contents: HoverContents::Markup(MarkupContent {
                    kind: if is_markdown {
                        MarkupKind::Markdown
                    } else {
                        MarkupKind::PlainText
                    },
                    value: contents,
                }),
                range: hover.get("range").and_then(core_range),
            }))
        })
    }
}

impl DefinitionProvider for CoreLspProvider {
    fn definitions(
        &self,
        text: &Rope,
        offset: usize,
        _window: &mut Window,
        cx: &mut App,
    ) -> Task<Result<Vec<LocationLink>>> {
        let path = self.path.clone();
        let source = text.to_string();
        let (line, column) = core_position(text, offset);
        cx.background_spawn(async move {
            let value = CoreClient::new()
                .execute_raw(
                    "lsp.builtinNavigation",
                    json!({
                        "filePath": path,
                        "text": source,
                        "method": "textDocument/definition",
                        "position": { "line": line, "utf16Column": column },
                    }),
                )
                .map_err(|error| anyhow::anyhow!(error.to_string()))?;
            let locations = value
                .get("locations")
                .and_then(Value::as_array)
                .map(|locations| {
                    locations
                        .iter()
                        .filter_map(location_link)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            Ok(locations)
        })
    }
}

fn completion_item(value: &Value) -> Option<CompletionItem> {
    let label = value.get("label")?.as_str()?.to_string();
    let insert_text = value
        .get("insertText")
        .and_then(Value::as_str)
        .unwrap_or(&label)
        .to_string();
    let kind = value
        .get("kind")
        .and_then(Value::as_i64)
        .and_then(completion_kind);
    let detail = value
        .get("detail")
        .and_then(Value::as_str)
        .map(str::to_string);
    Some(CompletionItem {
        label,
        kind,
        detail,
        insert_text: Some(insert_text),
        ..CompletionItem::default()
    })
}

fn completion_kind(value: i64) -> Option<CompletionItemKind> {
    let kind = u32::try_from(value).ok()?;
    Some(match kind {
        1 => CompletionItemKind::TEXT,
        2 => CompletionItemKind::METHOD,
        3 => CompletionItemKind::FUNCTION,
        4 => CompletionItemKind::CONSTRUCTOR,
        5 => CompletionItemKind::FIELD,
        6 => CompletionItemKind::VARIABLE,
        7 => CompletionItemKind::CLASS,
        8 => CompletionItemKind::INTERFACE,
        9 => CompletionItemKind::MODULE,
        10 => CompletionItemKind::PROPERTY,
        11 => CompletionItemKind::UNIT,
        12 => CompletionItemKind::VALUE,
        13 => CompletionItemKind::ENUM,
        14 => CompletionItemKind::KEYWORD,
        15 => CompletionItemKind::SNIPPET,
        16 => CompletionItemKind::COLOR,
        17 => CompletionItemKind::FILE,
        18 => CompletionItemKind::REFERENCE,
        19 => CompletionItemKind::FOLDER,
        20 => CompletionItemKind::ENUM_MEMBER,
        21 => CompletionItemKind::CONSTANT,
        22 => CompletionItemKind::STRUCT,
        23 => CompletionItemKind::EVENT,
        24 => CompletionItemKind::OPERATOR,
        25 => CompletionItemKind::TYPE_PARAMETER,
        _ => return None,
    })
}

fn location_link(value: &Value) -> Option<LocationLink> {
    let path = value
        .get("filePath")
        .or_else(|| value.get("displayPath"))?
        .as_str()?;
    let range = value.get("range").and_then(core_range)?;
    let uri = file_uri(path)?;
    Some(LocationLink {
        target_uri: uri,
        target_range: range,
        target_selection_range: range,
        origin_selection_range: None,
    })
}

/// 把平台路径转成 LSP 的 `file:` URI。
fn file_uri(path: &str) -> Option<lsp_types::Uri> {
    let normalized = path.replace('\\', "/");
    let uri = if normalized.starts_with('/') {
        format!("file://{normalized}")
    } else {
        format!("file:///{normalized}")
    };
    uri.parse().ok()
}

fn core_range(value: &Value) -> Option<lsp_types::Range> {
    Some(lsp_types::Range {
        start: core_position_value(value.get("start")?)?,
        end: core_position_value(value.get("end")?)?,
    })
}

fn core_position_value(value: &Value) -> Option<Position> {
    let character = value
        .get("character")
        .or_else(|| value.get("utf16Column"))?
        .as_u64()?;
    Some(Position {
        line: u32::try_from(value.get("line")?.as_u64()?).ok()?,
        character: u32::try_from(character).ok()?,
    })
}

/// 把 GPUI 的字节偏移换算成 Core 需要的 UTF-16 行列。
fn core_position(text: &Rope, offset: usize) -> (u64, u64) {
    let point = text.offset_to_point(offset);
    let line = text.slice_line(point.row).to_string();
    let end = point.column.min(line.len());
    let column = line[..end].encode_utf16().count();
    (point.row as u64, column as u64)
}

/// 当前光标行列，1-based。
fn cursor_position(state: &Entity<EditorState>, cx: &Context<EditorSurface>) -> Option<(u32, u32)> {
    let state = state.read(cx);
    let rope = state.text();
    let selection = state.selected_range();
    let offset = rope.offset_utf16_to_offset(selection.start);
    let point = rope.offset_to_point(offset);
    let line = rope.slice_line(point.row).to_string();
    let end = point.column.min(line.len());
    let column = line[..end].chars().count();
    Some((point.row as u32 + 1, column as u32 + 1))
}

/// 行注释前缀；返回 None 表示该扩展名没有单行注释或暂未识别
/// （CSS/HTML/Markdown 等需要块注释，不在 Toggle Comment 的范围内）。
fn line_comment_prefix(path: &Path) -> Option<&'static str> {
    let extension = path.extension()?.to_str()?;
    match extension {
        "java" | "js" | "jsx" | "ts" | "tsx" | "json" | "jsonc" | "rs" | "go" | "c" | "h"
        | "cpp" | "hpp" | "cs" | "kt" | "kts" | "swift" | "php" | "scala" | "less" => Some("//"),
        "py" | "rb" | "sh" | "bash" | "zsh" | "yaml" | "yml" | "toml" | "pl" | "ps1" => Some("#"),
        "sql" | "lua" => Some("--"),
        _ => None,
    }
}

fn path_text(document: &Option<DocumentState>) -> String {
    document
        .as_ref()
        .map(|document| document.absolute_path.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// 工作区相对路径与绝对路径。
fn document_identity(root: &Path, path: &Path) -> (String, String, PathBuf) {
    let absolute_path = if path.is_absolute() {
        normalize_path(path)
    } else {
        normalize_path(&root.join(path))
    };
    let relative = absolute_path
        .strip_prefix(root)
        .ok()
        .map(|value| value.to_string_lossy().replace('\\', "/"))
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| absolute_path.to_string_lossy().replace('\\', "/"));
    (relative.clone(), relative, absolute_path)
}

fn normalize_path(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
}

fn same_path(left: &Path, right: &Path) -> bool {
    let left = normalize_path(left);
    let right = normalize_path(right);
    if cfg!(windows) {
        left.to_string_lossy()
            .eq_ignore_ascii_case(&right.to_string_lossy())
    } else {
        left == right
    }
}

/// 文件身份：折叠 `./`/`..` 与分隔符，Windows 上再忽略大小写。
///
/// watcher 给的路径和编辑器记录的路径可能大小写、分隔符不同，比较前必须
/// 收敛成同一个 key，否则同一文件会被当成两个。
fn path_identity(path: &Path) -> String {
    let normalised = normalize_path(path).to_string_lossy().replace('\\', "/");
    if cfg!(windows) {
        normalised.to_lowercase()
    } else {
        normalised
    }
}

/// 文件扩展名对应的 gpui-kit tree-sitter 语言名。
fn language_for(path: &Path) -> Option<&'static str> {
    let extension = path.extension()?.to_str()?.to_ascii_lowercase();
    Some(match extension.as_str() {
        "java" => "java",
        "ts" => "typescript",
        "tsx" => "tsx",
        "js" | "mjs" | "cjs" => "javascript",
        "json" | "jsonc" => "json",
        "yaml" | "yml" => "yaml",
        "toml" => "toml",
        "rs" => "rust",
        "py" | "pyi" => "python",
        "go" => "go",
        "php" => "php",
        "md" | "markdown" => "markdown",
        "html" | "htm" => "html",
        "css" => "css",
        "sh" | "bash" => "bash",
        "sql" => "sql",
        "c" | "h" => "c",
        "cpp" | "cc" | "cxx" | "hpp" => "cpp",
        "cs" => "csharp",
        "kt" | "kts" => "kotlin",
        "rb" => "ruby",
        "lua" => "lua",
        "swift" => "swift",
        "dockerfile" => "bash",
        _ => return None,
    })
}
