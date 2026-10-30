//! 顶部应用菜单栏（三端自绘，同一套渲染路径）。
//!
//! 视觉以 macOS 原型为准：13pt 标签、22pt 触发器、圆角浮层、左对齐勾选位、
//! 右对齐 ⌘ 快捷键。行为复用 `gpui-kit` 的 [`PopupMenu`]（定位、子菜单、
//! 键盘上下选择、Esc/点击外部关闭、长菜单滚动），本模块只负责 Lithe 的皮与
//! 触发器之间的切换。
//!
//! 三端共用：这里没有任何 `cfg(target_os)` 分支，也没有系统原生菜单路径。

use gpui_kit::component::InteractiveElementExt as _;
use gpui_kit::component::h_flex;
use gpui_kit::component::menu::{PopupMenu, PopupMenuItem};
use gpui_kit::component::scroll::ScrollableMask;
use gpui_kit::{
    Anchor, App, Context, DismissEvent, Entity, EventEmitter, FocusHandle, Focusable as _,
    InteractiveElement as _, IntoElement, MouseButton, ParentElement as _, Render, Role,
    ScrollHandle, SharedString, StatefulInteractiveElement as _, Styled as _, Subscription, Window,
    anchored, deferred, div, prelude::FluentBuilder as _, px,
};

use crate::{LitheMetrics, MONO_FONT_FAMILY, current_tokens};

/// 菜单栏派发的统一动作。
///
/// 菜单条目数量多、id 是稳定字符串，因此不为每个条目定义 unit Action；
/// 工作台注册一个处理器读取 `MenuCommand.0` 再路由到具体能力。
#[derive(Clone, Debug, PartialEq, gpui_kit::Action)]
#[action(namespace = lithe_ui_menu, no_json)]
pub struct MenuCommand(pub SharedString);

impl MenuCommand {
    pub fn new(id: impl Into<SharedString>) -> Self {
        Self(id.into())
    }
}

/// 菜单栏展开状态变化。工作台据此隐藏/恢复原生 WebView。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MenuBarEvent {
    OpenChanged(bool),
}

impl EventEmitter<MenuBarEvent> for LitheMenuBar {}

/// 一个顶级菜单的声明式描述。
#[derive(Clone, Debug, PartialEq)]
pub struct MenuSpec {
    pub label: SharedString,
    pub items: Vec<MenuItemSpec>,
}

impl MenuSpec {
    pub fn new(label: impl Into<SharedString>) -> Self {
        Self {
            label: label.into(),
            items: Vec::new(),
        }
    }

    pub fn items(mut self, items: impl IntoIterator<Item = MenuItemSpec>) -> Self {
        self.items = items.into_iter().collect();
        self
    }
}

/// 菜单条目：动作、分隔线或子菜单。
#[derive(Clone, Debug, PartialEq)]
pub enum MenuItemSpec {
    Action {
        label: SharedString,
        /// 派发给工作台的稳定命令 id。
        command: SharedString,
        /// 已格式化的 macOS 快捷键文案，例如 `⌘S`、`⇧⌘P`。
        shortcut: Option<SharedString>,
        checked: bool,
        disabled: bool,
    },
    Separator,
    Submenu {
        label: SharedString,
        items: Vec<MenuItemSpec>,
    },
}

impl MenuItemSpec {
    pub fn action(label: impl Into<SharedString>, command: impl Into<SharedString>) -> Self {
        Self::Action {
            label: label.into(),
            command: command.into(),
            shortcut: None,
            checked: false,
            disabled: false,
        }
    }

    pub fn shortcut(mut self, shortcut: impl Into<SharedString>) -> Self {
        if let Self::Action {
            shortcut: current, ..
        } = &mut self
        {
            *current = Some(shortcut.into());
        }
        self
    }

    pub fn checked(mut self, checked: bool) -> Self {
        if let Self::Action {
            checked: current, ..
        } = &mut self
        {
            *current = checked;
        }
        self
    }

    pub fn disabled(mut self, disabled: bool) -> Self {
        if let Self::Action {
            disabled: current, ..
        } = &mut self
        {
            *current = disabled;
        }
        self
    }

    pub fn submenu(
        label: impl Into<SharedString>,
        items: impl IntoIterator<Item = MenuItemSpec>,
    ) -> Self {
        Self::Submenu {
            label: label.into(),
            items: items.into_iter().collect(),
        }
    }

    pub fn separator() -> Self {
        Self::Separator
    }
}

/// 自绘菜单栏状态。
pub struct LitheMenuBar {
    menus: Vec<MenuSpec>,
    /// 当前展开的顶级菜单下标；`None` 表示全部收起。
    open: Option<usize>,
    /// 展开时捕获的动作上下文，用于把 `MenuCommand` 派发回工作台。
    action_context: Option<FocusHandle>,
    /// 展开中的下拉菜单；下标变化时重建。
    popup: Option<(usize, Entity<PopupMenu>)>,
    /// 窄窗口下菜单行可横向滚动。
    scroll_handle: ScrollHandle,
    /// 上一次展开的顶级菜单；用于区分“点击收起”与“点击切换”。
    last_open: Option<usize>,
    /// 本帧是否刚刚收到下拉菜单的关闭事件。
    just_dismissed: bool,
    /// 上一次向工作台上报的展开状态。只在真正变化时发事件，避免每次悬停
    /// 都让工作台重绘。
    reported_open: bool,
    _dismiss: Option<Subscription>,
}

impl LitheMenuBar {
    pub fn new(menus: Vec<MenuSpec>) -> Self {
        Self {
            menus: menus.into_iter().map(sanitize_menu).collect(),
            open: None,
            action_context: None,
            popup: None,
            scroll_handle: ScrollHandle::new(),
            last_open: None,
            just_dismissed: false,
            reported_open: false,
            _dismiss: None,
        }
    }

    /// 把当前展开状态同步给工作台。
    ///
    /// 原生 WebView 是覆盖在 GPUI 之上的子视图，菜单浮层挡不住它，所以菜单
    /// 一展开工作台就要隐藏 WebView。这里只做“变化才上报”，且只在用户交互
    /// 路径调用，不在 `render` 里发事件。
    fn report_open_state(&mut self, cx: &mut Context<Self>) {
        let is_open = self.open.is_some();
        if self.reported_open != is_open {
            self.reported_open = is_open;
            cx.emit(MenuBarEvent::OpenChanged(is_open));
        }
    }

    /// 替换菜单树；展开中的菜单会被收起。
    pub fn set_menus(&mut self, menus: Vec<MenuSpec>, cx: &mut Context<Self>) {
        self.menus = menus.into_iter().map(sanitize_menu).collect();
        self.open = None;
        self.action_context = None;
        self.popup = None;
        self.last_open = None;
        self.just_dismissed = false;
        self._dismiss = None;
        self.report_open_state(cx);
        cx.notify();
    }

    fn is_open(&self, ix: usize) -> bool {
        self.open == Some(ix)
    }

    fn close(&mut self, cx: &mut Context<Self>) {
        self.open = None;
        self.action_context = None;
        self.popup = None;
        self._dismiss = None;
        self.report_open_state(cx);
        cx.notify();
    }

    fn toggle(&mut self, ix: usize, window: &mut Window, cx: &mut Context<Self>) {
        // 展开状态下点菜单栏会先触发下拉菜单的“外部点击关闭”，这里要区分
        // “点同一个菜单 = 收起”和“点另一个菜单 = 直接切换”。
        if self.just_dismissed {
            self.just_dismissed = false;
            if self.last_open == Some(ix) {
                self.last_open = None;
                return;
            }
        }

        if self.is_open(ix) {
            self.last_open = None;
            self.close(cx);
            return;
        }

        self.open = Some(ix);
        self.last_open = Some(ix);
        self.action_context = window.focused(cx);
        self.popup = None;
        self._dismiss = None;
        self.report_open_state(cx);
        cx.notify();
    }

    /// 展开菜单栏并立即打开第一个顶级菜单。
    ///
    /// 紧凑菜单栏（Tauri 的汉堡模式）在点击汉堡后直接显示“File”菜单，这条
    /// 路径与逐项点击触发器等价，只是省掉了一次点击。
    pub fn open_first(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.menus.is_empty() {
            return;
        }
        self.open = Some(0);
        self.last_open = Some(0);
        self.action_context = window.focused(cx);
        self.popup = None;
        self._dismiss = None;
        self.report_open_state(cx);
        cx.notify();
    }

    /// 关闭当前展开的菜单（含上报状态）。
    ///
    /// 菜单栏被整条隐藏时，下拉浮层不会收到 `DismissEvent`，必须由调用方
    /// 显式收起，否则工作台会一直以为菜单还开着、把 WebView 藏住。
    pub fn close_menus(&mut self, cx: &mut Context<Self>) {
        if self.open.is_some() {
            self.close(cx);
        }
    }

    /// 已经展开某个菜单时，悬停其它顶级菜单直接切换。
    fn hover(&mut self, ix: usize, hovered: &bool, cx: &mut Context<Self>) {
        if !*hovered || self.open.is_none() || self.is_open(ix) {
            return;
        }

        self.open = Some(ix);
        self.last_open = Some(ix);
        self.popup = None;
        self._dismiss = None;
        self.report_open_state(cx);
        cx.notify();
    }

    fn build_popup(&mut self, ix: usize, window: &mut Window, cx: &mut Context<Self>) {
        if self.popup.as_ref().is_some_and(|(open, _)| *open == ix) {
            return;
        }

        let Some(spec) = self.menus.get(ix).cloned() else {
            return;
        };

        let action_context = self.action_context.clone();
        let max_height = (window.window_bounds().get_bounds().size.height * 0.75)
            .min(px(LitheMetrics::MENU_POPUP_MAX_HEIGHT))
            .max(px(240.));
        let popup = PopupMenu::build(window, cx, move |menu, window, cx| {
            let menu = match action_context {
                Some(handle) => menu.action_context(handle),
                None => menu,
            };
            build_menu(menu, &spec.items, window, cx)
                .min_w(px(LitheMetrics::MENU_POPUP_MIN_WIDTH))
                .max_h(max_height)
                .scrollable(true)
        });

        self._dismiss =
            Some(
                cx.subscribe_in(&popup, window, |this, _, _: &DismissEvent, window, cx| {
                    this.just_dismissed = true;
                    this.close(cx);
                    // 本帧结束再清标记：同一帧内菜单栏触发器的按下事件仍能看到它。
                    cx.defer_in(window, |this, _window, cx| {
                        if this.just_dismissed {
                            this.just_dismissed = false;
                            cx.notify();
                        }
                    });
                }),
            );

        // 下拉菜单自己接管键盘：上下选择、回车执行、Esc 关闭。
        let focus_handle = popup.read(cx).focus_handle(cx);
        if !focus_handle.contains_focused(window, cx) {
            focus_handle.focus(window, cx);
        }

        self.popup = Some((ix, popup));
    }

    fn render_trigger(
        &mut self,
        ix: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let spec = self.menus[ix].clone();
        let is_open = self.is_open(ix);
        let tokens = current_tokens(cx);

        if is_open {
            self.build_popup(ix, window, cx);
        }

        let popup = if is_open {
            self.popup.as_ref().map(|(_, popup)| popup.clone())
        } else {
            None
        };

        div()
            .id(("lithe-menu-trigger", ix))
            .relative()
            .child(
                div()
                    .id(("lithe-menu-trigger-button", ix))
                    .occlude()
                    .role(Role::Button)
                    .aria_label(spec.label.clone())
                    .flex()
                    .flex_row()
                    .items_center()
                    .h(px(LitheMetrics::MENU_BAR_ITEM_HEIGHT))
                    .px(px(LitheMetrics::MENU_BAR_ITEM_PADDING_X))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .text_size(px(LitheMetrics::MENU_BAR_FONT_SIZE))
                    .text_color(tokens.primary_text)
                    .when(is_open, |this| this.bg(tokens.subtle_selection))
                    .hover(|this| this.bg(tokens.hover))
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(move |this, _, window, cx| {
                            // 菜单栏位于标题栏区域，按下时不要让窗口开始拖动。
                            window.prevent_default();
                            cx.stop_propagation();
                            this.toggle(ix, window, cx);
                        }),
                    )
                    .child(spec.label.clone()),
            )
            .on_hover(cx.listener(move |this, hovered, _, cx| this.hover(ix, hovered, cx)))
            .when_some(popup, |this, popup| {
                this.child(deferred(
                    anchored()
                        .anchor(Anchor::TopLeft)
                        .snap_to_window_with_margin(px(8.))
                        .child(div().mt(px(2.)).child(popup)),
                ))
            })
            .into_any_element()
    }
}

impl Render for LitheMenuBar {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let triggers = (0..self.menus.len())
            .map(|ix| self.render_trigger(ix, window, cx))
            .collect::<Vec<_>>();

        h_flex()
            .id("lithe-menu-bar")
            .role(Role::MenuBar)
            .flex_row()
            .items_center()
            .h_full()
            .gap(px(LitheMetrics::MENU_BAR_ITEM_GAP))
            .overflow_x_scroll()
            .lock_scroll_axis()
            .track_scroll(&self.scroll_handle)
            .children(triggers)
            .child(ScrollableMask::vertical_wheel(&self.scroll_handle))
    }
}

/// 把声明式条目树翻译成 gpui-kit 的 `PopupMenu` 条目。
///
/// 带快捷键的动作使用自定义行，保证三端都显示 macOS 的 ⌘ 文案；
/// 其余动作仍走 `PopupMenu` 的标准行，勾选/禁用/悬停样式与子菜单行保持一致。
fn build_menu(
    mut menu: PopupMenu,
    items: &[MenuItemSpec],
    window: &mut Window,
    cx: &mut App,
) -> PopupMenu {
    for item in items {
        match item {
            MenuItemSpec::Action {
                label,
                command,
                shortcut,
                checked,
                disabled,
            } => {
                let action = Box::new(MenuCommand::new(command.clone()));

                menu = if shortcut.is_some() {
                    let label = label.clone();
                    let shortcut = shortcut.clone();
                    let row = move |_: &mut Window, _: &mut App| {
                        menu_row(label.clone(), shortcut.clone())
                    };

                    // gpui-kit 没有公开“自定义行 + 勾选 + 禁用”的组合，禁用态
                    // 优先保证灰色和不可点击；勾选项在可用时仍走库里的勾选列。
                    if *disabled {
                        menu.menu_element_with_disabled(action, true, row)
                    } else {
                        menu.menu_element_with_check(*checked, action, row)
                    }
                } else {
                    menu.menu_with_check_and_disabled(label.clone(), *checked, action, *disabled)
                };
            }
            MenuItemSpec::Separator => {
                menu = menu.separator();
            }
            MenuItemSpec::Submenu { label, items } => {
                let submenu = PopupMenu::build(window, cx, |menu, window, cx| {
                    build_menu(menu, items, window, cx)
                        .min_w(px(LitheMetrics::MENU_POPUP_MIN_WIDTH))
                        .max_h(px(LitheMetrics::MENU_POPUP_MAX_HEIGHT))
                        .scrollable(true)
                });
                menu = menu.item(PopupMenuItem::submenu(label.clone(), submenu));
            }
        }
    }

    menu
}

/// 菜单行：左标签 + 右对齐快捷键。
fn menu_row(label: SharedString, shortcut: Option<SharedString>) -> impl IntoElement {
    h_flex()
        .w_full()
        .items_center()
        .justify_between()
        .gap(px(24.))
        .child(div().min_w_0().truncate().child(label))
        .when_some(shortcut, |this, shortcut| {
            this.child(
                div()
                    .flex_shrink_0()
                    // Tauri 的快捷键列用等宽字体，右对齐到菜单行末尾。
                    .font_family(MONO_FONT_FAMILY)
                    .text_size(px(LitheMetrics::MENU_SHORTCUT_FONT_SIZE))
                    .child(shortcut),
            )
        })
}

/// 菜单树清洗：去掉空子菜单、连续分隔线与首尾分隔线。
///
/// gpui-kit 的 `PopupMenu` 只隐藏最后一个分隔线，连续分隔线仍会画出来；
/// 动态菜单（最近项目、工具窗）在空状态下也容易产生空子菜单，统一在这里收口。
fn sanitize_menu(menu: MenuSpec) -> MenuSpec {
    MenuSpec {
        label: menu.label,
        items: sanitize_items(&menu.items),
    }
}

fn sanitize_items(items: &[MenuItemSpec]) -> Vec<MenuItemSpec> {
    let mut cleaned: Vec<MenuItemSpec> = Vec::with_capacity(items.len());

    for item in items {
        match item {
            MenuItemSpec::Separator => {
                if cleaned.is_empty() || matches!(cleaned.last(), Some(MenuItemSpec::Separator)) {
                    continue;
                }
                cleaned.push(MenuItemSpec::Separator);
            }
            MenuItemSpec::Submenu { label, items } => {
                let items = sanitize_items(items);
                if items.is_empty() {
                    continue;
                }
                cleaned.push(MenuItemSpec::Submenu {
                    label: label.clone(),
                    items,
                });
            }
            item => cleaned.push(item.clone()),
        }
    }

    if matches!(cleaned.last(), Some(MenuItemSpec::Separator)) {
        cleaned.pop();
    }

    cleaned
}

#[cfg(test)]
mod tests {
    use super::*;

    fn action(label: &str) -> MenuItemSpec {
        MenuItemSpec::action(label, label.to_ascii_lowercase())
    }

    #[test]
    fn sanitize_collapses_consecutive_separators() {
        let items = vec![
            action("a"),
            MenuItemSpec::separator(),
            MenuItemSpec::separator(),
            action("b"),
        ];

        let cleaned = sanitize_items(&items);
        assert_eq!(cleaned.len(), 3);
        assert!(matches!(cleaned[1], MenuItemSpec::Separator));
    }

    #[test]
    fn sanitize_drops_leading_and_trailing_separators() {
        let items = vec![
            MenuItemSpec::separator(),
            action("a"),
            MenuItemSpec::separator(),
        ];

        let cleaned = sanitize_items(&items);
        assert_eq!(cleaned, vec![action("a")]);
    }

    #[test]
    fn sanitize_drops_empty_submenus() {
        let items = vec![
            action("a"),
            MenuItemSpec::submenu("empty", Vec::new()),
            MenuItemSpec::submenu("only-separators", vec![MenuItemSpec::separator()]),
        ];

        let cleaned = sanitize_items(&items);
        assert_eq!(cleaned, vec![action("a")]);
    }

    #[test]
    fn sanitize_keeps_non_empty_submenu() {
        let items = vec![MenuItemSpec::submenu("sub", vec![action("a")])];

        let cleaned = sanitize_items(&items);
        assert!(matches!(cleaned.as_slice(), [MenuItemSpec::Submenu { .. }]));
    }
}
