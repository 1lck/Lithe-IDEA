//! 工作台命令面板（Command Palette）模态视图。
//!
//! 复刻 Tauri 端 `features/command-palette` 的通用弹层壳与动作清单：顶部搜索输入行、
//! 按 category 分组的命令列表、底部操作指引。当前只提供点击与键盘交互，选中后通过
//! [`CommandPaletteEvent::Execute`] 把命令 id 交给上层工作台处理，不在本模块执行真实命令。

use gpui_kit::assets::IconName;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, rgba, AnyElement, Context, EventEmitter, FocusHandle, FontWeight,
    InteractiveElement as _, IntoElement, KeyDownEvent, ParentElement as _, Render,
    StatefulInteractiveElement as _, Styled as _, Window,
};

use crate::theme::ThemeColors;

/// 命令面板中的一条命令。
///
/// `id` 为稳定的命令标识（如 `file.save`），`category` 用作列表分组标题，
/// `shortcut` 为展示用快捷键文案（不参与按键分发）。
#[derive(Debug, Clone)]
pub struct CommandPaletteItem {
    pub id: String,
    pub name: String,
    pub category: String,
    pub shortcut: Option<String>,
    pub icon: IconName,
}

/// 命令面板对外事件。
#[derive(Debug, Clone)]
pub enum CommandPaletteEvent {
    /// 选中并确认执行某条命令，携带命令 id。
    Execute(String),
    /// 请求关闭命令面板。
    Close,
}

/// 列表渲染行：分组标题或命令项（`Item` 携带该项在 `filtered` 中的位置）。
enum PaletteRow {
    Header(String),
    Item(usize),
}

/// 居中的命令面板模态，宽 704、最大高 440。
pub struct CommandPaletteModal {
    pub query: String,
    pub items: Vec<CommandPaletteItem>,
    /// 命中筛选的命令在 `items` 中的下标，保持构造时的分组顺序。
    pub filtered: Vec<usize>,
    pub selected_index: usize,
    pub focus_handle: FocusHandle,
    /// 预留的多级视图栈，根视图为 `"root"`。
    pub view_stack: Vec<String>,
}

impl EventEmitter<CommandPaletteEvent> for CommandPaletteModal {}

impl CommandPaletteModal {
    pub fn new(cx: &mut Context<Self>) -> Self {
        let items = build_commands();
        let filtered = (0..items.len()).collect();

        Self {
            query: String::new(),
            items,
            filtered,
            selected_index: 0,
            focus_handle: cx.focus_handle(),
            view_stack: vec!["root".to_string()],
        }
    }

    /// 复位到初始状态：清空查询、选中归零、视图栈回到根，并重算筛选结果。
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.query.clear();
        self.selected_index = 0;
        self.view_stack = vec!["root".to_string()];
        self.recompute_filtered();
        cx.notify();
    }

    /// 直接设置查询串（供上层联动外部输入）。
    #[allow(dead_code)]
    pub fn set_query(&mut self, q: impl Into<String>, cx: &mut Context<Self>) {
        self.query = q.into();
        self.selected_index = 0;
        self.recompute_filtered();
        cx.notify();
    }

    /// 在当前命中列表内移动选中项，`delta` 为正向下、为负向上，越界即夹紧。
    pub fn move_selection(&mut self, delta: i32, cx: &mut Context<Self>) {
        let total = self.filtered.len();
        if total == 0 {
            self.selected_index = 0;
        } else {
            let current = self.selected_index.min(total - 1) as i32;
            self.selected_index = (current + delta).clamp(0, total as i32 - 1) as usize;
        }
        cx.notify();
    }

    /// 按查询串重算命中列表：命令名、分组、id 任一包含即命中。
    fn recompute_filtered(&mut self) {
        let q = self.query.trim().to_lowercase();
        self.filtered = self
            .items
            .iter()
            .enumerate()
            .filter(|(_, item)| {
                q.is_empty()
                    || item.name.to_lowercase().contains(&q)
                    || item.category.to_lowercase().contains(&q)
                    || item.id.to_lowercase().contains(&q)
            })
            .map(|(idx, _)| idx)
            .collect();
        if self.selected_index >= self.filtered.len() {
            self.selected_index = self.filtered.len().saturating_sub(1);
        }
    }

    /// 把命中列表展开成“分组标题 + 命令项”的渲染行序列。
    fn build_rows(&self) -> Vec<PaletteRow> {
        let mut rows = Vec::new();
        let mut last_category: Option<&str> = None;
        for (position, &item_idx) in self.filtered.iter().enumerate() {
            let item = &self.items[item_idx];
            if last_category != Some(item.category.as_str()) {
                rows.push(PaletteRow::Header(item.category.clone()));
                last_category = Some(item.category.as_str());
            }
            rows.push(PaletteRow::Item(position));
        }
        rows
    }

    /// 当前有效选中下标（对空列表安全）。
    fn current_index(&self) -> usize {
        if self.filtered.is_empty() {
            0
        } else {
            self.selected_index.min(self.filtered.len() - 1)
        }
    }

    /// 执行命中列表第 `position` 项，发出其命令 id。
    fn execute_at(&self, position: usize, cx: &mut Context<Self>) {
        if let Some(&item_idx) = self.filtered.get(position) {
            cx.emit(CommandPaletteEvent::Execute(
                self.items[item_idx].id.clone(),
            ));
        }
    }
}

impl Render for CommandPaletteModal {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 请求聚焦以接收按键输入
        window.focus(&self.focus_handle, cx);

        let rows = self.build_rows();
        let current_index = self.current_index();

        // 全屏半透明遮罩：点击空白处关闭
        div()
            .id("command-palette-backdrop")
            .track_focus(&self.focus_handle)
            .absolute()
            .inset_0()
            .bg(rgba(0x00000088))
            .flex()
            .items_center()
            .justify_center()
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                let key = event.keystroke.key.as_str();
                match key {
                    "escape" => {
                        cx.emit(CommandPaletteEvent::Close);
                    }
                    "up" | "arrowup" => this.move_selection(-1, cx),
                    "down" | "arrowdown" => this.move_selection(1, cx),
                    "enter" => {
                        if !this.filtered.is_empty() {
                            let idx = this.current_index();
                            this.execute_at(idx, cx);
                        }
                    }
                    "backspace" => {
                        this.query.pop();
                        this.selected_index = 0;
                        this.recompute_filtered();
                        cx.notify();
                    }
                    "space" => {
                        this.query.push(' ');
                        this.selected_index = 0;
                        this.recompute_filtered();
                        cx.notify();
                    }
                    _ => {
                        // 无修饰键时把可打印字符追加到查询串
                        if !event.keystroke.modifiers.control
                            && !event.keystroke.modifiers.alt
                            && !event.keystroke.modifiers.platform
                        {
                            if let Some(ch) = &event.keystroke.key_char {
                                this.query.push_str(ch);
                                this.selected_index = 0;
                                this.recompute_filtered();
                                cx.notify();
                            } else if key.chars().count() == 1 {
                                this.query.push_str(key);
                                this.selected_index = 0;
                                this.recompute_filtered();
                                cx.notify();
                            }
                        }
                    }
                }
            }))
            .on_mouse_down(
                gpui_kit::MouseButton::Left,
                cx.listener(|_this, _event, _window, cx| {
                    cx.emit(CommandPaletteEvent::Close);
                }),
            )
            .child(
                v_flex()
                    .id("command-palette-card")
                    .w(px(704.0))
                    .max_h(px(440.0))
                    .bg(ThemeColors::surface())
                    .border_1()
                    .border_color(ThemeColors::border())
                    .rounded_lg()
                    .shadow_lg()
                    .overflow_hidden()
                    .on_mouse_down(
                        gpui_kit::MouseButton::Left,
                        cx.listener(|_this, _event, _window, cx| {
                            // 卡片内点击不冒泡到遮罩，避免误关闭
                            cx.stop_propagation();
                        }),
                    )
                    .child(
                        // 1. 顶部输入行：搜索图标 + 查询串/占位 + Esc 徽标
                        h_flex()
                            .h(px(52.0))
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
                                h_flex()
                                    .flex_1()
                                    .items_center()
                                    .gap_1()
                                    .child(
                                        div()
                                            .text_sm()
                                            .text_color(if self.query.is_empty() {
                                                ThemeColors::subtle_foreground()
                                            } else {
                                                ThemeColors::foreground()
                                            })
                                            .child(if self.query.is_empty() {
                                                crate::i18n::menu_text(
                                                    cx,
                                                    "commandPalette.placeholder",
                                                )
                                                .to_string()
                                            } else {
                                                self.query.clone()
                                            }),
                                    )
                                    .child(
                                        // 静态光标条，提示可输入
                                        div().w(px(2.0)).h(px(16.0)).bg(ThemeColors::primary()),
                                    ),
                            )
                            .child(shortcut_badge("Esc")),
                    )
                    .child(
                        // 2. 命令列表：按 category 分组，可滚动
                        div()
                            .flex_1()
                            .w_full()
                            .max_h(px(340.0))
                            .overflow_y_scrollbar()
                            .py_1()
                            .when(rows.is_empty(), |list| {
                                list.child(
                                    div()
                                        .w_full()
                                        .py_8()
                                        .text_center()
                                        .text_sm()
                                        .text_color(ThemeColors::subtle_foreground())
                                        .child(crate::i18n::menu_text(cx, "search.noResults")),
                                )
                            })
                            .children(rows.into_iter().map(|row| {
                                match row {
                                    PaletteRow::Header(category) => h_flex()
                                        .px_3()
                                        .pt_2()
                                        .pb_1()
                                        .child(
                                            div()
                                                .text_xs()
                                                .font_weight(FontWeight::MEDIUM)
                                                .text_color(ThemeColors::muted_foreground())
                                                .child(palette_category_label(&category, cx)),
                                        )
                                        .into_any_element(),
                                    PaletteRow::Item(position) => {
                                        let item = &self.items[self.filtered[position]];
                                        let is_selected = position == current_index;
                                        let icon = item.icon;
                                        let name = item.name.clone();
                                        let shortcut = item.shortcut.clone();

                                        h_flex()
                                            .id(("command-palette-item", position))
                                            .h(px(36.0))
                                            .w_full()
                                            .mx_2()
                                            .px_2p5()
                                            .items_center()
                                            .gap_2p5()
                                            .rounded_md()
                                            .cursor_pointer()
                                            .when(is_selected, |row| {
                                                row.bg(ThemeColors::selected())
                                            })
                                            .when(!is_selected, |row| {
                                                row.hover(|h| h.bg(ThemeColors::accent()))
                                            })
                                            .child(Icon::new(icon).size(px(15.0)).text_color(
                                                if is_selected {
                                                    ThemeColors::primary()
                                                } else {
                                                    ThemeColors::muted_foreground()
                                                },
                                            ))
                                            .child(
                                                div()
                                                    .flex_1()
                                                    .text_sm()
                                                    .text_color(ThemeColors::foreground())
                                                    .child(name),
                                            )
                                            .when_some(shortcut, |row, sc| {
                                                row.child(shortcut_badge(&sc))
                                            })
                                            .on_click(cx.listener(
                                                move |this, _event, _window, cx| {
                                                    this.execute_at(position, cx);
                                                },
                                            ))
                                            .into_any_element()
                                    }
                                }
                            })),
                    ),
            )
    }
}

/// 命令分组标题本地化：英文 category 映射到菜单键，未知回退原样。
/// 条目构造处的 category 字段保持英文不动，只在渲染时映射。
fn palette_category_label(category: &str, cx: &gpui_kit::App) -> String {
    let key = match category {
        "File" => Some("menu.file"),
        "Edit" => Some("menu.edit"),
        "View" => Some("menu.view"),
        "Go" => Some("menu.go"),
        "Terminal" => Some("menu.terminal"),
        "Run" => Some("menu.run"),
        "Tools" => Some("menu.tools"),
        "Window" => Some("menu.window"),
        "Help" => Some("menu.help"),
        "Settings" => Some("menu.preferences"),
        "Pane" => Some("menu.view"),
        _ => None,
    };
    match key {
        Some(key) => crate::i18n::menu_text(cx, key).to_string(),
        None => category.to_string(),
    }
}

/// 快捷键/键位徽标。
fn shortcut_badge(label: &str) -> AnyElement {
    div()
        .px_1p5()
        .py(px(1.0))
        .rounded_sm()
        .bg(ThemeColors::accent())
        .border_1()
        .border_color(ThemeColors::border())
        .text_xs()
        .text_color(ThemeColors::muted_foreground())
        .child(label.to_string())
        .into_any_element()
}

/// 构造一条命令，减少清单里的重复样板。
fn command(
    id: &str,
    name: &str,
    category: &str,
    shortcut: Option<&str>,
    icon: IconName,
) -> CommandPaletteItem {
    CommandPaletteItem {
        id: id.to_string(),
        name: name.to_string(),
        category: category.to_string(),
        shortcut: shortcut.map(|s| s.to_string()),
        icon,
    }
}

/// 与 Tauri 端动作工厂对齐的命令清单，按 category 顺序排列以支持列表分组。
fn build_commands() -> Vec<CommandPaletteItem> {
    vec![
        // File
        command(
            "file.new",
            "File: New File",
            "File",
            Some("Ctrl+N"),
            IconName::Plus,
        ),
        command(
            "file.open",
            "File: Open Project...",
            "File",
            Some("Ctrl+O"),
            IconName::FolderOpen,
        ),
        command(
            "file.save",
            "File: Save",
            "File",
            Some("Ctrl+S"),
            IconName::Save,
        ),
        command(
            "file.saveAll",
            "File: Save All",
            "File",
            Some("Ctrl+Shift+S"),
            IconName::SaveAll,
        ),
        command(
            "file.closeEditor",
            "File: Close Editor",
            "File",
            Some("Ctrl+W"),
            IconName::Close,
        ),
        command(
            "file.reopenClosed",
            "File: Reopen Closed Editor",
            "File",
            Some("Ctrl+Shift+T"),
            IconName::RotateCw,
        ),
        // Edit
        command(
            "edit.undo",
            "Edit: Undo",
            "Edit",
            Some("Ctrl+Z"),
            IconName::Undo,
        ),
        command(
            "edit.redo",
            "Edit: Redo",
            "Edit",
            Some("Ctrl+Shift+Z"),
            IconName::Redo,
        ),
        command(
            "edit.cut",
            "Edit: Cut",
            "Edit",
            Some("Ctrl+X"),
            IconName::Scissors,
        ),
        command(
            "edit.copy",
            "Edit: Copy",
            "Edit",
            Some("Ctrl+C"),
            IconName::Copy,
        ),
        command(
            "edit.paste",
            "Edit: Paste",
            "Edit",
            Some("Ctrl+V"),
            IconName::ClipboardPaste,
        ),
        command(
            "edit.find",
            "Edit: Find",
            "Edit",
            Some("Ctrl+F"),
            IconName::Search,
        ),
        command(
            "edit.replace",
            "Edit: Replace",
            "Edit",
            Some("Ctrl+H"),
            IconName::RefreshCw,
        ),
        command(
            "edit.format",
            "Edit: Format Document",
            "Edit",
            Some("Shift+Alt+F"),
            IconName::Code,
        ),
        // View
        command(
            "workbench.toggle_sidebar",
            "View: Toggle Sidebar",
            "View",
            Some("Ctrl+B"),
            IconName::PanelLeft,
        ),
        command(
            "workbench.toggle_terminal",
            "View: Toggle Bottom Panel",
            "View",
            Some("Ctrl+J"),
            IconName::PanelBottom,
        ),
        command(
            "view.zoomIn",
            "View: Zoom In",
            "View",
            Some("Ctrl+="),
            IconName::Plus,
        ),
        command(
            "view.zoomOut",
            "View: Zoom Out",
            "View",
            Some("Ctrl+-"),
            IconName::Minus,
        ),
        command(
            "view.resetZoom",
            "View: Reset Zoom",
            "View",
            Some("Ctrl+0"),
            IconName::RotateCw,
        ),
        command(
            "view.colorTheme",
            "View: Color Theme",
            "View",
            None,
            IconName::Palette,
        ),
        command(
            "view.iconTheme",
            "View: File Icon Theme",
            "View",
            None,
            IconName::Box,
        ),
        // Go
        command(
            "go.quickOpen",
            "Go: Quick Open",
            "Go",
            Some("Ctrl+P"),
            IconName::Search,
        ),
        command(
            "go.commandPalette",
            "Go: Command Palette",
            "Go",
            Some("Ctrl+Shift+P"),
            IconName::Search,
        ),
        command(
            "go.symbolInFile",
            "Go: Symbol in File",
            "Go",
            Some("Ctrl+Shift+O"),
            IconName::Code,
        ),
        command(
            "go.workspaceSymbol",
            "Go: Symbol in Workspace",
            "Go",
            Some("Ctrl+T"),
            IconName::Code,
        ),
        command(
            "go.goToLine",
            "Go: Go to Line",
            "Go",
            Some("Ctrl+G"),
            IconName::Hash,
        ),
        command(
            "go.back",
            "Go: Back",
            "Go",
            Some("Alt+Left"),
            IconName::ArrowLeft,
        ),
        command(
            "go.forward",
            "Go: Forward",
            "Go",
            Some("Alt+Right"),
            IconName::ArrowRight,
        ),
        command(
            "go.nextEditor",
            "Go: Next Editor",
            "Go",
            Some("Ctrl+Tab"),
            IconName::ArrowRight,
        ),
        // Terminal
        command(
            "terminal.new",
            "Terminal: New Terminal",
            "Terminal",
            Some("Ctrl+`"),
            IconName::Terminal,
        ),
        command(
            "terminal.split",
            "Terminal: Split Terminal",
            "Terminal",
            None,
            IconName::Columns2,
        ),
        command(
            "terminal.clear",
            "Terminal: Clear",
            "Terminal",
            None,
            IconName::Trash,
        ),
        command(
            "terminal.toggle",
            "Terminal: Toggle Panel",
            "Terminal",
            Some("Ctrl+J"),
            IconName::PanelBottom,
        ),
        // Run
        command(
            "run.start",
            "Run: Start",
            "Run",
            Some("Shift+F10"),
            IconName::Play,
        ),
        command(
            "run.debug",
            "Run: Start Debugging",
            "Run",
            Some("F5"),
            IconName::Bug,
        ),
        command(
            "run.stop",
            "Run: Stop",
            "Run",
            Some("Shift+F5"),
            IconName::Square,
        ),
        command(
            "run.withoutDebug",
            "Run: Run Without Debugging",
            "Run",
            Some("Ctrl+F5"),
            IconName::Play,
        ),
        command(
            "run.build",
            "Run: Build Project",
            "Run",
            Some("Ctrl+Shift+B"),
            IconName::Box,
        ),
        command(
            "run.tests",
            "Run: Run Tests",
            "Run",
            None,
            IconName::CircleCheck,
        ),
        // Tools
        command(
            "tools.keyboardShortcuts",
            "Tools: Keyboard Shortcuts",
            "Tools",
            Some("Ctrl+K Ctrl+S"),
            IconName::Keyboard,
        ),
        command(
            "tools.developerTools",
            "Tools: Toggle Developer Tools",
            "Tools",
            Some("Ctrl+Shift+I"),
            IconName::Bug,
        ),
        command(
            "tools.showLogs",
            "Tools: Show Logs",
            "Tools",
            None,
            IconName::Terminal,
        ),
        command(
            "tools.database",
            "Tools: Open Database",
            "Tools",
            None,
            IconName::Database,
        ),
        command(
            "tools.memory",
            "Tools: Memory Usage",
            "Tools",
            None,
            IconName::MemoryStick,
        ),
        command(
            "tools.languageServers",
            "Tools: Language Servers",
            "Tools",
            None,
            IconName::Info,
        ),
        // Window
        command(
            "window.minimize",
            "Window: Minimize",
            "Window",
            None,
            IconName::Minimize,
        ),
        command(
            "window.maximize",
            "Window: Maximize",
            "Window",
            None,
            IconName::Maximize,
        ),
        command(
            "window.toggleFullscreen",
            "Window: Toggle Fullscreen",
            "Window",
            Some("F11"),
            IconName::Maximize,
        ),
        command(
            "window.reload",
            "Window: Reload",
            "Window",
            Some("Ctrl+R"),
            IconName::RotateCw,
        ),
        command(
            "window.close",
            "Window: Close",
            "Window",
            Some("Ctrl+Shift+W"),
            IconName::Close,
        ),
        // Help
        command(
            "help.documentation",
            "Help: Documentation",
            "Help",
            None,
            IconName::BookOpen,
        ),
        command(
            "help.reportIssue",
            "Help: Report Issue",
            "Help",
            None,
            IconName::ExternalLink,
        ),
        command(
            "help.checkForUpdates",
            "Help: Check for Updates",
            "Help",
            None,
            IconName::RotateCw,
        ),
        command(
            "help.about",
            "Help: About Lithe",
            "Help",
            None,
            IconName::Info,
        ),
        command("help.welcome", "Help: Welcome", "Help", None, IconName::Zap),
        // Settings
        command(
            "workbench.open_settings",
            "Settings: Open Settings",
            "Settings",
            Some("Ctrl+,"),
            IconName::Settings,
        ),
        command(
            "workbench.open_settings_appearance",
            "Settings: Appearance",
            "Settings",
            None,
            IconName::SlidersHorizontal,
        ),
        command(
            "workbench.open_settings_keybindings",
            "Settings: Keybindings",
            "Settings",
            None,
            IconName::Keyboard,
        ),
        command(
            "workbench.open_settings_theme",
            "Settings: Color Theme",
            "Settings",
            None,
            IconName::Palette,
        ),
        // Pane
        command(
            "view.split_editor_right",
            "Pane: Split Editor Right",
            "Pane",
            None,
            IconName::Columns2,
        ),
        command(
            "view.split_editor_down",
            "Pane: Split Editor Down",
            "Pane",
            None,
            IconName::Rows2,
        ),
        command(
            "view.close_editor_group",
            "Pane: Close Editor Group",
            "Pane",
            None,
            IconName::Close,
        ),
        command(
            "view.close_other_groups",
            "Pane: Close Other Editor Groups",
            "Pane",
            None,
            IconName::Close,
        ),
        command(
            "view.move_editor_next_group",
            "Pane: Move Editor to Next Group",
            "Pane",
            None,
            IconName::ArrowRight,
        ),
        command(
            "view.move_editor_previous_group",
            "Pane: Move Editor to Previous Group",
            "Pane",
            None,
            IconName::ArrowLeft,
        ),
        command(
            "view.reset_editor_group_sizes",
            "Pane: Reset Editor Group Sizes",
            "Pane",
            None,
            IconName::Columns2,
        ),
        command(
            "view.toggle_editor_group_lock",
            "Pane: Toggle Editor Group Lock",
            "Pane",
            None,
            IconName::Lock,
        ),
    ]
}
