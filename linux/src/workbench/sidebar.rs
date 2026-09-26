use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::InputEvent;
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, Context, EventEmitter, FocusHandle, FontWeight, InteractiveElement as _, IntoElement,
    KeyDownEvent, ParentElement as _, Render, StatefulInteractiveElement as _, Styled as _,
    Subscription, Window,
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
    /// 打开 Git 面板并展示该文件的 diff（单击变更项）。
    OpenGitDiff {
        path: String,
        staged: bool,
    },
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
    /// 文件树过滤串（对齐 Tauri `treeSearchQuery`，匹配名称与路径）
    pub tree_filter: String,
    /// 是否展开文件树过滤输入（对齐 Tauri `SidebarSearchPopover` 的打开态）
    pub show_tree_filter: bool,
    /// 过滤命中路径（深度优先顺序，对齐 `orderedMatchedPaths`）
    tree_search_hits: Vec<String>,
    /// 回车跳转游标：当前聚焦的命中下标
    tree_search_match_index: usize,
    /// 文件树过滤输入框（复用统一搜索输入实现：IME / 粘贴由组件处理）。
    tree_search: super::search_input::SearchInput,
    _tree_search_subscription: Subscription,
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
    pub fn new(root_path: String, window: &mut Window, cx: &mut Context<Self>) -> Self {
        // 过滤输入复用统一搜索输入组件：IME 组字、Ctrl+V 粘贴、选区与光标
        // 均由 gpui-kit `Input` 处理，不再靠 `on_key_down` 手动拼接 `key_char`。
        let tree_search = super::search_input::SearchInput::new(
            crate::i18n::menu_text(cx, "search.search"),
            window,
            cx,
        )
        .compact();
        let _tree_search_subscription = tree_search.subscribe(cx, |this, event, cx| match event {
            InputEvent::Change => {
                this.tree_filter = this.tree_search.value(cx);
                this.recompute_tree_search();
                cx.notify();
            }
            InputEvent::PressEnter { shift, .. } => {
                // 对齐 Tauri：回车跳下一个命中，Shift+回车跳上一个。
                this.navigate_tree_search(!shift, cx);
            }
            _ => {}
        });

        let mut view = Self {
            root_path,
            active_tab: SidebarTab::Explorer,
            root_node: None,
            selected_path: None,
            is_loading: false,
            error_message: None,
            tree_filter: String::new(),
            show_tree_filter: false,
            tree_search_hits: Vec::new(),
            tree_search_match_index: 0,
            tree_search,
            _tree_search_subscription,
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

        // 无工作区时不做初始扫描：空路径查询只会得到一个错误态，
        // 而欢迎页此时已遮住侧边栏。首次打开项目时会重新 refresh。
        if !view.root_path.trim().is_empty() {
            view.refresh(cx);
            view.refresh_git(cx);
        }
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
                        // 快照刷新后重算搜索命中，避免旧命中路径与新树不一致。
                        sidebar.recompute_tree_search();
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
            let task = client.search(
                &cx,
                &root,
                &q,
                false,
                false,
                false,
                super::global_search::CONTENT_SEARCH_PAGE_SIZE,
                "",
            );

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

    /// 重算文件树搜索命中（对齐 Windows `collectFileTreeSearchHits`）。
    ///
    /// 空查询清空命中；非空时在完整递归快照上做 `"name path"` 子串匹配，
    /// 并重置回车跳转游标。
    pub fn recompute_tree_search(&mut self) {
        self.tree_search_match_index = 0;
        self.tree_search_hits = match &self.root_node {
            Some(root) if !self.tree_filter.trim().is_empty() => super::tree_search::collect_hits(
                root,
                &self.tree_filter,
                super::tree_search::TREE_SEARCH_RESULT_LIMIT,
            ),
            _ => Vec::new(),
        };
        // 对齐 Windows：有命中时自动聚焦首个命中，便于高亮与直接回车打开。
        if let Some(first) = self.tree_search_hits.first() {
            self.selected_path = Some(first.clone());
        }
    }

    /// 按覆盖集合强制设置目录展开态（对齐 Windows `expandedPathsOverride`）。
    ///
    /// 目录是否展开完全由 `expanded` 决定；文件节点保留原状。`is_root` 为真时
    /// 保留工作区根节点原展开态（根不代表可折叠层级）。
    fn apply_expanded_override(
        node: &mut FileEntry,
        expanded: &std::collections::HashSet<String>,
        is_root: bool,
    ) {
        if node.is_directory && !is_root {
            node.is_expanded = expanded.contains(&node.path);
        }
        if let Some(children) = &mut node.children {
            for child in children {
                Self::apply_expanded_override(child, expanded, false);
            }
        }
    }

    /// 回车/Shift+回车 在命中间跳转（对齐 `navigateTreeSearchMatch`）。
    ///
    /// 正向从当前游标向下一个命中推进（到尾部回到首个），反向则相反；
    /// 跳转即将目标命中选中，供文件树高亮显示。
    fn navigate_tree_search(&mut self, forward: bool, cx: &mut Context<Self>) {
        if self.tree_search_hits.is_empty() {
            return;
        }
        let count = self.tree_search_hits.len();
        self.tree_search_match_index = if forward {
            (self.tree_search_match_index + 1) % count
        } else {
            (self.tree_search_match_index + count - 1) % count
        };
        self.selected_path = Some(self.tree_search_hits[self.tree_search_match_index].clone());
        cx.notify();
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
            SidebarTab::Search => crate::i18n::menu_text(cx, "workbench.search").to_string(),
            SidebarTab::Git => crate::i18n::menu_text(cx, "workbench.sourceControl").to_string(),
        };
        // 过滤行在链式构建前算好，避免在 `.when` 闭包里同时借用 self 与 cx。
        let filter_row = if self.show_tree_filter {
            Some(self.render_filter_row(cx))
        } else {
            None
        };

        v_flex()
            .size_full()
            .bg(ThemeColors::bg_sidebar())
            .border_r_1()
            .border_color(ThemeColors::border())
            .track_focus(&self.focus_handle)
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                // 字符输入 / 退格 / 回车由内层 `Input` 处理（含 IME 与粘贴）；
                // 这里只接管 Esc：清空并收起过滤行。
                if this.show_tree_filter && event.keystroke.key.as_str() == "escape" {
                    this.close_tree_search(window, cx);
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
                                                if this.show_tree_filter {
                                                    this.close_tree_search(window, cx);
                                                } else {
                                                    this.show_tree_filter = true;
                                                    // 搜索输入接管键盘：打开时聚焦它一次。
                                                    this.tree_search.focus(window, cx);
                                                    cx.notify();
                                                }
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
                                        .tooltip(crate::i18n::menu_text(cx, "ui.refresh"))
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

    /// 收起过滤行并清空查询（Esc / 按钮 / 清除按钮共用）。
    fn close_tree_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.tree_filter.clear();
        self.show_tree_filter = false;
        self.tree_search_hits.clear();
        self.tree_search_match_index = 0;
        self.tree_search.set_value("", window, cx);
        cx.notify();
    }

    /// 文件树过滤输入行：复用统一搜索输入组件（IME 组字、Ctrl+V 粘贴、
    /// 选区、光标与回车提交均由组件处理）。
    ///
    /// 输入框用 `appearance(false)` 关掉自带背景/边框/焦点环，保留外层行现有
    /// 的紧凑样式，避免多出一层阴影或双层边框。
    fn render_filter_row(&self, cx: &mut Context<Self>) -> impl IntoElement {
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
            .child(self.tree_search.element())
            .child(
                Button::new("sidebar-filter-clear")
                    .small()
                    .ghost()
                    .icon(IconName::Close)
                    .tooltip(crate::i18n::menu_text(cx, "search.clear"))
                    .on_click(cx.listener(|this, _event, window, cx| {
                        this.close_tree_search(window, cx);
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
        let is_dark = !crate::theme::ThemePalette::is_light(&settings::resolved_theme_id(s, false));
        let query = self.tree_filter.trim().to_lowercase();

        let mut visible_items = Vec::new();
        if let Some(root) = &self.root_node {
            let mut node = root.clone();
            if !show_hidden {
                node.remove_hidden();
            }
            node.sort_recursive(folders_first);
            // 搜索生效时用命中结果覆盖展开态（对齐 Windows `expandedPathsOverride`）：
            // 仅保留命中子树，并强制展开命中项的祖先目录。
            if !query.is_empty() {
                let result = super::tree_search::filter_for_hits(&node, &self.tree_search_hits);
                // 将命中子树归到同一根节点下后应用展开覆盖。
                node.children = Some(result.children);
                let expanded: std::collections::HashSet<String> =
                    result.expanded_paths.into_iter().collect();
                Self::apply_expanded_override(&mut node, &expanded, true);
            }
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

        v_flex()
            .size_full()
            .py_1()
            .when(self.is_loading, |this| {
                this.child(
                    div()
                        .text_xs()
                        .text_color(ThemeColors::text_muted())
                        .p_2()
                        .child(format!("{}...", crate::i18n::menu_text(cx, "ui.loading"))),
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
                                    if let Some(arc) = crate::workbench::file_icon::folder_image(
                                        &item.name,
                                        item.is_expanded,
                                        is_dark,
                                    ) {
                                        div()
                                            .size(px(14.0))
                                            .child(
                                                gpui_kit::img(gpui_kit::ImageSource::Image(arc))
                                                    .size_full(),
                                            )
                                            .into_any_element()
                                    } else {
                                        Icon::new(IconName::FolderOpen)
                                            .size(px(14.0))
                                            .text_color(ThemeColors::accent_blue())
                                            .into_any_element()
                                    },
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
                                    if let Some(arc) = crate::workbench::file_icon::folder_image(
                                        &item.name,
                                        item.is_expanded,
                                        is_dark,
                                    ) {
                                        div()
                                            .size(px(14.0))
                                            .child(
                                                gpui_kit::img(gpui_kit::ImageSource::Image(arc))
                                                    .size_full(),
                                            )
                                            .into_any_element()
                                    } else {
                                        Icon::new(IconName::Folder)
                                            .size(px(14.0))
                                            .text_color(ThemeColors::accent_blue())
                                            .into_any_element()
                                    },
                                )
                                .into_any_element()
                        }
                    } else {
                        h_flex()
                            .items_center()
                            .gap_1()
                            .child(div().w(px(12.0)))
                            .when(show_icons, |row| {
                                row.child(
                                    if let Some(arc) =
                                        crate::workbench::file_icon::file_image(&item.name, is_dark)
                                    {
                                        div()
                                            .size(px(14.0))
                                            .child(
                                                gpui_kit::img(gpui_kit::ImageSource::Image(arc))
                                                    .size_full(),
                                            )
                                            .into_any_element()
                                    } else {
                                        let icon_name = if is_code_file(&item.name) {
                                            IconName::FileCode
                                        } else {
                                            IconName::FileText
                                        };
                                        Icon::new(icon_name)
                                            .size(px(14.0))
                                            .text_color(ThemeColors::text_muted())
                                            .into_any_element()
                                    },
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
                        div().text_xs().text_color(ThemeColors::text_muted()).child(
                            crate::i18n::menu_text(cx, "workbench.searchInFiles").to_string(),
                        ),
                    ),
            )
            .when(self.is_searching, |this| {
                this.child(
                    div()
                        .text_xs()
                        .text_color(ThemeColors::text_muted())
                        .p_1()
                        .child(format!("{}...", crate::i18n::menu_text(cx, "ui.loading"))),
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
                            .child(format!(
                                "{} ({})",
                                crate::i18n::menu_text(cx, "workbench.changes"),
                                self.git_changes.len()
                            )),
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
                                let staged = change.staged;
                                move |this, event: &gpui_kit::ClickEvent, _window, cx| {
                                    this.selected_path = Some(p.clone());
                                    if event.click_count() >= 2 {
                                        cx.emit(SidebarEvent::OpenFile(p.clone()));
                                    } else {
                                        cx.emit(SidebarEvent::OpenGitDiff {
                                            path: p.clone(),
                                            staged,
                                        });
                                    }
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
                                crate::i18n::menu_text(cx, "git.commitMessagePlaceholder")
                                    .to_string()
                            } else {
                                self.git_commit_message.clone()
                            }),
                    )
                    .child(
                        h_flex()
                            .w_full()
                            .items_center()
                            .justify_between()
                            .child(div().text_xs().text_color(ThemeColors::text_muted()).child(
                                format!(
                                    "{} ({})",
                                    crate::i18n::menu_text(cx, "workbench.changes"),
                                    self.git_changes.len()
                                ),
                            ))
                            .child(
                                Button::new("git-commit-btn")
                                    .small()
                                    .primary()
                                    .icon(IconName::Check)
                                    .label(crate::i18n::menu_text(cx, "git.commit"))
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
