//! 右侧通知工具窗口：对齐 Tauri `notifications-tool-window.tsx` 的展示语义。
//!
//! 可见性由宿主持有（对齐 `right-tool-window-actions.ts` 的 toggle 语义：
//! 同视图再点关闭、面板 X 关闭、隐藏时保活不卸载），本视图不保存可见标志，
//! 因此隐藏后重显不会丢失列表与搜索态。通知源为诊断快照（
//! [`NotificationsView::set_diagnostics`] 全量替换）与手动系统事件
//! （[`NotificationsView::push`] 追加），未读数口径与 Tauri 一致
//! （`success` 类型不计入未读）。

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, AppContext as _, Context, Entity, EventEmitter, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, Render, StatefulInteractiveElement as _, Styled as _, Window,
};

use crate::theme::ThemeColors;

/// 通知面板派发的事件：`Close` 由头部 X 发出，宿主据此隐藏右侧栏（保活）；  
/// `OpenFile` 由诊断类行点击发出，载荷为工作区相对路径与从 1 起的行号。
#[derive(Debug, Clone)]
pub enum NotificationsEvent {
    Close,
    OpenFile(String, u32),
}

/// 通知类型，对齐 Tauri `NotificationEntry["type"]`；`Diagnostic` 为 Linux 侧
/// 由诊断快照投递的定位类通知，点击时额外发出 `OpenFile`。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotificationKind {
    Info,
    Success,
    // `Warning` 暂无生产者（诊断后端接入后由 `set_diagnostics` 按级别构造）。
    #[allow(dead_code)]
    Warning,
    Error,
    Diagnostic,
}

/// 单条通知：诊断类通过 `path` 携带定位信息，非诊断类为 `None`。
#[derive(Debug, Clone)]
pub struct NotificationItem {
    id: u64,
    title: String,
    body: String,
    kind: NotificationKind,
    read: bool,
    path: Option<String>,
    line: u32,
}

/// 右侧通知工具窗口：内部持有通知列表本地态。
pub struct NotificationsView {
    items: Vec<NotificationItem>,
    next_id: u64,
    search: Option<Entity<InputState>>,
}

impl EventEmitter<NotificationsEvent> for NotificationsView {}

impl NotificationsView {
    /// 构造并预置 2 条未读提示，保证面板首次打开非空。
    pub fn new(_cx: &mut Context<Self>) -> Self {
        Self {
            items: vec![
                NotificationItem {
                    id: 0,
                    title: "Welcome to Lithe".to_string(),
                    body: "Notifications from the workspace and language services appear here."
                        .to_string(),
                    kind: NotificationKind::Info,
                    read: false,
                    path: None,
                    line: 1,
                },
                NotificationItem {
                    id: 1,
                    title: "Tip: diagnostics are clickable".to_string(),
                    body: "Click a diagnostic notification to jump to its file location."
                        .to_string(),
                    kind: NotificationKind::Info,
                    read: false,
                    path: None,
                    line: 1,
                },
            ],
            next_id: 2,
            search: None,
        }
    }

    /// 宿主投递手动系统事件：追加一条未读 `Info` 通知。
    pub fn push(
        &mut self,
        title: impl Into<String>,
        body: impl Into<String>,
        cx: &mut Context<Self>,
    ) {
        self.items.push(NotificationItem {
            id: self.next_id,
            title: title.into(),
            body: body.into(),
            kind: NotificationKind::Info,
            read: false,
            path: None,
            line: 1,
        });
        self.next_id += 1;
        cx.notify();
    }

    /// 全量替换诊断类通知（诊断快照语义）：保留非诊断项，诊断项按新快照
    /// 重建为未读；`line` 为从 1 起的行号，与跨平台契约一致。
    ///
    /// 当前尚无诊断生产者（底部 Diagnostics 面板仍为占位），保留给诊断后端
    /// 接入后调用。
    #[allow(dead_code)]
    pub fn set_diagnostics(
        &mut self,
        diagnostics: Vec<(String, u32, String)>,
        cx: &mut Context<Self>,
    ) {
        self.items
            .retain(|item| item.kind != NotificationKind::Diagnostic);
        for (path, line, message) in diagnostics {
            let body = format!("{}:{}", path, line);
            self.items.push(NotificationItem {
                id: self.next_id,
                title: message,
                body,
                kind: NotificationKind::Diagnostic,
                read: false,
                path: Some(path),
                line,
            });
            self.next_id += 1;
        }
        cx.notify();
    }

    /// 未读数：`Success` 类型不计入，与 Tauri 角标口径一致。
    pub fn unread_count(&self) -> usize {
        self.items
            .iter()
            .filter(|item| !item.read && item.kind != NotificationKind::Success)
            .count()
    }

    /// 全部标为已读。
    pub fn mark_all_read(&mut self, cx: &mut Context<Self>) {
        for item in &mut self.items {
            item.read = true;
        }
        cx.notify();
    }

    fn toggle_read(&mut self, id: u64, cx: &mut Context<Self>) {
        if let Some(item) = self.items.iter_mut().find(|item| item.id == id) {
            item.read = !item.read;
        }
        cx.notify();
    }

    /// 懒创建搜索输入框（首次渲染创建，后续渲染复用用户编辑态）。
    fn ensure_search(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Entity<InputState> {
        if let Some(entity) = self.search.clone() {
            return entity;
        }
        let entity = cx.new(|cx| InputState::new(window, cx));
        self.search = Some(entity.clone());
        entity
    }

    fn query(&self, cx: &Context<Self>) -> String {
        self.search
            .as_ref()
            .map(|entity| entity.read(cx).value().to_string())
            .unwrap_or_default()
            .trim()
            .to_lowercase()
    }
}

fn kind_icon(kind: NotificationKind) -> IconName {
    match kind {
        NotificationKind::Info => IconName::Info,
        NotificationKind::Success => IconName::CircleCheck,
        NotificationKind::Warning | NotificationKind::Error | NotificationKind::Diagnostic => {
            IconName::TriangleAlert
        }
    }
}

impl Render for NotificationsView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 快照后构建行，避免在 `.children` 闭包里同时借用 self 与 cx。
        let search_entity = self.ensure_search(window, cx);
        let query = self.query(cx);
        let unread = self.unread_count();
        let items: Vec<NotificationItem> = self
            .items
            .iter()
            .filter(|item| {
                query.is_empty()
                    || item.title.to_lowercase().contains(&query)
                    || item.body.to_lowercase().contains(&query)
            })
            .cloned()
            .collect();
        let is_empty = self.items.is_empty();

        let mut rows = Vec::new();
        for item in &items {
            let id = item.id;
            let path = item.path.clone();
            let line = item.line;
            let is_diagnostic = item.kind == NotificationKind::Diagnostic;
            rows.push(
                v_flex()
                    .id(format!("notification-{id}"))
                    .w_full()
                    .cursor_pointer()
                    .rounded_sm()
                    .px_2()
                    .py_1()
                    .gap_1()
                    .hover(|row| row.bg(ThemeColors::bg_tab_hover()))
                    .when(!item.read, |row| row.bg(ThemeColors::subtle_selection()))
                    .child(
                        h_flex()
                            .w_full()
                            .items_center()
                            .gap_1p5()
                            .child(Icon::new(kind_icon(item.kind)).size(px(14.0)).text_color(
                                if item.kind == NotificationKind::Error || is_diagnostic {
                                    ThemeColors::destructive()
                                } else {
                                    ThemeColors::text_muted()
                                },
                            ))
                            .child(
                                div()
                                    .flex_1()
                                    .truncate()
                                    .text_xs()
                                    .text_color(ThemeColors::text_primary())
                                    .when(!item.read, |title| title.font_weight(FontWeight::BOLD))
                                    .child(item.title.clone()),
                            )
                            .when(!item.read, |row| {
                                row.child(
                                    div()
                                        .w(px(6.0))
                                        .h(px(6.0))
                                        .rounded_full()
                                        .bg(ThemeColors::accent_blue())
                                        .flex_shrink_0(),
                                )
                            }),
                    )
                    .child(
                        div()
                            .w_full()
                            .pl(px(20.0))
                            .truncate()
                            .text_xs()
                            .text_color(ThemeColors::text_muted())
                            .child(item.body.clone()),
                    )
                    .on_click(cx.listener(move |this, _event, _window, cx| {
                        this.toggle_read(id, cx);
                        if is_diagnostic {
                            if let Some(path) = path.clone() {
                                cx.emit(NotificationsEvent::OpenFile(path, line));
                            }
                        }
                    }))
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
                        h_flex()
                            .items_center()
                            .gap_1p5()
                            .child(
                                div()
                                    .text_xs()
                                    .font_weight(FontWeight::BOLD)
                                    .text_color(ThemeColors::text_muted())
                                    .child(crate::i18n::menu_text(cx, "notifications.title")),
                            )
                            .when(unread > 0, |title| {
                                title.child(
                                    div()
                                        .text_xs()
                                        .text_color(ThemeColors::text_muted())
                                        .child(format!("({unread})")),
                                )
                            }),
                    )
                    .child(
                        h_flex()
                            .items_center()
                            .gap_1()
                            .when(unread > 0, |actions| {
                                actions.child(
                                    Button::new("notifications-mark-read")
                                        .small()
                                        .ghost()
                                        .label("Mark all read")
                                        .on_click(cx.listener(|this, _event, _window, cx| {
                                            this.mark_all_read(cx);
                                        })),
                                )
                            })
                            .child(
                                Button::new("notifications-close")
                                    .small()
                                    .ghost()
                                    .icon(IconName::Close)
                                    .tooltip(crate::i18n::menu_text(cx, "ui.close"))
                                    .on_click(cx.listener(|_this, _event, _window, cx| {
                                        cx.emit(NotificationsEvent::Close);
                                    })),
                            ),
                    ),
            )
            .child(
                h_flex()
                    .w_full()
                    .items_center()
                    .gap_1p5()
                    .px_2()
                    .py_2()
                    .child(
                        Icon::new(IconName::Search)
                            .size(px(13.0))
                            .text_color(ThemeColors::text_muted()),
                    )
                    .child(
                        div()
                            .flex_1()
                            .child(Input::new(&search_entity).cleanable(true)),
                    ),
            )
            .child(if is_empty {
                div()
                    .flex_1()
                    .w_full()
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_xs()
                    .text_color(ThemeColors::text_muted())
                    .child("No notifications")
                    .into_any_element()
            } else if items.is_empty() {
                div()
                    .flex_1()
                    .w_full()
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_xs()
                    .text_color(ThemeColors::text_muted())
                    .child("No matching notifications")
                    .into_any_element()
            } else {
                div()
                    .flex_1()
                    .w_full()
                    .overflow_y_scrollbar()
                    .px_2()
                    .py_1()
                    .children(rows)
                    .into_any_element()
            })
    }
}
