//! 右侧扩展面板：搜索 + 分类签 + 列表点选 + 详情，对齐 Tauri
//! `windows/tauri/src/extensions/ui/components/extensions-sidebar.tsx`
//! 的展示语义（标题计数、分类签计数、行点选、详情徽标与主操作）。
//!
//! 平台适配说明：Tauri 的扩展页在中央开 buffer 左右两栏展示，Linux 中央是
//! 编辑器 Tab 且右侧面板较窄，因此列表与详情纵向堆叠（列表上、详情下）；
//! 安装/更新/主题选用等需要远端市场与外观系统的能力暂不提供，主操作仅为
//! 启用/停用（落盘到 `~/.config/lithe/extensions.json`）。头部 X 只发射
//! [`ExtensionsEvent::Close`]，由外部（`view.rs`）决定面板显隐，与
//! [`crate::workbench::maven::MavenView`] 一致。

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, AnyElement, AppContext as _, Context, Entity, EventEmitter, FontWeight,
    InteractiveElement as _, IntoElement, ParentElement as _, Render,
    StatefulInteractiveElement as _, Styled as _, Subscription, Window,
};

use crate::theme::ThemeColors;

/// 扩展分类：与 Tauri `FILTER_TABS` 的 9 个 tab id 逐一对齐。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ExtensionCategory {
    #[default]
    All,
    Language,
    Theme,
    IconTheme,
    Database,
    Ai,
    Integration,
    Skill,
    Agent,
}

impl ExtensionCategory {
    /// 分类签的固定顺序，与 Tauri `FILTER_TABS` 一致。
    pub const ALL: [ExtensionCategory; 9] = [
        ExtensionCategory::All,
        ExtensionCategory::Language,
        ExtensionCategory::Theme,
        ExtensionCategory::IconTheme,
        ExtensionCategory::Database,
        ExtensionCategory::Ai,
        ExtensionCategory::Integration,
        ExtensionCategory::Skill,
        ExtensionCategory::Agent,
    ];

    /// 稳定 id，与 Tauri 的 tab id 对齐。
    pub fn as_str(self) -> &'static str {
        match self {
            ExtensionCategory::All => "all",
            ExtensionCategory::Language => "language",
            ExtensionCategory::Theme => "theme",
            ExtensionCategory::IconTheme => "icon-theme",
            ExtensionCategory::Database => "database",
            ExtensionCategory::Ai => "ai",
            ExtensionCategory::Integration => "integration",
            ExtensionCategory::Skill => "skill",
            ExtensionCategory::Agent => "agent",
        }
    }

    /// 分类签图标：对齐 Tauri 各 tab 图标；`all` 无图标。
    pub fn icon(self) -> Option<IconName> {
        match self {
            ExtensionCategory::All => None,
            ExtensionCategory::Language => Some(IconName::Languages),
            ExtensionCategory::Theme => Some(IconName::Paintbrush),
            ExtensionCategory::IconTheme => Some(IconName::Package),
            ExtensionCategory::Database => Some(IconName::Database),
            ExtensionCategory::Ai => Some(IconName::Sparkles),
            ExtensionCategory::Integration => Some(IconName::Plug),
            ExtensionCategory::Skill => Some(IconName::Brain),
            ExtensionCategory::Agent => Some(IconName::Bot),
        }
    }

    fn from_str(id: &str) -> Option<Self> {
        match id {
            "all" => Some(ExtensionCategory::All),
            "language" => Some(ExtensionCategory::Language),
            "theme" => Some(ExtensionCategory::Theme),
            "icon-theme" => Some(ExtensionCategory::IconTheme),
            "database" => Some(ExtensionCategory::Database),
            "ai" => Some(ExtensionCategory::Ai),
            "integration" => Some(ExtensionCategory::Integration),
            "skill" => Some(ExtensionCategory::Skill),
            "agent" => Some(ExtensionCategory::Agent),
            _ => None,
        }
    }
}

/// 单个扩展条目：仓库插件扫描结果或内置项（本地均视为已安装）。
#[derive(Debug, Clone)]
pub struct ExtensionItem {
    /// 稳定 id：`package.json` 的 name、`plugin.json` 的 id 或内置 id。
    pub id: String,
    pub name: String,
    pub version: String,
    pub description: String,
    pub category: ExtensionCategory,
    /// 发布者：`package.json` 的 publisher/author，缺失为 `None`（不展示）。
    pub publisher: Option<String>,
    /// 是否随产品发布（对齐 Tauri `isBundled` 徽标）。
    pub is_bundled: bool,
}

/// 扩展面板派发的事件。
#[derive(Debug, Clone)]
pub enum ExtensionsEvent {
    Close,
}

/// 右侧扩展面板：搜索框 + 分类签 + 列表点选 + 详情。
pub struct ExtensionsView {
    items: Vec<ExtensionItem>,
    /// 启用状态 `{id: bool}`，缺省视为启用，落盘到
    /// `~/.config/lithe/extensions.json`。
    enabled: HashMap<String, bool>,
    search_input: Option<Entity<InputState>>,
    _search_subscription: Option<Subscription>,
    category: ExtensionCategory,
    /// 选中的扩展 id（对齐 Tauri `selectedExtensionId`；过滤后不在列表
    /// 则展示回退到首项，不在此处改写）。
    selected: Option<String>,
}

impl EventEmitter<ExtensionsEvent> for ExtensionsView {}

impl ExtensionsView {
    pub fn new(_cx: &mut Context<Self>) -> Self {
        let mut view = Self {
            items: Vec::new(),
            enabled: load_enabled(),
            search_input: None,
            _search_subscription: None,
            category: ExtensionCategory::All,
            selected: None,
        };
        view.rescan();
        view
    }

    /// 重新扫描仓库插件（内置项常驻）；选中项消失则清空选中。
    pub fn rescan(&mut self) {
        let mut items = builtin_items();
        items.extend(scan_plugins());
        // 按 id 去重（扫描到的优先），再按名称稳定排序。
        let mut seen = std::collections::HashSet::new();
        items.retain(|item| seen.insert(item.id.clone()));
        items.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
        if let Some(selected) = self.selected.clone() {
            if !items.iter().any(|item| item.id == selected) {
                self.selected = None;
            }
        }
        self.items = items;
    }

    pub fn is_enabled(&self, id: &str) -> bool {
        self.enabled.get(id).copied().unwrap_or(true)
    }

    fn toggle(&mut self, id: &str, cx: &mut Context<Self>) {
        let next = !self.is_enabled(id);
        self.enabled.insert(id.to_string(), next);
        save_enabled(&self.enabled);
        cx.notify();
    }

    /// 懒创建搜索输入框（参考 `settings_dialog.rs::ensure_input`）。
    fn ensure_search_input(
        slot: &mut Option<Entity<InputState>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<InputState> {
        if let Some(entity) = slot.clone() {
            return entity;
        }
        let entity = cx.new(|cx| InputState::new(window, cx));
        *slot = Some(entity.clone());
        entity
    }

    fn search_query(&self, cx: &mut Context<Self>) -> String {
        self.search_input
            .as_ref()
            .map(|e| e.read(cx).value().to_string())
            .unwrap_or_default()
    }

    /// 搜索过滤（先搜索后分签，对齐 Tauri `searchMatchedExtensions`）。
    fn search_matched(&self, query: &str) -> Vec<&ExtensionItem> {
        let q = query.trim().to_lowercase();
        self.items
            .iter()
            .filter(|item| {
                q.is_empty()
                    || item.name.to_lowercase().contains(&q)
                    || item.description.to_lowercase().contains(&q)
                    || item.id.to_lowercase().contains(&q)
            })
            .collect()
    }

    /// 各分类签计数（搜索命中内部分类计数，对齐 Tauri `filterCounts`）。
    fn tab_counts(&self, matched: &[&ExtensionItem]) -> [usize; 9] {
        let mut counts = [0usize; 9];
        for (ix, category) in ExtensionCategory::ALL.iter().enumerate() {
            counts[ix] = if *category == ExtensionCategory::All {
                matched.len()
            } else {
                matched
                    .iter()
                    .filter(|item| item.category == *category)
                    .count()
            };
        }
        counts
    }

    /// 分类签行：横滑签 + 计数角标，对齐 Tauri `FILTER_TABS` 行。
    fn render_tab_row(&self, counts: &[usize; 9], cx: &mut Context<Self>) -> impl IntoElement {
        h_flex()
            .w_full()
            .gap_1()
            .overflow_x_scrollbar()
            .py_1()
            .children(
                ExtensionCategory::ALL
                    .iter()
                    .enumerate()
                    .map(|(ix, category)| {
                        let count = counts[ix];
                        let active = self.category == *category;
                        let id = category.as_str().to_string();
                        h_flex()
                            .id(format!("ext-tab-{id}"))
                            .flex_shrink_0()
                            .items_center()
                            .gap_1p5()
                            .h(px(28.0))
                            .px_2p5()
                            .rounded_sm()
                            .cursor_pointer()
                            .text_xs()
                            .when(active, |el| {
                                el.bg(ThemeColors::subtle_selection())
                                    .text_color(ThemeColors::text_primary())
                            })
                            .when(!active, |el| {
                                el.text_color(ThemeColors::text_muted()).hover(|h| {
                                    h.bg(ThemeColors::bg_tab_hover())
                                        .text_color(ThemeColors::text_primary())
                                })
                            })
                            .when_some(category.icon(), |el, icon| {
                                el.child(Icon::new(icon).size(px(13.0)).text_color(if active {
                                    ThemeColors::text_primary()
                                } else {
                                    ThemeColors::text_muted()
                                }))
                            })
                            .child(category_label(*category, cx))
                            .child(
                                div()
                                    .px_1()
                                    .rounded_sm()
                                    .text_xs()
                                    .bg(if active {
                                        ThemeColors::accent_blue()
                                    } else {
                                        ThemeColors::bg_tab_hover()
                                    })
                                    .text_color(if active {
                                        ThemeColors::foreground()
                                    } else {
                                        ThemeColors::text_muted()
                                    })
                                    .child(count.to_string()),
                            )
                            .on_click(cx.listener(move |this, _event, _window, cx| {
                                if let Some(category) = ExtensionCategory::from_str(&id) {
                                    this.category = category;
                                    cx.notify();
                                }
                            }))
                    }),
            )
    }

    /// 状态徽标：分类 / 已安装 / 已禁用 / 内置，对齐 Tauri 详情徽标行。
    fn render_badge(text: String, highlighted: bool) -> AnyElement {
        div()
            .px_1p5()
            .py_0p5()
            .rounded_sm()
            .border_1()
            .text_xs()
            .border_color(if highlighted {
                ThemeColors::accent_blue()
            } else {
                ThemeColors::border()
            })
            .text_color(if highlighted {
                ThemeColors::accent_blue()
            } else {
                ThemeColors::text_muted()
            })
            .child(text)
            .into_any_element()
    }

    /// 详情区：图标 + 名 + 发布者/版本 + 徽标 + 描述 + 主操作 + 贡献项，
    /// 对齐 Tauri 右侧详情栏（纵向堆叠适配窄面板）。
    fn render_detail(&self, item: &ExtensionItem, cx: &mut Context<Self>) -> AnyElement {
        let enabled = self.is_enabled(&item.id);
        let item_id = item.id.clone();
        let mut badges = vec![Self::render_badge(category_label(item.category, cx), false)];
        badges.push(Self::render_badge(
            crate::i18n::menu_text(cx, "extensions.installed").to_string(),
            true,
        ));
        if !enabled {
            badges.push(Self::render_badge(
                crate::i18n::menu_text(cx, "extensions.disabled").to_string(),
                false,
            ));
        }
        if item.is_bundled {
            badges.push(Self::render_badge(
                crate::i18n::menu_text(cx, "extensions.builtIn").to_string(),
                true,
            ));
        }
        let by_publisher = item.publisher.clone().map(|publisher| {
            crate::i18n::menu_text(cx, "extensions.byPublisher").replace("{publisher}", &publisher)
        });
        v_flex()
            .w_full()
            .gap_2()
            .p_3()
            .child(
                h_flex()
                    .w_full()
                    .items_center()
                    .gap_2p5()
                    .child(
                        div()
                            .flex_shrink_0()
                            .size(px(40.0))
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded_md()
                            .border_1()
                            .border_color(ThemeColors::border())
                            .bg(ThemeColors::background())
                            .child(
                                Icon::new(item.category.icon().unwrap_or(IconName::Puzzle))
                                    .size(px(18.0))
                                    .text_color(ThemeColors::text_muted()),
                            ),
                    )
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .child(
                                div()
                                    .truncate()
                                    .text_sm()
                                    .font_weight(FontWeight::BOLD)
                                    .text_color(ThemeColors::text_primary())
                                    .child(item.name.clone()),
                            )
                            .when_some(by_publisher, |el, text| {
                                el.child(
                                    div()
                                        .truncate()
                                        .text_xs()
                                        .text_color(ThemeColors::text_muted())
                                        .child(text),
                                )
                            })
                            .when(!item.version.is_empty(), |el| {
                                el.child(
                                    div()
                                        .text_xs()
                                        .text_color(ThemeColors::text_muted())
                                        .child(format!("v{}", item.version)),
                                )
                            }),
                    ),
            )
            .child(h_flex().w_full().flex_wrap().gap_1p5().children(badges))
            .when(!item.description.is_empty(), |el| {
                el.child(
                    div()
                        .w_full()
                        .text_xs()
                        .text_color(ThemeColors::text_muted())
                        .child(item.description.clone()),
                )
            })
            .child(
                Button::new(format!("ext-detail-toggle-{}", item.id))
                    .small()
                    .when(enabled, |b| b.ghost())
                    .when(!enabled, |b| b.primary())
                    .icon(if enabled {
                        IconName::Close
                    } else {
                        IconName::Check
                    })
                    .label(if enabled {
                        crate::i18n::menu_text(cx, "extensions.deactivate").to_string()
                    } else {
                        crate::i18n::menu_text(cx, "extensions.activate").to_string()
                    })
                    .on_click(cx.listener(move |this, _event, _window, cx| {
                        this.toggle(&item_id, cx);
                    })),
            )
            .child(
                v_flex()
                    .w_full()
                    .gap_1p5()
                    .child(
                        div()
                            .text_xs()
                            .font_weight(FontWeight::BOLD)
                            .text_color(ThemeColors::text_primary())
                            .child(crate::i18n::menu_text(cx, "extensions.contributions")),
                    )
                    .child(
                        h_flex()
                            .w_full()
                            .flex_wrap()
                            .gap_1p5()
                            .child(Self::render_badge(category_label(item.category, cx), false)),
                    ),
            )
            .into_any_element()
    }
}

/// 分类签文案：`extensions.*` 与 Tauri `locale.ts` 同键。
fn category_label(category: ExtensionCategory, cx: &gpui_kit::App) -> String {
    let key = match category {
        ExtensionCategory::All => "extensions.all",
        ExtensionCategory::Language => "extensions.languages",
        ExtensionCategory::Theme => "extensions.themes",
        ExtensionCategory::IconTheme => "extensions.iconThemes",
        ExtensionCategory::Database => "extensions.databases",
        ExtensionCategory::Ai => "extensions.ai",
        ExtensionCategory::Integration => "extensions.integrations",
        ExtensionCategory::Skill => "extensions.skills",
        ExtensionCategory::Agent => "extensions.agents",
    };
    crate::i18n::menu_text(cx, key).to_string()
}

impl Render for ExtensionsView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 搜索框懒创建 + 一次性订阅 Change 事件，保证输入时列表实时过滤。
        let search_entity = Self::ensure_search_input(&mut self.search_input, window, cx);
        if self._search_subscription.is_none() {
            self._search_subscription = Some(cx.subscribe(
                &search_entity,
                |_this: &mut Self, _, event: &InputEvent, cx| {
                    if matches!(event, InputEvent::Change) {
                        cx.notify();
                    }
                },
            ));
        }
        let query = self.search_query(cx);
        let matched = self.search_matched(&query);
        let counts = self.tab_counts(&matched);
        let filtered: Vec<&ExtensionItem> = matched
            .iter()
            .filter(|item| {
                self.category == ExtensionCategory::All || item.category == self.category
            })
            .copied()
            .collect();
        // 选中不在过滤结果内则回退首项（对齐 Tauri `selectedExtension` 回退）。
        let selected_id = self
            .selected
            .clone()
            .filter(|id| filtered.iter().any(|item| item.id == *id))
            .or_else(|| filtered.first().map(|item| item.id.clone()));
        let installed = self.items.len();
        let subtitle = format!(
            "{} · {}",
            crate::i18n::menu_text(cx, "extensions.availableCount")
                .replace("{count}", &filtered.len().to_string()),
            crate::i18n::menu_text(cx, "extensions.installedCount")
                .replace("{count}", &installed.to_string()),
        );

        let mut rows = Vec::new();
        for item in &filtered {
            let enabled = self.is_enabled(&item.id);
            let selected = selected_id.as_deref() == Some(item.id.as_str());
            let id_owned = item.id.clone();
            rows.push(
                h_flex()
                    .id(format!("ext-row-{}", item.id))
                    .w_full()
                    .items_center()
                    .gap_2p5()
                    .px_2()
                    .py_1p5()
                    .rounded_md()
                    .cursor_pointer()
                    .when(selected, |el| {
                        el.bg(ThemeColors::subtle_selection())
                            .text_color(ThemeColors::text_primary())
                    })
                    .when(!selected, |el| {
                        el.hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                    })
                    .child(
                        div()
                            .flex_shrink_0()
                            .size(px(36.0))
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded_md()
                            .border_1()
                            .border_color(ThemeColors::border())
                            .bg(ThemeColors::background())
                            .child(
                                Icon::new(item.category.icon().unwrap_or(IconName::Puzzle))
                                    .size(px(16.0))
                                    .text_color(ThemeColors::text_muted()),
                            ),
                    )
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .child(
                                div()
                                    .truncate()
                                    .text_xs()
                                    .font_weight(FontWeight::BOLD)
                                    .text_color(ThemeColors::text_primary())
                                    .child(item.name.clone()),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .truncate()
                                    .text_color(ThemeColors::text_muted())
                                    .child(item.description.clone()),
                            ),
                    )
                    .child(if enabled {
                        div()
                            .flex_shrink_0()
                            .size(px(28.0))
                            .flex()
                            .items_center()
                            .justify_center()
                            .text_color(ThemeColors::text_muted())
                            .child(
                                Icon::new(IconName::Check)
                                    .size(px(14.0))
                                    .text_color(ThemeColors::text_muted()),
                            )
                            .into_any_element()
                    } else {
                        Button::new(format!("ext-install-{}", item.id))
                            .small()
                            .primary()
                            .icon(IconName::Plus)
                            .tooltip(crate::i18n::menu_text(cx, "extensions.activate"))
                            .on_click(cx.listener(move |this, _event, _window, cx| {
                                this.enabled.insert(id_owned.clone(), true);
                                save_enabled(&this.enabled);
                                cx.notify();
                            }))
                            .into_any_element()
                    })
                    .on_click(cx.listener({
                        let id_owned = item.id.clone();
                        move |this, _event, _window, cx| {
                            this.selected = Some(id_owned.clone());
                            cx.notify();
                        }
                    }))
                    .into_any_element(),
            );
        }
        let detail = selected_id
            .as_deref()
            .and_then(|id| filtered.iter().find(|item| item.id == id))
            .map(|item| self.render_detail(item, cx));

        v_flex()
            .size_full()
            .bg(ThemeColors::bg_sidebar())
            .border_l_1()
            .border_color(ThemeColors::border())
            .child(
                h_flex()
                    .h(px(32.0))
                    .w_full()
                    .bg(ThemeColors::bg_sidebar())
                    .border_b_1()
                    .border_color(ThemeColors::border())
                    .items_center()
                    .justify_between()
                    .px_3()
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .child(
                                div()
                                    .text_xs()
                                    .font_weight(FontWeight::BOLD)
                                    .text_color(ThemeColors::text_muted())
                                    .child(crate::i18n::menu_text(cx, "extensions.title")),
                            )
                            .child(
                                div()
                                    .truncate()
                                    .text_xs()
                                    .text_color(ThemeColors::text_muted())
                                    .child(subtitle),
                            ),
                    )
                    .child(
                        Button::new("extensions-close")
                            .small()
                            .ghost()
                            .icon(IconName::Close)
                            .tooltip(crate::i18n::menu_text(cx, "ui.close"))
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                cx.emit(ExtensionsEvent::Close);
                            })),
                    ),
            )
            .child(
                v_flex()
                    .w_full()
                    .flex_shrink_0()
                    .gap_1()
                    .px_2()
                    .pt_2()
                    .child(
                        div()
                            .w_full()
                            .child(Input::new(&search_entity).cleanable(true)),
                    )
                    .child(self.render_tab_row(&counts, cx)),
            )
            .child(if rows.is_empty() {
                div()
                    .flex_1()
                    .w_full()
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_xs()
                    .text_color(ThemeColors::text_muted())
                    .child(crate::i18n::menu_text(cx, "extensions.noneFound"))
                    .into_any_element()
            } else {
                div()
                    .flex_1()
                    .w_full()
                    .min_h_0()
                    .overflow_y_scrollbar()
                    .px_1()
                    .children(rows)
                    .into_any_element()
            })
            .when_some(detail, |el, detail| {
                el.child(
                    div()
                        .w_full()
                        .flex_shrink_0()
                        .max_h(px(340.0))
                        .overflow_y_scrollbar()
                        .border_t_1()
                        .border_color(ThemeColors::border())
                        .bg(ThemeColors::bg_sidebar())
                        .child(detail),
                )
            })
    }
}

/// 内置项：随产品发布，不参与仓库扫描。
fn builtin_items() -> Vec<ExtensionItem> {
    vec![
        ExtensionItem {
            id: "git".to_string(),
            name: "Git".to_string(),
            version: "0.1.0".to_string(),
            description: "Git source control integration".to_string(),
            category: ExtensionCategory::Integration,
            publisher: None,
            is_bundled: true,
        },
        ExtensionItem {
            id: "maven".to_string(),
            name: "Maven".to_string(),
            version: "0.1.0".to_string(),
            description: "Maven project navigation and lifecycle".to_string(),
            category: ExtensionCategory::Integration,
            publisher: None,
            is_bundled: true,
        },
        ExtensionItem {
            id: "terminal".to_string(),
            name: "Terminal".to_string(),
            version: "0.1.0".to_string(),
            description: "Integrated terminal".to_string(),
            category: ExtensionCategory::Integration,
            publisher: None,
            is_bundled: true,
        },
    ]
}

/// 扫描仓库 `Plugins/` 目录：每个子目录优先读 `package.json`，缺失则读
/// `plugin.json`（仓库现状），二者皆无则跳过（由父目录继续下钻）。
/// 最大递归深度 4，跳过隐藏目录与构建产物目录。
fn scan_plugins() -> Vec<ExtensionItem> {
    let Some(root) = plugins_root() else {
        return Vec::new();
    };
    let mut out = Vec::new();
    walk_plugins_dir(&root, 0, &mut out);
    out
}

fn plugins_root() -> Option<PathBuf> {
    let mut candidates = Vec::new();
    if let Ok(cwd) = std::env::current_dir() {
        candidates.push(cwd.join("Plugins"));
    }
    if let Ok(exe) = std::env::current_exe() {
        let mut dir = exe.parent().map(Path::to_path_buf);
        for _ in 0..6 {
            let Some(current) = dir.clone() else {
                break;
            };
            candidates.push(current.join("Plugins"));
            dir = current.parent().map(Path::to_path_buf);
        }
    }
    candidates.into_iter().find(|path| path.is_dir())
}

const MAX_PLUGIN_SCAN_DEPTH: usize = 4;

const PLUGIN_SCAN_SKIP_DIRS: [&str; 7] = [
    "target",
    "node_modules",
    ".git",
    "dist",
    "build",
    "out",
    "vendor",
];

fn walk_plugins_dir(dir: &Path, depth: usize, out: &mut Vec<ExtensionItem>) {
    if depth > MAX_PLUGIN_SCAN_DEPTH {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut entries: Vec<_> = entries.flatten().collect();
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') || PLUGIN_SCAN_SKIP_DIRS.contains(&name.as_str()) {
            continue;
        }
        if let Some(item) = read_manifest(&path, &name) {
            out.push(item);
        }
        walk_plugins_dir(&path, depth + 1, out);
    }
}

#[derive(Debug, serde::Deserialize)]
struct PackageJson {
    name: Option<String>,
    version: Option<String>,
    description: Option<String>,
    keywords: Option<Vec<String>>,
    publisher: Option<String>,
    author: Option<String>,
}

#[derive(Debug, serde::Deserialize)]
struct PluginJson {
    id: Option<String>,
    #[serde(rename = "displayName")]
    display_name: Option<String>,
    version: Option<String>,
    description: Option<String>,
    #[serde(rename = "languageSupports")]
    language_supports: Option<Vec<serde_json::Value>>,
}

/// 读单个插件目录的清单：`package.json` 优先，`plugin.json` 兜底，
/// 字段缺失时用目录名；`plugin.json` 含非空 `languageSupports` 即归语言类。
fn read_manifest(dir: &Path, dir_name: &str) -> Option<ExtensionItem> {
    let package_path = dir.join("package.json");
    if package_path.is_file() {
        let text = std::fs::read_to_string(&package_path).ok()?;
        let manifest: PackageJson = serde_json::from_str(&text).ok()?;
        let keywords = manifest.keywords.clone().unwrap_or_default();
        let publisher = manifest
            .publisher
            .filter(|s| !s.trim().is_empty())
            .or_else(|| manifest.author.filter(|s| !s.trim().is_empty()));
        return Some(ExtensionItem {
            id: manifest
                .name
                .clone()
                .unwrap_or_else(|| dir_name.to_string()),
            name: manifest.name.unwrap_or_else(|| dir_name.to_string()),
            version: manifest.version.unwrap_or_default(),
            description: manifest.description.unwrap_or_default(),
            category: classify_keywords(&keywords),
            publisher,
            is_bundled: false,
        });
    }
    let plugin_path = dir.join("plugin.json");
    if plugin_path.is_file() {
        let text = std::fs::read_to_string(&plugin_path).ok()?;
        let manifest: PluginJson = serde_json::from_str(&text).ok()?;
        let category = match &manifest.language_supports {
            Some(supports) if !supports.is_empty() => ExtensionCategory::Language,
            _ => classify_text(&format!(
                "{} {}",
                manifest.id.clone().unwrap_or_default(),
                manifest.display_name.clone().unwrap_or_default()
            )),
        };
        return Some(ExtensionItem {
            id: manifest.id.clone().unwrap_or_else(|| dir_name.to_string()),
            name: manifest
                .display_name
                .or(manifest.id)
                .unwrap_or_else(|| dir_name.to_string()),
            version: manifest.version.unwrap_or_default(),
            description: manifest.description.unwrap_or_default(),
            category,
            publisher: None,
            is_bundled: false,
        });
    }
    None
}

/// 按 `package.json` keywords 简单归类，无 keywords 归 integration。
fn classify_keywords(keywords: &[String]) -> ExtensionCategory {
    classify_text(&keywords.join(" "))
}

/// 关键词归类：theme/icon-theme → 主题系，language/lang/lsp/syntax →
/// 语言，database/sql → 数据库，ai/llm/agent/chat/model → AI，
/// skill → 技能，其余 → integration（对齐 Tauri 9 分类）。
fn classify_text(text: &str) -> ExtensionCategory {
    let lower = text.to_lowercase();
    let has_any = |words: &[&str]| words.iter().any(|word| lower.contains(word));
    if has_any(&["icon-theme", "icon-pack", "file-icon"]) {
        ExtensionCategory::IconTheme
    } else if has_any(&["theme", "icon", "color-scheme"]) {
        ExtensionCategory::Theme
    } else if has_any(&["language", "lang", "lsp", "syntax", "grammar"]) {
        ExtensionCategory::Language
    } else if has_any(&[
        "database", "sql", "sqlite", "postgres", "mysql", "mongo", "redis",
    ]) {
        ExtensionCategory::Database
    } else if has_any(&["skill"]) {
        ExtensionCategory::Skill
    } else if has_any(&["agent", "robot"]) {
        ExtensionCategory::Agent
    } else if has_any(&["ai", "llm", "chat", "model"]) {
        ExtensionCategory::Ai
    } else {
        ExtensionCategory::Integration
    }
}

/// 启用状态落盘路径：`<config>/lithe/extensions.json`
///（配置目录规则见 `settings::config_dir`）。
fn extensions_state_path() -> Option<PathBuf> {
    Some(crate::settings::config_dir()?.join("lithe").join("extensions.json"))
}

fn load_enabled() -> HashMap<String, bool> {
    let Some(path) = extensions_state_path() else {
        return HashMap::new();
    };
    let Ok(text) = std::fs::read_to_string(&path) else {
        return HashMap::new();
    };
    serde_json::from_str::<HashMap<String, bool>>(&text).unwrap_or_default()
}

/// 写回启用状态：临时文件 + 原子替换（参考 `settings.rs::persist`）。
fn save_enabled(enabled: &HashMap<String, bool>) {
    let Some(path) = extensions_state_path() else {
        return;
    };
    if let Some(parent) = path.parent() {
        if std::fs::create_dir_all(parent).is_err() {
            return;
        }
    }
    let Ok(text) = serde_json::to_string_pretty(enabled) else {
        return;
    };
    let tmp = path.with_extension("json.tmp");
    if std::fs::write(&tmp, text).is_ok() {
        // Windows 的 `rename` 不会覆盖已存在目标，需先移除旧文件。
        #[cfg(windows)]
        {
            let _ = std::fs::remove_file(&path);
        }
        let _ = std::fs::rename(&tmp, &path);
    }
}
