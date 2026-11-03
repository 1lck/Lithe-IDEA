//! 提交工具窗标题栏（对齐 Tauri `git-view.tsx` 的 `SidebarTitleBar` +
//! `git-actions-menu.tsx` 的 16 项操作菜单）。
//!
//! Tauri 的提交工具窗标题栏只有两件事：
//! - 左侧「提交 / Stash」分段（`git-commit-tab`，选中态带独立底色与边框）；
//! - 右侧一个 `MoreHorizontal` 操作按钮，点开 Git 操作菜单。
//!
//! 全部菜单项都有真实动作（对齐 git-actions-menu.tsx 的 disabled / 降级
//! 规则）：写操作转发给 `GitPanel`；管理器对话框统一经
//! `CommitHeaderAction::Dialog(GitDialogKind)` 交给工作台打开。没有 Git
//! 仓库时菜单降级为「Initialize Repository + Refresh」两项（对齐
//! git-actions-menu.tsx:315-333）。刷新按钮属于变更区工具栏，不在这里
//! 重复一份；收起按钮由工具窗容器统一提供。

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu, PopupMenuItem};
use gpui_kit::component::{Icon, Sizable as _, h_flex};
use gpui_kit::{
    Anchor, AnyElement, Context, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, StatefulInteractiveElement as _, Styled as _, WeakEntity, div, px,
};
use lithe_features::git::GitDialogKind;
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, icon};

use crate::workbench::{CommitHeaderAction, ToolWindow, Workbench};

/// Tauri `git-commit-tab` 的高度与圆角。
const COMMIT_TAB_HEIGHT: f32 = 28.0;
const COMMIT_TAB_RADIUS: f32 = 6.0;
const COMMIT_TAB_PADDING_X: f32 = 8.0;
/// 标题栏操作按钮尺寸。
const HEADER_BUTTON_SIZE: f32 = 22.0;
const HEADER_BUTTON_RADIUS: f32 = 5.0;
const HEADER_ICON_SIZE: f32 = 14.0;

/// 提交工具窗的两种视图，对应标题栏上的两个分段。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CommitTab {
    Commit,
    Stash,
}

/// 渲染提交工具窗标题栏。
pub(crate) fn render_commit_tool_header(
    active_tab: CommitTab,
    has_git_repo: bool,
    tokens: LitheTokens,
    owner: WeakEntity<Workbench>,
    cx: &mut Context<Workbench>,
) -> AnyElement {
    let _ = cx;
    let tab_bar = h_flex()
        .id("lithe-commit-tabs")
        .items_center()
        .gap(px(2.0))
        .child(render_commit_tab(
            "lithe-commit-tab:commit",
            tr("Commit"),
            active_tab == CommitTab::Commit,
            false,
            tokens,
            owner.clone(),
        ))
        .child(render_commit_tab(
            "lithe-commit-tab:stash",
            tr("Stash"),
            active_tab == CommitTab::Stash,
            true,
            tokens,
            owner.clone(),
        ));

    let actions_owner = owner.clone();
    let actions_button = Button::new("lithe-commit-header-actions")
        .ghost()
        .with_size(px(HEADER_BUTTON_SIZE))
        .rounded(px(HEADER_BUTTON_RADIUS))
        .icon(icon(LitheIcon::More).with_size(px(HEADER_ICON_SIZE)))
        .tooltip(tr("Git actions"))
        .accessibility_label(tr("Git actions"))
        .dropdown_menu_with_anchor(Anchor::TopRight, {
            move |menu, _window, _cx| {
                // 每个菜单项的闭包单独捕获一份 owner（与既有代码同型）。
                let owner_repo_select = owner.clone();
                let owner_dialog_branch = owner.clone();
                let owner_log = owner.clone();
                let owner_dialog_push = owner.clone();
                let owner_dialog_pull = owner.clone();
                let owner_fetch = owner.clone();
                let owner_dialog_remotes = owner.clone();
                let owner_dialog_tags = owner.clone();
                let owner_stash = owner.clone();
                let owner_refresh = owner.clone();
                let owner_dialog_worktrees = owner.clone();
                let owner_dialog_rebase = owner.clone();
                let owner_dialog_patch = owner.clone();
                let owner_dialog_apply = owner.clone();
                let owner_discard = owner.clone();

                if !has_git_repo {
                    // Tauri 的降级菜单：没有仓库时只剩「初始化」与「刷新」。
                    // `PopupMenu::item` 是消费式构建器，必须把返回值作为
                    // 闭包结果直接返回，不能丢弃后再用 `menu`。
                    return menu
                        .item(
                            PopupMenuItem::new(tr("Initialize Repository"))
                                .icon(Icon::new(IconName::FolderGit))
                                .on_click(move |_, window, cx| {
                                    let _ = owner_repo_select.update(cx, |this, cx| {
                                        this.commit_header_action(
                                            CommitHeaderAction::Initialize,
                                            window,
                                            cx,
                                        );
                                    });
                                }),
                        )
                        .item(
                            PopupMenuItem::new(tr("Refresh Status"))
                                .icon(Icon::new(IconName::RotateCw))
                                .on_click(move |_, window, cx| {
                                    let _ = owner_refresh.update(cx, |this, cx| {
                                        this.refresh_tool(ToolWindow::Changes, window, cx)
                                    });
                                }),
                        );
                }

                menu.item(
                    PopupMenuItem::new(tr("Select Repository"))
                        .icon(Icon::new(IconName::Folder))
                        .on_click(move |_, window, cx| {
                            let _ = owner_repo_select
                                .update(cx, |this, cx| this.pick_project(window, cx));
                        }),
                )
                .separator()
                .item(
                    PopupMenuItem::new(tr("Manage Branches"))
                        .icon(Icon::new(IconName::GitBranch))
                        // Tauri 这里打开完整的分支管理器；面板内引用树的右键
                        // 菜单仍是独立的分支操作入口（两处入口并存）。
                        .on_click(move |_, window, cx| {
                            let _ = owner_dialog_branch.update(cx, |this, cx| {
                                this.commit_header_action(
                                    CommitHeaderAction::Dialog(GitDialogKind::Branches),
                                    window,
                                    cx,
                                );
                            });
                        }),
                )
                .item(
                    PopupMenuItem::new(tr("Show Branch Diff"))
                        .icon(Icon::new(IconName::GitPullRequest))
                        .on_click(move |_, window, cx| {
                            let _ = owner_log.update(cx, |this, cx| {
                                this.show_tool(ToolWindow::GitLog, window, cx)
                            });
                        }),
                )
                .separator()
                .item(
                    PopupMenuItem::new(tr("Push Changes"))
                        .icon(Icon::new(IconName::Upload))
                        .on_click(move |_, window, cx| {
                            let _ = owner_dialog_push.update(cx, |this, cx| {
                                this.commit_header_action(
                                    CommitHeaderAction::Dialog(GitDialogKind::Push),
                                    window,
                                    cx,
                                );
                            });
                        }),
                )
                .item(
                    PopupMenuItem::new(tr("Pull Changes"))
                        .icon(Icon::new(IconName::Download))
                        .on_click(move |_, window, cx| {
                            let _ = owner_dialog_pull.update(cx, |this, cx| {
                                this.commit_header_action(
                                    CommitHeaderAction::Dialog(GitDialogKind::Pull),
                                    window,
                                    cx,
                                );
                            });
                        }),
                )
                .item(
                    PopupMenuItem::new(tr("Fetch"))
                        .icon(Icon::new(IconName::GitPullRequest))
                        .on_click(move |_, window, cx| {
                            let _ = owner_fetch.update(cx, |this, cx| {
                                // 对齐 Tauri handleFetch：默认参数直执行，
                                // toast + 刷新，无对话框。
                                this.commit_header_action(CommitHeaderAction::Fetch, window, cx);
                            });
                        }),
                )
                .separator()
                .item(
                    PopupMenuItem::new(tr("Manage Remotes"))
                        .icon(Icon::new(IconName::HardDrive))
                        .on_click(move |_, window, cx| {
                            let _ = owner_dialog_remotes.update(cx, |this, cx| {
                                this.commit_header_action(
                                    CommitHeaderAction::Dialog(GitDialogKind::Remotes),
                                    window,
                                    cx,
                                );
                            });
                        }),
                )
                .item(
                    PopupMenuItem::new(tr("Manage Tags"))
                        .icon(Icon::new(IconName::Tag))
                        .on_click(move |_, window, cx| {
                            let _ = owner_dialog_tags.update(cx, |this, cx| {
                                this.commit_header_action(
                                    CommitHeaderAction::Dialog(GitDialogKind::Tags),
                                    window,
                                    cx,
                                );
                            });
                        }),
                )
                .item(
                    PopupMenuItem::new(tr("View Stashes"))
                        .icon(Icon::new(IconName::Archive))
                        .on_click(move |_, _, cx| {
                            let _ = owner_stash
                                .update(cx, |this, cx| this.set_commit_tab(CommitTab::Stash, cx));
                        }),
                )
                .separator()
                .item(
                    PopupMenuItem::new(tr("Refresh Status"))
                        .icon(Icon::new(IconName::RotateCw))
                        .on_click(move |_, window, cx| {
                            let _ = owner_refresh.update(cx, |this, cx| {
                                this.refresh_tool(ToolWindow::Changes, window, cx)
                            });
                        }),
                )
                .separator()
                .item(
                    PopupMenuItem::new(tr("Manage Worktrees…"))
                        .icon(Icon::new(IconName::Folder))
                        .on_click(move |_, window, cx| {
                            let _ = owner_dialog_worktrees.update(cx, |this, cx| {
                                this.commit_header_action(
                                    CommitHeaderAction::Dialog(GitDialogKind::Worktrees),
                                    window,
                                    cx,
                                );
                            });
                        }),
                )
                .item(
                    PopupMenuItem::new(tr("Interactive Rebase Session…"))
                        .icon(Icon::new(IconName::GitBranch))
                        .on_click(move |_, window, cx| {
                            let _ = owner_dialog_rebase.update(cx, |this, cx| {
                                this.commit_header_action(
                                    CommitHeaderAction::Dialog(GitDialogKind::Rebase),
                                    window,
                                    cx,
                                );
                            });
                        }),
                )
                .item(
                    PopupMenuItem::new(tr("Create Patch…"))
                        .icon(Icon::new(IconName::Upload))
                        .on_click(move |_, window, cx| {
                            let _ = owner_dialog_patch.update(cx, |this, cx| {
                                this.commit_header_action(
                                    CommitHeaderAction::Dialog(GitDialogKind::CreatePatch),
                                    window,
                                    cx,
                                );
                            });
                        }),
                )
                .item(
                    PopupMenuItem::new(tr("Apply Patch…"))
                        .icon(Icon::new(IconName::Download))
                        .on_click(move |_, window, cx| {
                            let _ = owner_dialog_apply.update(cx, |this, cx| {
                                this.commit_header_action(
                                    CommitHeaderAction::Dialog(GitDialogKind::ApplyPatch),
                                    window,
                                    cx,
                                );
                            });
                        }),
                )
                .separator()
                .item(
                    PopupMenuItem::new(tr("Discard All Changes"))
                        .icon(Icon::new(IconName::RotateCcw))
                        .on_click(move |_, window, cx| {
                            let _ = owner_discard.update(cx, |this, cx| {
                                // 对齐 Tauri handleDiscardAllChanges：Core
                                // `git.write discardAll`，确认受
                                // confirmBeforeDiscard 控制。
                                this.commit_header_action(
                                    CommitHeaderAction::DiscardAll,
                                    window,
                                    cx,
                                );
                            });
                        }),
                )
            }
        })
        .on_open_change(move |open, _window, cx| {
            let _ = actions_owner.update(cx, |this, cx| {
                this.set_menu_open(*open, cx);
            });
        });

    h_flex()
        .id("lithe-commit-header")
        .w_full()
        .flex_shrink_0()
        .h(px(LitheMetrics::TOOL_WINDOW_HEADER_HEIGHT))
        .items_center()
        .justify_between()
        .pl(px(8.0))
        .pr(px(10.0))
        .bg(tokens.tool_header)
        .border_b_1()
        .border_color(tokens.divider)
        .child(tab_bar)
        .child(actions_button)
        .into_any_element()
}

/// 单个分段。选中态用工具窗 tab 的底色与边框，未选中只保留悬停反馈。
fn render_commit_tab(
    id: &'static str,
    label: &'static str,
    selected: bool,
    is_stash: bool,
    tokens: LitheTokens,
    owner: WeakEntity<Workbench>,
) -> AnyElement {
    let mut tab = div()
        .id(id)
        .h(px(COMMIT_TAB_HEIGHT))
        .px(px(COMMIT_TAB_PADDING_X))
        .flex()
        .items_center()
        .rounded(px(COMMIT_TAB_RADIUS))
        .text_size(px(12.5))
        .cursor_pointer();

    tab = if selected {
        tab.bg(tokens.subtle_selection)
            .border_1()
            .border_color(tokens.panel_border)
            .font_weight(FontWeight::MEDIUM)
            .text_color(tokens.primary_text)
    } else {
        tab.text_color(tokens.tertiary_text)
            .hover(|style| style.bg(tokens.hover))
    };

    tab.on_click(move |_, _window, cx| {
        let _ = owner.update(cx, |this, cx| {
            this.set_commit_tab(
                if is_stash {
                    CommitTab::Stash
                } else {
                    CommitTab::Commit
                },
                cx,
            );
        });
    })
    .child(label)
    .into_any_element()
}
