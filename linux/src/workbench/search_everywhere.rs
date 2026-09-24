use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, rgba, Context, EventEmitter, FocusHandle, FontWeight, InteractiveElement as _,
    IntoElement, KeyDownEvent, ParentElement as _, Render, StatefulInteractiveElement as _,
    Styled as _, Window,
};

use crate::theme::ThemeColors;

/// Search Everywhere 动作本地化显示名（id → 菜单键），未知 id 回退 id 本身。
fn action_display_name(id: &str, cx: &gpui_kit::App) -> String {
    let key = match id {
        "workbench.new_file" => Some("menu.newFile"),
        "workbench.save" => Some("menu.save"),
        "workbench.close_tab" => Some("menu.closeTab"),
        "workbench.toggle_terminal" => Some("menu.toggleTerminal"),
        "workbench.toggle_sidebar" => Some("menu.toggleSecondarySidebar"),
        "workbench.open_settings" => Some("menu.preferences"),
        "workbench.refresh_workspace" => Some("ui.refresh"),
        "workbench.run" => Some("menu.run"),
        "workbench.debug" => Some("menu.startDebugging"),
        _ => None,
    };
    match key {
        Some(key) => crate::i18n::menu_text(cx, key).to_string(),
        None if id == "workbench.clear_terminal" => format!(
            "{}{}",
            crate::i18n::menu_text(cx, "ui.clear"),
            crate::i18n::menu_text(cx, "menu.terminal")
        ),
        None => id.to_string(),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SearchScope {
    All,
    Files,
    Actions,
}

#[derive(Debug, Clone)]
pub enum SearchEverywhereEvent {
    OpenFile(String),
    ExecuteAction(String),
    Close,
}

#[derive(Debug, Clone)]
pub struct SearchActionItem {
    pub id: String,
    pub name: String,
    pub shortcut: Option<String>,
    pub icon: IconName,
}

#[derive(Debug, Clone)]
pub enum MatchedItem {
    File {
        path: String,
        name: String,
        dir: String,
    },
    Action {
        id: String,
        shortcut: Option<String>,
        icon: IconName,
    },
}

/// IntelliJ / macOS Lithe 风格居中全局搜索模态弹窗
pub struct SearchEverywhereModal {
    pub query: String,
    pub scope: SearchScope,
    pub files: Vec<String>,
    pub actions: Vec<SearchActionItem>,
    pub selected_index: usize,
    pub focus_handle: FocusHandle,
}

impl EventEmitter<SearchEverywhereEvent> for SearchEverywhereModal {}

impl SearchEverywhereModal {
    pub fn new(cx: &mut Context<Self>) -> Self {
        let actions = vec![
            SearchActionItem {
                id: "workbench.new_file".to_string(),
                name: "New File".to_string(),
                shortcut: Some("Ctrl+N".to_string()),
                icon: IconName::FilePlus,
            },
            SearchActionItem {
                id: "workbench.save".to_string(),
                name: "Save Active File".to_string(),
                shortcut: Some("Ctrl+S".to_string()),
                icon: IconName::Save,
            },
            SearchActionItem {
                id: "workbench.close_tab".to_string(),
                name: "Close Active Tab".to_string(),
                shortcut: Some("Ctrl+W".to_string()),
                icon: IconName::Close,
            },
            SearchActionItem {
                id: "workbench.toggle_terminal".to_string(),
                name: "Toggle Terminal".to_string(),
                shortcut: Some("Ctrl+`".to_string()),
                icon: IconName::Terminal,
            },
            SearchActionItem {
                id: "workbench.toggle_sidebar".to_string(),
                name: "Toggle Sidebar".to_string(),
                shortcut: Some("Ctrl+B".to_string()),
                icon: IconName::PanelLeft,
            },
            SearchActionItem {
                id: "workbench.open_settings".to_string(),
                name: "Open Settings".to_string(),
                shortcut: Some("Ctrl+,".to_string()),
                icon: IconName::Settings,
            },
            SearchActionItem {
                id: "workbench.refresh_workspace".to_string(),
                name: "Refresh Workspace".to_string(),
                shortcut: Some("Ctrl+R".to_string()),
                icon: IconName::RotateCw,
            },
            SearchActionItem {
                id: "workbench.run".to_string(),
                name: "Run Project".to_string(),
                shortcut: Some("Ctrl+F5".to_string()),
                icon: IconName::Play,
            },
            SearchActionItem {
                id: "workbench.debug".to_string(),
                name: "Debug Project".to_string(),
                shortcut: Some("F5".to_string()),
                icon: IconName::Bug,
            },
            SearchActionItem {
                id: "workbench.clear_terminal".to_string(),
                name: "Clear Terminal".to_string(),
                shortcut: Some("Ctrl+K".to_string()),
                icon: IconName::Trash,
            },
        ];

        Self {
            query: String::new(),
            scope: SearchScope::All,
            files: Vec::new(),
            actions,
            selected_index: 0,
            focus_handle: cx.focus_handle(),
        }
    }

    pub fn set_files(&mut self, files: Vec<String>, cx: &mut Context<Self>) {
        self.files = files;
        cx.notify();
    }

    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.query.clear();
        self.selected_index = 0;
        cx.notify();
    }

    fn filtered_items(&self, cx: &gpui_kit::App) -> Vec<MatchedItem> {
        let q = self.query.trim().to_lowercase();
        let mut results = Vec::new();

        // 1. Files
        if self.scope == SearchScope::All || self.scope == SearchScope::Files {
            for file in &self.files {
                if q.is_empty() || file.to_lowercase().contains(&q) {
                    let (dir, name) = if let Some((d, n)) = file.rsplit_once('/') {
                        (d.to_string(), n.to_string())
                    } else {
                        (String::new(), file.clone())
                    };
                    results.push(MatchedItem::File {
                        path: file.clone(),
                        name,
                        dir,
                    });
                }
            }
        }

        // 2. Actions（本地化显示名、英文原名、id 任一包含即命中）
        if self.scope == SearchScope::All || self.scope == SearchScope::Actions {
            for act in &self.actions {
                let display = action_display_name(&act.id, cx);
                if q.is_empty()
                    || display.to_lowercase().contains(&q)
                    || act.name.to_lowercase().contains(&q)
                    || act.id.to_lowercase().contains(&q)
                {
                    results.push(MatchedItem::Action {
                        id: act.id.clone(),
                        shortcut: act.shortcut.clone(),
                        icon: act.icon,
                    });
                }
            }
        }

        results
    }

    fn select_item(&self, item: &MatchedItem, cx: &mut Context<Self>) {
        match item {
            MatchedItem::File { path, .. } => {
                cx.emit(SearchEverywhereEvent::OpenFile(path.clone()));
            }
            MatchedItem::Action { id, .. } => {
                cx.emit(SearchEverywhereEvent::ExecuteAction(id.clone()));
            }
        }
    }
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
        || lower.ends_with(".py")
        || lower.ends_with(".go")
        || lower.ends_with(".swift")
        || lower.ends_with(".sh")
        || lower.ends_with(".sql")
}

impl Render for SearchEverywhereModal {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 请求聚焦以接收按键输入
        window.focus(&self.focus_handle, cx);

        let filtered = self.filtered_items(cx);
        let current_index = if filtered.is_empty() {
            0
        } else {
            self.selected_index.min(filtered.len() - 1)
        };

        // 全屏半透明遮罩背景
        div()
            .id("search-everywhere-backdrop")
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
                        cx.emit(SearchEverywhereEvent::Close);
                    }
                    "up" | "arrowup" => {
                        if this.selected_index > 0 {
                            this.selected_index -= 1;
                            cx.notify();
                        }
                    }
                    "down" | "arrowdown" => {
                        let total = this.filtered_items(cx).len();
                        if total > 0 && this.selected_index + 1 < total {
                            this.selected_index += 1;
                            cx.notify();
                        }
                    }
                    "enter" => {
                        let items = this.filtered_items(cx);
                        let idx = if items.is_empty() {
                            0
                        } else {
                            this.selected_index.min(items.len() - 1)
                        };
                        if let Some(item) = items.get(idx) {
                            this.select_item(item, cx);
                        }
                    }
                    "backspace" => {
                        this.query.pop();
                        this.selected_index = 0;
                        cx.notify();
                    }
                    "space" => {
                        this.query.push(' ');
                        this.selected_index = 0;
                        cx.notify();
                    }
                    _ => {
                        if !event.keystroke.modifiers.control
                            && !event.keystroke.modifiers.alt
                            && !event.keystroke.modifiers.platform
                        {
                            if let Some(ch) = &event.keystroke.key_char {
                                this.query.push_str(ch);
                                this.selected_index = 0;
                                cx.notify();
                            } else if key.chars().count() == 1 {
                                this.query.push_str(key);
                                this.selected_index = 0;
                                cx.notify();
                            }
                        }
                    }
                }
            }))
            .on_mouse_down(
                gpui_kit::MouseButton::Left,
                cx.listener(|_this, _event, _window, cx| {
                    cx.emit(SearchEverywhereEvent::Close);
                }),
            )
            .child(
                // 居中模态卡片，宽 580px，深色卡片与边框阴影
                v_flex()
                    .id("search-everywhere-card")
                    .w(px(580.0))
                    .max_h(px(480.0))
                    .bg(ThemeColors::bg_sidebar())
                    .border_1()
                    .border_color(ThemeColors::border())
                    .rounded_lg()
                    .shadow_lg()
                    .overflow_hidden()
                    .on_mouse_down(
                        gpui_kit::MouseButton::Left,
                        cx.listener(|_this, _event, _window, cx| {
                            // 卡片内点击必须阻断冒泡，否则会触发遮罩的关闭逻辑。
                            cx.stop_propagation();
                        }),
                    )
                    .child(
                        // 1. 顶部搜索框栏（含图标、输入展示、关闭按钮）
                        h_flex()
                            .h(px(46.0))
                            .w_full()
                            .items_center()
                            .px_3()
                            .gap_2p5()
                            .border_b_1()
                            .border_color(ThemeColors::border())
                            .bg(ThemeColors::bg_titlebar())
                            .child(
                                Icon::new(IconName::Search)
                                    .size(px(16.0))
                                    .text_color(ThemeColors::accent_blue()),
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
                                                ThemeColors::text_muted()
                                            } else {
                                                ThemeColors::text_primary()
                                            })
                                            .child(if self.query.is_empty() {
                                                crate::i18n::menu_text(
                                                    cx,
                                                    "search.everywherePlaceholder",
                                                )
                                                .to_string()
                                            } else {
                                                self.query.clone()
                                            }),
                                    )
                                    .child(
                                        // 闪烁光标模拟
                                        div().w(px(2.0)).h(px(14.0)).bg(ThemeColors::accent_blue()),
                                    ),
                            )
                            .when(!self.query.is_empty(), |row| {
                                row.child(
                                    Button::new("clear-search-query")
                                        .small()
                                        .ghost()
                                        .icon(IconName::Close)
                                        .on_click(cx.listener(|this, _event, _window, cx| {
                                            this.query.clear();
                                            this.selected_index = 0;
                                            cx.notify();
                                        })),
                                )
                            })
                            .child(
                                Button::new("close-search-modal")
                                    .small()
                                    .ghost()
                                    .icon(IconName::Close)
                                    .on_click(cx.listener(|_this, _event, _window, cx| {
                                        cx.emit(SearchEverywhereEvent::Close);
                                    })),
                            ),
                    )
                    .child(
                        // 2. Scope 药丸选项（All, Files, Actions）
                        h_flex()
                            .h(px(34.0))
                            .w_full()
                            .items_center()
                            .px_3()
                            .gap_1p5()
                            .border_b_1()
                            .border_color(ThemeColors::border())
                            .bg(ThemeColors::bg_tab_bar())
                            .child(self.render_scope_pill(
                                "scope-all",
                                crate::i18n::menu_text(cx, "search.scopeAll").to_string(),
                                self.scope == SearchScope::All,
                                SearchScope::All,
                                cx,
                            ))
                            .child(self.render_scope_pill(
                                "scope-files",
                                crate::i18n::menu_text(cx, "search.scopeFiles").to_string(),
                                self.scope == SearchScope::Files,
                                SearchScope::Files,
                                cx,
                            ))
                            .child(self.render_scope_pill(
                                "scope-actions",
                                crate::i18n::menu_text(cx, "search.scopeActions").to_string(),
                                self.scope == SearchScope::Actions,
                                SearchScope::Actions,
                                cx,
                            )),
                    )
                    .child(
                        // 3. 结果列表展示区
                        div()
                            .flex_1()
                            .w_full()
                            .max_h(px(320.0))
                            .overflow_y_scrollbar()
                            .py_1()
                            .when(filtered.is_empty(), |list| {
                                list.child(
                                    div()
                                        .w_full()
                                        .py_8()
                                        .text_center()
                                        .text_xs()
                                        .text_color(ThemeColors::text_muted())
                                        .child(crate::i18n::menu_text(cx, "search.noResults")),
                                )
                            })
                            .children(filtered.into_iter().enumerate().map(|(idx, item)| {
                                let is_selected = idx == current_index;
                                let item_clone = item.clone();

                                h_flex()
                                    .id(idx)
                                    .h(px(34.0))
                                    .w_full()
                                    .items_center()
                                    .justify_between()
                                    .px_3()
                                    .cursor_pointer()
                                    .when(is_selected, |row| {
                                        row.bg(ThemeColors::subtle_selection())
                                            .border_l_2()
                                            .border_color(ThemeColors::accent_blue())
                                    })
                                    .when(!is_selected, |row| {
                                        row.hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                                    })
                                    .child(match &item {
                                        MatchedItem::File { name, dir, .. } => {
                                            let icon = if is_code_file(name) {
                                                IconName::FileCode
                                            } else {
                                                IconName::FileText
                                            };
                                            h_flex()
                                                .items_center()
                                                .gap_2()
                                                .child(
                                                    Icon::new(icon)
                                                        .size(px(14.0))
                                                        .text_color(ThemeColors::accent_blue()),
                                                )
                                                .child(
                                                    div()
                                                        .text_xs()
                                                        .font_weight(FontWeight::MEDIUM)
                                                        .text_color(ThemeColors::text_primary())
                                                        .child(name.clone()),
                                                )
                                                .when(!dir.is_empty(), |row| {
                                                    row.child(
                                                        div()
                                                            .text_xs()
                                                            .text_color(ThemeColors::text_muted())
                                                            .child(dir.clone()),
                                                    )
                                                })
                                                .into_any_element()
                                        }
                                        MatchedItem::Action { id, icon, .. } => h_flex()
                                            .items_center()
                                            .gap_2()
                                            .child(
                                                Icon::new(*icon)
                                                    .size(px(14.0))
                                                    .text_color(ThemeColors::accent_green()),
                                            )
                                            .child(
                                                div()
                                                    .text_xs()
                                                    .font_weight(FontWeight::MEDIUM)
                                                    .text_color(ThemeColors::text_primary())
                                                    .child(action_display_name(id, cx)),
                                            )
                                            .into_any_element(),
                                    })
                                    .child(match &item {
                                        MatchedItem::File { .. } => div()
                                            .text_xs()
                                            .text_color(ThemeColors::text_muted())
                                            .child(crate::i18n::menu_text(cx, "menu.file"))
                                            .into_any_element(),
                                        MatchedItem::Action { shortcut, .. } => {
                                            if let Some(sc) = shortcut {
                                                div()
                                                    .px_1p5()
                                                    .py(px(1.0))
                                                    .rounded_sm()
                                                    .bg(ThemeColors::bg_titlebar())
                                                    .border_1()
                                                    .border_color(ThemeColors::border())
                                                    .text_xs()
                                                    .text_color(ThemeColors::text_muted())
                                                    .child(sc.clone())
                                                    .into_any_element()
                                            } else {
                                                div().into_any_element()
                                            }
                                        }
                                    })
                                    .on_click(cx.listener(move |this, _event, _window, cx| {
                                        this.select_item(&item_clone, cx);
                                    }))
                            })),
                    )
                    .child(
                        // 4. 底部标题
                        h_flex()
                            .h(px(26.0))
                            .w_full()
                            .items_center()
                            .justify_end()
                            .px_3()
                            .bg(ThemeColors::bg_titlebar())
                            .border_t_1()
                            .border_color(ThemeColors::border())
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::text_muted())
                                    .child(crate::i18n::menu_text(cx, "workbench.search")),
                            ),
                    ),
            )
    }
}

impl SearchEverywhereModal {
    fn render_scope_pill(
        &self,
        id: &'static str,
        label: String,
        is_active: bool,
        scope: SearchScope,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        h_flex()
            .id(id)
            .items_center()
            .px_2p5()
            .py(px(2.0))
            .rounded_full()
            .cursor_pointer()
            .text_xs()
            .when(is_active, |pill| {
                pill.bg(ThemeColors::accent_blue())
                    .text_color(ThemeColors::text_primary())
                    .font_weight(FontWeight::BOLD)
            })
            .when(!is_active, |pill| {
                pill.text_color(ThemeColors::text_muted()).hover(|h| {
                    h.bg(ThemeColors::bg_tab_hover())
                        .text_color(ThemeColors::text_primary())
                })
            })
            .child(label)
            .on_click(cx.listener(move |this, _event, _window, cx| {
                this.scope = scope;
                this.selected_index = 0;
                cx.notify();
            }))
    }
}
