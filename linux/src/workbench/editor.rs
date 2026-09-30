use gpui_kit::assets::IconName;
use gpui_kit::base::input::{InputContextMenuCapabilities, NativeMenu};
use gpui_kit::base::ElementExt as _;
use gpui_kit::component::input::{Editor, EditorState, InputEvent, Position};
use gpui_kit::component::menu::{ContextMenuExt as _, PopupMenu};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, relative, AppContext as _, ClipboardItem, Context, DismissEvent, Entity, EventEmitter,
    Focusable as _, FontWeight, InteractiveElement as _, IntoElement, KeyDownEvent,
    ParentElement as _, Pixels, Point, Render, StatefulInteractiveElement as _, Styled as _,
    Subscription, Task, WeakEntity, Window,
};

use std::collections::HashMap;
use std::rc::Rc;
use std::time::Duration;

use super::panes::PaneId;
use super::tab_menu::{SplitCallback, ToggleLockCallback};

use crate::core::CoreClient;
use crate::settings;
use crate::theme::ThemeColors;

/// 与 Windows 编辑器一致的自动保存防抖窗口。
const AUTO_SAVE_DELAY: Duration = Duration::from_millis(150);

/// 单个文档的自动保存任务状态。
///
/// 每个文档只保留一个前台任务。连续编辑只推进修订号并重置防抖标记，不创建
/// 并行写盘任务；旧快照写盘后若修订号已变化，当前任务继续保存最新内容。
struct AutoSaveState {
    revision: u64,
    running: bool,
    debounce_requested: bool,
    task: Option<Task<()>>,
}

impl AutoSaveState {
    fn request(&mut self) {
        self.revision = self.revision.wrapping_add(1);
        self.debounce_requested = true;
    }

    fn take_debounce(&mut self) -> bool {
        let requested = self.debounce_requested;
        self.debounce_requested = false;
        requested
    }
}

/// 编辑区右键菜单的临时状态。
///
/// Linux 的 `NativeMenu` fallback 会把焦点移到 `PopupMenu`，上游编辑器因此
/// 隐藏选区。这里复用同一个官方菜单与动作，但不让菜单取得编辑器焦点。
struct EditorContextMenu {
    menu: Entity<PopupMenu>,
    position: Point<Pixels>,
    _subscription: Subscription,
}

#[derive(Debug, Clone)]
pub struct EditorTab {
    pub path: String,
    pub title: String,
    pub content: String,
    pub is_dirty: bool,
    /// 固定标签：批量关闭跳过，固定组永远排在标签栏前段。
    pub is_pinned: bool,
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
    /// 按文档路径隔离自动保存任务，避免切换标签或连续编辑产生并行写入。
    auto_saves: HashMap<String, AutoSaveState>,
    client: CoreClient,
    /// 撤销/重做历史（全文快照，栈顶恒等于编辑器当前值）。
    undo_stack: Vec<String>,
    redo_stack: Vec<String>,
    /// 已关闭标签（标签快照，原索引），后进先出供恢复。
    closed_stack: Vec<(EditorTab, usize)>,
    /// 右键菜单目标标签（UI 层读写，方法层不消费）。
    pub context_menu_tab: Option<usize>,
    /// 编辑区正文右键菜单；保持编辑器焦点，避免 Linux fallback 隐藏选区。
    editor_context_menu: Option<EditorContextMenu>,
    /// 所属窗格（工作台装配；`None` 时右键菜单用 0 与空回调兜底）。
    pub pane_id: Option<PaneId>,
    /// 所属窗格锁定镜像（工作台回写，决定锁定项文案）。
    pub pane_locked: bool,
    /// 拆分回调（工作台注入，经 workbench entity 回写）。
    pub on_split: Option<SplitCallback>,
    /// 锁定回调（工作台注入，经 workbench entity 回写）。
    pub on_toggle_lock: Option<ToggleLockCallback>,
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
            auto_saves: HashMap::new(),
            client: CoreClient::new(),
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            closed_stack: Vec::new(),
            context_menu_tab: None,
            editor_context_menu: None,
            pane_id: None,
            pane_locked: false,
            on_split: None,
            on_toggle_lock: None,
        }
    }

    /// 为活动文档安排自动保存；关闭自动保存或关闭文档时取消对应任务。
    fn schedule_active_auto_save(&mut self, cx: &mut Context<Self>) {
        let Some(path) = self
            .active_tab_index
            .and_then(|index| self.tabs.get(index).map(|tab| tab.path.clone()))
        else {
            return;
        };
        self.schedule_auto_save(path, cx);
    }

    /// 按文档修订启动唯一的自动保存任务。
    ///
    /// 防抖阶段不取消正在等待的任务，而是由下一次循环重新计时；写入阶段保持
    /// 同一个任务串行执行，确保新修订不会与旧快照并行落盘。
    fn schedule_auto_save(&mut self, path: String, cx: &mut Context<Self>) {
        if !settings::get(cx).auto_save {
            self.cancel_auto_save(&path);
            return;
        }

        let should_start = match self.auto_saves.entry(path.clone()) {
            std::collections::hash_map::Entry::Occupied(mut entry) => {
                let state = entry.get_mut();
                state.request();
                !state.running
            }
            std::collections::hash_map::Entry::Vacant(entry) => {
                let mut state = AutoSaveState {
                    revision: 0,
                    running: false,
                    debounce_requested: false,
                    task: None,
                };
                state.request();
                entry.insert(state);
                true
            }
        };
        if !should_start {
            return;
        }
        if let Some(state) = self.auto_saves.get_mut(&path) {
            state.running = true;
        }

        let root = self.workspace_root.clone();
        let client = self.client.clone();
        let worker_path = path.clone();
        let task = cx.spawn(async move |this, cx| loop {
            let should_debounce = this
                .update(cx, |editor, cx| {
                    if !editor.auto_saves.contains_key(&worker_path) {
                        return None;
                    }
                    if !settings::get(cx).auto_save {
                        if let Some(state) = editor.auto_saves.get_mut(&worker_path) {
                            state.running = false;
                        }
                        return None;
                    }
                    let Some(tab) = editor.tabs.iter().find(|tab| tab.path == worker_path) else {
                        if let Some(state) = editor.auto_saves.get_mut(&worker_path) {
                            state.running = false;
                        }
                        return None;
                    };
                    if !tab.is_dirty {
                        if let Some(state) = editor.auto_saves.get_mut(&worker_path) {
                            state.running = false;
                        }
                        return None;
                    }
                    let Some(state) = editor.auto_saves.get_mut(&worker_path) else {
                        return None;
                    };
                    Some(state.take_debounce())
                })
                .unwrap_or(None);
            let Some(should_debounce) = should_debounce else {
                break;
            };
            if should_debounce {
                cx.background_executor().timer(AUTO_SAVE_DELAY).await;
                continue;
            }

            let snapshot = this
                .update(cx, |editor, cx| {
                    if !settings::get(cx).auto_save {
                        return None;
                    }
                    let state = editor.auto_saves.get(&worker_path)?;
                    let tab = editor.tabs.iter().find(|tab| tab.path == worker_path)?;
                    if !tab.is_dirty {
                        return None;
                    }
                    let text = editor
                        .active_tab_index
                        .and_then(|index| editor.tabs.get(index))
                        .filter(|active| active.path == worker_path)
                        .map(|_| editor.editor_state.read(cx).value().to_string())
                        .unwrap_or_else(|| tab.content.clone());
                    Some((state.revision, text))
                })
                .unwrap_or(None);
            let Some((revision, text)) = snapshot else {
                let _ = this.update(cx, |editor, _| {
                    if let Some(state) = editor.auto_saves.get_mut(&worker_path) {
                        state.running = false;
                    }
                });
                break;
            };

            let result = client.write_file(&cx, &root, &worker_path, &text).await;
            let should_continue = this
                .update(cx, |editor, cx| {
                    let active_has_newer_text = editor
                        .active_tab_index
                        .and_then(|index| editor.tabs.get(index))
                        .filter(|active| active.path == worker_path)
                        .is_some_and(|_| editor.editor_state.read(cx).value().to_string() != text);
                    let Some(state) = editor.auto_saves.get_mut(&worker_path) else {
                        return false;
                    };
                    let Some(tab) = editor.tabs.iter_mut().find(|tab| tab.path == worker_path)
                    else {
                        state.running = false;
                        return false;
                    };

                    if let Err(error) = &result {
                        tracing::error!(
                            path = %worker_path,
                            error = %error,
                            "automatic file save failed"
                        );
                    } else if tab.content == text && !active_has_newer_text {
                        tab.is_dirty = false;
                    }

                    let content_changed = tab.content != text || active_has_newer_text;
                    let newer_revision = state.revision != revision;
                    if result.is_ok() && (content_changed || newer_revision) {
                        state.debounce_requested = true;
                        true
                    } else {
                        state.running = false;
                        false
                    }
                })
                .unwrap_or(false);
            if !should_continue {
                break;
            }
        });
        if let Some(state) = self.auto_saves.get_mut(&path) {
            state.task = Some(task);
        }
    }

    /// 取消指定文档的自动保存任务。
    pub fn cancel_auto_save(&mut self, path: &str) {
        self.auto_saves.remove(path);
    }

    /// 清理已关闭文档的自动保存任务。
    fn retain_auto_save_states(&mut self) {
        self.auto_saves
            .retain(|path, _| self.tabs.iter().any(|tab| tab.path == *path));
    }

    /// 打开文件，如果已在标签中则切换，否则新增标签
    pub fn open_file(&mut self, path: String, content: String, cx: &mut Context<Self>) {
        if let Some(pos) = self.tabs.iter().position(|t| t.path == path) {
            if self.tabs[pos].content != content {
                self.cancel_auto_save(&self.tabs[pos].path.clone());
                if let Some(tab) = self.tabs.get_mut(pos) {
                    tab.content = content;
                    tab.is_dirty = false;
                }
                self.sync_needed = true;
            }
            self.active_tab_index = Some(pos);
            self.publish_active_document(cx);
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
            is_pinned: false,
            cursor_line: 1,
            cursor_col: 1,
        });

        self.active_tab_index = Some(self.tabs.len() - 1);
        self.sync_needed = true;
        self.publish_active_document(cx);
        cx.notify();
    }

    /// 关闭指定索引的标签页
    pub fn close_tab(&mut self, index: usize, cx: &mut Context<Self>) {
        if index < self.tabs.len() {
            self.record_closed(index);
            self.tabs.remove(index);
            self.retain_auto_save_states();
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
        // 上游 `Language::from_name` 只认 `bash`/`sh`，`language_name` 的 `Shell`
        // 转小写后是 `shell`，此处映射回 `sh` 否则高亮回退到 Plain。
        let language = if language == "shell" {
            "sh"
        } else {
            language.as_str()
        };
        let content = tab.content.clone();
        self.editor_state.update(cx, |editor, cx| {
            editor.set_value(content, window, cx);
            editor.set_highlighter(language, cx);
        });

        self.synced_tab = Some(index);
        self.sync_needed = false;
        self.publish_active_document(cx);
    }

    /// 向父视图广播当前活动文档（无活动标签时不广播）。
    fn publish_active_document(&mut self, cx: &mut Context<Self>) {
        let Some(tab) = self.active_tab_index.and_then(|index| self.tabs.get(index)) else {
            return;
        };
        cx.emit(EditorTabEvent::DocumentChanged {
            path: tab.path.clone(),
            text: tab.content.clone(),
        });
    }

    /// 编辑器文本变化后回写标签内容并标记为已修改。
    fn on_editor_change(&mut self, cx: &mut Context<Self>) {
        let Some(index) = self.active_tab_index else {
            return;
        };

        let value = self.editor_state.read(cx).value().to_string();
        let mut changed = false;
        if let Some(tab) = self.tabs.get_mut(index) {
            if tab.content != value {
                tab.content = value.clone();
                tab.is_dirty = true;
                changed = true;
            }
        }
        if changed {
            self.schedule_active_auto_save(cx);
        }
        if self.undo_stack.last().is_none_or(|top| *top != value) {
            self.undo_stack.push(value);
            if self.undo_stack.len() > 100 {
                let overflow = self.undo_stack.len() - 100;
                self.undo_stack.drain(..overflow);
            }
            self.redo_stack.clear();
        }
        self.publish_active_document(cx);
        cx.notify();
    }

    /// 返回当前活动文件路径，供 Run 构造 Current File 请求。
    pub fn active_file_path(&self) -> Option<String> {
        let index = self.active_tab_index?;
        self.tabs.get(index).map(|tab| tab.path.clone())
    }

    /// 保存当前活动的标签页至磁盘（对接 `file.write`）。
    pub fn save_active(&mut self, cx: &mut Context<Self>) {
        self.save_active_task(cx).detach();
    }

    /// Run 前等待保存完成；错误原样返回给启动工作流。
    pub fn save_active_task(
        &mut self,
        cx: &mut Context<Self>,
    ) -> gpui_kit::Task<Result<(), String>> {
        let Some(idx) = self.active_tab_index else {
            return cx.spawn(async move |_this, _cx| Ok(()));
        };
        let Some(tab) = self.tabs.get(idx) else {
            return cx.spawn(async move |_this, _cx| Ok(()));
        };
        if !tab.is_dirty {
            return cx.spawn(async move |_this, _cx| Ok(()));
        }

        // 以编辑器内的实时文本为准，避免依赖事件回写的时序。
        let text = self.editor_state.read(cx).value().to_string();
        let root = self.workspace_root.clone();
        let path = tab.path.clone();
        let client = self.client.clone();
        cx.spawn(async move |this, cx| {
            client.write_file(&cx, &root, &path, &text).await?;
            let _ = this.update(cx, |ed, cx| {
                let active_has_newer_text = ed
                    .active_tab_index
                    .and_then(|index| ed.tabs.get(index))
                    .filter(|active| active.path == path)
                    .is_some_and(|_| ed.editor_state.read(cx).value().to_string() != text);
                if let Some(tab) = ed.tabs.iter_mut().find(|tab| tab.path == path) {
                    if tab.content == text && !active_has_newer_text {
                        tab.is_dirty = false;
                    }
                }
                cx.notify();
            });
            Ok(())
        })
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
        self.schedule_active_auto_save(cx);
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
        self.schedule_active_auto_save(cx);
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
        self.schedule_active_auto_save(cx);
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

    /// 打开编辑区正文右键菜单。
    ///
    /// gpui-kit 的 Linux `NativeMenu` fallback 会聚焦 `PopupMenu`，从而让上游
    /// `Editor` 的选区绘制条件失效。这里复用官方 `PopupMenu` 和编辑动作，但
    /// 不把焦点交给菜单，编辑器因此持续绘制原有蓝色选区。
    fn open_editor_context_menu(
        &mut self,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.active_tab_index.is_none() {
            return;
        }

        let editor_focus = self
            .editor_state
            .read(cx)
            .presentation()
            .focus_handle()
            .clone();
        let capabilities = self.editor_state.read(cx).context_menu_capabilities();
        let menu = PopupMenu::build(window, cx, move |menu, _window, cx| {
            build_editor_context_menu(menu, cx, capabilities).action_context(editor_focus)
        });
        let subscription = cx.subscribe(&menu, |this, _, _: &DismissEvent, cx| {
            this.editor_context_menu = None;
            cx.notify();
        });
        self.editor_context_menu = Some(EditorContextMenu {
            menu,
            position,
            _subscription: subscription,
        });
        cx.notify();
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

    /// 关闭全部标签（逐个进恢复栈；固定标签保留）。
    pub fn close_all_tabs(&mut self, cx: &mut Context<Self>) {
        if self.tabs.is_empty() {
            return;
        }
        let active_path = self
            .active_tab_index
            .and_then(|index| self.tabs.get(index))
            .map(|tab| tab.path.clone());
        let mut kept = Vec::new();
        for (index, tab) in self.tabs.drain(..).enumerate() {
            if tab.is_pinned {
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
        self.retain_auto_save_states();
        self.active_tab_index =
            active_path.and_then(|path| self.tabs.iter().position(|tab| tab.path == path));
        self.sync_needed = true;
        cx.notify();
    }

    /// 关闭除活动标签外的全部标签（固定标签保留，固定组在前）。
    pub fn close_other_tabs(&mut self, cx: &mut Context<Self>) {
        let Some(active) = self.active_tab_index else {
            return;
        };
        if active >= self.tabs.len() {
            return;
        }
        let active_path = self.tabs.get(active).map(|tab| tab.path.clone());
        let mut kept: Vec<(usize, EditorTab)> = Vec::new();
        for (index, tab) in self.tabs.drain(..).enumerate() {
            if index == active || tab.is_pinned {
                kept.push((index, tab));
            } else {
                self.closed_stack.push((tab, index));
            }
        }
        if self.closed_stack.len() > 30 {
            let overflow = self.closed_stack.len() - 30;
            self.closed_stack.drain(..overflow);
        }
        // 固定组在前并保持原相对顺序。
        kept.sort_by_key(|(index, tab)| (!tab.is_pinned, *index));
        self.tabs = kept.into_iter().map(|(_, tab)| tab).collect();
        self.retain_auto_save_states();
        self.active_tab_index =
            active_path.and_then(|path| self.tabs.iter().position(|tab| tab.path == path));
        self.sync_needed = true;
        cx.notify();
    }

    /// 关闭全部未修改（`is_dirty == false`）的标签（固定标签保留）。
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
            if tab.is_dirty || tab.is_pinned {
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
        self.retain_auto_save_states();
        self.active_tab_index =
            active_path.and_then(|path| self.tabs.iter().position(|tab| tab.path == path));
        self.sync_needed = true;
        cx.notify();
    }

    /// 关闭活动标签左侧的全部标签（固定标签保留在前段）。
    pub fn close_tabs_to_left(&mut self, cx: &mut Context<Self>) {
        let Some(active) = self.active_tab_index else {
            return;
        };
        if active == 0 || active >= self.tabs.len() {
            return;
        }
        let active_path = self.tabs.get(active).map(|tab| tab.path.clone());
        let mut pinned_left: Vec<EditorTab> = Vec::new();
        for (index, tab) in self.tabs.drain(..active).enumerate() {
            if tab.is_pinned {
                pinned_left.push(tab);
            } else {
                self.closed_stack.push((tab, index));
            }
        }
        if self.closed_stack.len() > 30 {
            let overflow = self.closed_stack.len() - 30;
            self.closed_stack.drain(..overflow);
        }
        for (offset, tab) in pinned_left.into_iter().enumerate() {
            self.tabs.insert(offset, tab);
        }
        self.retain_auto_save_states();
        self.active_tab_index =
            active_path.and_then(|path| self.tabs.iter().position(|tab| tab.path == path));
        self.sync_needed = true;
        cx.notify();
    }

    /// 关闭活动标签右侧的全部标签（固定标签保留）。
    pub fn close_tabs_to_right(&mut self, cx: &mut Context<Self>) {
        let Some(active) = self.active_tab_index else {
            return;
        };
        if active >= self.tabs.len() || active + 1 >= self.tabs.len() {
            return;
        }
        let mut pinned_right: Vec<EditorTab> = Vec::new();
        for (offset, tab) in self.tabs.drain(active + 1..).enumerate() {
            if tab.is_pinned {
                pinned_right.push(tab);
            } else {
                self.closed_stack.push((tab, active + 1 + offset));
            }
        }
        if self.closed_stack.len() > 30 {
            let overflow = self.closed_stack.len() - 30;
            self.closed_stack.drain(..overflow);
        }
        self.tabs.extend(pinned_right);
        self.retain_auto_save_states();
        self.sync_needed = true;
        cx.notify();
    }

    /// 关闭除 `idx` 外的全部标签（`close_other_tabs` 的指定索引版，供右键菜单调用；固定标签保留，固定组在前）。
    pub fn close_others_at(&mut self, idx: usize, cx: &mut Context<Self>) {
        if idx >= self.tabs.len() {
            return;
        }
        let kept_path = self.tabs.get(idx).map(|tab| tab.path.clone());
        let mut kept: Vec<(usize, EditorTab)> = Vec::new();
        for (index, tab) in self.tabs.drain(..).enumerate() {
            if index == idx || tab.is_pinned {
                kept.push((index, tab));
            } else {
                self.closed_stack.push((tab, index));
            }
        }
        if self.closed_stack.len() > 30 {
            let overflow = self.closed_stack.len() - 30;
            self.closed_stack.drain(..overflow);
        }
        // 固定组在前并保持原相对顺序；`idx` 未固定时排在固定段之后。
        kept.sort_by_key(|(index, tab)| (!tab.is_pinned, *index));
        self.tabs = kept.into_iter().map(|(_, tab)| tab).collect();
        self.retain_auto_save_states();
        self.active_tab_index =
            kept_path.and_then(|path| self.tabs.iter().position(|tab| tab.path == path));
        self.sync_needed = true;
        cx.notify();
    }

    /// 关闭 `idx` 右侧的全部标签（`close_tabs_to_right` 的指定索引版，供右键菜单调用；固定标签保留）。
    pub fn close_to_right_at(&mut self, idx: usize, cx: &mut Context<Self>) {
        if idx >= self.tabs.len() || idx + 1 >= self.tabs.len() {
            return;
        }
        let active_path = self
            .active_tab_index
            .and_then(|index| self.tabs.get(index))
            .map(|tab| tab.path.clone());
        let mut pinned_right: Vec<EditorTab> = Vec::new();
        for (offset, tab) in self.tabs.drain(idx + 1..).enumerate() {
            if tab.is_pinned {
                pinned_right.push(tab);
            } else {
                self.closed_stack.push((tab, idx + 1 + offset));
            }
        }
        if self.closed_stack.len() > 30 {
            let overflow = self.closed_stack.len() - 30;
            self.closed_stack.drain(..overflow);
        }
        self.tabs.extend(pinned_right);
        self.retain_auto_save_states();
        if let Some(active) = self.active_tab_index {
            if active > idx {
                // 活动页被关掉时回退到 `idx`；固定活动页幸存时按 path 跟随。
                self.active_tab_index = active_path
                    .and_then(|path| self.tabs.iter().position(|tab| tab.path == path))
                    .or(Some(idx));
            }
        }
        self.sync_needed = true;
        cx.notify();
    }

    /// 翻转 `idx` 标签的固定状态并物理重排（固定组永远在前）。
    /// 固定→移到固定段末尾，取消固定→移到固定段之后紧邻；活动页与已同步
    /// 位按 path 跟随被移动的标签。内容未变故不置 `sync_needed`，只 `notify`。
    pub fn toggle_pin_at(&mut self, idx: usize, cx: &mut Context<Self>) {
        if idx >= self.tabs.len() {
            return;
        }
        let active_path = self
            .active_tab_index
            .and_then(|index| self.tabs.get(index))
            .map(|tab| tab.path.clone());
        let synced_path = self
            .synced_tab
            .and_then(|index| self.tabs.get(index))
            .map(|tab| tab.path.clone());
        let mut tab = self.tabs.remove(idx);
        tab.is_pinned = !tab.is_pinned;
        let pinned_count = self.tabs.iter().filter(|tab| tab.is_pinned).count();
        self.tabs.insert(pinned_count.min(self.tabs.len()), tab);
        if let Some(path) = active_path {
            self.active_tab_index = self.tabs.iter().position(|tab| tab.path == path);
        }
        if let Some(path) = synced_path {
            self.synced_tab = self.tabs.iter().position(|tab| tab.path == path);
        }
        cx.notify();
    }

    /// 从磁盘重读指定标签（失败忽略；同步走既有 `sync_needed` 机制）。
    pub fn reload_tab(&mut self, idx: usize, cx: &mut Context<Self>) {
        let Some(tab) = self.tabs.get(idx) else {
            return;
        };
        let path = tab.path.clone();
        self.cancel_auto_save(&path);
        let root = self.workspace_root.clone();
        let client = self.client.clone();

        cx.spawn(async move |this, cx| {
            let task = client.read_file(&cx, &root, &path);
            if let Ok(text) = task.await {
                let _ = this.update(cx, |ed, cx| {
                    if let Some(t) = ed.tabs.get_mut(idx) {
                        if t.path == path {
                            t.content = text;
                            t.is_dirty = false;
                            ed.sync_needed = true;
                            cx.notify();
                        }
                    }
                });
            }
        })
        .detach();
    }

    /// 返回指定标签的绝对路径（`workspace_root/path` 拼接，供复制路径/文件管理器显示用）。
    pub fn tab_abs_path(&self, idx: usize) -> Option<String> {
        self.tabs
            .get(idx)
            .map(|tab| format!("{}/{}", self.workspace_root.trim_end_matches('/'), tab.path))
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
        self.schedule_active_auto_save(cx);
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
                        let active_has_newer_text = ed
                            .active_tab_index
                            .and_then(|index| ed.tabs.get(index))
                            .filter(|active| active.path == path)
                            .is_some_and(|_| ed.editor_state.read(cx).value().to_string() != text);
                        if let Some(tab) = ed.tabs.iter_mut().find(|tab| tab.path == path) {
                            if tab.content == text && !active_has_newer_text {
                                tab.is_dirty = false;
                            }
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

/// 编辑器标签派发的事件（右键菜单动作由 UI 层触发，父视图订阅处理）。
#[derive(Debug, Clone)]
pub enum EditorTabEvent {
    OpenInTerminal {
        dir: String,
    },
    /// 活动标签的内容或身份发生变化，父视图据此同步 LSP 文档态。
    DocumentChanged {
        path: String,
        text: String,
    },
}

impl EventEmitter<EditorTabEvent> for EditorView {}

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

/// 在编辑器完成本帧布局后接管其右键回调。
///
/// 这里只更新子实体 `EditorState`，不在 `EditorView` 自己的 `on_prepaint`
/// 回调中回写父实体，避免 GPUI 的实体重复 lease。鼠标事件仍由上游编辑器
/// 处理，因此右键到选区外的光标移动语义保持不变。
fn install_editor_context_menu_handler(
    editor_state: &Entity<EditorState>,
    view: &WeakEntity<EditorView>,
    cx: &mut gpui_kit::App,
) {
    let handler_view = view.clone();
    editor_state.update(cx, |state, _cx| {
        state.on_context_menu(Rc::new(
            move |_menu: NativeMenu,
                  _capabilities: InputContextMenuCapabilities,
                  position: Point<Pixels>,
                  window: &mut Window,
                  cx: &mut gpui_kit::App| {
                let handler_view = handler_view.clone();
                window.defer(cx, move |window, cx| {
                    let Some(view) = handler_view.upgrade() else {
                        return;
                    };
                    view.update(cx, |editor, cx| {
                        editor.open_editor_context_menu(position, window, cx);
                    });
                });
            },
        ));
    });
}

/// 构造与上游内置编辑菜单相同的项目，但交给应用自己的非抢焦点浮层。
fn build_editor_context_menu(
    mut menu: PopupMenu,
    cx: &mut Context<PopupMenu>,
    capabilities: InputContextMenuCapabilities,
) -> PopupMenu {
    let enabled = !capabilities.is_disabled();
    let editable = enabled && !capabilities.is_readonly();

    if capabilities.is_code_editor() {
        menu = menu
            .menu_with_disabled(
                crate::i18n::menu_text(cx, "menu.goToDefinition"),
                Box::new(gpui_kit::base::input::GoToDefinition),
                !(enabled && capabilities.has_definition()),
            )
            .menu_with_disabled(
                crate::i18n::menu_text(cx, "menu.showCodeActions"),
                Box::new(gpui_kit::base::input::ToggleCodeActions),
                !(editable && capabilities.has_code_actions()),
            )
            .separator();
    }

    menu = menu
        .menu_with_disabled(
            crate::i18n::menu_text(cx, "menu.cut"),
            Box::new(gpui_kit::base::input::Cut),
            !(editable && capabilities.is_copyable()),
        )
        .menu_with_disabled(
            crate::i18n::menu_text(cx, "menu.copy"),
            Box::new(gpui_kit::base::input::Copy),
            !capabilities.is_copyable(),
        )
        .menu_with_disabled(
            crate::i18n::menu_text(cx, "menu.paste"),
            Box::new(gpui_kit::base::input::Paste),
            !(editable && cx.read_from_clipboard().is_some()),
        )
        .separator()
        .menu(
            crate::i18n::menu_text(cx, "menu.selectAll"),
            Box::new(gpui_kit::base::input::SelectAll),
        );

    menu
}

impl Render for EditorView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.sync_active_editor(window, cx);
        // 设置弹窗可直接改 word_wrap/line_numbers/render_whitespace：每帧对齐
        // 全局设置（菜单 toggle 已同步，此处覆盖对话框路径）。
        {
            let s = settings::get(cx);
            let wrap = s.word_wrap;
            let show_numbers = s.line_numbers;
            let show_ws = s.render_whitespace.as_str() != "none";
            if wrap != self.soft_wrap {
                self.soft_wrap = wrap;
                self.editor_state.update(cx, |editor, cx| {
                    editor.set_soft_wrap(wrap, window, cx);
                });
            }
            if show_numbers != self.show_line_numbers {
                self.show_line_numbers = show_numbers;
                self.editor_state.update(cx, |editor, cx| {
                    editor.set_line_number(show_numbers, window, cx);
                });
            }
            if show_ws != self.show_whitespace {
                self.show_whitespace = show_ws;
                self.editor_state.update(cx, |editor, cx| {
                    editor.set_show_whitespaces(show_ws, window, cx);
                });
            }
        }

        let active_tab = self
            .active_tab_index
            .and_then(|idx| self.tabs.get(idx).cloned());
        let is_dark = {
            let s = settings::get(cx);
            !crate::theme::ThemePalette::is_light(&settings::resolved_theme_id(s, false))
        };

        let editor_state = self.editor_state.clone();
        let editor_state_for_handler = self.editor_state.clone();
        let editor_view = cx.entity().downgrade();
        let editor_menu = self
            .editor_context_menu
            .as_ref()
            .map(|menu| menu.menu.clone());
        let editor_context_menu_overlay = self.editor_context_menu.as_ref().map(|menu| {
            gpui_kit::deferred(
                gpui_kit::anchored().child(
                    div()
                        .w(window.bounds().size.width)
                        .h(window.bounds().size.height)
                        .on_scroll_wheel(|_, _, cx| {
                            cx.stop_propagation();
                        })
                        .child(
                            gpui_kit::anchored()
                                .position(menu.position)
                                .snap_to_window_with_margin(px(8.0))
                                .child(menu.menu.clone()),
                        ),
                ),
            )
            .with_priority(gpui_kit::base::POPUP_PRIORITY)
        });

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
                        // 对齐 Tauri `shouldShowTabCloseButton`：固定常显，
                        // `always` 常显，`active` 仅当前显，其余悬停显。
                        let visibility =
                            crate::settings::get(cx).tab_close_button_visibility.clone();
                        let show_close = tab.is_pinned
                            || visibility == "always"
                            || (visibility == "active" && is_active);
                        let group_name = format!("tab-close-group-{idx}");

                        h_flex()
                            .id(idx)
                            .group(group_name.clone())
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
                                if let Some(arc) =
                                    crate::workbench::file_icon::file_image(&title, is_dark)
                                {
                                    div()
                                        .size(px(14.0))
                                        .child(
                                            gpui_kit::img(gpui_kit::ImageSource::Image(arc))
                                                .size_full(),
                                        )
                                        .into_any_element()
                                } else {
                                    let icon_name = if is_code_file(&title) {
                                        IconName::FileCode
                                    } else {
                                        IconName::FileText
                                    };
                                    Icon::new(icon_name)
                                        .size(px(14.0))
                                        .text_color(if is_active {
                                            ThemeColors::accent_blue()
                                        } else {
                                            ThemeColors::text_muted()
                                        })
                                        .into_any_element()
                                },
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
                                    .when(!show_close, |d| {
                                        d.opacity(0.0)
                                            .group_hover(group_name, |style| style.opacity(1.0))
                                    })
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
                            // 右键记 `context_menu_tab` 并弹出标签菜单（上游
                            // `context_menu` 管显隐，浮层不占布局；点选后由
                            // 菜单动作清 `None`，点外由下式清 `None`）。
                            .on_mouse_down(
                                gpui_kit::MouseButton::Right,
                                cx.listener(move |this, _event, _window, cx| {
                                    this.context_menu_tab = Some(idx);
                                    cx.notify();
                                }),
                            )
                            .on_mouse_down_out(cx.listener(|this, _event, _window, cx| {
                                if this.context_menu_tab.is_some() {
                                    this.context_menu_tab = None;
                                    cx.notify();
                                }
                            }))
                            .context_menu({
                                let view = cx.entity();
                                let pane_id = self.pane_id.unwrap_or(0);
                                let locked = self.pane_locked;
                                let on_split: SplitCallback = self
                                    .on_split
                                    .clone()
                                    .unwrap_or_else(|| Rc::new(|_, _, _, _| {}));
                                let on_toggle_lock: ToggleLockCallback = self
                                    .on_toggle_lock
                                    .clone()
                                    .unwrap_or_else(|| Rc::new(|_, _| {}));
                                crate::workbench::tab_menu::tab_context_menu(
                                    view,
                                    idx,
                                    pane_id,
                                    locked,
                                    on_split,
                                    on_toggle_lock,
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
                    .when_some(editor_menu.as_ref(), |this, menu| {
                        let menu_focus = menu.focus_handle(cx);
                        this.capture_key_down(move |event: &KeyDownEvent, window, cx| {
                            if event.keystroke.modifiers.shift
                                || event.keystroke.modifiers.control
                                || event.keystroke.modifiers.alt
                                || event.keystroke.modifiers.platform
                            {
                                return;
                            }
                            match event.keystroke.key.as_str() {
                                "up" => menu_focus.dispatch_action(
                                    &gpui_kit::base::actions::SelectUp,
                                    window,
                                    cx,
                                ),
                                "down" => menu_focus.dispatch_action(
                                    &gpui_kit::base::actions::SelectDown,
                                    window,
                                    cx,
                                ),
                                "enter" => menu_focus.dispatch_action(
                                    &gpui_kit::base::actions::Confirm { secondary: false },
                                    window,
                                    cx,
                                ),
                                "escape" => menu_focus.dispatch_action(
                                    &gpui_kit::base::actions::Cancel,
                                    window,
                                    cx,
                                ),
                                _ => return,
                            }
                            cx.stop_propagation();
                            window.prevent_default();
                        })
                    })
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
                    })
                    .on_prepaint(move |_bounds, _window, cx| {
                        install_editor_context_menu_handler(
                            &editor_state_for_handler,
                            &editor_view,
                            cx,
                        );
                    }),
            )
            .when_some(editor_context_menu_overlay, |this, overlay| {
                this.child(overlay)
            })
    }
}

#[cfg(test)]
mod tests {
    use super::AutoSaveState;

    #[test]
    fn auto_save_burst_keeps_latest_revision_in_one_task() {
        let mut state = AutoSaveState {
            revision: 0,
            running: true,
            debounce_requested: false,
            task: None,
        };

        state.request();
        state.request();

        assert_eq!(state.revision, 2);
        assert!(state.running, "a running worker must absorb repeated edits");
        assert!(state.take_debounce());
        assert!(!state.take_debounce());
    }
}
