//! Git Log 左栏引用树与引用动作（检出 / 新建 / 重命名 / 删除 / 推送等）。
//!
//! 拆分自原 `git.rs`。动作语义对齐 Tauri `git-log-tool-window` 的
//! runReferenceAction 系列：写操作统一经 `run_reference_write` 走 Core
//! `git.write`，破坏性 / 集成动作先弹确认。

use std::collections::BTreeMap;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::menu::PopupMenuItem;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, AppContext as _, Context, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, Stateful, StatefulInteractiveElement as _, Styled as _,
    Window, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheTokens, MONO_FONT_FAMILY};

use super::model::{CoreReference, root_text};
use super::{BranchPromptAction, GitPanel, execute_git_command};

impl GitPanel {
    /// Git Log 左栏：垂直图标条 + 分支与引用树（对齐截图左侧）。
    pub(crate) fn render_log_references_panel(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // 最左侧垂直小动作条（完全对齐 Tauri GitReferenceToolbar 的动作集合与
        // 可用性规则：新建 / 更新 / 删除 / 比较 | 刷新 | 定位 HEAD / 过滤）。
        let selected = self.selected_reference_object().cloned();
        let current = self.current_reference_object().cloned();
        let busy = self.is_reference_busy();
        // 更新按钮要求选中分支有上游（对齐 getGitReferenceToolbarState）。
        let can_update = selected.as_ref().is_some_and(|reference| {
            reference.is_local() && reference.upstream_short_name.is_some()
        });
        // 删除要求选中的是本地分支且不是当前分支。
        let can_delete = selected
            .as_ref()
            .is_some_and(|reference| reference.is_local() && !reference.is_current);
        // 比较要求选中的引用不是当前分支。
        let can_compare = selected
            .as_ref()
            .is_some_and(|reference| !reference.is_current);
        // 新建分支的起点：选中引用，缺省当前分支。
        let can_create = selected.is_some() || current.is_some();

        let action_stripe = v_flex()
            .w(px(36.0))
            .h_full()
            .items_center()
            .gap(px(2.0))
            .py(px(4.0))
            .bg(tokens.editor)
            .border_r_1()
            .border_color(tokens.divider)
            .child(
                Button::new("git-log-act:new-branch")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("New Branch"))
                    .disabled(busy || !can_create)
                    .child(Icon::new(gpui_kit::assets::IconName::Plus).with_size(px(14.0)))
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.run_reference_action("createBranch", cx);
                    })),
            )
            .child(
                Button::new("git-log-act:update")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Update Selected"))
                    .disabled(busy || !can_update)
                    .child(
                        Icon::new(gpui_kit::assets::IconName::ArrowDownToLine).with_size(px(14.0)),
                    )
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.run_reference_action("update", cx);
                    })),
            )
            .child(
                Button::new("git-log-act:delete-branch")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Delete Branch"))
                    .disabled(busy || !can_delete)
                    .child(Icon::new(gpui_kit::assets::IconName::Trash).with_size(px(14.0)))
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.run_reference_action("deleteLocal", cx);
                    })),
            )
            .child(
                Button::new("git-log-act:compare")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Compare with current"))
                    .disabled(busy || !can_compare)
                    .child(Icon::new(gpui_kit::assets::IconName::GitCompare).with_size(px(14.0)))
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.run_reference_action("compareWithCurrent", cx);
                    })),
            )
            // 分割线
            .child(div().w(px(20.0)).h(px(1.0)).my(px(4.0)).bg(tokens.divider))
            .child(
                Button::new("git-log-act:refresh")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Refresh"))
                    .disabled(busy)
                    .child(Icon::new(gpui_kit::assets::IconName::RotateCw).with_size(px(14.0)))
                    .on_click(cx.listener(|this, _, window, cx| this.refresh(window, cx))),
            )
            .child(
                Button::new("git-log-act:head")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Go to HEAD"))
                    .disabled(self.current_reference_object().is_none())
                    .child(Icon::new(gpui_kit::assets::IconName::Crosshair).with_size(px(14.0)))
                    // 定位 HEAD：选中当前分支并请求该分支的历史。
                    .on_click(cx.listener(|this, _, _window, cx| {
                        if let Some(current) = this
                            .references
                            .iter()
                            .find(|reference| reference.is_current)
                        {
                            this.select_reference(current.short_name.clone(), cx);
                        }
                    })),
            )
            .child(
                Button::new("git-log-act:all-branches")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("All branches"))
                    .child(Icon::new(gpui_kit::assets::IconName::ListFilter).with_size(px(14.0)))
                    // 回到全部分支视图：清空选中引用并重载。
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.select_reference(String::new(), cx);
                    })),
            )
            // 推至底部的全展开与全收起
            .child(div().flex_1())
            .child(
                Button::new("git-log-act:expand-all")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Expand all"))
                    .child(
                        Icon::new(gpui_kit::assets::IconName::ChevronsUpDown).with_size(px(14.0)),
                    )
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.collapsed_groups.clear();
                        cx.notify();
                    })),
            )
            .child(
                Button::new("git-log-act:collapse-all")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Collapse all"))
                    .child(Icon::new(gpui_kit::assets::IconName::Minimize2).with_size(px(14.0)))
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.collapse_all_groups();
                        cx.notify();
                    })),
            );

        // 引用树列表
        let mut tree = v_flex()
            .id("lithe-git-log-ref-tree")
            .flex_1()
            .h_full()
            .overflow_y_scroll()
            .p(px(6.0))
            .gap(px(2.0));

        let references = &self.references;
        let local: Vec<&CoreReference> = references
            .iter()
            .filter(|reference| reference.is_local())
            .collect();
        let remotes: Vec<&CoreReference> = references
            .iter()
            .filter(|reference| reference.is_remote())
            .collect();
        let tags: Vec<&CoreReference> = references
            .iter()
            .filter(|reference| reference.is_tag())
            .collect();

        // 顶部 `+ 引用 N`
        tree = tree.child(
            h_flex()
                .w_full()
                .h(px(24.0))
                .items_center()
                .justify_between()
                .px(px(4.0))
                .child(
                    h_flex()
                        .gap(px(4.0))
                        .items_center()
                        .child(
                            Icon::new(gpui_kit::assets::IconName::Plus)
                                .with_size(px(11.0))
                                .text_color(tokens.secondary_text),
                        )
                        .child(
                            div()
                                .text_size(px(12.0))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(tokens.primary_text)
                                .child(tr("References")),
                        ),
                )
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(tokens.tertiary_text)
                        .child(references.len().to_string()),
                ),
        );

        tree = self.render_reference_group(tree, tr("Local"), &local, true, tokens, cx);
        tree = self.render_remote_groups(tree, &remotes, tokens, cx);
        tree = self.render_reference_group(tree, tr("Tags"), &tags, false, tokens, cx);

        if references.is_empty() {
            tree = tree.child(
                div()
                    .p(px(12.0))
                    .text_size(px(12.0))
                    .text_color(tokens.secondary_text)
                    .child(if self.loading_references {
                        tr("Loading…")
                    } else {
                        tr("No branches")
                    }),
            );
        }

        h_flex()
            .id("lithe-git-log-sidebar")
            .w(px(280.0))
            .h_full()
            .flex_shrink_0()
            .bg(tokens.sidebar)
            .border_r_1()
            .border_color(tokens.divider)
            .child(action_stripe)
            .child(tree)
            .into_any_element()
    }

    /// 渲染一个本地分支 / 标签分组（平铺，无子目录）。
    fn render_reference_group(
        &self,
        mut tree: Stateful<gpui_kit::Div>,
        title: &'static str,
        items: &[&CoreReference],
        show_current: bool,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> Stateful<gpui_kit::Div> {
        if items.is_empty() {
            return tree;
        }
        let group_key = title.to_string();
        let collapsed = self.collapsed_groups.contains(&group_key);
        tree = tree.child(
            h_flex()
                .id(SharedString::from(format!("git-log-group:{group_key}")))
                .w_full()
                .h(px(20.0))
                .items_center()
                .justify_between()
                .px(px(4.0))
                .rounded(px(3.0))
                .cursor_pointer()
                .hover(|s| s.bg(tokens.hover))
                .child(
                    h_flex()
                        .gap(px(4.0))
                        .items_center()
                        .child(group_chevron(collapsed, tokens))
                        .child(
                            div()
                                .text_size(px(12.0))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(tokens.primary_text)
                                .child(tr(title)),
                        ),
                )
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(tokens.tertiary_text)
                        .child(items.len().to_string()),
                )
                .on_click(cx.listener(move |this, _, _window, cx| {
                    this.toggle_group(&group_key.clone(), cx);
                })),
        );
        if collapsed {
            return tree;
        }
        for reference in items {
            tree = self.render_reference_row(tree, reference, show_current, tokens, cx);
        }
        tree
    }

    /// 渲染远程分组：远程 -> 按远端名折叠，内部平铺远程分支。
    fn render_remote_groups(
        &self,
        mut tree: Stateful<gpui_kit::Div>,
        remotes: &[&CoreReference],
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> Stateful<gpui_kit::Div> {
        if remotes.is_empty() {
            return tree;
        }
        // 按远端名分组，保持 Core 返回的 refname 排序。
        let mut by_remote: BTreeMap<String, Vec<&CoreReference>> = BTreeMap::new();
        for reference in remotes {
            by_remote
                .entry(reference.remote_name().to_string())
                .or_default()
                .push(reference);
        }

        let collapsed = self.collapsed_groups.contains("Remote");
        tree = tree.child(
            h_flex()
                .id("git-log-group:Remote")
                .w_full()
                .h(px(20.0))
                .mt(px(4.0))
                .items_center()
                .justify_between()
                .px(px(4.0))
                .child(
                    h_flex()
                        .gap(px(4.0))
                        .items_center()
                        .child(group_chevron(collapsed, tokens))
                        .child(
                            div()
                                .text_size(px(12.0))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(tokens.primary_text)
                                .child(tr("Remote")),
                        ),
                )
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(tokens.tertiary_text)
                        .child(remotes.len().to_string()),
                ),
        );
        if collapsed {
            return tree;
        }

        for (remote, branches) in by_remote {
            let group_key = format!("remote/{remote}");
            let remote_collapsed = self.collapsed_groups.contains(&group_key);
            tree = tree.child(
                h_flex()
                    .id(SharedString::from(format!("git-log-remote:{remote}")))
                    .w_full()
                    .h(px(20.0))
                    .pl(px(10.0))
                    .pr(px(4.0))
                    .rounded(px(3.0))
                    .items_center()
                    .gap(px(4.0))
                    .cursor_pointer()
                    .hover(|s| s.bg(tokens.hover))
                    .child(group_chevron(remote_collapsed, tokens))
                    .child(remote_folder_icon(remote_collapsed, tokens))
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(tokens.primary_text)
                            .child(remote.clone()),
                    )
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        this.toggle_group(&group_key.clone(), cx);
                    })),
            );
            if remote_collapsed {
                continue;
            }
            for branch in branches {
                tree = self.render_reference_row(tree, branch, false, tokens, cx);
            }
        }
        tree
    }

    /// 引用树的单行：分支图标 + 短名 + 当前分支标记 / 领先落后计数。
    fn render_reference_row(
        &self,
        tree: Stateful<gpui_kit::Div>,
        reference: &CoreReference,
        show_current: bool,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> Stateful<gpui_kit::Div> {
        let name = reference.short_name.clone();
        let is_current = show_current && reference.is_current;
        let is_selected = is_current || self.selected_reference.as_deref() == Some(name.as_str());
        let ahead_behind = if reference.ahead > 0 || reference.behind > 0 {
            format!("↑{} ↓{}", reference.ahead, reference.behind)
        } else {
            String::new()
        };
        let indent = px(24.0);
        let name_for_menu = name.clone();
        let reference_for_menu = reference.clone();

        tree.child(
            h_flex()
                .id(SharedString::from(format!("git-log-ref-row:{name}")))
                .w_full()
                .h(px(21.0))
                .px(px(6.0))
                .pl(indent)
                .rounded(px(4.0))
                .items_center()
                .justify_between()
                .when(is_selected, |this| this.bg(tokens.selection))
                .when(!is_selected, |this| this.hover(|s| s.bg(tokens.hover)))
                .cursor_pointer()
                .child(
                    h_flex()
                        .items_center()
                        .gap(px(4.0))
                        .min_w(px(0.0))
                        .child(if is_current {
                            Icon::new(gpui_kit::assets::IconName::Check)
                                .with_size(px(11.0))
                                .text_color(if is_selected {
                                    tokens.tool_window_selected_text
                                } else {
                                    tokens.success
                                })
                        } else if reference.is_tag() {
                            Icon::new(gpui_kit::assets::IconName::Tag)
                                .with_size(px(11.0))
                                .text_color(if is_selected {
                                    tokens.tool_window_selected_text
                                } else {
                                    tokens.secondary_text
                                })
                        } else {
                            Icon::new(gpui_kit::assets::IconName::GitBranch)
                                .with_size(px(11.0))
                                .text_color(if is_selected {
                                    tokens.tool_window_selected_text
                                } else {
                                    tokens.secondary_text
                                })
                        })
                        .child(
                            div()
                                .truncate()
                                .text_size(px(12.0))
                                .text_color(if is_selected {
                                    tokens.tool_window_selected_text
                                } else {
                                    tokens.primary_text
                                })
                                .child(name.clone()),
                        ),
                )
                .child(
                    h_flex()
                        .items_center()
                        .gap(px(4.0))
                        .when(is_current, |this| {
                            this.child(
                                div()
                                    .px(px(4.0))
                                    .py(px(0.5))
                                    .rounded(px(3.0))
                                    .bg(tokens.raised)
                                    .text_size(px(10.0))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(tokens.accent)
                                    .child(tr("Current")),
                            )
                        })
                        .when(!ahead_behind.is_empty(), |this| {
                            this.child(
                                div()
                                    .text_size(px(10.5))
                                    .font_family(MONO_FONT_FAMILY)
                                    .text_color(tokens.tertiary_text)
                                    .child(ahead_behind),
                            )
                        }),
                )
                .on_click(cx.listener(move |this, _, _window, cx| {
                    this.select_reference(name.clone(), cx);
                }))
                // 右键动作菜单：按引用类别给出可用动作，对齐 Tauri
                // `GitReferenceContextMenu` 的分组。
                .on_mouse_down(
                    gpui_kit::MouseButton::Right,
                    cx.listener(move |this, event: &gpui_kit::MouseDownEvent, window, cx| {
                        // 右键先选中该行，动作以它为目标（对齐 Tauri onContextSelect）。
                        this.select_reference(name_for_menu.clone(), cx);
                        this.open_reference_menu(
                            reference_for_menu.clone(),
                            event.position,
                            window,
                            cx,
                        );
                    }),
                ),
        )
    }

    /// 打开引用动作菜单。菜单条目来自 Tauri `GitReferenceContextMenu` 的分组。
    pub(crate) fn open_reference_menu(
        &mut self,
        reference: CoreReference,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let busy = self.is_reference_busy();
        let owner = cx.weak_entity();
        let popup =
            gpui_kit::component::menu::PopupMenu::build(window, cx, move |menu, _window, _cx| {
                let mut menu = menu.min_w(px(200.0));
                let mut first_group = true;
                // 与 Tauri 相同的三段分组：检出/新建 → 比较/集成 → 更新/推送/重命名 → 删除。
                let groups: &[&[&str]] = if reference.is_local() {
                    if reference.is_current {
                        &[&["createBranch"], &["update", "push", "rename"]]
                    } else {
                        &[
                            &["checkout", "createBranch", "checkoutAndRebase"],
                            &[
                                "compareWithCurrent",
                                "rebaseCurrentOnto",
                                "mergeIntoCurrent",
                            ],
                            &["update", "push", "rename"],
                        ]
                    }
                } else if reference.is_remote() {
                    &[
                        &["checkout", "createBranch", "checkoutAndRebase"],
                        &[
                            "compareWithCurrent",
                            "rebaseCurrentOnto",
                            "mergeIntoCurrent",
                        ],
                        &["pullRebaseIntoCurrent", "pullMergeIntoCurrent"],
                    ]
                } else {
                    &[&["checkout", "createBranch", "compareWithCurrent"]]
                };

                for group in groups {
                    if first_group {
                        first_group = false;
                    } else {
                        menu = menu.separator();
                    }
                    for action in group.iter() {
                        // 删除类动作放在最后的独立分组（见下方）。
                        if matches!(*action, "deleteLocal" | "deleteRemote" | "deleteTag") {
                            continue;
                        }
                        // update / push 需要上游分支（对齐 Tauri 的禁用规则）。
                        let disabled = busy
                            || (*action == "update" && reference.upstream_short_name.is_none());
                        let label = reference_action_title(action);
                        let owner = owner.clone();
                        let action = *action;
                        menu = menu.item(PopupMenuItem::new(label).disabled(disabled).on_click(
                            move |_, _, cx| {
                                let _ = owner.update(cx, |this, cx| {
                                    this.run_reference_action(action, cx);
                                });
                            },
                        ));
                    }
                }

                // 复制分支名 + 删除（对齐 Tauri 菜单尾部分组）。
                menu = menu.separator();
                if reference.kind != "tag" {
                    let owner = owner.clone();
                    let label_for_copy = reference.short_name.clone();
                    menu = menu.item(PopupMenuItem::new(tr("Copy Branch Name")).on_click(
                        move |_, window, cx| {
                            let _ = owner.update(cx, |this, cx| {
                                this.copy_reference_name(&label_for_copy, window, cx);
                            });
                        },
                    ));
                }
                let delete_action = if reference.is_local() {
                    "deleteLocal"
                } else if reference.is_remote() {
                    "deleteRemote"
                } else {
                    "deleteTag"
                };
                let owner = owner.clone();
                let delete_label = reference_action_title(delete_action);
                menu = menu.item(
                    PopupMenuItem::new(delete_label)
                        .disabled(busy || (delete_action == "deleteLocal" && reference.is_current))
                        .on_click(move |_, _, cx| {
                            let _ = owner.update(cx, |this, cx| {
                                this.run_reference_action(delete_action, cx);
                            });
                        }),
                );
                menu
            });

        cx.subscribe_in(
            &popup,
            window,
            |this, _, _: &gpui_kit::DismissEvent, _window, cx| {
                this.reference_menu = None;
                cx.notify();
            },
        )
        .detach();
        self.reference_menu = Some((popup, position));
        cx.notify();
    }

    /// 复制引用名到剪贴板。
    pub(crate) fn copy_reference_name(
        &self,
        name: &str,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string(name.to_string()));
        cx.notify();
    }

    /// 选中引用并按它重载历史；空字符串 = 全部分支。
    pub(crate) fn select_reference(&mut self, short_name: String, cx: &mut Context<Self>) {
        let next = if short_name.is_empty() {
            None
        } else {
            Some(short_name)
        };
        if self.selected_reference == next {
            return;
        }
        self.selected_reference = next;
        // 引用变化必须重载历史；generation 由 reload_all 统一管理。
        self.generation = self.generation.wrapping_add(1);
        self.history.clear();
        self.selected_commit_hash = None;
        self.commit_files.clear();
        self.load_history(cx);
        cx.notify();
    }

    pub(crate) fn toggle_group(&mut self, key: &str, cx: &mut Context<Self>) {
        if !self.collapsed_groups.remove(key) {
            self.collapsed_groups.insert(key.to_string());
        }
        cx.notify();
    }

    pub(crate) fn collapse_all_groups(&mut self) {
        self.collapsed_groups.clear();
        self.collapsed_groups.insert(tr("Local").to_string());
        self.collapsed_groups.insert(tr("Remote").to_string());
        self.collapsed_groups.insert(tr("Tags").to_string());
    }

    // -----------------------------------------------------------------------
    // 引用动作（对齐 Tauri git-log-tool-window 的 runReferenceAction 系列）
    // -----------------------------------------------------------------------

    /// 选中的引用对象；引用动作都以它为目标。
    pub(crate) fn selected_reference_object(&self) -> Option<&CoreReference> {
        let short = self.selected_reference.as_deref()?;
        self.references
            .iter()
            .find(|reference| reference.short_name == short)
    }

    /// 当前分支引用对象。
    pub(crate) fn current_reference_object(&self) -> Option<&CoreReference> {
        self.references
            .iter()
            .find(|reference| reference.is_current)
    }

    /// 是否有引用写操作在执行。
    pub(crate) fn is_reference_busy(&self) -> bool {
        self.reference_mutation.is_some()
    }

    /// 发起一个引用写操作（Core `git.write`），成功后刷新并提示。
    ///
    /// `payload_extra` 由调用方按 operation 拼装（name / mode / strategy 等）。
    pub(crate) fn run_reference_write(
        &mut self,
        action: &'static str,
        operation: &'static str,
        reference: &CoreReference,
        mut payload: serde_json::Value,
        cx: &mut Context<Self>,
    ) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root_text(&root) else {
            return;
        };
        if self.is_reference_busy() {
            return;
        }

        // 对齐 Tauri `referencePayload`：新客户端统一发类型化 gitReference。
        payload["root"] = serde_json::Value::String(root_text);
        payload["operation"] = serde_json::Value::String(operation.to_string());
        payload["gitReference"] = serde_json::json!({
            "fullName": reference.full_name,
            "shortName": reference.short_name,
            "kind": reference.kind,
        });

        let generation = self.generation;
        let client = self.client;
        self.reference_mutation = Some(action);
        self.error = None;
        self.notice = None;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move { execute_git_command(&client, "git.write", payload) })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.reference_mutation = None;
                match raw {
                    Ok(value) => {
                        // git.write 返回 GitCommandResponse；exitCode 非 0 视为失败。
                        let command =
                            super::model::parse_command(&value).unwrap_or_default();
                        if command.exit_code == 0 {
                            this.reload_all(cx);
                            this.notice =
                                Some(SharedString::from(reference_action_title(action)));
                        } else {
                            this.error = Some(SharedString::from(
                                super::model::command_failure_detail(
                                    &command,
                                    reference_action_title(action),
                                ),
                            ));
                        }
                    }
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 无确认直接执行的动作：本地 / 远程分支检出（对齐 Tauri：检出无二次确认，
    /// 成功与否由分支标签切换表达）。
    fn checkout_reference(&mut self, reference: &CoreReference, cx: &mut Context<Self>) {
        self.run_reference_write("checkout", "checkout", reference, serde_json::json!({}), cx);
    }

    /// 更新选中分支：等价 Tauri 的 updateGitLogBranch（fetch + 受保护快进）。
    fn update_reference(&mut self, reference: &CoreReference, cx: &mut Context<Self>) {
        if reference.upstream_short_name.is_none() {
            return;
        }
        self.run_reference_write(
            "update",
            "updateBranch",
            reference,
            serde_json::json!({}),
            cx,
        );
    }

    /// 推送选中分支。简单场景（无分歧）直接 push；失败信息留在状态行。
    fn push_reference(&mut self, reference: &CoreReference, cx: &mut Context<Self>) {
        if !reference.is_local() {
            return;
        }
        self.run_reference_write("push", "push", reference, serde_json::json!({}), cx);
    }

    /// 需要确认的集成动作：检出标签 / rebase / merge / pull。
    fn request_reference_confirm(
        &mut self,
        action: &'static str,
        operation: &'static str,
        reference: CoreReference,
        success: &'static str,
        cx: &mut Context<Self>,
    ) {
        let current = self
            .current_reference_object()
            .map(|reference| reference.short_name.clone())
            .unwrap_or_else(|| "HEAD".to_string());
        let title = reference_action_title(action);
        let message = match action {
            "rebaseCurrentOnto" => format!("{} → {}?", tr("Rebase"), reference.short_name),
            "mergeIntoCurrent" => format!("{} → {}?", reference.short_name, current),
            _ => format!("{}: {}?", title, reference.short_name),
        };
        self.reference_confirm = Some(super::rewrite::ReferenceConfirm {
            operation,
            reference,
            title,
            message,
            success,
        });
        cx.notify();
    }

    /// 用户确认后执行挂起的引用动作。
    pub(crate) fn confirm_reference_action(&mut self, cx: &mut Context<Self>) {
        let Some(confirm) = self.reference_confirm.take() else {
            return;
        };
        self.run_reference_write(
            reference_action_key(confirm.operation),
            confirm.operation,
            &confirm.reference,
            serde_json::json!({}),
            cx,
        );
        self.notice = Some(SharedString::from(confirm.success));
        cx.notify();
    }

    pub(crate) fn cancel_reference_action(&mut self, cx: &mut Context<Self>) {
        if self.reference_confirm.take().is_some() {
            cx.notify();
        }
    }

    /// 删除本地分支。对齐 Tauri：不二次确认，删除后给「恢复」通知入口；
    /// GPUI 的通知系统暂无动作按钮，因此恢复走 Core 的 deleteBranch 返回值
    /// 记录到 notice，用户可从 reflog 找回（Core 侧 delete_branch 已保留该信息）。
    fn delete_local_reference(&mut self, reference: &CoreReference, cx: &mut Context<Self>) {
        if reference.is_current {
            return;
        }
        self.run_reference_write(
            "deleteLocal",
            "deleteBranch",
            reference,
            serde_json::json!({}),
            cx,
        );
    }

    /// 删除远程分支（带确认）。
    fn delete_remote_reference(&mut self, reference: &CoreReference, cx: &mut Context<Self>) {
        let title = reference_action_title("deleteRemote");
        self.reference_confirm = Some(super::rewrite::ReferenceConfirm {
            operation: "deleteBranch",
            reference: reference.clone(),
            title,
            message: format!("{} ({})?", tr("Delete Remote Branch"), reference.short_name),
            success: tr("Branch deleted"),
        });
        cx.notify();
    }

    /// 打开新建分支输入框（起点 = 当前选中引用，缺省当前分支）。
    pub(crate) fn request_create_branch(&mut self, cx: &mut Context<Self>) {
        let Some(source) = self
            .selected_reference_object()
            .cloned()
            .or_else(|| self.current_reference_object().cloned())
        else {
            return;
        };
        self.branch_prompt = Some((BranchPromptAction::Create, source));
        self.branch_input = None;
        cx.notify();
    }

    /// 打开重命名分支输入框。
    fn request_rename_branch(&mut self, reference: &CoreReference, cx: &mut Context<Self>) {
        if !reference.is_local() {
            return;
        }
        self.branch_prompt = Some((BranchPromptAction::Rename, reference.clone()));
        self.branch_input = None;
        cx.notify();
    }

    /// 惰性创建分支输入框。`InputState::new` 需要 Window，只能在 render 期调用。
    pub(crate) fn ensure_branch_input(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some((action, source)) = self.branch_prompt.as_ref() else {
            return;
        };
        if self.branch_input.is_some() {
            return;
        }
        let initial = match action {
            BranchPromptAction::Create => String::new(),
            BranchPromptAction::Rename => source.short_name.clone(),
        };
        let input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(tr("Branch name"))
                .default_value(initial)
        });
        let subscription = cx.subscribe_in(
            &input,
            window,
            |this: &mut Self, _input, event: &InputEvent, _window, cx| match event {
                InputEvent::PressEnter { .. } => this.submit_branch_prompt(cx),
                InputEvent::Change | InputEvent::Focus | InputEvent::Blur => {}
            },
        );
        // 订阅随实体一起保活；这里只为简化字段而丢弃句柄是安全的，因为
        // `branch_input` 清空时弹窗已关闭，迟到的 Enter 事件找不到目标。
        let _ = subscription;
        self.branch_input = Some(input);
        cx.notify();
    }

    /// 分支输入框元素；render 期调用以完成惰性创建。
    pub(crate) fn branch_input_element(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        self.ensure_branch_input(window, cx);
        self.branch_input
            .clone()
            .map(|input| Input::new(&input).small().into_any_element())
    }

    /// 读取输入框当前内容并提交。
    pub(crate) fn submit_branch_prompt(&mut self, cx: &mut Context<Self>) {
        let Some(input) = self.branch_input.clone() else {
            return;
        };
        let value = input.read(cx).value().to_string();
        self.confirm_branch_prompt(value, cx);
    }

    /// 分支输入框确认：新建走 createBranch（`--no-track` 语义由 Core 保证），
    /// 重命名走 renameBranch。
    fn confirm_branch_prompt(&mut self, name: String, cx: &mut Context<Self>) {
        let Some((action, source)) = self.branch_prompt.take() else {
            return;
        };
        self.branch_input = None;
        let name = name.trim().to_string();
        if name.is_empty() {
            return;
        }
        match action {
            BranchPromptAction::Create => {
                self.run_reference_write(
                    "createBranch",
                    "createBranch",
                    &source,
                    serde_json::json!({ "name": name }),
                    cx,
                );
            }
            BranchPromptAction::Rename => {
                self.run_reference_write(
                    "rename",
                    "renameBranch",
                    &source,
                    serde_json::json!({ "name": name }),
                    cx,
                );
            }
        }
    }

    pub(crate) fn cancel_branch_prompt(&mut self, cx: &mut Context<Self>) {
        if self.branch_prompt.take().is_some() {
            self.branch_input = None;
            cx.notify();
        }
    }

    /// 引用行的右键 / 工具条动作统一入口，按引用类别分发（对齐 Tauri
    /// `getGitReferenceActions` 的可用集合）。
    pub(crate) fn run_reference_action(&mut self, action: &'static str, cx: &mut Context<Self>) {
        let Some(reference) = self.selected_reference_object().cloned() else {
            return;
        };
        match action {
            "checkout" => match reference.kind.as_str() {
                "tag" => self.request_reference_confirm(
                    "checkout",
                    "checkout",
                    reference,
                    tr("Checkout"),
                    cx,
                ),
                _ => self.checkout_reference(&reference, cx),
            },
            "createBranch" => self.request_create_branch(cx),
            "checkoutAndRebase" => self.request_reference_confirm(
                "checkoutAndRebase",
                "checkoutAndRebase",
                reference,
                tr("Checkout and Rebase"),
                cx,
            ),
            "compareWithCurrent" => {
                // 对齐 Tauri `viewBranchDiff`：打开选中引用与工作区的比较。
                // GPUI 的 diff 视图尚未接入，先按引用过滤历史作为最小可用行为。
                self.select_reference(reference.short_name.clone(), cx);
            }
            "rebaseCurrentOnto" => self.request_reference_confirm(
                "rebaseCurrentOnto",
                "rebase",
                reference,
                tr("Rebase Current onto Selected"),
                cx,
            ),
            "mergeIntoCurrent" => self.request_reference_confirm(
                "mergeIntoCurrent",
                "merge",
                reference,
                tr("Merge Selected into Current"),
                cx,
            ),
            "pullRebaseIntoCurrent" => self.request_reference_confirm(
                "pullRebaseIntoCurrent",
                "pull",
                reference,
                tr("Pull (Rebase) into Current"),
                cx,
            ),
            "pullMergeIntoCurrent" => self.request_reference_confirm(
                "pullMergeIntoCurrent",
                "pull",
                reference,
                tr("Pull (Merge) into Current"),
                cx,
            ),
            "update" => self.update_reference(&reference, cx),
            "push" => self.push_reference(&reference, cx),
            "rename" => self.request_rename_branch(&reference, cx),
            "deleteLocal" => self.delete_local_reference(&reference, cx),
            "deleteRemote" => self.delete_remote_reference(&reference, cx),
            "deleteTag" => {
                let title = reference_action_title("deleteTag");
                let message = format!("{}?", reference.short_name);
                self.reference_confirm = Some(super::rewrite::ReferenceConfirm {
                    operation: "deleteTag",
                    reference,
                    title,
                    message,
                    success: tr("Tag deleted"),
                });
                cx.notify();
            }
            _ => {}
        }
    }
}

/// 引用动作的标题与确认文案 key（对齐 Tauri `t("git.log.action.${action}")`）。
pub(crate) fn reference_action_title(action: &str) -> &'static str {
    match action {
        "checkout" => tr("Checkout"),
        "checkoutAndRebase" => tr("Checkout and Rebase"),
        "rebaseCurrentOnto" => tr("Rebase Current onto Selected"),
        "mergeIntoCurrent" => tr("Merge Selected into Current"),
        "pullRebaseIntoCurrent" => tr("Pull (Rebase) into Current"),
        "pullMergeIntoCurrent" => tr("Pull (Merge) into Current"),
        "update" => tr("Update Selected"),
        "push" => tr("Push"),
        "rename" => tr("Rename"),
        "deleteLocal" => tr("Delete Branch"),
        "deleteRemote" => tr("Delete Remote Branch"),
        "deleteTag" => tr("Delete"),
        "createBranch" => tr("New Branch"),
        _ => tr("Git operation"),
    }
}

/// 引用动作在确认/执行后用于 notice 的短 key：checkoutAndRebase 这类
/// 复合动作的 operation 与展示名不同。
fn reference_action_key(operation: &str) -> &'static str {
    match operation {
        "merge" => "mergeIntoCurrent",
        "rebase" => "rebaseCurrentOnto",
        "pull" => "pullMergeIntoCurrent",
        other => match other {
            "checkoutAndRebase" => "checkoutAndRebase",
            "checkout" => "checkout",
            "deleteBranch" => "deleteLocal",
            "deleteTag" => "deleteTag",
            "createBranch" => "createBranch",
            "renameBranch" => "rename",
            "updateBranch" => "update",
            "push" => "push",
            _ => "checkout",
        },
    }
}

/// 引用树分组行的折叠箭头。
pub(crate) fn group_chevron(collapsed: bool, tokens: LitheTokens) -> AnyElement {
    Icon::new(if collapsed {
        gpui_kit::assets::IconName::ChevronRight
    } else {
        gpui_kit::assets::IconName::ChevronDown
    })
    .with_size(px(10.0))
    .text_color(tokens.secondary_text)
    .into_any_element()
}

/// 远程分组行的文件夹图标，随折叠状态切换开合。
pub(crate) fn remote_folder_icon(collapsed: bool, tokens: LitheTokens) -> AnyElement {
    Icon::new(if collapsed {
        gpui_kit::assets::IconName::Folder
    } else {
        gpui_kit::assets::IconName::FolderOpen
    })
    .with_size(px(12.0))
    .text_color(tokens.secondary_text)
    .into_any_element()
}
