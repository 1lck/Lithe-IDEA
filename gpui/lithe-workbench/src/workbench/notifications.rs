//! 右侧通知中心（对齐 Tauri `features/notifications` 的 store 与工具窗）。
//!
//! 数据层与 Tauri `notifications.store.ts` 一致：
//! - 行内容（类型 + 消息 + 详情）是合并键，相同内容只增加出现次数并置顶；
//! - 最新在前，最多保留 [`MAX_NOTIFICATIONS`]（Tauri 同为 20）条；
//! - 打开面板即全部已读，右侧活动栏徽标只统计非 success 的未读。
//!
//! 界面层与 Tauri `NotificationsToolWindow` 一致：
//! 搜索框、类型筛选、日期分组（可折叠 + 计数）、行级右键菜单、
//! 面板右键菜单与详情视图。

use std::time::{SystemTime, UNIX_EPOCH};

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::Input;
use gpui_kit::component::menu::{ContextMenuExt as _, DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::{Icon, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    ClipboardItem, Context, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    RenderOnce as _, SharedString, StatefulInteractiveElement as _, Styled as _, WeakEntity,
    Window, div, px, relative,
};
use lithe_ui::components::tool_window_header::ToolWindowHeader;
use lithe_ui::i18n::{language, tr};
use lithe_ui::{LitheMetrics, LitheTokens, current_tokens};

use super::{OVERLAY_CONTEXT, Workbench};

/// 通知中心保留的最大条数（对齐 Tauri `MAX_NOTIFICATIONS = 20`）。
pub(super) const MAX_NOTIFICATIONS: usize = 20;

/// Toast 自动消失时长（sonner 默认 4000ms，Tauri 未覆盖）。
const TOAST_DURATION_MS: u64 = 4_000;
/// 同时可见的最大 toast 数（sonner `visibleToasts` 默认 3）。
const MAX_VISIBLE_TOASTS: usize = 3;
/// Toast 卡片宽度（sonner 默认 360px）。
const TOAST_WIDTH: f32 = 360.0;

/// 右下角实时弹出的 toast（对齐 Tauri sonner 的一条可见 toast）。
///
/// 只承载呈现，不做留存：进通知中心的数据在 `push_notification` 里已合并。
#[derive(Clone, Debug)]
pub(super) struct ToastEntry {
    message: SharedString,
    description: Option<SharedString>,
    kind: NotificationKind,
    shown_at: u64,
}

impl ToastEntry {
    fn matches(&self, kind: NotificationKind, message: &str, description: Option<&str>) -> bool {
        self.kind == kind && self.message == message && self.description.as_deref() == description
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum NotificationKind {
    /// 普通信息。
    Info,
    Success,
    Warning,
    Error,
}

impl NotificationKind {
    /// Tauri 类型字符串（搜索匹配与复制文本使用，保持小写英文原文）。
    fn type_key(self) -> &'static str {
        match self {
            Self::Info => "info",
            Self::Success => "success",
            Self::Warning => "warning",
            Self::Error => "error",
        }
    }

    /// 展示用分类名，与筛选菜单共用词条。
    fn label(self) -> &'static str {
        match self {
            Self::Info => tr("Info"),
            Self::Success => tr("Success"),
            Self::Warning => tr("Warnings"),
            Self::Error => tr("Errors"),
        }
    }

    fn icon(self) -> IconName {
        match self {
            Self::Info => IconName::Info,
            Self::Success => IconName::Check,
            Self::Warning => IconName::CircleAlert,
            Self::Error => IconName::CircleX,
        }
    }

    /// Toast 图标（对齐 Tauri sonner icons 配置：warning 与 error 共用
    /// AlertTriangle，success 用 CheckCircle，info 用 Info）。
    fn toast_icon(self) -> IconName {
        match self {
            Self::Success => IconName::CircleCheck,
            Self::Warning | Self::Error => IconName::TriangleAlert,
            Self::Info => IconName::Info,
        }
    }

    fn color(self, tokens: LitheTokens) -> gpui_kit::Hsla {
        match self {
            Self::Info => tokens.accent,
            Self::Success => tokens.success,
            Self::Warning => tokens.warning,
            Self::Error => tokens.error,
        }
    }
}

/// 类型筛选（对齐 Tauri `NotificationFilter`）。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum NotificationFilter {
    #[default]
    All,
    Info,
    Success,
    Warning,
    Error,
}

impl NotificationFilter {
    fn matches(self, kind: NotificationKind) -> bool {
        match self {
            Self::All => true,
            Self::Info => kind == NotificationKind::Info,
            Self::Success => kind == NotificationKind::Success,
            Self::Warning => kind == NotificationKind::Warning,
            Self::Error => kind == NotificationKind::Error,
        }
    }

    fn kind(self) -> Option<NotificationKind> {
        match self {
            Self::All => None,
            Self::Info => Some(NotificationKind::Info),
            Self::Success => Some(NotificationKind::Success),
            Self::Warning => Some(NotificationKind::Warning),
            Self::Error => Some(NotificationKind::Error),
        }
    }
}

/// 通知中心的一条记录（对齐 Tauri `NotificationEntry`）。
///
/// 行内容是身份：同内容重复上报只增加 `count`；合并时保留首现行号。
#[derive(Clone, Debug)]
pub(crate) struct NotificationEntry {
    pub(super) id: u64,
    pub(super) message: SharedString,
    pub(super) description: Option<SharedString>,
    pub(super) kind: NotificationKind,
    /// 首次上报时间；对齐 Tauri 模型保留，分组展示用 updated_at。
    #[allow(dead_code)]
    pub(super) created_at: u64,
    pub(super) updated_at: u64,
    pub(super) read: bool,
    /// 同一内容累计出现的次数，首报为 1。
    pub(super) count: usize,
}

impl Workbench {
    pub(super) fn next_notification_timestamp() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_millis() as u64)
            .unwrap_or_default()
    }

    /// 记录一条通知（对齐 Tauri `record`）：内容相同则合并并置顶。
    pub(crate) fn push_notification(
        &mut self,
        message: &'static str,
        description: Option<SharedString>,
        kind: NotificationKind,
    ) {
        let now = Self::next_notification_timestamp();
        let message = SharedString::from(message);

        // 内容（类型 + 消息 + 详情）是合并键；重复上报抬升计数而不是新增行。
        let existing = self.notifications.iter_mut().position(|entry| {
            entry.kind == kind
                && entry.message == message
                && entry.description.as_deref() == description.as_deref()
        });
        match existing {
            Some(index) => {
                let mut entry = self.notifications.remove(index);
                entry.count += 1;
                entry.updated_at = now;
                entry.read = false;
                self.notifications.insert(0, entry);
            }
            None => {
                self.notifications.insert(
                    0,
                    NotificationEntry {
                        id: self.next_notification_id,
                        message: message.clone(),
                        description: description.clone(),
                        kind,
                        created_at: now,
                        updated_at: now,
                        read: false,
                        count: 1,
                    },
                );
                self.next_notification_id = self.next_notification_id.wrapping_add(1);
                if self.notifications.len() > MAX_NOTIFICATIONS {
                    self.notifications.truncate(MAX_NOTIFICATIONS);
                }
            }
        }

        // 每条通知同时以 toast 形式在右下角实时弹出（对齐 Tauri 的 sonner
        // Toaster + NotificationRecorder 链路：toast 是实时反馈，通知中心是留存）。
        self.show_toast(message.clone(), description.clone(), kind, now);
    }

    pub(super) fn close_notifications(&mut self, cx: &mut Context<Self>) {
        self.notifications_visible = false;
        self.active_notification = None;
        cx.notify();
    }

    pub(super) fn clear_notifications(&mut self, cx: &mut Context<Self>) {
        self.notifications.clear();
        self.active_notification = None;
        cx.notify();
    }

    /// 弹出一条 toast（对齐 sonner：同内容刷新现有卡片，超过 3 条丢弃最旧）。
    fn show_toast(
        &mut self,
        message: SharedString,
        description: Option<SharedString>,
        kind: NotificationKind,
        now: u64,
    ) {
        if let Some(existing) = self
            .toasts
            .iter_mut()
            .find(|toast| toast.matches(kind, &message, description.as_deref()))
        {
            existing.shown_at = now;
            return;
        }
        self.toasts.insert(
            0,
            ToastEntry {
                message,
                description,
                kind,
                shown_at: now,
            },
        );
        if self.toasts.len() > MAX_VISIBLE_TOASTS {
            self.toasts.truncate(MAX_VISIBLE_TOASTS);
        }
    }

    /// 清理已过期的 toast；有变化时触发重绘。
    pub(super) fn prune_expired_toasts(&mut self, cx: &mut Context<Self>) {
        let now = Self::next_notification_timestamp();
        let before = self.toasts.len();
        self.toasts
            .retain(|toast| now.saturating_sub(toast.shown_at) < TOAST_DURATION_MS);
        if self.toasts.len() != before {
            cx.notify();
        }
    }

    /// 距离最近一个 toast 过期还剩多少毫秒。
    pub(super) fn next_toast_expiry_in(&self) -> Option<u64> {
        let now = Self::next_notification_timestamp();
        self.toasts
            .iter()
            .map(|toast| TOAST_DURATION_MS.saturating_sub(now.saturating_sub(toast.shown_at)))
            .min()
    }

    /// 手动关闭一条 toast（右下角卡片的关闭按钮）。
    fn dismiss_toast(
        &mut self,
        kind: NotificationKind,
        message: SharedString,
        description: Option<SharedString>,
        cx: &mut Context<Self>,
    ) {
        self.toasts
            .retain(|toast| !toast.matches(kind, &message, description.as_deref()));
        cx.notify();
    }

    /// 非成功类未读数；对齐 Tauri 触发按钮的徽标口径。
    pub(super) fn notification_unread_count(&self) -> usize {
        self.notifications
            .iter()
            .filter(|entry| !entry.read && entry.kind != NotificationKind::Success)
            .count()
    }

    pub(super) fn remove_notification(&mut self, id: u64, cx: &mut Context<Self>) {
        self.notifications.retain(|entry| entry.id != id);
        if self.active_notification == Some(id) {
            self.active_notification = None;
        }
        cx.notify();
    }

    pub(super) fn set_notification_filter(
        &mut self,
        filter: NotificationFilter,
        cx: &mut Context<Self>,
    ) {
        if self.notification_filter != filter {
            self.notification_filter = filter;
            cx.notify();
        }
    }

    pub(super) fn toggle_notification_group(&mut self, label: String, cx: &mut Context<Self>) {
        if let Some(index) = self
            .notification_collapsed_groups
            .iter()
            .position(|item| item == &label)
        {
            self.notification_collapsed_groups.remove(index);
        } else {
            self.notification_collapsed_groups.push(label);
        }
        cx.notify();
    }

    pub(super) fn open_notification_details(&mut self, id: u64, cx: &mut Context<Self>) {
        self.active_notification = Some(id);
        cx.notify();
    }

    pub(super) fn close_notification_details(&mut self, cx: &mut Context<Self>) {
        self.active_notification = None;
        cx.notify();
    }

    fn notification_entry(&self, id: u64) -> Option<&NotificationEntry> {
        self.notifications.iter().find(|entry| entry.id == id)
    }

    /// 复制单条通知的消息（含出现次数后缀）。
    pub(super) fn copy_notification_message(&mut self, id: u64, cx: &mut Context<Self>) {
        let Some(entry) = self.notification_entry(id) else {
            return;
        };
        let text = format_occurrence(&entry.message, entry.count);
        self.copy_text(text, Some(id), cx);
    }

    /// 复制单条通知的详情正文。
    pub(super) fn copy_notification_details(&mut self, id: u64, cx: &mut Context<Self>) {
        let Some(entry) = self.notification_entry(id) else {
            return;
        };
        let Some(description) = entry.description.clone() else {
            return;
        };
        self.copy_text(description.to_string(), Some(id), cx);
    }

    /// 复制单条通知的完整文本（消息 + 详情 + 类型与时间）。
    pub(super) fn copy_notification_text(&mut self, id: u64, cx: &mut Context<Self>) {
        let Some(entry) = self.notification_entry(id) else {
            return;
        };
        self.copy_text(format_notification_text(entry), Some(id), cx);
    }

    /// 复制全部通知（对齐 Tauri `copyAll`，条目间以 `\n\n---\n\n` 分隔）。
    pub(super) fn copy_all_notifications(&mut self, cx: &mut Context<Self>) {
        if self.notifications.is_empty() {
            return;
        }
        let text = self
            .notifications
            .iter()
            .map(format_notification_text)
            .collect::<Vec<_>>()
            .join("\n\n---\n\n");
        self.copy_text(text, None, cx);
    }

    fn copy_text(&mut self, text: String, copied_id: Option<u64>, cx: &mut Context<Self>) {
        cx.write_to_clipboard(ClipboardItem::new_string(text));
        self.copied_notification = copied_id;
        // 「已复制」提示 1 秒后还原（对齐 Tauri 的 1000ms setTimeout）。
        self._notification_copied_task = cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(std::time::Duration::from_secs(1))
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.copied_notification.take().is_some() {
                    cx.notify();
                }
            });
        });
        cx.notify();
    }

    /// 按筛选与搜索词过滤后的通知，最新在前（与存储顺序一致）。
    fn filtered_notifications(&self) -> Vec<&NotificationEntry> {
        let query = self.notification_search.trim().to_lowercase();
        let now = Self::next_notification_timestamp();
        self.notifications
            .iter()
            .filter(|entry| self.notification_filter.matches(entry.kind))
            .filter(|entry| {
                if query.is_empty() {
                    return true;
                }
                [
                    Some(entry.message.as_ref()),
                    entry.description.as_deref(),
                    Some(entry.kind.type_key()),
                    Some(format_notification_age(entry.updated_at, now).as_str()),
                ]
                .into_iter()
                .flatten()
                .any(|value| value.to_lowercase().contains(&query))
            })
            .collect()
    }

    /// 把过滤结果按日期分组标签切成连续分组（Tauri `groupedNotifications`）。
    fn notification_groups(&self) -> Vec<(String, Vec<&NotificationEntry>)> {
        let now = Self::next_notification_timestamp();
        let mut groups: Vec<(String, Vec<&NotificationEntry>)> = Vec::new();
        for entry in self.filtered_notifications() {
            let label = format_notification_group_label(entry.updated_at, now);
            match groups.last_mut() {
                Some((last_label, entries)) if *last_label == label => entries.push(entry),
                _ => groups.push((label, vec![entry])),
            }
        }
        groups
    }

    /// 右侧通知面板，对齐 Tauri `NotificationsToolWindow`。
    pub(super) fn render_notifications_panel(
        &self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        match self
            .active_notification
            .and_then(|id| self.notification_entry(id))
        {
            Some(_) => self.render_notification_details(window, cx),
            None => self.render_notification_list(window, cx),
        }
    }

    fn render_notification_list(
        &self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let tokens = current_tokens(cx);
        let owner = cx.weak_entity();
        let filter_owner = owner.clone();
        let menu_open_owner = owner.clone();
        let collapse_owner = cx.weak_entity();
        let now = Self::next_notification_timestamp();
        let groups = self.notification_groups();
        let has_entries = !self.notifications.is_empty();

        // 过滤下拉（对齐 Tauri filter 菜单：选中项带勾选标记）。
        let filter = self.notification_filter;
        let filter_items = [
            (NotificationFilter::All, tr("All")),
            (NotificationFilter::Info, tr("Info")),
            (NotificationFilter::Success, tr("Success")),
            (NotificationFilter::Warning, tr("Warnings")),
            (NotificationFilter::Error, tr("Errors")),
        ];

        // 搜索行（对齐 Tauri CommandHeader：搜索图标 + 输入框 + 筛选按钮）。
        let search_row = h_flex()
            .w_full()
            .px(px(8.))
            .py(px(6.))
            .items_center()
            .gap(px(4.))
            .child(
                Icon::new(IconName::Search)
                    .with_size(px(14.))
                    .text_color(tokens.secondary_text),
            )
            .children(self.notification_input.clone().map(|input| {
                Input::new(&input)
                    .flex_1()
                    .min_w(px(0.))
                    .small()
                    .cleanable(true)
                    .bordered(false)
            }))
            .child(
                Button::new("lithe-notifications-filter")
                    .ghost()
                    .small()
                    .icon(Icon::new(IconName::ListFilter))
                    .when(filter.kind().is_some(), |this| this.bg(tokens.selection))
                    .tooltip(tr("Filter Notifications"))
                    .accessibility_label(tr("Filter Notifications"))
                    .dropdown_menu_with_anchor(gpui_kit::Anchor::TopRight, move |menu, _, _| {
                        let mut menu = menu;
                        for (value, label) in filter_items {
                            let item_owner = filter_owner.clone();
                            menu = menu.item(
                                PopupMenuItem::new(label).checked(filter == value).on_click(
                                    move |_, _, cx| {
                                        let _ = item_owner.update(cx, |this, cx| {
                                            this.set_notification_filter(value, cx);
                                        });
                                    },
                                ),
                            );
                        }
                        menu
                    })
                    .on_open_change(move |open, _window, cx| {
                        let _ =
                            menu_open_owner.update(cx, |this, cx| this.set_menu_open(*open, cx));
                    }),
            );

        // 列表；空列表时右键菜单为空（对齐 Tauri onContextMenu 的提前返回）。
        let mut list = v_flex()
            .id("lithe-notifications-list")
            .w_full()
            .flex_1()
            .min_h(px(0.))
            .px(px(6.))
            .pb(px(6.))
            .gap(px(4.))
            .overflow_y_scroll();

        if self.notifications.is_empty() {
            list = list.child(
                div()
                    .size_full()
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(tr("No notifications yet.")),
            );
        } else if groups.is_empty() {
            list = list.child(
                div()
                    .size_full()
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(tr("No matching notifications.")),
            );
        } else {
            for (label, entries) in groups {
                let collapsed = self.notification_collapsed_groups.contains(&label);
                list = list.child(notification_group_header(
                    label.clone(),
                    entries.len(),
                    collapsed,
                    tokens,
                    owner.clone(),
                ));
                if !collapsed {
                    for entry in &entries {
                        list = list.child(notification_row(entry, now, tokens, owner.clone()));
                    }
                }
            }
        }

        // 面板级右键菜单：全部复制 / 全部清除（对齐 Tauri panelContextMenu）。
        let panel_owner = cx.weak_entity();
        let list = list.context_menu(move |menu, _window, _cx| {
            if !has_entries {
                return menu;
            }
            let copy_owner = panel_owner.clone();
            let clear_owner = panel_owner.clone();
            menu.item(
                PopupMenuItem::new(tr("Copy All"))
                    .icon(Icon::new(IconName::Copy))
                    .on_click(move |_, _, cx| {
                        let _ = copy_owner.update(cx, |this, cx| this.copy_all_notifications(cx));
                    }),
            )
            .separator()
            .item(
                PopupMenuItem::new(tr("Clear All"))
                    .icon(Icon::new(IconName::Trash))
                    .on_click(move |_, _, cx| {
                        let _ = clear_owner.update(cx, |this, cx| this.clear_notifications(cx));
                    }),
            )
        });

        let dismiss = cx.listener(Self::on_action_dismiss_overlay);
        let header = ToolWindowHeader::new(tr("Notifications"))
            .on_collapse({
                move |_window, cx| {
                    let _ = collapse_owner.update(cx, |this, cx| this.close_notifications(cx));
                }
            })
            .render(_window, cx);

        v_flex()
            .id("lithe-notifications-panel")
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .rounded(px(LitheMetrics::PANE_RADIUS))
            .overflow_hidden()
            .bg(tokens.editor)
            .track_focus(&self.overlay_focus)
            .key_context(OVERLAY_CONTEXT)
            .on_action(dismiss)
            .child(header)
            .child(search_row)
            .child(div().flex_1().min_h(px(0.)).child(list))
            .into_any_element()
    }

    /// 详情视图（对齐 Tauri 的 `Command` 详情弹层，改为面板内二级视图）。
    fn render_notification_details(
        &self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let tokens = current_tokens(cx);
        let Some(id) = self.active_notification else {
            return self.render_notification_list(_window, cx);
        };
        let Some(entry) = self.notification_entry(id) else {
            return self.render_notification_list(_window, cx);
        };
        let now = Self::next_notification_timestamp();
        let age = format_notification_age(entry.updated_at, now);
        let copied = self.copied_notification == Some(entry.id);
        let has_description = entry.description.is_some();

        // 详情动作条：复制 / 删除（对齐 Tauri 详情弹层底部按钮）。
        let copy_owner = cx.weak_entity();
        let delete_owner = cx.weak_entity();
        let actions = h_flex()
            .items_center()
            .gap(px(8.))
            .p(px(8.))
            .child(
                Button::new("lithe-notification-copy")
                    .ghost()
                    .small()
                    .label(if copied { tr("Copied") } else { tr("Copy") })
                    .icon(Icon::new(IconName::Copy))
                    .on_click(move |_, _, cx| {
                        let _ = copy_owner.update(cx, |this, cx| {
                            this.copy_notification_text(id, cx);
                        });
                    }),
            )
            .child(
                Button::new("lithe-notification-delete")
                    .danger()
                    .small()
                    .label(tr("Delete"))
                    .icon(Icon::new(IconName::Trash))
                    .on_click(move |_, _, cx| {
                        let _ = delete_owner.update(cx, |this, cx| {
                            this.remove_notification(id, cx);
                        });
                    }),
            );

        let meta_line = h_flex()
            .items_center()
            .gap(px(4.))
            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
            .text_color(tokens.tertiary_text)
            .child(entry.kind.label())
            .child("-")
            .child(age);

        let mut content = v_flex()
            .flex_1()
            .min_h(px(0.))
            .child(
                h_flex()
                    .w_full()
                    .items_start()
                    .gap(px(8.))
                    .px(px(12.))
                    .py(px(10.))
                    .child(
                        Icon::new(entry.kind.icon())
                            .with_size(px(14.))
                            .text_color(entry.kind.color(tokens)),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(tokens.primary_text)
                            .child(format_occurrence(&entry.message, entry.count)),
                    ),
            )
            .child(div().w_full().px(px(12.)).pb(px(8.)).child(meta_line));

        if let Some(description) = entry.description.clone() {
            content = content.child(
                div()
                    .w_full()
                    .border_t(px(1.))
                    .border_b(px(1.))
                    .border_color(tokens.divider)
                    .px(px(12.))
                    .py(px(8.))
                    .max_h(px(160.))
                    .id("lithe-notification-description")
                    .overflow_y_scroll()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(description),
            );
        }

        // 消息 / 详情 / 整条通知的快捷复制入口（对齐 Tauri 右键菜单）。
        let message_owner = cx.weak_entity();
        let details_owner = cx.weak_entity();
        let text_owner = cx.weak_entity();
        let quick_menu = v_flex()
            .w_full()
            .border_t(px(1.))
            .border_color(tokens.divider)
            .child(
                Button::new("lithe-notification-copy-message")
                    .ghost()
                    .small()
                    .label(tr("Copy Message"))
                    .icon(Icon::new(IconName::Copy))
                    .on_click(move |_, _, cx| {
                        let _ = message_owner.update(cx, |this, cx| {
                            this.copy_notification_message(id, cx);
                        });
                    }),
            )
            .children(has_description.then(|| {
                Button::new("lithe-notification-copy-details")
                    .ghost()
                    .small()
                    .label(tr("Copy Details"))
                    .icon(Icon::new(IconName::Copy))
                    .on_click(move |_, _, cx| {
                        let _ = details_owner.update(cx, |this, cx| {
                            this.copy_notification_details(id, cx);
                        });
                    })
                    .into_any_element()
            }))
            .child(
                Button::new("lithe-notification-copy-notification")
                    .ghost()
                    .small()
                    .label(tr("Copy Notification"))
                    .icon(Icon::new(IconName::Copy))
                    .on_click(move |_, _, cx| {
                        let _ = text_owner.update(cx, |this, cx| {
                            this.copy_notification_text(id, cx);
                        });
                    }),
            );

        let dismiss = cx.listener(Self::on_action_dismiss_overlay);
        let header = ToolWindowHeader::new(tr("Notification details"))
            .on_collapse({
                let owner = cx.weak_entity();
                move |_window, cx| {
                    let _ = owner.update(cx, |this, cx| this.close_notification_details(cx));
                }
            })
            .render(_window, cx);

        v_flex()
            .id("lithe-notification-details")
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .rounded(px(LitheMetrics::PANE_RADIUS))
            .overflow_hidden()
            .bg(tokens.editor)
            .track_focus(&self.overlay_focus)
            .key_context(OVERLAY_CONTEXT)
            .on_action(dismiss)
            .child(header)
            .child(content)
            .child(quick_menu)
            .child(actions)
            .into_any_element()
    }

    /// 右下角 toast 浮层（对齐 Tauri sonner `position="bottom-right"`）。
    ///
    /// 最新的卡片最靠近角落；卡片只遮挡自身命中区，不拦整窗点击。
    pub(super) fn render_toasts(&self, cx: &mut Context<Self>) -> Option<gpui_kit::AnyElement> {
        if self.toasts.is_empty() {
            return None;
        }
        let tokens = current_tokens(cx);
        let owner = cx.weak_entity();
        let now = Self::next_notification_timestamp();

        // 存储是新→旧；渲染旧→新，让最新卡片贴着右下角（sonner 顺序）。
        let mut stack = v_flex().w(px(TOAST_WIDTH)).items_end().gap(px(14.));
        for (index, toast) in self.toasts.iter().enumerate().rev() {
            stack = stack.child(toast_card(index, toast, now, tokens, owner.clone()));
        }

        Some(
            div()
                .id("lithe-toast-layer")
                .absolute()
                // sonner 默认 offset 32px：底部起点在状态栏之上。
                .bottom(px(LitheMetrics::STATUS_BAR_HEIGHT + 8.))
                .right(px(32.))
                .child(stack)
                .into_any_element(),
        )
    }
}

/// 单张 toast 卡片（对齐 sonner 默认卡片：圆角 xl、边框、图标 + 标题 + 详情、
/// 悬停显示右上角关闭按钮）。
fn toast_card(
    index: usize,
    toast: &ToastEntry,
    _now: u64,
    tokens: LitheTokens,
    owner: WeakEntity<Workbench>,
) -> gpui_kit::AnyElement {
    let dismiss_owner = owner.clone();
    let message = toast.message.clone();
    let description = toast.description.clone();
    let dismiss_message = message.clone();
    let dismiss_description = description.clone();
    let kind = toast.kind;

    h_flex()
        .id(SharedString::from(format!("lithe-toast-card-{index}")))
        .group(SharedString::from(format!("lithe-toast-{index}")))
        .relative()
        .occlude()
        .w(px(TOAST_WIDTH))
        .items_start()
        .gap(px(8.))
        .p(px(12.))
        .pr(px(20.))
        .rounded(px(12.))
        .border_1()
        .border_color(tokens.panel_border)
        .bg(tokens.editor)
        .shadow_lg()
        .child(
            Icon::new(kind.toast_icon())
                .with_size(px(18.))
                .flex_shrink_0()
                // Tauri 的自定义 toast 图标未指定颜色，跟随正文前景色。
                .text_color(tokens.primary_text),
        )
        .child(
            v_flex()
                .flex_1()
                .min_w(px(0.))
                .gap(px(2.))
                .child(
                    div()
                        .w_full()
                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                        .line_height(relative(1.4))
                        .text_color(tokens.primary_text)
                        .child(message),
                )
                .children(description.clone().map(|description| {
                    div()
                        .w_full()
                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                        .line_height(relative(1.4))
                        .text_color(tokens.secondary_text)
                        .child(description)
                })),
        )
        .child(
            div()
                .absolute()
                .top(px(8.))
                .right(px(8.))
                .invisible()
                .group_hover(
                    SharedString::from(format!("lithe-toast-{index}")),
                    |style| style.visible(),
                )
                .child(
                    Button::new(SharedString::from(format!("lithe-toast-close-{index}")))
                        .ghost()
                        .xsmall()
                        .icon(Icon::new(IconName::Close).with_size(px(14.)))
                        .accessibility_label(tr("Close"))
                        .on_click(move |_, _, cx| {
                            cx.stop_propagation();
                            let _ = dismiss_owner.update(cx, |this, cx| {
                                this.dismiss_toast(
                                    kind,
                                    dismiss_message.clone(),
                                    dismiss_description.clone(),
                                    cx,
                                );
                            });
                        }),
                ),
        )
        .into_any_element()
}

/// 分组标题行：折叠箭头 + 日期 + 计数徽标（对齐 Tauri CollapsibleTrigger）。
fn notification_group_header(
    label: String,
    count: usize,
    collapsed: bool,
    tokens: LitheTokens,
    owner: WeakEntity<Workbench>,
) -> gpui_kit::AnyElement {
    let toggle_label = label.clone();
    h_flex()
        .id(SharedString::from(format!(
            "lithe-notification-group-{label}"
        )))
        .w_full()
        .h(px(24.))
        .px(px(8.))
        .gap(px(4.))
        .items_center()
        .rounded(px(6.))
        .hover(|style| style.bg(tokens.hover))
        .cursor_pointer()
        .on_click(move |_, _, cx| {
            let _ = owner.update(cx, |this, cx| {
                this.toggle_notification_group(toggle_label.clone(), cx)
            });
        })
        .child(
            Icon::new(if collapsed {
                IconName::ChevronRight
            } else {
                IconName::ChevronDown
            })
            .with_size(px(14.))
            .text_color(tokens.tertiary_text),
        )
        .child(
            div()
                .flex_1()
                .min_w(px(0.))
                .truncate()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(SharedString::from(label)),
        )
        .child(
            div()
                .px(px(6.))
                .py(px(1.))
                .rounded_full()
                .bg(tokens.hover)
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.tertiary_text)
                .child(count.to_string()),
        )
        .into_any_element()
}

/// 单条通知行：类型图标 + 消息（含出现次数后缀）+ 悬停删除 + 右键菜单。
fn notification_row(
    entry: &NotificationEntry,
    _now: u64,
    tokens: LitheTokens,
    owner: WeakEntity<Workbench>,
) -> gpui_kit::AnyElement {
    let id = entry.id;
    let click_owner = owner.clone();
    let delete_owner = owner.clone();
    let menu_owner = owner;
    let message = format_occurrence(&entry.message, entry.count);
    let has_description = entry.description.is_some();

    // 右键菜单（对齐 Tauri notificationContextMenu）。
    let context_menu =
        move |menu: gpui_kit::component::menu::PopupMenu,
              _window: &mut Window,
              _cx: &mut Context<gpui_kit::component::menu::PopupMenu>| {
            let mut menu = menu.item(
                PopupMenuItem::new(tr("Copy Message"))
                    .icon(Icon::new(IconName::Copy))
                    .on_click({
                        let owner = menu_owner.clone();
                        move |_, _, cx| {
                            let _ =
                                owner.update(cx, |this, cx| this.copy_notification_message(id, cx));
                        }
                    }),
            );
            if has_description {
                menu = menu.item(
                    PopupMenuItem::new(tr("Copy Details"))
                        .icon(Icon::new(IconName::Copy))
                        .on_click({
                            let owner = menu_owner.clone();
                            move |_, _, cx| {
                                let _ = owner
                                    .update(cx, |this, cx| this.copy_notification_details(id, cx));
                            }
                        }),
                );
            }
            menu = menu
                .item(
                    PopupMenuItem::new(tr("Copy Notification"))
                        .icon(Icon::new(IconName::Copy))
                        .on_click({
                            let owner = menu_owner.clone();
                            move |_, _, cx| {
                                let _ = owner
                                    .update(cx, |this, cx| this.copy_notification_text(id, cx));
                            }
                        }),
                )
                .separator()
                .item(
                    PopupMenuItem::new(tr("Delete"))
                        .icon(Icon::new(IconName::Trash))
                        .on_click({
                            let owner = menu_owner.clone();
                            move |_, _, cx| {
                                let _ =
                                    owner.update(cx, |this, cx| this.remove_notification(id, cx));
                            }
                        }),
                )
                .item(
                    PopupMenuItem::new(tr("Clear All"))
                        .icon(Icon::new(IconName::Trash))
                        .on_click({
                            let owner = menu_owner.clone();
                            move |_, _, cx| {
                                let _ = owner.update(cx, |this, cx| this.clear_notifications(cx));
                            }
                        }),
                );
            menu
        };

    // 行内容：类型图标 + 消息 + 悬停显示的删除按钮。
    h_flex()
        .id(SharedString::from(format!("lithe-notification-row-{id}")))
        .group("lithe-notification-row")
        .w_full()
        .h(px(28.))
        .px(px(8.))
        .gap(px(8.))
        .items_center()
        .rounded(px(6.))
        .hover(|style| style.bg(tokens.hover))
        .cursor_pointer()
        .on_click(move |_, _, cx| {
            let _ = click_owner.update(cx, |this, cx| this.open_notification_details(id, cx));
        })
        .context_menu(context_menu)
        .child(
            Icon::new(entry.kind.icon())
                .with_size(px(14.))
                .flex_shrink_0()
                .text_color(entry.kind.color(tokens)),
        )
        .child(
            div()
                .flex_1()
                .min_w(px(0.))
                .truncate()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.primary_text)
                .child(message),
        )
        .child(
            div()
                .flex_shrink_0()
                .invisible()
                .group_hover("lithe-notification-row", |style| style.visible())
                .child(
                    Button::new(SharedString::from(format!(
                        "lithe-notification-delete-{id}"
                    )))
                    .ghost()
                    .xsmall()
                    .icon(Icon::new(IconName::Trash))
                    .tooltip(tr("Delete Notification"))
                    .accessibility_label(tr("Delete Notification"))
                    .on_click(move |_, _, cx| {
                        cx.stop_propagation();
                        let _ = delete_owner.update(cx, |this, cx| {
                            this.remove_notification(id, cx);
                        });
                    }),
                ),
        )
        .into_any_element()
}

/// 相对年龄，紧凑格式（对齐 Tauri `formatCompactRelativeDate`，afterWeek: "days"）。
fn format_notification_age(timestamp: u64, now: u64) -> String {
    let diff_ms = now.saturating_sub(timestamp);
    let diff_mins = diff_ms / 60_000;
    let diff_hours = diff_ms / 3_600_000;
    let diff_days = diff_ms / 86_400_000;

    if diff_mins < 1 {
        tr("Just now").to_string()
    } else if diff_hours < 24 {
        format!("{diff_mins}m ago")
    } else {
        format!("{diff_days}d ago")
    }
}

/// 出现次数后缀；词条与 shared `notifications.occurrenceCount` 对齐
/// （zh「{message}（{count}）」，en「{message} ({count})」）。gpui 取词表
/// 不支持参数，这里按语言分支拼装，改词条时需同步 shared。
fn format_occurrence(message: &str, count: usize) -> String {
    if count <= 1 {
        return message.to_string();
    }
    if language() == "zh-CN" {
        format!("{message}（{count}）")
    } else {
        format!("{message} ({count})")
    }
}

/// 复制用的整条通知文本（对齐 Tauri `formatNotificationText`）。
fn format_notification_text(entry: &NotificationEntry) -> String {
    let now = Workbench::next_notification_timestamp();
    let mut parts = vec![format_occurrence(&entry.message, entry.count)];
    if let Some(description) = &entry.description {
        parts.push(description.to_string());
    }
    parts.push(format!(
        "{} - {}",
        entry.kind.type_key(),
        format_notification_age(entry.updated_at, now)
    ));
    parts.join("\n\n")
}

/// 日期分组标签（对齐 Tauri `formatCalendarDateGroup`）：
/// 今天 / 昨天 / 本地化短日期，跨年时补年份。
fn format_notification_group_label(timestamp: u64, now: u64) -> String {
    let (ty, tm, td) = civil_from_unix_ms(timestamp);
    let (ny, nm, nd) = civil_from_unix_ms(now);
    if (ty, tm, td) == (ny, nm, nd) {
        return tr("Today").to_string();
    }

    let (yy, ym, yd) = civil_from_unix_ms(now.saturating_sub(86_400_000));
    if (ty, tm, td) == (yy, ym, yd) {
        return tr("Yesterday").to_string();
    }

    if language() == "zh-CN" {
        if ty != ny {
            format!("{ty}年{tm}月{td}日")
        } else {
            format!("{tm}月{td}日")
        }
    } else {
        const MONTHS: [&str; 12] = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ];
        let month = MONTHS[(tm as usize - 1).min(11)];
        if ty != ny {
            format!("{month} {td}, {ty}")
        } else {
            format!("{month} {td}")
        }
    }
}

/// Unix 毫秒转（年，月，日）；Howard Hinnant `civil_from_days` 算法。
fn civil_from_unix_ms(timestamp: u64) -> (i64, u32, u32) {
    let days = (timestamp / 86_400_000) as i64;
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if month <= 2 { year + 1 } else { year }, month, day)
}
