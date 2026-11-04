//! Git Log 右栏的提交文件呈现：文件树构建/渲染、平铺列表行、树/列表切换。
//!
//! 从 `log_view.rs` 拆出，避免 Git Log 主文件超过 1500 行；行为与拆分前一致
//! （文件树按 `/` 分段、目录在前、同类按名称排序；单击打开提交差异，双击在
//! 编辑器打开工作区文件）。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Icon, Selectable as _, Sizable as _, h_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, ClickEvent, Context, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, Stateful, StatefulInteractiveElement as _, Styled as _,
    div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheTokens, icon};

use super::model::ExpandedSet;
use super::{CommitFilesView, GitPanel};

/// 提交文件树的节点：目录（含子节点）或文件。
pub(crate) struct CommitTreeEntry {
    /// 展示名（目录的一段名或文件名）。
    name: String,
    /// 相对仓库根的完整路径；目录与文件都用它作为折叠/选中 key。
    path: String,
    /// 目录的子节点；文件为空。
    children: Vec<CommitTreeEntry>,
    /// 是否为目录。
    is_dir: bool,
}

/// 把扁平的提交文件列表按 `/` 拆成目录树。
///
/// 目录节点排在文件之前，同类按名字排序，结果稳定可复现。
pub(super) fn build_commit_file_tree(files: &[String]) -> Vec<CommitTreeEntry> {
    fn insert(nodes: &mut Vec<CommitTreeEntry>, file: &str, segments: &[&str], prefix: &str) {
        let Some((head, rest)) = segments.split_first() else {
            return;
        };
        let path = if prefix.is_empty() {
            (*head).to_string()
        } else {
            format!("{prefix}/{head}")
        };
        if rest.is_empty() {
            nodes.push(CommitTreeEntry {
                name: (*head).to_string(),
                path,
                children: Vec::new(),
                is_dir: false,
            });
            return;
        }
        let index = match nodes
            .iter()
            .position(|node| node.is_dir && node.name == *head)
        {
            Some(index) => index,
            None => {
                nodes.push(CommitTreeEntry {
                    name: (*head).to_string(),
                    path: path.clone(),
                    children: Vec::new(),
                    is_dir: true,
                });
                nodes.len() - 1
            }
        };
        insert(&mut nodes[index].children, file, rest, &path);
    }

    fn sort(nodes: &mut Vec<CommitTreeEntry>) {
        nodes.sort_by(|a, b| {
            b.is_dir
                .cmp(&a.is_dir)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });
        for node in nodes.iter_mut() {
            sort(&mut node.children);
        }
    }

    let mut root = Vec::new();
    for file in files {
        let segments: Vec<&str> = file.split('/').filter(|s| !s.is_empty()).collect();
        insert(&mut root, file, &segments, "");
    }
    sort(&mut root);
    root
}

/// 递归渲染提交文件树节点。`Div` 的构建器是消费式的，因此按值进出。
pub(super) fn render_commit_tree_nodes(
    nodes: &[CommitTreeEntry],
    depth: usize,
    collapsed: &ExpandedSet,
    selected_file: Option<&str>,
    tokens: LitheTokens,
    cx: &mut Context<GitPanel>,
    mut out: Stateful<gpui_kit::Div>,
) -> Stateful<gpui_kit::Div> {
    for node in nodes {
        let indent = px(6.0 + depth as f32 * 12.0);
        if node.is_dir {
            let is_collapsed = collapsed.contains(&node.path);
            let path = node.path.clone();
            out = out.child(
                h_flex()
                    .id(SharedString::from(format!("git-log-dir-row:{}", node.path)))
                    .w_full()
                    .h(px(22.0))
                    .pl(indent)
                    .pr(px(6.0))
                    .rounded(px(4.0))
                    .items_center()
                    .gap(px(4.0))
                    .hover(|s| s.bg(tokens.hover))
                    .cursor_pointer()
                    .child(
                        Icon::new(if is_collapsed {
                            gpui_kit::assets::IconName::ChevronRight
                        } else {
                            gpui_kit::assets::IconName::ChevronDown
                        })
                        .with_size(px(10.0))
                        .text_color(tokens.secondary_text),
                    )
                    .child(
                        Icon::new(gpui_kit::assets::IconName::Folder)
                            .with_size(px(13.0))
                            .text_color(tokens.secondary_text),
                    )
                    .child(
                        div()
                            .truncate()
                            .text_size(px(12.0))
                            .text_color(tokens.secondary_text)
                            .child(node.name.clone()),
                    )
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        if !this.collapsed_commit_dirs.remove(&path) {
                            this.collapsed_commit_dirs.insert(path.clone());
                        }
                        cx.notify();
                    })),
            );
            if !is_collapsed {
                out = render_commit_tree_nodes(
                    &node.children,
                    depth + 1,
                    collapsed,
                    selected_file,
                    tokens,
                    cx,
                    out,
                );
            }
        } else {
            let path_str = node.path.clone();
            let path_for_open = node.path.clone();
            let is_selected = selected_file == Some(node.path.as_str());
            let icon_kind = if node.name.ends_with(".java") {
                icon(LitheIcon::Java).with_size(px(13.0))
            } else if node.name.ends_with(".xml") {
                Icon::new(gpui_kit::assets::IconName::Code).with_size(px(13.0))
            } else {
                icon(LitheIcon::File).with_size(px(13.0))
            };
            out = out.child(
                h_flex()
                    .id(SharedString::from(format!(
                        "git-log-file-row:{}",
                        node.path
                    )))
                    .w_full()
                    .h(px(22.0))
                    .pl(indent + px(14.0))
                    .pr(px(6.0))
                    .rounded(px(4.0))
                    .items_center()
                    .gap(px(6.0))
                    // 单击选中加载 diff；双击在编辑器打开工作区文件
                    //（对齐 Tauri onOpen / onDoubleClick 分工）。
                    .when(is_selected, |this| this.bg(tokens.subtle_selection))
                    .when(!is_selected, |this| this.hover(|s| s.bg(tokens.hover)))
                    .cursor_pointer()
                    .child(icon_kind)
                    .child(
                        div()
                            .truncate()
                            .text_size(px(12.0))
                            .text_color(tokens.primary_text)
                            .child(node.name.clone()),
                    )
                    .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                        if event.click_count() >= 2 {
                            // 双击：在编辑器打开工作区的真实文件。
                            this.open_change(&path_for_open.clone(), window, cx);
                        } else {
                            // 单击：在中央编辑区打开该提交的差异。
                            this.select_commit_file(path_str.clone(), window, cx);
                        }
                    })),
            );
        }
    }
    out
}

impl GitPanel {
    /// 平铺列表里的一个提交文件行。
    pub(super) fn render_commit_file_list_row(
        &self,
        path: &str,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let is_selected = self.selected_commit_file.as_deref() == Some(path);
        let (file_name, directory) = super::model::split_path(path);
        let path_for_open = path.to_string();
        let path_for_diff = path.to_string();
        let icon_kind = if file_name.ends_with(".java") {
            icon(LitheIcon::Java).with_size(px(13.0))
        } else if file_name.ends_with(".xml") {
            Icon::new(gpui_kit::assets::IconName::Code).with_size(px(13.0))
        } else {
            icon(LitheIcon::File).with_size(px(13.0))
        };

        h_flex()
            .id(SharedString::from(format!("git-log-file-list:{}", path)))
            .w_full()
            .h(px(24.0))
            .px(px(6.0))
            .rounded(px(4.0))
            .items_center()
            .gap(px(6.0))
            .when(is_selected, |this| this.bg(tokens.subtle_selection))
            .when(!is_selected, |this| this.hover(|s| s.bg(tokens.hover)))
            .cursor_pointer()
            .child(icon_kind)
            .child(
                div()
                    .flex_shrink_0()
                    .text_size(px(12.0))
                    .text_color(tokens.primary_text)
                    .child(file_name),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(px(11.0))
                    .text_color(tokens.tertiary_text)
                    .child(directory),
            )
            .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                if event.click_count() >= 2 {
                    this.open_change(&path_for_open.clone(), window, cx);
                } else {
                    this.select_commit_file(path_for_diff.clone(), window, cx);
                }
            }))
            .into_any_element()
    }

    /// 提交文件的「树状 / 列表」切换。
    pub(super) fn render_commit_files_view_toggle(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tree_active = self.commit_files_view == CommitFilesView::Tree;
        h_flex()
            .items_center()
            .gap(px(2.0))
            .child(
                Button::new("git-log:files-tree")
                    .ghost()
                    .with_size(px(20.0))
                    .rounded(px(3.0))
                    .selected(tree_active)
                    .tooltip(tr("Show file tree"))
                    .child(
                        Icon::new(gpui_kit::assets::IconName::FolderTree)
                            .with_size(px(12.0))
                            .text_color(if tree_active {
                                tokens.primary_text
                            } else {
                                tokens.tertiary_text
                            }),
                    )
                    .on_click(cx.listener(|this, _, _window, cx| {
                        if this.commit_files_view != CommitFilesView::Tree {
                            this.commit_files_view = CommitFilesView::Tree;
                            cx.notify();
                        }
                    })),
            )
            .child(
                Button::new("git-log:files-list")
                    .ghost()
                    .with_size(px(20.0))
                    .rounded(px(3.0))
                    .selected(!tree_active)
                    .tooltip(tr("Show file list"))
                    .child(
                        Icon::new(gpui_kit::assets::IconName::List)
                            .with_size(px(12.0))
                            .text_color(if tree_active {
                                tokens.tertiary_text
                            } else {
                                tokens.primary_text
                            }),
                    )
                    .on_click(cx.listener(|this, _, _window, cx| {
                        if this.commit_files_view != CommitFilesView::List {
                            this.commit_files_view = CommitFilesView::List;
                            cx.notify();
                        }
                    })),
            )
            .into_any_element()
    }
}
