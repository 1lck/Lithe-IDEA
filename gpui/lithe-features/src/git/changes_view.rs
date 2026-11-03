//! 变更区：工具栏、changelist 栏、变更树（多选 / 分组复选框 / 未跟踪目录
//! 展开 / 右键菜单）。
//!
//! 拆分自原 `git.rs` 并对齐 Tauri `git-status-panel.tsx`：
//! - 复选框 = 「纳入本次提交」（staged 态），分组头复选框三态聚合；
//! - 点击 = 单选，Ctrl/Cmd = 累加，Shift = 范围（对齐 `selectTreeEntries`）；
//! - 未跟踪目录汇总行展开走 Core `git.untrackedDirectory`；
//! - 右键菜单提供 View Diff / Stage / Unstage / Rollback / Delete / Add to
//!   VCS / .gitignore / .local exclude / Create Patch / Commit / Move to
//!   Changelist（对齐 Tauri :1538-1848 的分组）。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::checkbox::Checkbox;
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    Anchor, AnyElement, ClickEvent, Context, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _,
    div, px, white,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens};

use super::model::{
    ACTION_HORIZONTAL_PADDING, CHANGE_ROW_HEIGHT, CHANGES_TOOLBAR_BUTTON_SIZE,
    CHANGES_TOOLBAR_HEIGHT, GROUP_HEADER_HEIGHT, STATUS_LINE_HEIGHT, in_group, split_path,
    status_color, status_letter,
};
use super::{ChangeAction, ChangeGroup, GitPanel, PendingAction, Selection};

impl GitPanel {
    /// 变更区工具栏：对齐 Tauri `GitStatusPanel` 的 `SidebarToolbar`
    /// （40px 高、图标按钮 22px、右侧显示当前分支）。
    ///
    /// Eye 按钮 = 预览第一处变更（staged 优先，其次工作区 / 未跟踪），
    /// 对齐 Tauri `previewFirstChange`。
    pub(crate) fn render_changes_toolbar(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let owner = cx.weak_entity();
        let branch = self
            .status
            .as_ref()
            .and_then(|status| status.branch.clone());
        let ahead = self.status.as_ref().map_or(0, |status| status.ahead);
        let behind = self.status.as_ref().map_or(0, |status| status.behind);
        // 任何写操作进行中时，所有写按钮一起禁用，避免并发改写索引。
        let busy = self.pending_action.is_some() || self.committing;
        let stage_all_pending =
            matches!(self.pending_action.as_ref(), Some(PendingAction::StageAll));
        let can_stage_all = !busy && self.can_stage_all();
        let can_unstage_all = !busy && self.can_unstage_all();
        // 没有可预览的变更时，Eye 保持禁用。
        let can_preview = self.first_change_path().is_some();

        h_flex()
            .id("lithe-git-changes-toolbar")
            .w_full()
            .flex_shrink_0()
            .h(px(CHANGES_TOOLBAR_HEIGHT))
            .items_center()
            .gap(px(2.0))
            .px(px(7.0))
            .bg(tokens.sidebar)
            .child(
                Button::new("lithe-git:refresh")
                    .ghost()
                    .with_size(px(CHANGES_TOOLBAR_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(lithe_ui::icon(lithe_ui::LitheIcon::Refresh).with_size(px(16.0)))
                    .tooltip(tr("Refresh"))
                    .disabled(
                        self.loading_status
                            || self.loading_history
                            || self.pending_action.is_some()
                            || self.committing,
                    )
                    .on_click(cx.listener(|this, _, window, cx| this.refresh(window, cx))),
            )
            .child(
                Button::new("lithe-git:discard-selected")
                    .ghost()
                    .with_size(px(CHANGES_TOOLBAR_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(
                        gpui_kit::component::Icon::new(gpui_kit::assets::IconName::Undo2)
                            .with_size(px(16.0)),
                    )
                    .tooltip(tr("Discard selected changes"))
                    .disabled(
                        busy || (self.multi_selected.is_empty() && self.selected.is_none()),
                    )
                    .on_click(cx.listener(|this, _, _window, cx| this.discard_selected_change(cx))),
            )
            .child(
                Button::new("lithe-git:stage-all")
                    .ghost()
                    .with_size(px(CHANGES_TOOLBAR_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(
                        gpui_kit::component::Icon::new(
                            gpui_kit::assets::IconName::ArrowDownToLine,
                        )
                        .with_size(px(16.0)),
                    )
                    .tooltip(tr("Stage all changes"))
                    .loading(stage_all_pending)
                    .disabled(!can_stage_all)
                    .on_click(cx.listener(|this, _, _window, cx| this.stage_all_changes(cx))),
            )
            .child(
                // 对齐 Tauri `previewFirstChange`：预览第一处变更。
                Button::new("lithe-git:preview-first")
                    .ghost()
                    .with_size(px(CHANGES_TOOLBAR_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(
                        gpui_kit::component::Icon::new(gpui_kit::assets::IconName::Eye)
                            .with_size(px(16.0)),
                    )
                    .tooltip(tr("Preview first change"))
                    .disabled(!can_preview)
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.preview_first_change(window, cx);
                    })),
            )
            .child(
                Button::new("lithe-git:more-options")
                    .ghost()
                    .with_size(px(CHANGES_TOOLBAR_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(
                        gpui_kit::component::Icon::new(gpui_kit::assets::IconName::Ellipsis)
                            .with_size(px(16.0)),
                    )
                    .tooltip(tr("More options"))
                    .dropdown_menu_with_anchor(Anchor::TopLeft, {
                        let folder_view = self.folder_view;
                        let can_unstage = can_unstage_all;
                        let can_stash = !busy && self.can_stage_all();
                        let owner_opt = owner.clone();
                        move |menu, _window, _cx| {
                            let owner_grp = owner_opt.clone();
                            let owner_flt = owner_opt.clone();
                            let owner_src = owner_opt.clone();
                            let owner_uns = owner_opt.clone();
                            let owner_stash = owner_opt.clone();
                            menu.item(
                                PopupMenuItem::new(tr("Group by Directory"))
                                    .checked(folder_view)
                                    .on_click(move |_, _, cx| {
                                        let _ = owner_grp.update(cx, |this, cx| {
                                            this.folder_view = true;
                                            cx.notify();
                                        });
                                    }),
                            )
                            .item(
                                PopupMenuItem::new(tr("Flat List"))
                                    .checked(!folder_view)
                                    .on_click(move |_, _, cx| {
                                        let _ = owner_flt.update(cx, |this, cx| {
                                            this.folder_view = false;
                                            cx.notify();
                                        });
                                    }),
                            )
                            .separator()
                            .item(
                                PopupMenuItem::new(tr("Choose Diff Source"))
                                    .on_click(move |_, window, cx| {
                                        let _ = owner_src.update(cx, |this, cx| {
                                            this.open_dialog(
                                                super::GitDialogKind::ChooseDiffSource,
                                                window,
                                                cx,
                                            );
                                        });
                                    }),
                            )
                            .item(
                                PopupMenuItem::new(tr("Unstage All Changes"))
                                    .disabled(!can_unstage)
                                    .on_click(move |_, _, cx| {
                                        let _ = owner_uns.update(cx, |this, cx| {
                                            this.unstage_all_changes(cx);
                                        });
                                    }),
                            )
                            .item(
                                PopupMenuItem::new(tr("Stash All Unstaged"))
                                    .disabled(!can_stash)
                                    .on_click(move |_, _, cx| {
                                        let _ = owner_stash.update(cx, |this, cx| {
                                            this.request_stash_push(
                                                super::stash_view::StashPushScope::AllUnstaged,
                                                Vec::new(),
                                                cx,
                                            );
                                        });
                                    }),
                            )
                        }
                    }),
            )
            .child(div().flex_1())
            .when(ahead > 0 || behind > 0, |this| {
                this.child(
                    div()
                        .flex_shrink_0()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.secondary_text)
                        .child(format!("↑{ahead} ↓{behind}")),
                )
            })
            .when_some(branch, |this, branch| {
                this.child(
                    div()
                        .min_w(px(0.0))
                        .flex_shrink_1()
                        .truncate()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.tertiary_text)
                        .child(branch),
                )
            })
            .into_any_element()
    }

    /// changelist 栏：真实列表选择器 + New/Rename/Delete + 父仓库引用开关
    /// （对齐 Tauri `GitChangelistBar`）。设置 `showGitChangelists=false` 时
    /// 整栏隐藏（对齐 Tauri git-view.tsx:236-241）。
    pub(crate) fn render_changelist_bar(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if !self.show_changelists {
            return div().into_any_element();
        }
        let owner = cx.weak_entity();
        let active = self.changelists.active_name();
        let items = self.changelists.names();
        let can_edit = self.changelists.can_edit_active();

        let selector = Button::new("lithe-git:changelist-selector")
            .ghost()
            .h(px(26.0))
            .w(px(156.0))
            .px(px(8.0))
            .rounded(px(4.0))
            .border_1()
            .border_color(tokens.panel_border)
            .items_center()
            .justify_between()
            .child(
                div()
                    .truncate()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.primary_text)
                    // 下面下拉菜单的闭包还要读 active，先克隆一份避免 move。
                    .child(active.clone()),
            )
            .child(
                Icon::new(gpui_kit::assets::IconName::ChevronDown)
                    .with_size(px(12.0))
                    .text_color(tokens.secondary_text),
            )
            .dropdown_menu(move |menu, _window, _cx| {
                let mut menu = menu.min_w(px(180.0));
                for (id, name) in items.iter() {
                    let owner = owner.clone();
                    let id = id.clone();
                    let is_active = name == &active;
                    menu = menu.item(
                        PopupMenuItem::new(name.clone())
                            .checked(is_active)
                            .on_click(move |_, _, cx| {
                                let _ = owner.update(cx, |this, cx| {
                                    this.changelists.set_active(&id);
                                    cx.notify();
                                });
                            }),
                    );
                }
                menu
            });

        let changelist_actions = h_flex()
            .items_center()
            .gap(px(2.0))
            .child(
                Button::new("lithe-git:new-changelist")
                    .ghost()
                    .with_size(px(CHANGES_TOOLBAR_BUTTON_SIZE))
                    .rounded(px(4.0))
                    .icon(Icon::new(gpui_kit::assets::IconName::Plus).with_size(px(13.0)))
                    .tooltip(tr("New Changelist"))
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.request_changelist_name(
                            super::changelists::ChangelistPrompt::New,
                            window,
                            cx,
                        );
                    })),
            )
            .child(
                Button::new("lithe-git:edit-changelist")
                    .ghost()
                    .with_size(px(CHANGES_TOOLBAR_BUTTON_SIZE))
                    .rounded(px(4.0))
                    .icon(Icon::new(gpui_kit::assets::IconName::Pencil).with_size(px(13.0)))
                    .tooltip(tr("Rename Changelist"))
                    .disabled(!can_edit)
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.request_changelist_name(
                            super::changelists::ChangelistPrompt::Rename,
                            window,
                            cx,
                        );
                    })),
            )
            .child(
                Button::new("lithe-git:delete-changelist")
                    .ghost()
                    .with_size(px(CHANGES_TOOLBAR_BUTTON_SIZE))
                    .rounded(px(4.0))
                    .icon(Icon::new(gpui_kit::assets::IconName::Trash).with_size(px(13.0)))
                    .tooltip(tr("Delete Changelist"))
                    .disabled(!can_edit)
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.delete_active_changelist(cx);
                    })),
            );

        let row1 = h_flex()
            .w_full()
            .items_center()
            .justify_between()
            .child(selector)
            .child(changelist_actions);

        let parent_ref_checkbox = h_flex()
            .items_center()
            .gap(px(6.0))
            .child(
                Checkbox::new("lithe-git:update-parent-refs")
                    .small()
                    .checked(self.update_parent_refs)
                    .on_change(cx.listener(|this, checked: &bool, _window, cx| {
                        this.update_parent_refs = *checked;
                        cx.notify();
                    })),
            )
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr("Update Parent Repository References")),
            );

        v_flex()
            .id("lithe-git-changelist-bar")
            .w_full()
            .px(px(8.0))
            .pt(px(6.0))
            .pb(px(8.0))
            .gap(px(6.0))
            .bg(tokens.sidebar)
            .child(row1)
            .child(parent_ref_checkbox)
            .into_any_element()
    }

    pub(crate) fn render_body(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        // Tauri 的提交面板是单栏：工具条下方是更改列表选择器，接着是变更树，
        // 提交区固定在底部。changelist 栏受设置开关控制。
        v_flex()
            .w_full()
            .flex_1()
            .min_h_0()
            .child(self.render_changelist_bar(tokens, cx))
            .child(self.render_change_list(tokens, cx))
            .into_any_element()
    }

    pub(crate) fn render_change_list(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mut list = v_flex()
            .id("lithe-git-changes-scroll")
            .w_full()
            .flex_1()
            .h_full()
            .min_h_0()
            .min_w_0()
            .bg(tokens.sidebar)
            // gpui 0.3.10 的 `overflow_y_scroll` 只在有稳定 id 的 Stateful 元素上。
            .overflow_y_scroll();

        let Some(status) = self.status.as_ref() else {
            return list
                .child(empty_state(
                    tokens,
                    if self.loading_status {
                        tr("Loading changes…")
                    } else {
                        tr("Changes unavailable")
                    },
                ))
                .into_any_element();
        };

        if status.branch.is_none() {
            return list
                .child(empty_state(tokens, tr("Not a Git repository")))
                .into_any_element();
        }

        let mut total = 0usize;
        // 提交与写操作都会改动索引，同一时刻只允许一个在飞。
        let busy = self.pending_action.is_some() || self.committing;
        // 「暂存优先」关闭时工作区变更排在暂存之前（Tauri showStagedFirst）。
        let groups: &[ChangeGroup] = if self.git_show_staged_first {
            &[
                ChangeGroup::Staged,
                ChangeGroup::Worktree,
                ChangeGroup::Untracked,
            ]
        } else {
            &[
                ChangeGroup::Worktree,
                ChangeGroup::Staged,
                ChangeGroup::Untracked,
            ]
        };
        for group in groups.iter().copied() {
            let changes = status
                .changes
                .iter()
                .filter(|change| in_group(change, group))
                .collect::<Vec<_>>();
            // 「显示未跟踪文件」关闭时隐藏整组。
            if group == ChangeGroup::Untracked && !self.git_show_untracked {
                continue;
            }
            if changes.is_empty() {
                continue;
            }
            total += changes.len();
            list = list.child(self.render_group_header(group, &changes, busy, tokens, cx));
            for change in changes {
                if change.is_untracked_directory() {
                    list = list.child(self.render_untracked_directory_row(
                        change,
                        busy,
                        tokens,
                        cx,
                    ));
                    // 展开的目录渲染缓存里的文件行；加载中显示一行占位。
                    if self.untracked_expanded.contains(&change.path) {
                        match self.untracked_child_files(&change.path) {
                            Some(files) => {
                                for file in files.clone() {
                                    list = list.child(self.render_untracked_file_row(
                                        &change.path, &file, busy, tokens, cx,
                                    ));
                                }
                            }
                            None => {
                                list = list.child(
                                    div()
                                        .w_full()
                                        .flex_shrink_0()
                                        .h(px(STATUS_LINE_HEIGHT))
                                        .px(px(ACTION_HORIZONTAL_PADDING))
                                        .items_center()
                                        .flex()
                                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                                        .text_color(tokens.tertiary_text)
                                        .child(if self.is_untracked_loading(&change.path) {
                                            tr("Loading…").to_string()
                                        } else {
                                            tr("No files").to_string()
                                        }),
                                );
                            }
                        }
                    }
                    continue;
                }
                list = list.child(self.render_change_row(
                    change,
                    group,
                    self.pending_action.as_ref(),
                    busy,
                    tokens,
                    cx,
                ));
            }
        }

        if total == 0 {
            list = list.child(empty_state(tokens, tr("No changes")));
        }
        list.into_any_element()
    }

    /// 分组标题行：三态复选框（全部含 / 全不含 / 部分）+ 标题 + 计数。
    fn render_group_header(
        &self,
        group: ChangeGroup,
        changes: &[&super::model::CoreChange],
        busy: bool,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let toggleable: Vec<&super::model::CoreChange> = changes
            .iter()
            .copied()
            .filter(|change| change.can_toggle_staging && !change.is_untracked_directory())
            .collect();
        let all_staged = !toggleable.is_empty()
            && toggleable.iter().all(|change| change.staged);
        let any_staged = toggleable.iter().any(|change| change.staged);
        let group_for_toggle = group;

        h_flex()
            .w_full()
            .flex_shrink_0()
            .h(px(GROUP_HEADER_HEIGHT))
            .gap(px(6.0))
            .px(px(ACTION_HORIZONTAL_PADDING))
            .child(
                Checkbox::new(SharedString::from(format!("lithe-git:group:{}", group.id())))
                    .small()
                    .checked(all_staged)
                    .disabled(busy || toggleable.is_empty())
                    .on_change(cx.listener(move |this, _checked: &bool, _window, cx| {
                        // 三态聚合：全选时点击=全部取消暂存，否则=全部暂存。
                        this.toggle_group_staging(group_for_toggle, !all_staged || !any_staged, cx);
                    })),
            )
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.secondary_text)
                    .child(group.title()),
            )
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(changes.len().to_string()),
            )
            .into_any_element()
    }

    /// 未跟踪目录汇总行：「N files」+ 展开 / 收起；展开内容来自
    /// Core `git.untrackedDirectory`（对齐 Tauri 汇总行 + 双击切换）。
    fn render_untracked_directory_row(
        &self,
        change: &super::model::CoreChange,
        busy: bool,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let directory = change.path.clone();
        let expanded = self.untracked_expanded.contains(&directory);
        let files_label = match change.untracked_file_count {
            Some(count) => tr("{count} files").replace("{count}", &count.to_string()),
            None => tr("files").to_string(),
        };
        let (name, parent) = split_path(directory.trim_end_matches('/'));
        let path_for_stage = directory.clone();
        let path_for_menu = directory.clone();
        let dir_for_menu = directory.clone();

        let row = h_flex()
            .id(SharedString::from(format!(
                "lithe-git:untracked-dir:{}",
                change.path
            )))
            .w_full()
            .flex_shrink_0()
            .h(px(CHANGE_ROW_HEIGHT))
            .px(px(ACTION_HORIZONTAL_PADDING))
            .items_center()
            .gap(px(6.0))
            .hover(|style| style.bg(tokens.hover))
            .cursor_pointer()
            .on_click(cx.listener(move |this, _, window, cx| {
                this.toggle_untracked_directory(&dir_for_menu.clone(), window, cx);
            }))
            .child(
                Icon::new(if expanded {
                    gpui_kit::assets::IconName::ChevronDown
                } else {
                    gpui_kit::assets::IconName::ChevronRight
                })
                .with_size(px(12.0))
                .text_color(tokens.secondary_text),
            )
            .child(
                Icon::new(gpui_kit::assets::IconName::Folder)
                    .with_size(px(14.0))
                    .text_color(tokens.success),
            )
            .child(
                v_flex()
                    .min_w(px(0.0))
                    .flex_1()
                    .gap(px(1.0))
                    .child(
                        div()
                            .min_w(px(0.0))
                            .truncate()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.primary_text)
                            .child(name),
                    )
                    .child(
                        div()
                            .min_w(px(0.0))
                            .truncate()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(format!("{parent} · {files_label}")),
                    ),
            )
            .child(
                Button::new(SharedString::from(format!(
                    "lithe-git:untracked-dir-stage:{}",
                    change.path
                )))
                .ghost()
                .xsmall()
                .label(tr("Stage"))
                .disabled(busy || !change.can_toggle_staging)
                .on_click(cx.listener(move |this, _, _window, cx| {
                    cx.stop_propagation();
                    this.apply_change_action(
                        path_for_stage.clone(),
                        ChangeGroup::Untracked,
                        ChangeAction::Stage,
                        cx,
                    );
                })),
            )
            .on_mouse_down(
                gpui_kit::MouseButton::Right,
                cx.listener(move |this, event: &gpui_kit::MouseDownEvent, window, cx| {
                    this.open_change_menu(&path_for_menu.clone(), event.position, window, cx);
                }),
            );
        row.into_any_element()
    }

    /// 展开的未跟踪目录里的文件行：路径缩进 + Stage（对齐 Tauri 的
    /// 展开列表；文件尚未纳入版本控制，只有一次性暂存 / 打开动作）。
    fn render_untracked_file_row(
        &self,
        _directory: &str,
        file: &str,
        busy: bool,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let (name, parent) = split_path(file);
        let stage_path = file.to_string();
        let open_path = file.to_string();
        let menu_path = file.to_string();

        h_flex()
            .id(SharedString::from(format!(
                "lithe-git:untracked-file:{}",
                file
            )))
            .w_full()
            .flex_shrink_0()
            .h(px(CHANGE_ROW_HEIGHT))
            .pl(px(ACTION_HORIZONTAL_PADDING + 18.0))
            .pr(px(ACTION_HORIZONTAL_PADDING))
            .items_center()
            .gap(px(6.0))
            .hover(|style| style.bg(tokens.hover))
            .cursor_pointer()
            .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                if event.click_count() >= 2 {
                    this.open_change(&open_path, window, cx);
                }
            }))
            .child(
                Icon::new(gpui_kit::assets::IconName::FileText)
                    .with_size(px(14.0))
                    .text_color(tokens.success),
            )
            .child(
                v_flex()
                    .min_w(px(0.0))
                    .flex_1()
                    .gap(px(1.0))
                    .child(
                        div()
                            .min_w(px(0.0))
                            .truncate()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.primary_text)
                            .child(name),
                    )
                    .child(
                        div()
                            .min_w(px(0.0))
                            .truncate()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(parent),
                    ),
            )
            .child(
                Button::new(SharedString::from(format!(
                    "lithe-git:untracked-file-stage:{}",
                    file
                )))
                .ghost()
                .xsmall()
                .label(tr("Stage"))
                .disabled(busy)
                .on_click(cx.listener(move |this, _, _window, cx| {
                    cx.stop_propagation();
                    this.stage_paths(&[stage_path.clone()], cx);
                })),
            )
            .on_mouse_down(
                gpui_kit::MouseButton::Right,
                cx.listener(move |this, event: &gpui_kit::MouseDownEvent, window, cx| {
                    this.open_change_menu(&menu_path.clone(), event.position, window, cx);
                }),
            )
            .into_any_element()
    }

    fn render_change_row(
        &self,
        change: &super::model::CoreChange,
        group: ChangeGroup,
        pending: Option<&PendingAction>,
        busy: bool,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let (file_name, directory) = split_path(&change.path);
        let selection = Selection {
            path: change.path.clone(),
            group,
        };
        let selected = self.is_selected(&selection);
        let letter = status_letter(change, group);
        let letter_color = if selected {
            white()
        } else {
            status_color(letter, change.untracked, tokens)
        };
        // 重命名在 Git 中同时提供旧路径；展示成 `old → new` 比只显示新路径更容易
        // 对应到用户改动的文件。
        let detail = match change.original_path.as_deref() {
            Some(original) if !original.is_empty() && original != change.path => {
                format!("{original} → {}", change.path)
            }
            _ => directory,
        };

        let click_selection = selection.clone();
        let click_path = change.path.clone();
        let menu_path = change.path.clone();
        // 复选框表示「纳入本次提交」。Core 只有索引这一个可写状态，因此勾选等价
        // 于暂存、取消勾选等价于取消暂存——与 IntelliJ 提交面板的语义一致。
        let checkbox_path = change.path.clone();
        let checkbox_checked = group == ChangeGroup::Staged;

        let mut row = div()
            .id(SharedString::from(format!(
                "lithe-git:change:{}:{}",
                group.id(),
                change.path
            )))
            .w_full()
            .flex_shrink_0()
            .h(px(CHANGE_ROW_HEIGHT))
            .px(px(ACTION_HORIZONTAL_PADDING))
            .flex()
            .flex_row()
            .items_center()
            .gap(px(6.0))
            .when(selected, |this| this.bg(tokens.selection))
            .when(!selected, |this| this.hover(|style| style.bg(tokens.hover)))
            .cursor_pointer()
            .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                this.select_change_with_modifiers(
                    click_selection.clone(),
                    event.modifiers().control
                        || event.modifiers().platform
                        || event.modifiers().alt,
                    event.modifiers().shift,
                    cx,
                );
                if event.click_count() >= 2 {
                    this.open_change(&click_path, window, cx);
                }
            }))
            .child(
                // IntelliJ 把「包含在提交里」的复选框放在状态字母之前。
                Checkbox::new(SharedString::from(format!(
                    "lithe-git:include:{}:{}",
                    group.id(),
                    change.path
                )))
                .small()
                .flex_shrink_0()
                .checked(checkbox_checked)
                .disabled(busy || !change.can_toggle_staging)
                .on_change(cx.listener(move |this, checked: &bool, _window, cx| {
                    let action = if *checked {
                        ChangeAction::Stage
                    } else {
                        ChangeAction::Unstage
                    };
                    this.apply_change_action(checkbox_path.clone(), group, action, cx);
                })),
            )
            .child(
                div()
                    .w(px(LitheMetrics::TREE_ICON_SIZE))
                    .flex_shrink_0()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .font_weight(FontWeight::BOLD)
                    .text_color(letter_color)
                    .child(letter.to_string()),
            )
            .child(
                v_flex()
                    .min_w(px(0.0))
                    .flex_1()
                    .gap(px(1.0))
                    .child(
                        div()
                            .min_w(px(0.0))
                            .truncate()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(if selected {
                                white()
                            } else {
                                tokens.primary_text
                            })
                            .child(file_name),
                    )
                    .when(!detail.is_empty(), |this| {
                        this.child(
                            div()
                                .min_w(px(0.0))
                                .truncate()
                                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                                .text_color(if selected {
                                    white()
                                } else {
                                    tokens.secondary_text
                                })
                                .child(detail),
                        )
                    }),
            );

        // 按钮始终显示（悬停显隐需要行级 group 状态，收益不值得额外复杂度）。
        for action in super::actions::actions_for(change, group) {
            row = row.child(render_action_button(
                change, group, *action, selected, pending, busy, cx,
            ));
        }
        row.on_mouse_down(
            gpui_kit::MouseButton::Right,
            cx.listener(move |this, event: &gpui_kit::MouseDownEvent, window, cx| {
                // 右键先选中该行，动作以它为目标（对齐 Tauri onContextSelect）。
                let selection = Selection {
                    path: menu_path.clone(),
                    group,
                };
                if !this.is_selected(&selection) {
                    this.multi_selected.clear();
                    this.multi_selected.insert(selection.clone());
                    this.selected = Some(selection);
                }
                this.open_change_menu(&menu_path.clone(), event.position, window, cx);
            }),
        )
        .into_any_element()
    }

    /// 变更行右键菜单（对齐 Tauri git-status-panel.tsx:1538-1848）。
    pub(crate) fn open_change_menu(
        &mut self,
        path: &str,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut gpui_kit::Window,
        cx: &mut Context<Self>,
    ) {
        let owner = cx.weak_entity();
        let selected_count = self.multi_selected.len().max(1);
        let paths: Vec<String> = if self.multi_selected.is_empty() {
            vec![path.to_string()]
        } else {
            self.multi_selected.iter().map(|s| s.path.clone()).collect()
        };
        let busy = self.pending_action.is_some() || self.committing;

        let popup =
            gpui_kit::component::menu::PopupMenu::build(window, cx, move |menu, _window, _cx| {
                let mut menu = menu.min_w(px(220.0));
                // --- 差异来源分组 ---
                menu = menu
                    .item(PopupMenuItem::new(tr("View Diff")).on_click({
                        let owner = owner.clone();
                        let path = paths.first().cloned().unwrap_or_default();
                        move |_, window, cx| {
                            let _ = owner.update(cx, |this, cx| {
                                this.preview_change_paths(vec![path.clone()], window, cx);
                            });
                        }
                    }));
                menu = menu.separator();
                // --- 暂存分组 ---
                menu = menu
                    .item(PopupMenuItem::new(tr("Stage selected")).disabled(busy).on_click({
                        let owner = owner.clone();
                        let stage_paths = paths.clone();
                        move |_, _, cx| {
                            let _ = owner.update(cx, |this, cx| {
                                this.stage_paths(&stage_paths.clone(), cx);
                            });
                        }
                    }))
                    .item(
                        PopupMenuItem::new(tr("Unstage selected"))
                            .disabled(busy)
                            .on_click({
                                let owner = owner.clone();
                                let unstage_paths = paths.clone();
                                move |_, _, cx| {
                                    let _ = owner.update(cx, |this, cx| {
                                        this.unstage_paths(&unstage_paths.clone(), cx);
                                    });
                                }
                            }),
                    );
                menu = menu.separator();
                // --- 破坏性动作分组 ---
                menu = menu
                    .item(
                        PopupMenuItem::new(tr("Rollback"))
                            .disabled(busy)
                            .on_click({
                                let owner = owner.clone();
                                let rollback_paths = paths.clone();
                                move |_, _, cx| {
                                    let _ = owner.update(cx, |this, cx| {
                                        this.rollback_paths(&rollback_paths.clone(), cx);
                                    });
                                }
                            }),
                    )
                    .item(
                        PopupMenuItem::new(
                            tr("Delete {count} files").replace(
                                "{count}",
                                &selected_count.to_string(),
                            ),
                        )
                        .disabled(busy)
                        .on_click({
                            let owner = owner.clone();
                            let delete_paths = paths.clone();
                            move |_, _, cx| {
                                let _ = owner.update(cx, |this, cx| {
                                    this.request_delete_files(&delete_paths.clone(), cx);
                                });
                            }
                        }),
                    );
                menu = menu.separator();
                // --- 版本控制分组 ---
                menu = menu
                    .item(
                        PopupMenuItem::new(tr("Add to VCS")).disabled(busy).on_click({
                            let owner = owner.clone();
                            let add_paths = paths.clone();
                            move |_, _, cx| {
                                let _ = owner.update(cx, |this, cx| {
                                    this.stage_paths(&add_paths.clone(), cx);
                                });
                            }
                        }),
                    )
                    .item(
                        PopupMenuItem::new(tr("Add to .gitignore"))
                            .disabled(busy)
                            .on_click({
                                let owner = owner.clone();
                                let ignore_paths = paths.clone();
                                move |_, _, cx| {
                                    let _ = owner.update(cx, |this, cx| {
                                        this.request_add_to_ignore(
                                            super::ignore::IgnoreTarget::Gitignore,
                                            &ignore_paths.clone(),
                                            cx,
                                        );
                                    });
                                }
                            }),
                    )
                    .item(
                        PopupMenuItem::new(tr("Add to .local exclude"))
                            .disabled(busy)
                            .on_click({
                                let owner = owner.clone();
                                let exclude_paths = paths.clone();
                                move |_, _, cx| {
                                    let _ = owner.update(cx, |this, cx| {
                                        this.request_add_to_ignore(
                                            super::ignore::IgnoreTarget::LocalExclude,
                                            &exclude_paths.clone(),
                                            cx,
                                        );
                                    });
                                }
                            }),
                    );
                menu = menu.separator();
                // --- 流程分组 ---
                menu = menu
                    .item(
                        PopupMenuItem::new(tr("Create Patch…")).on_click({
                            let owner = owner.clone();
                            let patch_paths = paths.clone();
                            move |_, window, cx| {
                                let _ = owner.update(cx, |this, cx| {
                                    this.set_patch_selection(patch_paths.clone());
                                    this.open_dialog(
                                        super::GitDialogKind::CreatePatch,
                                        window,
                                        cx,
                                    );
                                });
                            }
                        }),
                    )
                    .item(
                        PopupMenuItem::new(tr("Commit selected")).on_click({
                            let owner = owner.clone();
                            let commit_paths = paths.clone();
                            move |_, _, cx| {
                                let _ = owner.update(cx, |this, cx| {
                                    this.stage_paths(&commit_paths.clone(), cx);
                                    this.focus_commit_message(cx);
                                });
                            }
                        }),
                    )
                    .item(
                        PopupMenuItem::new(tr("Stash selected")).disabled(busy).on_click({
                            let owner = owner.clone();
                            let stash_paths = paths.clone();
                            move |_, _, cx| {
                                let _ = owner.update(cx, |this, cx| {
                                    this.request_stash_push(
                                        super::stash_view::StashPushScope::Selected,
                                        stash_paths.clone(),
                                        cx,
                                    );
                                });
                            }
                        }),
                    )
                    .item(
                        PopupMenuItem::new(tr("Move to Changelist…")).on_click({
                            let owner = owner.clone();
                            let move_paths = paths.clone();
                            move |_, _, cx| {
                                let _ = owner.update(cx, |this, cx| {
                                    this.request_move_to_changelist(move_paths.clone(), cx);
                                });
                            }
                        }),
                    );
                menu
            });

        cx.subscribe_in(
            &popup,
            window,
            |this, _, _: &gpui_kit::DismissEvent, _window, cx| {
                this.change_menu = None;
                cx.notify();
            },
        )
        .detach();
        self.change_menu = Some((popup, position));
        cx.notify();
    }
}

/// 行内动作按钮。
///
/// 按钮嵌在可点击的变更行里，因此必须在自己的点击回调里 `stop_propagation`，
/// 否则一次点击会同时改变选中项，双击还会顺带打开文件。
fn render_action_button(
    change: &super::model::CoreChange,
    group: ChangeGroup,
    action: ChangeAction,
    selected: bool,
    pending: Option<&PendingAction>,
    busy: bool,
    cx: &mut Context<GitPanel>,
) -> AnyElement {
    let path = change.path.clone();
    let in_progress = matches!(
        pending,
        Some(PendingAction::Change {
            path: pending_path,
            group: pending_group,
            action: pending_action,
        }) if *pending_group == group
            && *pending_action == action
            && pending_path.as_str() == path.as_str()
    );
    // 子模块父 gitlink 无法安全切换暂存状态；Core 用 can_toggle_staging 标明。
    let staging_blocked =
        !change.can_toggle_staging && matches!(action, ChangeAction::Stage | ChangeAction::Unstage);

    Button::new(SharedString::from(format!(
        "lithe-git:change:{}:{}:{}",
        group.id(),
        change.path,
        action.id()
    )))
    .ghost()
    .xsmall()
    .label(action.label())
    .loading(in_progress)
    .disabled(busy || staging_blocked)
    // 选中行是强调色背景，幽灵按钮需要换成白字才看得清。
    .when(selected, |this| this.text_color(white()))
    .on_click(cx.listener(move |this, _, _window, cx| {
        cx.stop_propagation();
        if action == ChangeAction::Discard {
            this.request_discard(path.clone(), group, cx);
        } else {
            this.apply_change_action(path.clone(), group, action, cx);
        }
    }))
    .into_any_element()
}

// --- 渲染辅助 ---------------------------------------------------------------

pub(crate) fn status_line(color: gpui_kit::Hsla, message: SharedString) -> AnyElement {
    div()
        .w_full()
        .flex_shrink_0()
        .h(px(STATUS_LINE_HEIGHT))
        .px(px(ACTION_HORIZONTAL_PADDING))
        .flex()
        .items_center()
        .child(
            div()
                .min_w(px(0.0))
                .flex_1()
                .truncate()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(color)
                .child(message),
        )
        .into_any_element()
}

pub(crate) fn empty_state(tokens: LitheTokens, message: &str) -> AnyElement {
    v_flex()
        .size_full()
        .items_center()
        .justify_center()
        .gap(px(8.0))
        .px(px(16.0))
        .child(
            Icon::new(gpui_kit::assets::IconName::FileSearch)
                .with_size(px(44.0))
                .text_color(tokens.tertiary_text),
        )
        .child(
            div()
                .text_size(px(14.0))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(tokens.primary_text)
                .child(if message == tr("No changes") {
                    tr("Select a file to review").to_string()
                } else {
                    message.to_string()
                }),
        )
        .child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(if message == tr("No changes") {
                    tr("Changes from external tools will appear automatically.").to_string()
                } else {
                    String::new()
                }),
        )
        .into_any_element()
}
