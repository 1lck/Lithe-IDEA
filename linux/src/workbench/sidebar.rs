use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{h_flex, v_flex, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, rgb, Context, EventEmitter, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, StatefulInteractiveElement as _, Styled as _, Window,
};
use serde::{Deserialize, Serialize};

use crate::core::CoreClient;

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
}

/// 侧边栏派发的事件
#[derive(Debug, Clone)]
pub enum SidebarEvent {
    OpenFile(String),
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
    // 搜索状态
    #[allow(dead_code)]
    pub search_query: String,
    pub search_results: Vec<SearchResultItem>,
    pub is_searching: bool,
    // Git 状态
    pub git_branch: Option<String>,
    pub git_changes: Vec<GitChangeItem>,
    pub is_git_loading: bool,
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
            search_query: String::new(),
            search_results: Vec::new(),
            is_searching: false,
            git_branch: None,
            git_changes: Vec::new(),
            is_git_loading: false,
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
                            line: m
                                .get("line")
                                .and_then(|l| l.as_u64())
                                .map(|l| l as usize),
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

impl Render for SidebarView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .size_full()
            .bg(rgb(0x161724))
            .border_r_1()
            .border_color(rgb(0x23263b))
            .child(
                // 顶部视图切换栏 (Explorer / Search / Git)
                h_flex()
                    .h(px(36.0))
                    .w_full()
                    .bg(rgb(0x141522))
                    .border_b_1()
                    .border_color(rgb(0x23263b))
                    .items_center()
                    .justify_between()
                    .px_2()
                    .child(
                        h_flex()
                            .items_center()
                            .gap_1()
                            .child(
                                Button::new("tab-explorer")
                                    .small()
                                    .when(self.active_tab == SidebarTab::Explorer, |b| {
                                        b.primary()
                                    })
                                    .when(self.active_tab != SidebarTab::Explorer, |b| {
                                        b.ghost()
                                    })
                                    .label("Files")
                                    .on_click(cx.listener(|this, _event, _window, cx| {
                                        this.set_tab(SidebarTab::Explorer, cx);
                                    })),
                            )
                            .child(
                                Button::new("tab-search")
                                    .small()
                                    .when(self.active_tab == SidebarTab::Search, |b| {
                                        b.primary()
                                    })
                                    .when(self.active_tab != SidebarTab::Search, |b| {
                                        b.ghost()
                                    })
                                    .label("Search")
                                    .on_click(cx.listener(|this, _event, _window, cx| {
                                        this.set_tab(SidebarTab::Search, cx);
                                    })),
                            )
                            .child(
                                Button::new("tab-git")
                                    .small()
                                    .when(self.active_tab == SidebarTab::Git, |b| b.primary())
                                    .when(self.active_tab != SidebarTab::Git, |b| b.ghost())
                                    .label(format!("Git ({})", self.git_changes.len()))
                                    .on_click(cx.listener(|this, _event, _window, cx| {
                                        this.set_tab(SidebarTab::Git, cx);
                                    })),
                            ),
                    )
                    .child(
                        Button::new("refresh-btn")
                            .small()
                            .ghost()
                            .label("↻")
                            .on_click(cx.listener(|this, _event, _window, cx| {
                                this.refresh(cx);
                                this.refresh_git(cx);
                            })),
                    ),
            )
            .child(
                // 对应面板内容渲染
                div().flex_1().w_full().child(
                    match self.active_tab {
                        SidebarTab::Explorer => self.render_explorer(cx).into_any_element(),
                        SidebarTab::Search => self.render_search(cx).into_any_element(),
                        SidebarTab::Git => self.render_git(cx).into_any_element(),
                    },
                ),
            )
    }
}

impl SidebarView {
    fn render_explorer(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let mut visible_items = Vec::new();
        if let Some(root) = &self.root_node {
            root.collect_visible(0, &mut visible_items);
        }

        v_flex()
            .size_full()
            .p_2()
            .gap_1()
            .when(self.is_loading, |this| {
                this.child(
                    div()
                        .text_xs()
                        .text_color(rgb(0x8a90a2))
                        .p_2()
                        .child("Loading workspace files..."),
                )
            })
            .when_some(self.error_message.as_ref(), |this, err| {
                this.child(
                    div()
                        .text_xs()
                        .text_color(rgb(0xef4444))
                        .p_2()
                        .child(err.clone()),
                )
            })
            .children(visible_items.into_iter().enumerate().map(|(idx, item)| {
                let is_selected = self.selected_path.as_deref() == Some(&item.path);
                let path_str = item.path.clone();
                let is_dir = item.is_directory;
                let indent = item.depth as f32 * 12.0;

                h_flex()
                    .id(idx)
                    .h(px(24.0))
                    .w_full()
                    .items_center()
                    .cursor_pointer()
                    .rounded_sm()
                    .pl(px(indent + 4.0))
                    .pr_2()
                    .text_xs()
                    .when(is_selected, |row| {
                        row.bg(rgb(0x2a2d42)).text_color(rgb(0xffffff))
                    })
                    .when(!is_selected, |row| {
                        row.text_color(rgb(0xcfd3e0)).hover(|h| h.bg(rgb(0x1e2030)))
                    })
                    .child(if is_dir {
                        if item.is_expanded { "📂 " } else { "📁 " }
                    } else {
                        "📄 "
                    })
                    .child(item.name)
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
                    .bg(rgb(0x1e2030))
                    .rounded_sm()
                    .px_2()
                    .child(
                        div()
                            .text_xs()
                            .text_color(rgb(0x8a90a2))
                            .child("Search files or text..."),
                    ),
            )
            .when(self.is_searching, |this| {
                this.child(
                    div()
                        .text_xs()
                        .text_color(rgb(0x8a90a2))
                        .child("Searching..."),
                )
            })
            .children(
                self.search_results
                    .iter()
                    .enumerate()
                    .map(|(idx, res)| {
                        let path = res.path.clone();
                        let line_info = res
                            .line
                            .map(|l| format!(":{}", l))
                            .unwrap_or_default();
                        let preview = res.preview.clone().unwrap_or_default();

                        v_flex()
                            .id(idx)
                            .p_1()
                            .rounded_sm()
                            .cursor_pointer()
                            .hover(|h| h.bg(rgb(0x1e2030)))
                            .child(
                                h_flex()
                                    .items_center()
                                    .gap_1()
                                    .text_xs()
                                    .text_color(rgb(0x60a5fa))
                                    .child(format!("{}{}", path, line_info)),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(rgb(0x9ca3af))
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
                    }),
            )
    }

    fn render_git(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let branch = self.git_branch.clone().unwrap_or_else(|| "DETACHED".to_string());

        v_flex()
            .size_full()
            .p_2()
            .gap_2()
            .child(
                h_flex()
                    .items_center()
                    .gap_2()
                    .pb_2()
                    .border_b_1()
                    .border_color(rgb(0x23263b))
                    .text_xs()
                    .text_color(rgb(0x10b981))
                    .child("⎇ Branch:")
                    .child(branch),
            )
            .child(
                div()
                    .text_xs()
                    .text_color(rgb(0x8a90a2))
                    .child(format!("Changed Files ({})", self.git_changes.len())),
            )
            .children(self.git_changes.iter().enumerate().map(|(idx, change)| {
                let path = change.path.clone();
                let status = change.status.clone();

                h_flex()
                    .id(idx)
                    .h(px(24.0))
                    .w_full()
                    .items_center()
                    .justify_between()
                    .px_2()
                    .rounded_sm()
                    .cursor_pointer()
                    .hover(|h| h.bg(rgb(0x1e2030)))
                    .text_xs()
                    .child(
                        h_flex()
                            .items_center()
                            .gap_2()
                            .text_color(rgb(0xcfd3e0))
                            .child(path.clone()),
                    )
                    .child(
                        div()
                            .text_color(rgb(0xf59e0b))
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
            }))
    }
}
