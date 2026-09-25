use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::InputEvent;
use gpui_kit::component::{h_flex, v_flex, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, rgba, uniform_list, AnyElement, Context, EventEmitter, FocusHandle, FontWeight,
    InteractiveElement as _, IntoElement, KeyDownEvent, ParentElement as _, Render, ScrollStrategy,
    StatefulInteractiveElement as _, Styled as _, Subscription, UniformListScrollHandle, Window,
};

use crate::theme::ThemeColors;
use crate::workbench::search_input::SearchInput;

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

/// 结果条数上限，对齐 macOS `SearchEverywhereResults.matchLimit`；
/// 命中顶到上限时列表底部展示 "… more" 提示行。
const RESULT_LIMIT: usize = 200;

/// IntelliJ / macOS Lithe 风格居中全局搜索模态弹窗
///
/// 性能约束（对齐 macOS `SearchEverywhereView` 的 LazyVStack + matchLimit）：
/// 命中列表只在查询 / 范围 / 文件索引变化时重算一次并缓存，渲染走官方
/// `uniform_list` 虚拟化（只布局可见行），禁止在 render 里全量过滤文件。
pub struct SearchEverywhereModal {
    pub query: String,
    pub scope: SearchScope,
    pub files: Vec<String>,
    /// 与 `files` 平行的小写副本，避免每次按键对全量路径做 `to_lowercase` 分配。
    files_lower: Vec<String>,
    pub actions: Vec<SearchActionItem>,
    /// 命中结果缓存（已按 `RESULT_LIMIT` 截断），只在查询/范围/索引变化时重算。
    pub filtered: Vec<MatchedItem>,
    /// 命中数顶到 `RESULT_LIMIT` 时为 true，列表底部展示 "… more"。
    filtered_truncated: bool,
    pub selected_index: usize,
    pub focus_handle: FocusHandle,
    /// 结果列表滚动句柄，键盘导航时把选中项滚到可视区中央（对齐 macOS）。
    list_handle: UniformListScrollHandle,
    /// 搜索框（复用统一搜索输入实现：IME / 粘贴由组件处理）。
    search: SearchInput,
    _search_subscription: Subscription,
    /// 打开时需要在下一帧复位并聚焦搜索框（只做一次）。
    pending_reset: bool,
}

impl EventEmitter<SearchEverywhereEvent> for SearchEverywhereModal {}

impl SearchEverywhereModal {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search = SearchInput::new(
            crate::i18n::menu_text(cx, "search.everywherePlaceholder"),
            window,
            cx,
        );
        let _search_subscription = search.subscribe(cx, |this, event, cx| match event {
            InputEvent::Change => {
                this.query = this.search.value(cx);
                this.selected_index = 0;
                this.recompute_filtered(cx);
                cx.notify();
            }
            InputEvent::PressEnter { shift, .. } => {
                let idx = if *shift {
                    this.selected_index.saturating_sub(1)
                } else if this.filtered.is_empty() {
                    0
                } else {
                    this.selected_index.min(this.filtered.len() - 1)
                };
                if let Some(item) = this.filtered.get(idx).cloned() {
                    this.select_item(&item, cx);
                }
            }
            _ => {}
        });
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
            files_lower: Vec::new(),
            actions,
            filtered: Vec::new(),
            filtered_truncated: false,
            selected_index: 0,
            focus_handle: cx.focus_handle(),
            list_handle: UniformListScrollHandle::new(),
            search,
            _search_subscription,
            pending_reset: true,
        }
    }

    pub fn set_files(&mut self, files: Vec<String>, cx: &mut Context<Self>) {
        // 小写副本一次性预算，查询匹配只做 `contains`，不再逐路径分配。
        self.files_lower = files.iter().map(|f| f.to_lowercase()).collect();
        self.files = files;
        self.recompute_filtered(cx);
        cx.notify();
    }

    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.query.clear();
        self.selected_index = 0;
        self.recompute_filtered(cx);
        self.pending_reset = true;
        cx.notify();
    }

    /// 按当前查询与范围重算命中列表并缓存（对齐 macOS `matchLimit` 截断）。
    ///
    /// 空查询时直接清空结果（macOS `if hasQuery` 才展示结果区），
    /// 避免打开弹窗就渲染整个工作区文件列表。
    fn recompute_filtered(&mut self, cx: &gpui_kit::App) {
        self.filtered.clear();
        self.filtered_truncated = false;
        self.selected_index = self.selected_index.min(self.filtered.len());

        let q = self.query.trim().to_lowercase();
        if q.is_empty() {
            return;
        }

        // 1. Files：顶到 RESULT_LIMIT 即停，避免大工作区全量收集。
        if self.scope == SearchScope::All || self.scope == SearchScope::Files {
            for (file, file_lower) in self.files.iter().zip(self.files_lower.iter()) {
                if self.filtered.len() >= RESULT_LIMIT {
                    self.filtered_truncated = true;
                    break;
                }
                if file_lower.contains(&q) {
                    let (dir, name) = if let Some((d, n)) = file.rsplit_once('/') {
                        (d.to_string(), n.to_string())
                    } else {
                        (String::new(), file.clone())
                    };
                    self.filtered.push(MatchedItem::File {
                        path: file.clone(),
                        name,
                        dir,
                    });
                }
            }
        }

        // 2. Actions（本地化显示名、英文原名、id 任一包含即命中）。
        if !self.filtered_truncated
            && (self.scope == SearchScope::All || self.scope == SearchScope::Actions)
        {
            for act in &self.actions {
                if self.filtered.len() >= RESULT_LIMIT {
                    self.filtered_truncated = true;
                    break;
                }
                let display = action_display_name(&act.id, cx);
                if display.to_lowercase().contains(&q)
                    || act.name.to_lowercase().contains(&q)
                    || act.id.to_lowercase().contains(&q)
                {
                    self.filtered.push(MatchedItem::Action {
                        id: act.id.clone(),
                        shortcut: act.shortcut.clone(),
                        icon: act.icon,
                    });
                }
            }
        }

        self.selected_index = self.selected_index.min(self.filtered.len());
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
        // 打开后只复位/聚焦搜索框一次；不要每帧抢焦点（否则输入框打不进字）。
        if self.pending_reset {
            self.pending_reset = false;
            self.search.set_value("", window, cx);
            self.search.focus(window, cx);
        }

        // 命中列表已缓存（recompute_filtered），渲染只读缓存，不做全量过滤。
        // 对齐 macOS：空查询不渲染结果区（`if hasQuery`）。
        let has_query = !self.query.trim().is_empty();

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
                // 字符输入 / 退格 / 空格由搜索框处理（含 IME 与粘贴）；
                // 这里只管方向键与 Esc。
                match event.keystroke.key.as_str() {
                    "escape" => cx.emit(SearchEverywhereEvent::Close),
                    "up" | "arrowup" => {
                        if this.selected_index > 0 {
                            this.selected_index -= 1;
                            // 对齐 macOS：选中项变化后滚动到可视区中央。
                            this.list_handle
                                .scroll_to_item(this.selected_index, ScrollStrategy::Center);
                            cx.notify();
                        }
                    }
                    "down" | "arrowdown" => {
                        let total = this.filtered.len();
                        if total > 0 && this.selected_index + 1 < total {
                            this.selected_index += 1;
                            this.list_handle
                                .scroll_to_item(this.selected_index, ScrollStrategy::Center);
                            cx.notify();
                        }
                    }
                    _ => {}
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
                            .child(self.search.element())
                            .when(!self.query.is_empty(), |row| {
                                row.child(
                                    Button::new("clear-search-query")
                                        .small()
                                        .ghost()
                                        .icon(IconName::Close)
                                        .on_click(cx.listener(|this, _event, window, cx| {
                                            this.query.clear();
                                            this.selected_index = 0;
                                            this.search.set_value("", window, cx);
                                            this.search.focus(window, cx);
                                            this.recompute_filtered(cx);
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
                        // 3. 结果列表展示区：对齐 macOS `if hasQuery`，空查询不渲染
                        // 结果区；列表走官方 `uniform_list` 虚拟化，只布局可见行。
                        {
                            let list_handle = self.list_handle.clone();
                            let result_count = self.filtered.len();
                            v_flex().w_full().when(has_query, |list| {
                                if result_count == 0 {
                                    list.child(
                                        div()
                                            .w_full()
                                            .py_8()
                                            .text_center()
                                            .text_xs()
                                            .text_color(ThemeColors::text_muted())
                                            .child(crate::i18n::menu_text(cx, "search.noResults")),
                                    )
                                } else {
                                    list.child(
                                        uniform_list(
                                            "search-everywhere-results",
                                            result_count,
                                            cx.processor(
                                                move |this,
                                                      visible: std::ops::Range<usize>,
                                                      _window,
                                                      cx| {
                                                    let current = if this.filtered.is_empty() {
                                                        0
                                                    } else {
                                                        this.selected_index
                                                            .min(this.filtered.len() - 1)
                                                    };
                                                    visible.clone().filter_map(|idx| {
                                                        let item =
                                                            this.filtered.get(idx)?.clone();
                                                        Some(this.render_result_row(
                                                            idx, item, current, cx,
                                                        ))
                                                    })
                                                    .collect::<Vec<_>>()
                                                },
                                            ),
                                        )
                                        .track_scroll(&list_handle)
                                        .h(px(320.0))
                                        .w_full()
                                        .py_1(),
                                    )
                                    // 对齐 macOS `moreRow`：命中顶到上限时提示还有更多。
                                    .when(self.filtered_truncated, |list| {
                                        list.child(
                                            h_flex()
                                                .h(px(22.0))
                                                .w_full()
                                                .items_center()
                                                .px_3()
                                                .child(
                                                    div()
                                                        .text_xs()
                                                        .text_color(ThemeColors::text_muted())
                                                        .child("… more"),
                                                ),
                                        )
                                    })
                                }
                            })
                        },
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
    /// 渲染单条命中行（由 `uniform_list` 按可见范围调用，样式与旧版一致）。
    fn render_result_row(
        &self,
        idx: usize,
        item: MatchedItem,
        current_index: usize,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let is_selected = idx == current_index;

        h_flex()
            .id(("search-everywhere-result", idx))
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
                if let Some(item) = this.filtered.get(idx).cloned() {
                    this.select_item(&item, cx);
                }
            }))
            .into_any_element()
    }

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
                this.recompute_filtered(cx);
                cx.notify();
            }))
    }
}
