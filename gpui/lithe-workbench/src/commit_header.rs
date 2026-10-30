//! 提交工具窗标题栏（对齐 Tauri `git-view.tsx` 的 `SidebarTitleBar`）。
//!
//! Tauri 的提交工具窗标题栏只有两件事：
//! - 左侧「提交 / Stash」分段（`git-commit-tab`，选中态带独立底色与边框）；
//! - 右侧一个 `MoreHorizontal` 操作按钮，点开 Git 操作菜单。
//!
//! 刷新按钮属于变更区工具栏（`GitStatusPanel` 的 `toolbarLeading`），不在这里
//! 重复一份；收起按钮由工具窗容器统一提供。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu, PopupMenuItem};
use gpui_kit::component::{h_flex, Sizable as _};
use gpui_kit::{
    AnyElement, Context, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    StatefulInteractiveElement as _, Styled as _, WeakEntity, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, icon};

use crate::workbench::{CommitHeaderAction, Workbench};

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
            "Stash",
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
        .dropdown_menu({
            let owner = actions_owner.clone();
            move |menu, _, _| {
                let stage_owner = owner.clone();
                let unstage_owner = owner.clone();
                let discard_owner = owner.clone();
                menu.item(
                    PopupMenuItem::new(tr("Stage all changes")).on_click(move |_, _, cx| {
                        let _ = stage_owner.update(cx, |this, cx| {
                            this.commit_header_action(CommitHeaderAction::StageAll, cx);
                        });
                    }),
                )
                .item(
                    PopupMenuItem::new(tr("Unstage all changes")).on_click(move |_, _, cx| {
                        let _ = unstage_owner.update(cx, |this, cx| {
                            this.commit_header_action(CommitHeaderAction::UnstageAll, cx);
                        });
                    }),
                )
                .separator()
                .item(
                    PopupMenuItem::new(tr("Discard selected changes")).on_click(move |_, _, cx| {
                        let _ = discard_owner.update(cx, |this, cx| {
                            this.commit_header_action(CommitHeaderAction::DiscardSelected, cx);
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
