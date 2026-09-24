//! 右侧扩展面板：搜索 + 分类 + 列表 + 启用开关，对齐 Tauri
//! `windows/tauri/src/extensions/ui/components/extensions-sidebar.tsx`
//! 的搜索与分类交互语义。
//!
//! 平台适配说明：Tauri 的扩展在中央开 buffer 展示详情，Linux 中央是编辑器
//! Tab，因此扩展列表改走右侧面板；交互保持一致（搜索框过滤、分类下拉、
//! 列表行、启用开关）。头部 X 只发射 [`ExtensionsEvent::Close`]，由外部
//! （`view.rs`）决定面板显隐，与 [`crate::workbench::maven::MavenView`] 一致。

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::menu::DropdownMenu as _;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, AppContext as _, Context, Entity, EventEmitter, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, Render, StatefulInteractiveElement as _, Styled as _,
    Subscription, Window,
};

use crate::theme::ThemeColors;

/// 扩展分类：Tauri `extensionsActiveTab` 的 Linux 子集（`all` 为过滤器，
/// 其余为归类目标；`icon-theme`/`database`/`skill`/`agent` 暂归 `integration`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ExtensionCategory {
    #[default]
    All,
    Language,
    Theme,
    Ai,
    Integration,
}

impl ExtensionCategory {
    /// 分类下拉的固定顺序，与 Tauri `FILTER_TABS` 的主分组顺序一致。
    pub const ALL: [ExtensionCategory; 5] = [
        ExtensionCategory::All,
        ExtensionCategory::Language,
        ExtensionCategory::Theme,
        ExtensionCategory::Ai,
        ExtensionCategory::Integration,
    ];

    /// 稳定 id，与 Tauri 的 tab id 对齐。
    pub fn as_str(self) -> &'static str {
        match self {
            ExtensionCategory::All => "all",
            ExtensionCategory::Language => "language",
            ExtensionCategory::Theme => "theme",
            ExtensionCategory::Ai => "ai",
            ExtensionCategory::Integration => "integration",
        }
    }

    /// 下拉展示文案：`i18n.rs` 无对应键，按约定英文直写。
    pub fn label(self) -> &'static str {
        match self {
            ExtensionCategory::All => "All",
            ExtensionCategory::Language => "Languages",
            ExtensionCategory::Theme => "Themes",
            ExtensionCategory::Ai => "AI",
            ExtensionCategory::Integration => "Integrations",
        }
    }

    fn from_str(id: &str) -> Option<Self> {
        match id {
            "all" => Some(ExtensionCategory::All),
            "language" => Some(ExtensionCategory::Language),
            "theme" => Some(ExtensionCategory::Theme),
            "ai" => Some(ExtensionCategory::Ai),
            "integration" => Some(ExtensionCategory::Integration),
            _ => None,
        }
    }
}

/// 单个扩展条目：仓库插件扫描结果或内置项。
#[derive(Debug, Clone)]
pub struct ExtensionItem {
    /// 稳定 id：`package.json` 的 name、`plugin.json` 的 id 或内置 id。
    pub id: String,
    pub name: String,
    pub version: String,
    pub description: String,
    pub category: ExtensionCategory,
}

/// 扩展面板派发的事件。
#[derive(Debug, Clone)]
pub enum ExtensionsEvent {
    Close,
}

/// 右侧扩展面板：搜索框 + 分类下拉 + 列表 + 启用开关。
pub struct ExtensionsView {
    items: Vec<ExtensionItem>,
    /// 启用状态 `{id: bool}`，缺省视为启用，落盘到
    /// `~/.config/lithe/extensions.json`。
    enabled: HashMap<String, bool>,
    search_input: Option<Entity<InputState>>,
    _search_subscription: Option<Subscription>,
    category: ExtensionCategory,
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
        };
        view.rescan();
        view
    }

    /// 重新扫描仓库插件（内置项常驻）。
    pub fn rescan(&mut self) {
        let mut items = builtin_items();
        items.extend(scan_plugins());
        // 按 id 去重（扫描到的优先），再按名称稳定排序。
        let mut seen = std::collections::HashSet::new();
        items.retain(|item| seen.insert(item.id.clone()));
        items.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
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

    /// 搜索 + 分类双重过滤，对齐 Tauri 的 `filteredExtensions`。
    fn filtered_items(&self, query: &str) -> Vec<&ExtensionItem> {
        let q = query.trim().to_lowercase();
        self.items
            .iter()
            .filter(|item| {
                self.category == ExtensionCategory::All || item.category == self.category
            })
            .filter(|item| {
                q.is_empty()
                    || item.name.to_lowercase().contains(&q)
                    || item.description.to_lowercase().contains(&q)
                    || item.id.to_lowercase().contains(&q)
            })
            .collect()
    }

    /// 分类下拉：当前值按钮 + ChevronDown（复用 `settings_dialog.rs`
    /// `render_dropdown` 思路：选中项打勾）。
    fn render_category_dropdown(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let view = cx.entity();
        let current = self.category.as_str();
        let current_label = self.category.label().to_string();
        let options: Vec<(&'static str, String)> = ExtensionCategory::ALL
            .iter()
            .map(|c| (c.as_str(), c.label().to_string()))
            .collect();
        Button::new("extensions-category")
            .small()
            .ghost()
            .rounded_md()
            .border_1()
            .border_color(ThemeColors::border())
            .bg(ThemeColors::background())
            .w(px(160.0))
            .child(
                div()
                    .flex_1()
                    .text_xs()
                    .text_color(ThemeColors::foreground())
                    .child(current_label),
            )
            .child(
                Icon::new(IconName::ChevronDown)
                    .size(px(13.0))
                    .text_color(ThemeColors::subtle_foreground()),
            )
            .dropdown_menu(move |menu, _window, _cx| {
                let mut menu = menu;
                for (value, label) in &options {
                    let v = view.clone();
                    let value = *value;
                    let label = label.clone();
                    let selected = value == current;
                    let item = gpui_kit::component::menu::PopupMenuItem::new(label);
                    let item = if selected {
                        item.icon(IconName::Check)
                    } else {
                        item
                    };
                    menu = menu.item(item.on_click(move |_, _, cx| {
                        v.update(cx, |this, cx| {
                            if let Some(category) = ExtensionCategory::from_str(value) {
                                this.category = category;
                                cx.notify();
                            }
                        });
                    }));
                }
                menu
            })
    }

    /// 启用开关：可点击药丸，圆点指示状态（对齐 `settings_dialog.rs`
    /// `render_toggle`，无文字）。
    fn render_toggle(&self, id: &str, value: bool, cx: &mut Context<Self>) -> impl IntoElement {
        let id_owned = id.to_string();
        h_flex()
            .id(format!("ext-toggle-{id_owned}"))
            .items_center()
            .gap_1p5()
            .px_2p5()
            .py_1()
            .rounded_sm()
            .border_1()
            .cursor_pointer()
            .text_xs()
            .when(value, |el| {
                el.bg(ThemeColors::primary())
                    .border_color(ThemeColors::primary())
                    .text_color(ThemeColors::foreground())
            })
            .when(!value, |el| {
                el.bg(ThemeColors::background())
                    .border_color(ThemeColors::border())
                    .text_color(ThemeColors::subtle_foreground())
                    .hover(|h| {
                        h.bg(ThemeColors::accent())
                            .text_color(ThemeColors::foreground())
                    })
            })
            .child(div().w(px(8.0)).h(px(8.0)).rounded_full().bg(if value {
                ThemeColors::foreground()
            } else {
                ThemeColors::subtle_foreground()
            }))
            .on_click(cx.listener(move |this, _event, _window, cx| {
                this.toggle(&id_owned, cx);
            }))
    }
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
        let filtered = self.filtered_items(&query);
        let enabled_snapshot = self.enabled.clone();

        let mut rows = Vec::new();
        for item in &filtered {
            let enabled = enabled_snapshot.get(&item.id).copied().unwrap_or(true);
            let name = item.name.clone();
            let version = item.version.clone();
            let description = item.description.clone();
            rows.push(
                h_flex()
                    .id(format!("ext-row-{}", item.id))
                    .w_full()
                    .items_center()
                    .gap_2()
                    .px_2p5()
                    .py_1p5()
                    .rounded_sm()
                    .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                    .child(
                        Icon::new(IconName::Puzzle)
                            .size(px(14.0))
                            .text_color(ThemeColors::subtle_foreground()),
                    )
                    .child(
                        v_flex()
                            .flex_1()
                            .gap_0p5()
                            .overflow_hidden()
                            .child(
                                h_flex()
                                    .items_center()
                                    .gap_1p5()
                                    .child(
                                        div()
                                            .text_xs()
                                            .truncate()
                                            .text_color(if enabled {
                                                ThemeColors::text_primary()
                                            } else {
                                                ThemeColors::text_muted()
                                            })
                                            .child(name),
                                    )
                                    .child(
                                        div()
                                            .text_xs()
                                            .flex_shrink_0()
                                            .text_color(ThemeColors::text_muted())
                                            .child(version),
                                    ),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .truncate()
                                    .text_color(ThemeColors::text_muted())
                                    .child(description),
                            ),
                    )
                    .child(self.render_toggle(&item.id, enabled, cx).into_any_element())
                    .into_any_element(),
            );
        }

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
                        div()
                            .text_xs()
                            .font_weight(FontWeight::BOLD)
                            .text_color(ThemeColors::text_muted())
                            .child(crate::i18n::menu_text(cx, "extensions.title")),
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
                    .gap_2()
                    .p_2()
                    .border_b_1()
                    .border_color(ThemeColors::border())
                    .child(
                        div()
                            .w_full()
                            .child(Input::new(&search_entity).cleanable(true)),
                    )
                    .child(self.render_category_dropdown(cx)),
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
                    .child("No extensions found")
                    .into_any_element()
            } else {
                div()
                    .flex_1()
                    .w_full()
                    .overflow_y_scrollbar()
                    .children(rows)
                    .into_any_element()
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
        },
        ExtensionItem {
            id: "maven".to_string(),
            name: "Maven".to_string(),
            version: "0.1.0".to_string(),
            description: "Maven project navigation and lifecycle".to_string(),
            category: ExtensionCategory::Integration,
        },
        ExtensionItem {
            id: "terminal".to_string(),
            name: "Terminal".to_string(),
            version: "0.1.0".to_string(),
            description: "Integrated terminal".to_string(),
            category: ExtensionCategory::Integration,
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
        return Some(ExtensionItem {
            id: manifest
                .name
                .clone()
                .unwrap_or_else(|| dir_name.to_string()),
            name: manifest.name.unwrap_or_else(|| dir_name.to_string()),
            version: manifest.version.unwrap_or_default(),
            description: manifest.description.unwrap_or_default(),
            category: classify_keywords(&keywords),
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
        });
    }
    None
}

/// 按 `package.json` keywords 简单归类，无 keywords 归 integration。
fn classify_keywords(keywords: &[String]) -> ExtensionCategory {
    classify_text(&keywords.join(" "))
}

/// 关键词归类：theme → 主题，language/lang/lsp/syntax → 语言，
/// ai/llm/agent/chat/model → AI，其余 → integration。
fn classify_text(text: &str) -> ExtensionCategory {
    let lower = text.to_lowercase();
    let has_any = |words: &[&str]| words.iter().any(|word| lower.contains(word));
    if has_any(&["theme", "icon", "color-scheme"]) {
        ExtensionCategory::Theme
    } else if has_any(&["language", "lang", "lsp", "syntax", "grammar"]) {
        ExtensionCategory::Language
    } else if has_any(&["ai", "llm", "agent", "chat", "model"]) {
        ExtensionCategory::Ai
    } else {
        ExtensionCategory::Integration
    }
}

/// 启用状态落盘路径：`~/.config/lithe/extensions.json`
///（`$XDG_CONFIG_HOME` 优先，与 `settings.rs::config_path` 同规则）。
fn extensions_state_path() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|path| !path.as_os_str().is_empty())
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))?;
    Some(base.join("lithe").join("extensions.json"))
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
        let _ = std::fs::rename(&tmp, &path);
    }
}
