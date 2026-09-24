use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, Context, EventEmitter, FocusHandle, FontWeight, InteractiveElement as _, IntoElement,
    KeyDownEvent, ParentElement as _, Render, StatefulInteractiveElement as _, Styled as _, Window,
};
use serde::{Deserialize, Serialize};

use crate::core::CoreClient;
use crate::settings;
use crate::theme::ThemeColors;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SidebarTab {
    Explorer,
    Search,
    Git,
}

/// 侧边栏文件树节点，对接 `lithe-core` 的工作区快照数据模型
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileEntry {
    pub path: String,
    pub name: String,
    pub is_directory: bool,
    #[serde(default)]
    pub size: Option<u64>,
    #[serde(default)]
    pub children: Option<Vec<FileEntry>>,
    #[serde(default)]
    pub is_expanded: bool,
}

#[derive(Debug, Clone)]
pub struct FlatFileItem {
    pub path: String,
    pub name: String,
    pub is_directory: bool,
    #[allow(dead_code)]
    pub size: Option<u64>,
    pub depth: usize,
    pub is_expanded: bool,
    #[allow(dead_code)]
    pub has_children: bool,
}

impl FileEntry {
    pub fn collect_visible(&self, depth: usize, output: &mut Vec<FlatFileItem>) {
        let has_children = self
            .children
            .as_ref()
            .map_or(false, |items| !items.is_empty());

        output.push(FlatFileItem {
            path: self.path.clone(),
            name: self.name.clone(),
            is_directory: self.is_directory,
            size: self.size,
            depth,
            is_expanded: self.is_expanded,
            has_children,
        });

        if self.is_directory && self.is_expanded {
            if let Some(children) = &self.children {
                for child in children {
                    child.collect_visible(depth + 1, output);
                }
            }
        }
    }

    /// 按偏好递归排序子节点：`folders-first` 目录在前同组按名称，
    /// `name` 全按名称。对齐 Tauri 文件树排序。
    pub fn sort_recursive(&mut self, folders_first: bool) {
        if let Some(children) = &mut self.children {
            children.sort_by(|a, b| {
                if folders_first && a.is_directory != b.is_directory {
                    return b.is_directory.cmp(&a.is_directory);
                }
                a.name.to_lowercase().cmp(&b.name.to_lowercase())
            });
            for child in children.iter_mut() {
                child.sort_recursive(folders_first);
            }
        }
    }

    /// 递归移除隐藏文件（`.` 开头），对齐 `showHiddenFilesInFileTree=false` 的行为。
    pub fn remove_hidden(&mut self) {
        if let Some(children) = &mut self.children {
            children.retain(|c| !c.name.starts_with('.'));
            for child in children.iter_mut() {
                child.remove_hidden();
            }
        }
    }
}

/// 侧边栏派发的事件
#[derive(Debug, Clone)]
pub enum SidebarEvent {
    OpenFile(String),
    /// 新建文件入口已移出 explorer 头部（对齐 Tauri），保留变体供外部调用。
    #[allow(dead_code)]
    NewFile,
    Commit(String),
}

#[derive(Debug, Clone)]
pub struct SearchResultItem {
    pub path: String,
    pub line: Option<usize>,
    pub preview: Option<String>,
}

#[derive(Debug, Clone)]
pub struct GitChangeItem {
    pub path: String,
    pub status: String,
    #[allow(dead_code)]
    pub staged: bool,
}

/// 侧边栏主视图组件
pub struct SidebarView {
    pub root_path: String,
    pub active_tab: SidebarTab,
    // 资源管理器状态
    pub root_node: Option<FileEntry>,
    pub selected_path: Option<String>,
    pub is_loading: bool,
    pub error_message: Option<String>,
    /// 文件树过滤串（对齐 Tauri `treeSearchQuery`，仅按文件名过滤）
    pub tree_filter: String,
    /// 是否展开文件树过滤输入（对齐 Tauri `SidebarSearchPopover` 的打开态）
    pub show_tree_filter: bool,
    // 搜索状态
    #[allow(dead_code)]
    pub search_query: String,
    pub search_results: Vec<SearchResultItem>,
    pub is_searching: bool,
    // Git 状态
    pub git_branch: Option<String>,
    pub git_changes: Vec<GitChangeItem>,
    pub is_git_loading: bool,
    pub git_commit_message: String,
    focus_handle: FocusHandle,
    client: CoreClient,
}

impl EventEmitter<SidebarEvent> for SidebarView {}

impl SidebarView {
    pub fn new(root_path: String, cx: &mut Context<Self>) -> Self {
        let mut view = Self {
            root_path,
            active_tab: SidebarTab::Explorer,
            root_node: None,
            selected_path: None,
            is_loading: false,
            error_message: None,
            tree_filter: String::new(),
            show_tree_filter: false,
            search_query: String::new(),
            search_results: Vec::new(),
            is_searching: false,
            git_branch: None,
            git_changes: Vec::new(),
            is_git_loading: false,
            git_commit_message: String::new(),
            focus_handle: cx.focus_handle(),
            client: CoreClient::new(),
        };

        view.refresh(cx);
        view.refresh_git(cx);
        view
    }

    pub fn set_tab(&mut self, tab: SidebarTab, cx: &mut Context<Self>) {
        self.active_tab = tab;
        cx.notify();
    }

    /// 对接 `lithe-core` 刷新工作区文件快照
    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        self.is_loading = true;
        self.error_message = None;
        cx.notify();

        let client = self.client.clone();
        let root = self.root_path.clone();

        cx.spawn(async move |this, cx| {
            let task = client.snapshot(&cx, &root);

            match task.await {
                Ok(val) => {
                    let mut node = val
                        .get("root")
                        .and_then(|r| serde_json::from_value::<FileEntry>(r.clone()).ok());

                    if let Some(entry) = &mut node {
                        entry.is_expanded = true;
                    }

                    let _ = this.update(cx, |sidebar, cx| {
                        sidebar.root_node = node;
                        sidebar.is_loading = false;
                        cx.notify();
                    });
                }
                Err(err) => {
                    let _ = this.update(cx, |sidebar, cx| {
                        sidebar.error_message = Some(err);
                        sidebar.is_loading = false;
                        cx.notify();
                    });
                }
            }
        })
        .detach();
    }

    /// 执行搜索
    #[allow(dead_code)]
    pub fn execute_search(&mut self, query: &str, cx: &mut Context<Self>) {
        self.search_query = query.to_string();
        if query.trim().is_empty() {
            self.search_results.clear();
            cx.notify();
            return;
        }

        self.is_searching = true;
        cx.notify();

        let client = self.client.clone();
        let root = self.root_path.clone();
        let q = query.to_string();

        cx.spawn(async move |this, cx| {
            let task = client.search(&cx, &root, &q);

            match task.await {
                Ok(matches) => {
                    let items: Vec<SearchResultItem> = matches
                        .into_iter()
                        .map(|m| SearchResultItem {
                            path: m
                                .get("path")
                                .and_then(|p| p.as_str())
                                .unwrap_or("")
                                .to_string(),
                            line: m.get("line").and_then(|l| l.as_u64()).map(|l| l as usize),
                            preview: m
                                .get("preview")
                                .and_then(|p| p.as_str())
                                .map(|s| s.to_string()),
                        })
                        .collect();

                    let _ = this.update(cx, |sidebar, cx| {
                        sidebar.search_results = items;
                        sidebar.is_searching = false;
                        cx.notify();
                    });
                }
                Err(_) => {
                    let _ = this.update(cx, |sidebar, cx| {
                        sidebar.search_results.clear();
                        sidebar.is_searching = false;
                        cx.notify();
                    });
                }
            }
        })
        .detach();
    }

    /// 刷新 Git 状态
    pub fn refresh_git(&mut self, cx: &mut Context<Self>) {
        self.is_git_loading = true;
        cx.notify();

        let client = self.client.clone();
        let root = self.root_path.clone();

        cx.spawn(async move |this, cx| {
            let task = client.git_status(&cx, &root);

            match task.await {
                Ok(val) => {
                    let branch = val
                        .get("branch")
                        .and_then(|b| b.as_str())
                        .map(|s| s.to_string());

                    let mut changes = Vec::new();
                    if let Some(arr) = val.get("changes").and_then(|c| c.as_array()) {
                        for item in arr {
                            let path = item
                                .get("path")
                                .and_then(|p| p.as_str())
                                .unwrap_or("")
                                .to_string();
                            let status = item
                                .get("status")
                                .and_then(|s| s.as_str())
                                .unwrap_or("M")
                                .to_string();
                            let staged = item
                                .get("staged")
                                .and_then(|s| s.as_bool())
                                .unwrap_or(false);

                            changes.push(GitChangeItem {
                                path,
                                status,
                                staged,
                            });
                        }
                    }

                    let _ = this.update(cx, |sidebar, cx| {
                        sidebar.git_branch = branch;
                        sidebar.git_changes = changes;
                        sidebar.is_git_loading = false;
                        cx.notify();
                    });
                }
                Err(_) => {
                    let _ = this.update(cx, |sidebar, cx| {
                        sidebar.is_git_loading = false;
                        cx.notify();
                    });
                }
            }
        })
        .detach();
    }

    pub fn toggle_directory(&mut self, path: &str, cx: &mut Context<Self>) {
        if let Some(root) = &mut self.root_node {
            Self::toggle_dir_in_entry(root, path);
            cx.notify();
        }
    }

    fn toggle_dir_in_entry(entry: &mut FileEntry, target_path: &str) -> bool {
        if entry.path == target_path && entry.is_directory {
            entry.is_expanded = !entry.is_expanded;
            return true;
        }

        if let Some(children) = &mut entry.children {
            for child in children {
                if Self::toggle_dir_in_entry(child, target_path) {
                    return true;
                }
            }
        }
        false
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

impl Render for SidebarView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 标题跟随语言：Explorer 用 workbench.project（项目/Project）。
        let title = match self.active_tab {
            SidebarTab::Explorer => crate::i18n::menu_text(cx, "workbench.project").to_string(),
            SidebarTab::Search => "SEARCH".to_string(),
            SidebarTab::Git => "GIT".to_string(),
        };
        // 过滤行在链式构建前算好，避免在 `.when` 闭包里同时借用 self 与 cx。
        let filter_row = if self.show_tree_filter {
            Some(Self::render_filter_row(&self.tree_filter, cx))
        } else {
            None
        };

        v_flex()
            .size_full()
            .bg(ThemeColors::bg_sidebar())
            .border_r_1()
            .border_color(ThemeColors::border())
            .track_focus(&self.focus_handle)
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                // 文件树过滤输入：字符追加、退格删除、Esc 清空并收起。
                if !this.show_tree_filter {
                    return;
                }
                let key = event.keystroke.key.as_str();
                match key {
                    "escape" => {
                        this.tree_filter.clear();
                        this.show_tree_filter = false;
                        cx.notify();
                    }
                    "backspace" => {
                        this.tree_filter.pop();
                        cx.notify();
                    }
                    "enter" => {}
                    _ => {
                        if !event.keystroke.modifiers.control
                            && !event.keystroke.modifiers.alt
                            && !event.keystroke.modifiers.platform
                        {
                            let mut changed = false;
                            if let Some(ch) = &event.keystroke.key_char {
                                this.tree_filter.push_str(ch);
                                changed = true;
                            } else if key.chars().count() == 1 {
                                this.tree_filter.push_str(key);
                                changed = true;
                            }
                            if changed {
                                cx.notify();
                            }
                        }
                    }
                }
            }))
            .child(
                // 顶部标题：Explorer 显示搜索与偏好设置（对齐 Tauri
                // `file-explorer-tree.tsx` 的 SidebarHeader），无新建/刷新按钮。
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
                            .child(title),
                    )
                    .child(
                        h_flex()
                            .items_center()
                            .gap_1()
                            .when(self.active_tab == SidebarTab::Explorer, |buttons| {
                                buttons
                                    .child(
                                        Button::new("sidebar-tree-search")
                                            .small()
                                            .ghost()
                                            .icon(IconName::Search)
                                            .tooltip(crate::i18n::menu_text(
                                                cx,
                                                "fileExplorer.searchFiles",
                                            ))
                                            .on_click(cx.listener(|this, _event, window, cx| {
                                                this.show_tree_filter = !this.show_tree_filter;
                                                if this.show_tree_filter {
                                                    window.focus(&this.focus_handle, cx);
                                                } else {
                                                    this.tree_filter.clear();
                                                }
                                                cx.notify();
                                            })),
                                    )
                                    .child(Self::render_explorer_prefs(cx))
                            })
                            .when(self.active_tab != SidebarTab::Explorer, |buttons| {
                                buttons.child(
                                    Button::new("sidebar-refresh")
                                        .small()
                                        .ghost()
                                        .icon(IconName::RotateCw)
                                        .tooltip("Refresh")
                                        .on_click(cx.listener(|this, _event, _window, cx| {
                                            this.refresh(cx);
                                            this.refresh_git(cx);
                                        })),
                                )
                            }),
                    ),
            )
            .when_some(filter_row, |this, row| this.child(row))
            .child(
                // 对应面板内容渲染
                div()
                    .flex_1()
                    .w_full()
                    .overflow_y_scrollbar()
                    .child(match self.active_tab {
                        SidebarTab::Explorer => self.render_explorer(cx).into_any_element(),
                        SidebarTab::Search => self.render_search(cx).into_any_element(),
                        SidebarTab::Git => self.render_git(cx).into_any_element(),
                    }),
            )
    }
}

impl SidebarView {
    /// Explorer 偏好设置下拉：对齐 Tauri `file-explorer-tree.tsx` 的
    /// Preferences 菜单（可见性/外观/排序顺序/缩进子菜单 + 自动显示/删除确认）。
    /// 所有开关直接写入 XDG 持久化设置。
    fn render_explorer_prefs(cx: &mut Context<Self>) -> impl IntoElement {
        let view = cx.entity();
        // 下拉构建闭包要求 'static：文案与状态快照全部预先解析为 owned 值再 move。
        let t_visibility = crate::i18n::menu_text(cx, "fileExplorer.visibility").to_string();
        let t_appearance = crate::i18n::menu_text(cx, "settings.tabs.appearance").to_string();
        let t_sort = crate::i18n::menu_text(cx, "settings.files.sortOrder").to_string();
        let t_indent = crate::i18n::menu_text(cx, "fileExplorer.indentation").to_string();
        let t_prefs = crate::i18n::menu_text(cx, "fileExplorer.preferences").to_string();
        let t_hidden = crate::i18n::menu_text(cx, "settings.files.hiddenFiles").to_string();
        let t_gitignored = crate::i18n::menu_text(cx, "fileExplorer.gitignoredFiles").to_string();
        let t_git_status =
            crate::i18n::menu_text(cx, "fileExplorer.gitStatusDecorations").to_string();
        let t_icons = crate::i18n::menu_text(cx, "fileExplorer.fileIcons").to_string();
        let t_guides = crate::i18n::menu_text(cx, "fileExplorer.indentGuides").to_string();
        let t_compact = crate::i18n::menu_text(cx, "settings.files.compactFolders").to_string();
        let t_hide_root = crate::i18n::menu_text(cx, "settings.files.hideRootFolder").to_string();
        let t_folders_first = crate::i18n::menu_text(cx, "settings.files.foldersFirst").to_string();
        let t_name = crate::i18n::menu_text(cx, "settings.files.name").to_string();
        let t_indent_compact =
            crate::i18n::menu_text(cx, "fileExplorer.indentationCompact").to_string();
        let t_indent_default =
            crate::i18n::menu_text(cx, "fileExplorer.indentationDefault").to_string();
        let t_indent_spacious =
            crate::i18n::menu_text(cx, "fileExplorer.indentationSpacious").to_string();
        let t_indent_wide = crate::i18n::menu_text(cx, "fileExplorer.indentationWide").to_string();
        let t_reveal = crate::i18n::menu_text(cx, "settings.files.autoReveal").to_string();
        let t_confirm =
            crate::i18n::menu_text(cx, "settings.files.confirmBeforeDelete").to_string();

        let s = settings::get(cx).clone();
        let show_hidden = s.show_hidden_files_in_file_tree;
        let show_gitignored = s.show_gitignored_files_in_file_tree;
        let show_git_status = s.show_git_status_in_file_tree;
        let show_icons = s.show_file_icons_in_file_tree;
        let show_indent_guides = s.show_indent_guides_in_file_tree;
        let compact_folders = s.compact_folders_in_file_tree;
        let hide_root = s.hide_root_folder_in_file_tree;
        let sort_order = s.file_tree_sort_order.clone();
        let indent_size = s.file_tree_indent_size as i32;
        let auto_reveal = s.auto_reveal_active_file_in_file_tree;
        let confirm_delete = s.confirm_before_file_delete;

        // 开关项构造器：checked 状态 + 点击翻转并落盘。
        let check_item = |label: String,
                          checked: bool,
                          toggle: fn(&mut crate::settings::Settings),
                          v: gpui_kit::Entity<SidebarView>| {
            PopupMenuItem::new(label)
                .checked(checked)
                .on_click(move |_, _, cx| {
                    v.update(cx, |_, cx| {
                        crate::settings::update(cx, |s| toggle(s));
                    });
                })
        };

        Button::new("sidebar-explorer-prefs")
            .small()
            .ghost()
            .icon(IconName::SlidersHorizontal)
            .tooltip(t_prefs)
            .dropdown_menu(move |menu, window, cx| {
                let v0 = view.clone();
                // 子菜单构建闭包是 move：外层 dropdown 构建器为 Fn，每次调用前 clone。
                let menu = menu.submenu(t_visibility.clone(), window, cx, {
                    let v = v0.clone();
                    let t_hidden = t_hidden.clone();
                    let t_gitignored = t_gitignored.clone();
                    let t_git_status = t_git_status.clone();
                    move |sub, _w, _cx| {
                        sub.item(check_item(
                            t_hidden.clone(),
                            show_hidden,
                            |s| {
                                s.show_hidden_files_in_file_tree = !s.show_hidden_files_in_file_tree
                            },
                            v.clone(),
                        ))
                        .item(check_item(
                            t_gitignored.clone(),
                            show_gitignored,
                            |s| {
                                s.show_gitignored_files_in_file_tree =
                                    !s.show_gitignored_files_in_file_tree
                            },
                            v.clone(),
                        ))
                        .item(check_item(
                            t_git_status.clone(),
                            show_git_status,
                            |s| s.show_git_status_in_file_tree = !s.show_git_status_in_file_tree,
                            v.clone(),
                        ))
                    }
                });
                let menu = menu.submenu(t_appearance.clone(), window, cx, {
                    let v = v0.clone();
                    let t_icons = t_icons.clone();
                    let t_guides = t_guides.clone();
                    let t_compact = t_compact.clone();
                    let t_hide_root = t_hide_root.clone();
                    move |sub, _w, _cx| {
                        sub.item(check_item(
                            t_icons.clone(),
                            show_icons,
                            |s| s.show_file_icons_in_file_tree = !s.show_file_icons_in_file_tree,
                            v.clone(),
                        ))
                        .item(check_item(
                            t_guides.clone(),
                            show_indent_guides,
                            |s| {
                                s.show_indent_guides_in_file_tree =
                                    !s.show_indent_guides_in_file_tree
                            },
                            v.clone(),
                        ))
                        .item(check_item(
                            t_compact.clone(),
                            compact_folders,
                            |s| s.compact_folders_in_file_tree = !s.compact_folders_in_file_tree,
                            v.clone(),
                        ))
                        .item(check_item(
                            t_hide_root.clone(),
                            hide_root,
                            |s| s.hide_root_folder_in_file_tree = !s.hide_root_folder_in_file_tree,
                            v.clone(),
                        ))
                    }
                });
                let menu = menu.submenu(t_sort.clone(), window, cx, {
                    let v = v0.clone();
                    let current = sort_order.clone();
                    let labels = [t_folders_first.clone(), t_name.clone()];
                    move |sub, _w, _cx| {
                        let mut sub = sub;
                        for (value, label) in [("folders-first", &labels[0]), ("name", &labels[1])]
                        {
                            let vv = v.clone();
                            let item = PopupMenuItem::new(label.clone());
                            let item = if current == value {
                                item.icon(IconName::Check)
                            } else {
                                item
                            };
                            sub = sub.item(item.on_click(move |_, _, cx| {
                                vv.update(cx, |_, cx| {
                                    crate::settings::update(cx, |s| {
                                        s.file_tree_sort_order = value.to_string()
                                    });
                                });
                            }));
                        }
                        sub
                    }
                });
                let menu = menu.submenu(t_indent.clone(), window, cx, {
                    let v = v0.clone();
                    let labels = [
                        t_indent_compact.clone(),
                        t_indent_default.clone(),
                        t_indent_spacious.clone(),
                        t_indent_wide.clone(),
                    ];
                    move |sub, _w, _cx| {
                        let mut sub = sub;
                        for (value, label) in [
                            (12, &labels[0]),
                            (16, &labels[1]),
                            (20, &labels[2]),
                            (24, &labels[3]),
                        ] {
                            let vv = v.clone();
                            let item = PopupMenuItem::new(label.clone());
                            let item = if indent_size == value {
                                item.icon(IconName::Check)
                            } else {
                                item
                            };
                            sub = sub.item(item.on_click(move |_, _, cx| {
                                vv.update(cx, |_, cx| {
                                    crate::settings::update(cx, |s| {
                                        s.file_tree_indent_size = value as f32
                                    });
                                });
                            }));
                        }
                        sub
                    }
                });
                menu.separator()
                    .item(check_item(
                        t_reveal.clone(),
                        auto_reveal,
                        |s| {
                            s.auto_reveal_active_file_in_file_tree =
                                !s.auto_reveal_active_file_in_file_tree
                        },
                        v0.clone(),
                    ))
                    .item(check_item(
                        t_confirm.clone(),
                        confirm_delete,
                        |s| s.confirm_before_file_delete = !s.confirm_before_file_delete,
                        v0.clone(),
                    ))
            })
    }

    /// 文件树过滤输入行：展示当前过滤串，键盘输入由根节点 `on_key_down` 处理。
    fn render_filter_row(filter: &str, cx: &mut Context<Self>) -> impl IntoElement {
        h_flex()
            .h(px(28.0))
            .w_full()
            .items_center()
            .gap_2()
            .mx_2()
            .px_2()
            .rounded_sm()
            .border_1()
            .border_color(ThemeColors::primary())
            .bg(ThemeColors::bg_tab_active())
            .child(
                Icon::new(IconName::Search)
                    .size(px(13.0))
                    .text_color(ThemeColors::text_muted()),
            )
            .child(
                div()
                    .flex_1()
                    .text_xs()
                    .text_color(if filter.is_empty() {
                        ThemeColors::text_muted()
                    } else {
                        ThemeColors::text_primary()
                    })
                    .child(if filter.is_empty() {
                        crate::i18n::menu_text(cx, "search.search").to_string()
                    } else {
                        filter.to_string()
                    }),
            )
            .child(
                Button::new("sidebar-filter-clear")
                    .small()
                    .ghost()
                    .icon(IconName::Close)
                    .tooltip(crate::i18n::menu_text(cx, "search.clear"))
                    .on_click(cx.listener(|this, _event, _window, cx| {
                        this.tree_filter.clear();
                        this.show_tree_filter = false;
                        cx.notify();
                    })),
            )
    }

    fn render_explorer(&self, cx: &mut Context<Self>) -> impl IntoElement {
        // 文件树偏好：排序、隐藏根目录、隐藏文件过滤、缩进、图标、文本过滤。
        let s = settings::get(cx);
        let folders_first = s.file_tree_sort_order == "folders-first";
        let hide_root = s.hide_root_folder_in_file_tree;
        let show_hidden = s.show_hidden_files_in_file_tree;
        let indent_size = s.file_tree_indent_size;
        let show_icons = s.show_file_icons_in_file_tree;
        let query = self.tree_filter.trim().to_lowercase();

        let mut visible_items = Vec::new();
        if let Some(root) = &self.root_node {
            let mut node = root.clone();
            if !show_hidden {
                node.remove_hidden();
            }
            node.sort_recursive(folders_first);
            if hide_root && node.is_directory {
                // 隐藏根目录：从子节点开始按深度 0 收集。
                if let Some(children) = &node.children {
                    for child in children {
                        child.collect_visible(0, &mut visible_items);
                    }
                }
            } else {
                node.collect_visible(0, &mut visible_items);
            }
        }
        // 文本过滤：保留名称命中项及其祖先目录。
        if !query.is_empty() {
            let mut keep: std::collections::HashSet<String> = std::collections::HashSet::new();
            for item in &visible_items {
                if item.name.to_lowercase().contains(&query) {
                    let mut path = item.path.clone();
                    loop {
                        keep.insert(path.clone());
                        match path.rfind('/') {
                            Some(idx) => path.truncate(idx),
                            None => break,
                        }
                    }
                }
            }
            visible_items.retain(|item| keep.contains(&item.path));
        }

        v_flex()
            .size_full()
            .py_1()
            .when(self.is_loading, |this| {
                this.child(
                    div()
                        .text_xs()
                        .text_color(ThemeColors::text_muted())
                        .p_2()
                        .child("Loading workspace files..."),
                )
            })
            .when_some(self.error_message.as_ref(), |this, err| {
                this.child(
                    div()
                        .text_xs()
                        .text_color(ThemeColors::accent_red())
                        .p_2()
                        .child(err.clone()),
                )
            })
            .children(visible_items.into_iter().enumerate().map(|(idx, item)| {
                let is_selected = self.selected_path.as_deref() == Some(&item.path);
                let path_str = item.path.clone();
                let is_dir = item.is_directory;
                let indent = item.depth as f32 * indent_size;

                h_flex()
                    .id(idx)
                    .h(px(24.0))
                    .w_full()
                    .items_center()
                    .cursor_pointer()
                    .rounded_sm()
                    .pl(px(indent + 6.0))
                    .pr_2()
                    .gap_1p5()
                    .text_xs()
                    .when(is_selected, |row| {
                        row.bg(ThemeColors::subtle_selection())
                            .text_color(ThemeColors::text_primary())
                    })
                    .when(!is_selected, |row| {
                        row.text_color(ThemeColors::text_primary())
                            .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                    })
                    .child(if is_dir {
                        if item.is_expanded {
                            h_flex()
                                .items_center()
                                .gap_1()
                                .child(
                                    Icon::new(IconName::ChevronDown)
                                        .size(px(12.0))
                                        .text_color(ThemeColors::text_muted()),
                                )
                                .child(
                                    Icon::new(IconName::FolderOpen)
                                        .size(px(14.0))
                                        .text_color(ThemeColors::accent_blue()),
                                )
                                .into_any_element()
                        } else {
                            h_flex()
                                .items_center()
                                .gap_1()
                                .child(
                                    Icon::new(IconName::ChevronRight)
                                        .size(px(12.0))
                                        .text_color(ThemeColors::text_muted()),
                                )
                                .child(
                                    Icon::new(IconName::Folder)
                                        .size(px(14.0))
                                        .text_color(ThemeColors::accent_blue()),
                                )
                                .into_any_element()
                        }
                    } else {
                        let icon_name = if is_code_file(&item.name) {
                            IconName::FileCode
                        } else {
                            IconName::FileText
                        };
                        h_flex()
                            .items_center()
                            .gap_1()
                            .child(div().w(px(12.0)))
                            .when(show_icons, |row| {
                                row.child(
                                    Icon::new(icon_name)
                                        .size(px(14.0))
                                        .text_color(ThemeColors::text_muted()),
                                )
                            })
                            .into_any_element()
                    })
                    .child(div().flex_1().truncate().child(item.name))
                    .on_click(cx.listener({
                        let path = path_str.clone();
                        move |this, _event, _window, cx| {
                            if is_dir {
                                this.toggle_directory(&path, cx);
                            } else {
                                this.selected_path = Some(path.clone());
                                cx.emit(SidebarEvent::OpenFile(path.clone()));
                                cx.notify();
                            }
                        }
                    }))
            }))
    }

    fn render_search(&self, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .size_full()
            .p_2()
            .gap_2()
            .child(
                h_flex()
                    .h(px(28.0))
                    .w_full()
                    .items_center()
                    .gap_2()
                    .bg(ThemeColors::bg_tab_active())
                    .border_1()
                    .border_color(ThemeColors::border())
                    .rounded(px(4.0))
                    .px_2()
                    .child(
                        Icon::new(IconName::Search)
                            .size(px(13.0))
                            .text_color(ThemeColors::text_muted()),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(ThemeColors::text_muted())
                            .child("Search files or text..."),
                    ),
            )
            .when(self.is_searching, |this| {
                this.child(
                    div()
                        .text_xs()
                        .text_color(ThemeColors::text_muted())
                        .p_1()
                        .child("Searching..."),
                )
            })
            .children(self.search_results.iter().enumerate().map(|(idx, res)| {
                let path = res.path.clone();
                let line_info = res.line.map(|l| format!(":{}", l)).unwrap_or_default();
                let preview = res.preview.clone().unwrap_or_default();

                v_flex()
                    .id(idx)
                    .p_1p5()
                    .rounded_sm()
                    .cursor_pointer()
                    .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                    .child(
                        h_flex()
                            .items_center()
                            .gap_1p5()
                            .text_xs()
                            .child(
                                Icon::new(IconName::FileText)
                                    .size(px(12.0))
                                    .text_color(ThemeColors::accent_blue()),
                            )
                            .child(
                                div()
                                    .text_color(ThemeColors::accent_blue())
                                    .child(format!("{}{}", path, line_info)),
                            ),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(ThemeColors::text_muted())
                            .pl(px(18.0))
                            .child(preview),
                    )
                    .on_click(cx.listener({
                        let p = path.clone();
                        move |this, _event, _window, cx| {
                            this.selected_path = Some(p.clone());
                            cx.emit(SidebarEvent::OpenFile(p.clone()));
                            cx.notify();
                        }
                    }))
            }))
    }

    fn render_git(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let branch = self
            .git_branch
            .clone()
            .unwrap_or_else(|| "DETACHED".to_string());

        v_flex()
            .size_full()
            .justify_between()
            .child(
                // 1. Git 变更文件列表区
                v_flex()
                    .flex_1()
                    .w_full()
                    .p_2()
                    .gap_2()
                    .overflow_y_scrollbar()
                    .child(
                        h_flex()
                            .items_center()
                            .gap_2()
                            .pb_2()
                            .border_b_1()
                            .border_color(ThemeColors::border())
                            .child(
                                Icon::new(IconName::GitBranch)
                                    .size(px(13.0))
                                    .text_color(ThemeColors::accent_green()),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .font_weight(FontWeight::BOLD)
                                    .text_color(ThemeColors::accent_green())
                                    .child(branch),
                            ),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(ThemeColors::text_muted())
                            .child(format!("Changed Files ({})", self.git_changes.len())),
                    )
                    .children(self.git_changes.iter().enumerate().map(|(idx, change)| {
                        let path = change.path.clone();
                        let status = change.status.clone();
                        let status_color = match status.as_str() {
                            "M" => ThemeColors::accent_yellow(),
                            "A" => ThemeColors::accent_green(),
                            "D" => ThemeColors::accent_red(),
                            _ => ThemeColors::text_muted(),
                        };

                        let icon_name = if is_code_file(&path) {
                            IconName::FileCode
                        } else {
                            IconName::FileText
                        };

                        h_flex()
                            .id(idx)
                            .h(px(24.0))
                            .w_full()
                            .items_center()
                            .justify_between()
                            .px_2()
                            .rounded_sm()
                            .cursor_pointer()
                            .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                            .text_xs()
                            .child(
                                h_flex()
                                    .items_center()
                                    .gap_2()
                                    .child(
                                        Icon::new(icon_name)
                                            .size(px(13.0))
                                            .text_color(ThemeColors::text_muted()),
                                    )
                                    .child(
                                        div()
                                            .text_color(ThemeColors::text_primary())
                                            .truncate()
                                            .child(path.clone()),
                                    ),
                            )
                            .child(
                                div()
                                    .font_weight(FontWeight::BOLD)
                                    .text_color(status_color)
                                    .child(status),
                            )
                            .on_click(cx.listener({
                                let p = path.clone();
                                move |this, _event, _window, cx| {
                                    this.selected_path = Some(p.clone());
                                    cx.emit(SidebarEvent::OpenFile(p.clone()));
                                    cx.notify();
                                }
                            }))
                    })),
            )
            .child(
                // 2. Git 面板底部 Commit 工作区
                v_flex()
                    .w_full()
                    .p_2()
                    .border_t_1()
                    .border_color(ThemeColors::border())
                    .bg(ThemeColors::bg_tab_bar())
                    .gap_2()
                    .child(
                        // Commit message 输入提示卡片
                        div()
                            .w_full()
                            .bg(ThemeColors::bg_editor())
                            .border_1()
                            .border_color(ThemeColors::border())
                            .rounded(px(4.0))
                            .p_2()
                            .text_xs()
                            .text_color(if self.git_commit_message.is_empty() {
                                ThemeColors::text_muted()
                            } else {
                                ThemeColors::text_primary()
                            })
                            .child(if self.git_commit_message.is_empty() {
                                "Commit message (e.g. feat: update files)...".to_string()
                            } else {
                                self.git_commit_message.clone()
                            }),
                    )
                    .child(
                        h_flex()
                            .w_full()
                            .items_center()
                            .justify_between()
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::text_muted())
                                    .child(format!("{} changed", self.git_changes.len())),
                            )
                            .child(
                                Button::new("git-commit-btn")
                                    .small()
                                    .primary()
                                    .icon(IconName::Check)
                                    .label("Commit")
                                    .on_click(cx.listener(|this, _event, _window, cx| {
                                        let msg = if this.git_commit_message.trim().is_empty() {
                                            "feat: update workspace files".to_string()
                                        } else {
                                            this.git_commit_message.trim().to_string()
                                        };
                                        cx.emit(SidebarEvent::Commit(msg));
                                    })),
                            ),
                    ),
            )
    }
}
