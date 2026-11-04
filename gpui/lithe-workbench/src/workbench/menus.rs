use std::path::PathBuf;
use std::rc::Rc;

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::command::{Command, CommandEntry, CommandGroup, CommandItem, CommandState};
use gpui_kit::component::menu::{PopupMenu, PopupMenuItem};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::private::serde_json::{self, Value};
use gpui_kit::{
    AnyElement, AppContext as _, ClickEvent, Context, DismissEvent, Entity, FontWeight,
    InteractiveElement as _, IntoElement, ParentElement as _, Point, Render, SharedString,
    StatefulInteractiveElement as _, Styled as _, WeakEntity, Window, anchored, deferred, div, px,
};
use lithe_features::git::GitDialogKind;
use lithe_ui::i18n::tr;
use lithe_ui::icons::{LitheIcon, icon};
use lithe_ui::links;
use lithe_ui::{LitheMetrics, LitheTokens, current_tokens};

use super::dock::{DockAnchor, ToolWindow};
use super::tabs::file_identity;
use super::{TOP_MENU_CONTEXT, Workbench, theme_id_for, theme_kind_for};
use crate::app_menu::{self, MenuCommand, MenuState};
use crate::layout;

/// 分支弹窗的一行数据（本地或远程跟踪分支）。
///
/// `kind` 保留 Core `GitReferenceResponse.kind` 的原始值（local / remote），
/// checkout 时按类型化 `gitReference` 回传，不靠名字猜来源。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct BranchEntry {
    pub(super) full_name: String,
    pub(super) short_name: String,
    pub(super) kind: String,
    pub(super) is_current: bool,
    pub(super) ahead: usize,
    pub(super) behind: usize,
}

impl BranchEntry {
    /// 远程跟踪分支。Core 只对带上游的本地分支计算 ahead/behind，
    /// 远程行因此不显示追踪计数（不伪造数据）。
    fn is_remote(&self) -> bool {
        self.kind == "remote"
    }
}

/// 分支弹窗一行的动作目标。`Command` 过滤后仍按这里的原始下标回调，
/// 所以创建行与分支行可以共用一个确认回调。
#[derive(Clone, Debug, PartialEq, Eq)]
enum BranchMenuRow {
    Create(String),
    Checkout(BranchEntry),
}

/// 分支弹窗的列表视图（`Command` 的宿主）。
///
/// 搜索框 `CommandState` 与工作台常驻，但列表模型放在这个独立实体里：
/// 输入变化只重绘本实体与它的列表，不再 `notify` 整个工作台（此前每敲一个
/// 字符都会重建编辑器、项目树、工具窗等整棵树）。`CommandItem` 模型按
/// 「查询 + 数据版本」缓存，同一查询下的重绘不再重建每个分支行。
pub(crate) struct BranchMenuView {
    owner: WeakEntity<Workbench>,
    palette: Entity<CommandState>,
    local: Vec<BranchEntry>,
    remote: Vec<BranchEntry>,
    current: SharedString,
    loading: bool,
    error: Option<SharedString>,
    /// Core 是否报告当前项目是 Git 仓库；不是时管理器入口禁用。
    has_repository: bool,
    /// 数据快照版本；变化时让下面两层缓存失效。
    revision: u64,
    /// 本实体上一次构建的 CommandItem 行模型（按数据版本缓存，跨查询复用）。
    items: Option<BranchItemCache>,
    /// 本实体上一次构建的 `Command` 模型（按「查询 + 数据版本」缓存）。
    cache: Option<BranchMenuCache>,
}

/// 与查询无关的行模型：分支数据不变时只构建一次，输入查询不会重建
/// 每个分支行的 `CommandItem`（只重建「新建分支」那一行）。
struct BranchItemCache {
    revision: u64,
    local_items: Vec<CommandItem>,
    remote_items: Vec<CommandItem>,
    local_rows: Rc<Vec<BranchMenuRow>>,
    remote_rows: Rc<Vec<BranchMenuRow>>,
}

struct BranchMenuCache {
    query: String,
    revision: u64,
    entries: Vec<CommandEntry>,
    /// 本帧的「新建分支」目标名；`has_create` 决定 section 0 是创建行。
    create_name: Option<String>,
    has_create: bool,
    local_rows: Rc<Vec<BranchMenuRow>>,
    remote_rows: Rc<Vec<BranchMenuRow>>,
}

impl Workbench {
    pub(super) fn render_top_menu(
        &self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if !self.project_menu_visible && !self.branch_menu_visible {
            return None;
        }

        let tokens = current_tokens(cx);
        let backdrop_owner = cx.weak_entity();
        let anchor = self.branch_trigger_bounds.get();
        // 项目菜单保持左对齐的固定位置；分支菜单锚定在分支按钮正下方，
        // 不再借用项目按钮的左偏移（项目名变长后分支按钮会移动）。
        let (panel, left, top, width) = if self.project_menu_visible {
            (
                self.render_project_menu(cx),
                layout::TOP_MENU_LEFT,
                px(LitheMetrics::TOP_BAR_HEIGHT + layout::TOP_MENU_TOP_GAP),
                layout::TOP_MENU_WIDTH,
            )
        } else {
            let viewport = window.viewport_size().width;
            // 窄窗口下不能让 375pt 的弹窗越过右边缘：先按窗口收缩，再夹左侧。
            let width = layout::BRANCH_MENU_WIDTH.min((viewport - px(16.)).max(px(200.)));
            let left = anchor
                .map(|bounds| bounds.left())
                .unwrap_or(layout::TOP_MENU_LEFT);
            let left = left
                .min((viewport - width - px(8.)).max(px(8.)))
                .max(px(8.));
            let top = anchor
                .map(|bounds| bounds.bottom() + px(layout::TOP_MENU_TOP_GAP))
                .unwrap_or(px(LitheMetrics::TOP_BAR_HEIGHT + layout::TOP_MENU_TOP_GAP));
            (self.render_branch_menu(cx), left, top, width)
        };

        Some(
            div()
                .id("lithe-top-menu-layer")
                .absolute()
                .inset_0()
                .size_full()
                .track_focus(&self.overlay_focus)
                .key_context(TOP_MENU_CONTEXT)
                .on_action(cx.listener(Self::on_action_dismiss_menu))
                .child(
                    div()
                        .id("lithe-top-menu-backdrop")
                        .absolute()
                        .inset_0()
                        .size_full()
                        .occlude()
                        .on_click(move |_event: &ClickEvent, _window, cx| {
                            let _ = backdrop_owner.update(cx, |this, cx| this.close_menus(cx));
                        }),
                )
                .child(
                    div()
                        .id("lithe-top-menu-panel")
                        .occlude()
                        .absolute()
                        .top(top)
                        .left(left)
                        .w(width)
                        .rounded(px(LitheMetrics::MENU_RADIUS))
                        .overflow_hidden()
                        .bg(tokens.raised)
                        .border_1()
                        .border_color(tokens.panel_border)
                        .child(panel),
                )
                .into_any_element(),
        )
    }

    pub(super) fn render_project_menu(&self, cx: &mut Context<Self>) -> AnyElement {
        let tokens = current_tokens(cx);
        let current = self.project_root.as_deref().map(file_identity);
        let mut list = v_flex()
            .id("lithe-project-menu-list")
            .w_full()
            .max_h(layout::TOP_MENU_LIST_MAX_HEIGHT)
            .py(px(4.))
            .overflow_y_scroll();

        if self.recent_projects.is_empty() {
            list = list.child(menu_empty_row(tr("No recent projects"), tokens));
        } else {
            for path in self
                .recent_projects
                .iter()
                .take(layout::TOP_MENU_MAX_RECENT_PROJECTS)
            {
                let is_current = current
                    .as_deref()
                    .is_some_and(|identity| identity == file_identity(path).as_str());
                list = list.child(project_menu_row(
                    cx.weak_entity(),
                    path.clone(),
                    is_current,
                    tokens,
                ));
            }
        }

        let open_owner = cx.weak_entity();
        v_flex()
            .w_full()
            .child(list)
            .child(div().w_full().h(px(1.)).bg(tokens.divider))
            .child(
                h_flex()
                    .id("lithe-project-menu-open")
                    .w_full()
                    .items_center()
                    .gap(px(8.))
                    .px(px(12.))
                    .h(px(34.))
                    .hover(|this| this.bg(tokens.hover))
                    .cursor_pointer()
                    .on_click(move |_event: &ClickEvent, window, cx| {
                        let _ = open_owner.update(cx, |this, cx| {
                            this.close_menus(cx);
                            this.pick_project(window, cx);
                        });
                    })
                    .child(
                        icon(LitheIcon::FolderOpen)
                            .with_size(px(14.))
                            .text_color(tokens.secondary_text),
                    )
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.primary_text)
                            .child(tr("Open Project…")),
                    ),
            )
            .into_any_element()
    }

    pub(super) fn render_branch_menu(&self, _cx: &mut Context<Self>) -> AnyElement {
        // 列表交给独立实体渲染：查询变化只重绘它自己，工作台整棵树不参与。
        self.branch_menu.clone().into_any_element()
    }

    /// 把工作台的分支快照推给列表实体。只有内容变化才让列表缓存失效，
    /// 避免 `git.status` 刷新导致每次重建全部分支行。
    pub(super) fn sync_branch_menu(&self, cx: &mut Context<Self>) {
        let (local, remote) = split_branches(&self.branches);
        let current = self.branch.clone();
        let loading = self.branches_loading;
        let error = self.branch_error.clone();
        // 与顶栏一致：有项目且已读到当前分支 = Core 报告的 Git 仓库。
        let has_repository = self.project_root.is_some() && !self.branch.is_empty();
        let view = self.branch_menu.clone();
        view.update(cx, |view, cx| {
            view.set_snapshot(local, remote, current, loading, error, has_repository, cx);
        });
    }

    /// 打开分支行的 `⋯` 动作菜单（对齐 Tauri `BranchRow` 的 DropdownMenu）。
    /// 当前只提供 Checkout / Delete（Merge / Rebase 在 Git Log 引用面板里
    /// 已有完整入口，这里不重复实现）。
    pub(super) fn open_branch_row_menu(
        &mut self,
        entry: BranchEntry,
        position: Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let owner = cx.weak_entity();
        let popup =
            PopupMenu::build(window, cx, move |menu, _window, _cx| {
                let mut menu = menu.min_w(px(190.));
                let checkout_entry = entry.clone();
                let checkout_owner = owner.clone();
                menu = menu.item(
                    PopupMenuItem::new(tr("Checkout"))
                        .disabled(entry.is_current)
                        .on_click(move |_, window, cx| {
                            let entry = checkout_entry.clone();
                            let _ = checkout_owner.update(cx, |this, cx| {
                                this.checkout_branch(entry, window, cx);
                            });
                        }),
                );
                // 删除只对本地分支开放：远程分支的删除要推送到远端，
                // 不在这个入口伪造（Tauri footer 弹窗同样只列本地分支）。
                if !entry.is_remote() {
                    menu = menu.separator();
                    let delete_entry = entry.clone();
                    let delete_owner = owner.clone();
                    menu = menu.item(
                        PopupMenuItem::new(tr("Delete Branch"))
                            .disabled(entry.is_current)
                            .on_click(move |_, window, cx| {
                                let entry = delete_entry.clone();
                                let _ = delete_owner.update(cx, |this, cx| {
                                    this.delete_branch(entry, window, cx);
                                });
                            }),
                    );
                }
                menu
            });

        let subscription =
            cx.subscribe_in(&popup, window, |this, _, _: &DismissEvent, _window, cx| {
                this.branch_row_menu = None;
                this._branch_row_menu_subscription = None;
                cx.notify();
            });
        self.branch_row_menu = Some((popup, position));
        self._branch_row_menu_subscription = Some(subscription);
        cx.notify();
    }

    /// 分支行动作菜单的浮层（与标签页右键菜单同一套 `deferred + anchored`）。
    pub(super) fn render_branch_row_menu(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        // 弹窗已经关闭时（打开文件、命令面板、设置等路径会直接隐藏弹窗）
        // 不再画出孤立的行菜单。
        if !self.branch_menu_visible {
            return None;
        }
        let (popup, position) = self.branch_row_menu.as_ref()?;
        let popup = popup.clone();
        let position = *position;
        Some(
            deferred(
                anchored().position(position).snap_to_window().child(
                    div()
                        .occlude()
                        .on_mouse_down_out(cx.listener(move |this, _, _, cx| {
                            if this.branch_row_menu.take().is_some() {
                                this._branch_row_menu_subscription = None;
                                cx.notify();
                            }
                        }))
                        .child(popup),
                ),
            )
            .into_any_element(),
        )
    }

    /// 从分支弹窗打开现有的 Git 管理器对话框（`Manage Branches…` /
    /// `Manage Worktrees…`）。对话框本身由覆盖层实现，这里只负责把当前
    /// 仓库根与 Git 面板句柄交给它。
    pub(super) fn open_git_dialog(
        &mut self,
        kind: GitDialogKind,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.close_menus(cx);
        let panel = self.git.clone();
        let root = self.git.read(cx).repository_root().clone();
        let client = self.client;
        let workbench = cx.weak_entity();
        crate::workbench::overlays::git_dialogs::GitDialogView::open(
            kind,
            client,
            root,
            Vec::new(),
            panel.downgrade(),
            workbench,
            window,
            cx,
        );
    }

    pub(super) fn toggle_project_menu(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.project_menu_visible {
            self.project_menu_visible = false;
        } else {
            self.branch_menu_visible = false;
            self.project_menu_visible = true;
            self.overlay_focus.focus(window, cx);
        }
        cx.notify();
    }

    pub(crate) fn toggle_branch_menu(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.branch_menu_visible {
            self.branch_menu_visible = false;
            self.branch_row_menu = None;
            self._branch_row_menu_subscription = None;
            cx.notify();
            return;
        }
        if self.project_root.is_none() {
            self.status_message = Some(tr("Open a project first").into());
            cx.notify();
            return;
        }
        self.project_menu_visible = false;
        self.branch_menu_visible = true;
        // 重新打开时丢弃上次残留的行菜单。
        self.branch_row_menu = None;
        self._branch_row_menu_subscription = None;
        self.overlay_focus.focus(window, cx);
        // 每次打开都清空搜索并锁定搜索框（对齐 Tauri 打开时 select 查询词）。
        let palette = self.branch_palette.clone();
        palette.update(cx, |state, state_cx| {
            state.set_query("", window, state_cx);
            state.focus(window, state_cx);
        });
        self.load_branches(window, cx);
        cx.notify();
    }

    pub(super) fn close_menus(&mut self, cx: &mut Context<Self>) {
        if self.tab_context_menu.is_some() {
            self.tab_context_menu = None;
            self._tab_context_menu_subscription = None;
            cx.notify();
        }
        // 分支行的 `⋯` 菜单属于顶层菜单的一部分：一起关掉，避免弹窗关掉后
        // 还残留一个孤立的动作菜单。
        if self.branch_row_menu.take().is_some() {
            self._branch_row_menu_subscription = None;
            cx.notify();
        }
        if self.project_menu_visible || self.branch_menu_visible {
            self.project_menu_visible = false;
            self.branch_menu_visible = false;
            cx.notify();
        }
    }

    pub(super) fn refresh_branch(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(root) = self.project_root.clone() else {
            // 没有项目就没有分支；保持空值让顶栏隐藏分支入口。
            self.branch = SharedString::default();
            self.git_change_count = 0;
            self.branch_menu_visible = false;
            self.sync_branch_menu(cx);
            cx.notify();
            return;
        };

        self.branch_refresh_generation = self.branch_refresh_generation.wrapping_add(1);
        let generation = self.branch_refresh_generation;

        cx.spawn_in(window, async move |this, cx| {
            let client = lithe_core_client::CoreClient::new();
            // Core 的 GitReferencesRequest 契约字段是 `root`（曾误用 `path`
            // 导致分支菜单报 invalid_request: missing field 'root'）。
            let payload = serde_json::json!({ "root": root.to_string_lossy() });
            let result = cx
                .background_spawn(async move {
                    lithe_features::git::execute_git_command(&client, "git.status", payload)
                })
                .await;

            let _ = this.update_in(cx, |this, _window, cx| {
                if this.branch_refresh_generation != generation {
                    return;
                }
                match result {
                    Ok(value) => {
                        // CoreClient 已解包响应的 `data`，分支和变更都在顶层；
                        // 之前误读 `data.branch`，顶部一直停留在 `main`。
                        let branch = value
                            .get("branch")
                            .and_then(Value::as_str)
                            .unwrap_or_default();
                        this.branch = SharedString::from(branch.to_string());
                        if this.branch.is_empty() {
                            // 非 Git 仓库：顶栏不再显示一个不存在的 `main`。
                            this.branch_menu_visible = false;
                        }
                        let changes = value
                            .get("changes")
                            .and_then(Value::as_array)
                            .map(|array| array.len())
                            .unwrap_or(0);
                        this.git_change_count = changes;
                    }
                    Err(error) => {
                        this.branch = SharedString::default();
                        this.branch_menu_visible = false;
                        this.git_change_count = 0;
                        lithe_features::logging::log_event(
                            lithe_features::logging::Level::Debug,
                            "git",
                            format!("git.status failed: {error}"),
                        );
                    }
                }
                this.sync_branch_menu(cx);
                cx.notify();
            });
        })
        .detach();
    }

    pub(super) fn load_branches(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(root) = self.project_root.clone() else {
            self.branches.clear();
            self.branches_loading = false;
            self.branch_error = None;
            self.sync_branch_menu(cx);
            cx.notify();
            return;
        };

        self.branch_generation = self.branch_generation.wrapping_add(1);
        let generation = self.branch_generation;
        self.branches_loading = true;
        self.branch_error = None;
        self.sync_branch_menu(cx);
        cx.notify();

        cx.spawn_in(window, async move |this, cx| {
            let client = lithe_core_client::CoreClient::new();
            // Core 的 GitReferencesRequest 契约字段是 `root`（曾误用 `path`
            // 导致分支菜单报 invalid_request: missing field 'root'）。
            let payload = serde_json::json!({ "root": root.to_string_lossy() });
            let result = cx
                .background_spawn(async move {
                    lithe_features::git::execute_git_command(&client, "git.references", payload)
                })
                .await;

            let _ = this.update_in(cx, |this, _window, cx| {
                if this.branch_generation != generation {
                    return;
                }
                this.branches_loading = false;
                match result {
                    Ok(value) => {
                        this.branches = parse_branches(&value);
                        this.branch_error = None;
                    }
                    Err(error) => {
                        this.branches.clear();
                        this.branch_error = Some(SharedString::from(error.to_string()));
                    }
                }
                this.sync_branch_menu(cx);
                cx.notify();
            });
        })
        .detach();
    }

    /// 切换到本地或远程跟踪分支。
    ///
    /// 走 Core 的 `git.write` + `operation: "checkout"` + 类型化
    /// `gitReference`（与 Git Log 引用面板、Tauri `checkoutReference` 同一
    /// 契约）。远程分支由 Core `switch_validated_reference` 建同名本地分支
    /// （`--track -c <name> refs/remotes/<remote>/<branch>`），这里不自己拼
    /// 本地分支名，也不伪造 ahead/behind。
    pub(super) fn checkout_branch(
        &mut self,
        entry: BranchEntry,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // 当前分支是 no-op（Tauri `handleBranchChange` 同款守卫）。
        if entry.is_current || entry.short_name.is_empty() {
            return;
        }
        let display = entry.short_name.clone();
        let Some(root) = self.project_root.clone() else {
            return;
        };

        self.close_menus(cx);
        self.status_message = Some(format!("{} {display}…", tr("Checking out")).into());
        cx.notify();

        cx.spawn_in(window, async move |this, cx| {
            let client = lithe_core_client::CoreClient::new();
            let payload = serde_json::json!({
                "root": root.to_string_lossy(),
                "operation": "checkout",
                "gitReference": {
                    "fullName": entry.full_name,
                    "shortName": entry.short_name,
                    "kind": entry.kind,
                },
            });
            let result = cx
                .background_spawn(async move {
                    lithe_features::git::execute_git_command(&client, "git.write", payload)
                })
                .await;

            let _ = this.update_in(cx, |this, window, cx| {
                match result {
                    Ok(value) => {
                        let failed = value
                            .get("exitCode")
                            .and_then(Value::as_i64)
                            .map(|code| code != 0)
                            .unwrap_or(false);
                        if failed {
                            let message =
                                super::overlays::git_dialogs::failure_detail(&value);
                            this.status_message = Some(SharedString::from(message.clone()));
                            this.push_notification(
                                tr("Branches"),
                                Some(message.into()),
                                super::notifications::NotificationKind::Error,
                            );
                        } else {
                            this.status_message = None;
                            this.refresh_branch(window, cx);
                            this.refresh_project_tree(window, cx);
                        }
                    }
                    Err(error) => {
                        let message = error.to_string();
                        this.status_message = Some(SharedString::from(message.clone()));
                        this.push_notification(
                            tr("Branches"),
                            Some(message.into()),
                            super::notifications::NotificationKind::Error,
                        );
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 删除一个本地分支（Core `git.write` + `operation: "deleteBranch"`）。
    ///
    /// 请求体按 Core `GitWriteRequest` 使用类型化 `gitReference`（`reference`
    /// 旧字段只会被当成裸名字，`local_branch_name` 会拒绝）。当前分支与远程
    /// 分支在入口处就禁用，Core 也会再校验一次。
    pub(super) fn delete_branch(
        &mut self,
        entry: BranchEntry,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if entry.is_current || entry.is_remote() || entry.short_name.is_empty() {
            return;
        }
        let name = entry.short_name.clone();
        let Some(root) = self.project_root.clone() else {
            return;
        };

        self.status_message = Some(format!("{} {name}…", tr("Delete Branch")).into());
        cx.notify();

        cx.spawn_in(window, async move |this, cx| {
            let client = lithe_core_client::CoreClient::new();
            let payload = serde_json::json!({
                "root": root.to_string_lossy(),
                "operation": "deleteBranch",
                "gitReference": {
                    "fullName": entry.full_name,
                    "shortName": entry.short_name,
                    "kind": "local",
                },
            });
            let result = cx
                .background_spawn(async move {
                    lithe_features::git::execute_git_command(&client, "git.write", payload)
                })
                .await;

            let _ = this.update_in(cx, |this, window, cx| {
                match result {
                    Ok(value) => {
                        let failed = value
                            .get("exitCode")
                            .and_then(Value::as_i64)
                            .map(|code| code != 0)
                            .unwrap_or(false);
                        if failed {
                            let message =
                                super::overlays::git_dialogs::failure_detail(&value);
                            this.status_message = Some(SharedString::from(message.clone()));
                            this.push_notification(
                                tr("Delete Branch"),
                                Some(message.into()),
                                super::notifications::NotificationKind::Error,
                            );
                        } else {
                            this.status_message = None;
                            this.load_branches(window, cx);
                        }
                    }
                    Err(error) => {
                        let message = error.to_string();
                        this.status_message = Some(SharedString::from(message.clone()));
                        this.push_notification(
                            tr("Delete Branch"),
                            Some(message.into()),
                            super::notifications::NotificationKind::Error,
                        );
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 以当前分支为起点创建本地分支（对齐 Tauri `handleCreateBranch`：
    /// 只创建不切换，创建后刷新分支列表）。
    pub(super) fn create_branch(
        &mut self,
        name: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let name = name.trim().to_string();
        if name.is_empty() {
            return;
        }
        let Some(root) = self.project_root.clone() else {
            return;
        };
        let current = self.branch.to_string();
        if current.is_empty() {
            return;
        }

        self.close_menus(cx);
        self.status_message = Some(format!("{} {name}…", tr("New Branch")).into());
        cx.notify();

        cx.spawn_in(window, async move |this, cx| {
            let client = lithe_core_client::CoreClient::new();
            let payload = serde_json::json!({
                "root": root.to_string_lossy(),
                "operation": "createBranch",
                "name": name,
                "gitReference": {
                    "fullName": format!("refs/heads/{current}"),
                    "shortName": current,
                    "kind": "local",
                },
            });
            let result = cx
                .background_spawn(async move {
                    lithe_features::git::execute_git_command(&client, "git.write", payload)
                })
                .await;

            let _ = this.update_in(cx, |this, window, cx| {
                match result {
                    Ok(value) => {
                        let failed = value
                            .get("exitCode")
                            .and_then(Value::as_i64)
                            .map(|code| code != 0)
                            .unwrap_or(false);
                        if failed {
                            let message =
                                super::overlays::git_dialogs::failure_detail(&value);
                            this.status_message = Some(SharedString::from(message.clone()));
                            this.push_notification(
                                tr("New Branch"),
                                Some(message.into()),
                                super::notifications::NotificationKind::Error,
                            );
                        } else {
                            this.status_message = None;
                            this.load_branches(window, cx);
                        }
                    }
                    Err(error) => {
                        let message = error.to_string();
                        this.status_message = Some(SharedString::from(message.clone()));
                        this.push_notification(
                            tr("New Branch"),
                            Some(message.into()),
                            super::notifications::NotificationKind::Error,
                        );
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(super) fn pick_file(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.project_root.is_none() {
            self.status_message = Some(tr("Open a project first").into());
            cx.notify();
            return;
        }

        let platform = self.platform.clone();
        let title = tr("Open File").to_string();
        cx.spawn_in(window, async move |this, cx| {
            let path = platform.pick_file(title, Vec::new()).await;
            let Some(path) = path else {
                return;
            };
            let _ = this.update_in(cx, |this, window, cx| {
                this.open_file_from_tree(path, window, cx);
            });
        })
        .detach();
    }

    pub(super) fn toggle_menu_bar(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.menu_bar_visible {
            let menu_bar = self.menu_bar.clone();
            menu_bar.update(cx, |bar, bar_cx| bar.close_menus(bar_cx));
            self.menu_bar_visible = false;
        } else {
            self.menu_bar_visible = true;
            self.install_menus(cx);
            let menu_bar = self.menu_bar.clone();
            menu_bar.update(cx, |bar, bar_cx| bar.open_first(window, bar_cx));
        }
        cx.notify();
    }

    pub(super) fn menu_state(&self, cx: &Context<Self>) -> MenuState<'_> {
        MenuState {
            has_project: self.project_root.is_some(),
            has_active_tab: self.active_tab.is_some(),
            // 借用而不是复制：签名路径每次重绘都会跑一遍。
            recent_projects: &self.recent_projects,
            left_visible: self.left_visible,
            bottom_visible: self.bottom_visible,
            right_visible: self.right_visible,
            active_left: self.active_left.id(),
            active_bottom: self.active_bottom.map(ToolWindow::id),
            active_right: self.active_right.map(ToolWindow::id),
            dark: self.settings.dark,
            theme: theme_id_for(theme_kind_for(&self.settings.theme)),
            wrap: self.settings.editor_wrap,
            minimap: self.settings.editor_minimap,
            line_numbers: self.settings.editor_line_numbers,
            render_whitespace: self.settings.editor_render_whitespace,
            notifications_visible: self.notifications_visible,
            can_go_back: !self.nav_back.is_empty(),
            can_go_forward: !self.nav_forward.is_empty(),
            can_reopen_closed: !self.closed_tabs.is_empty(),
            menu_bar_visible: self.menu_bar_visible,
            language: lithe_ui::i18n::language(),
            // Theme 子菜单的数据源；注册表随主题一起静态注册。
            themes: lithe_ui::registered_themes(),
            // Stop Debugging 映射为停止当前运行会话，菜单按会话状态启停。
            run_running: self.run_panel.read(cx).is_running(),
            terminal_at_capacity: self.terminal_sessions.len()
                >= super::terminal::MAX_TERMINAL_SESSIONS,
        }
    }

    pub(super) fn install_menus(&mut self, cx: &mut Context<Self>) {
        let state = self.menu_state(cx);
        let signature = state.signature();
        // 签名没变：菜单内容、勾选与禁用状态都已经是最新的，保留现有菜单树
        // 即可。此前每次显示菜单栏（⌥M / 汉堡按钮）都会无条件重建全部
        // `MenuSpec` 并 `set_menus`，而 `set_menus` 会重置展开下标、丢掉已建好
        // 的下拉浮层，再触发一次整窗重绘。
        let menus = if self.menu_installed && signature == self.menu_signature {
            None
        } else {
            Some(app_menu::build_menus(&state))
        };
        drop(state);

        if let Some(menus) = menus {
            self.menu_bar
                .update(cx, |bar, bar_cx| bar.set_menus(menus, bar_cx));
            self.menu_signature = signature;
            self.menu_installed = true;
        }
        self.menu_install_pending = false;
    }

    pub(super) fn on_action_menu_command(
        &mut self,
        action: &MenuCommand,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.run_menu_command(action.0.as_str(), window, cx);
    }

    pub(super) fn run_menu_command(
        &mut self,
        command: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(path) = app_menu::decode_open_recent(command) {
            self.open_project(path, window, cx);
            return;
        }

        // Edit > Find Next / Find Previous：直接驱动编辑器已有的查找会话，
        // 不经过 action。查找条未打开时编辑器内部是安全 no-op，与 macOS
        // 在查找条隐藏时禁用这两项的语义一致。
        if matches!(command, "edit.findNext" | "edit.findPrevious") {
            let forward = command == "edit.findNext";
            self.editor.update(cx, |editor, editor_cx| {
                if forward {
                    editor.find_next(editor_cx);
                } else {
                    editor.find_previous(editor_cx);
                }
            });
            return;
        }

        let editor_command = match command {
            "edit.undo" => Some("undo"),
            "edit.redo" => Some("redo"),
            "edit.cut" => Some("editor.action.clipboardCutAction"),
            "edit.copy" => Some("editor.action.clipboardCopyAction"),
            "edit.paste" => Some("editor.action.clipboardPasteAction"),
            "edit.selectAll" => Some("editor.action.selectAll"),
            "edit.find" => Some("actions.find"),
            "edit.replace" => Some("editor.action.startFindReplaceAction"),
            "edit.toggleComment" => Some("editor.action.commentLine"),
            "edit.quickFix" => Some("editor.action.quickFix"),
            "edit.duplicateLine" => Some("editor.action.copyLinesDownAction"),
            "edit.deleteLine" => Some("editor.action.deleteLines"),
            "edit.moveLineUp" => Some("editor.action.moveLinesUpAction"),
            "edit.moveLineDown" => Some("editor.action.moveLinesDownAction"),
            _ => None,
        };

        if let Some(action) = editor_command {
            self.dispatch_editor_action(command, action, window, cx);
            return;
        }

        // 分支里的同名别名（例如 `file.closeTab` → `file.closeFile`、
        // `navigate.*` → `go.*`、`view.quickOpen` → `go.quickOpen`）是历史
        // 命令名。当前没有菜单项或快捷键构造这些别名，因此它们不进
        // `command_handled` 白名单（放进白名单会让“没有入口的命令”看起来
        // 像可用能力）；分支保留给可能直接构造 `MenuCommand` 的内部调用。
        match command {
            "file.openProject" => self.pick_project(window, cx),
            "file.openFile" => self.pick_file(window, cx),
            "file.closeProject" => self.close_current_project(window, cx),
            "file.newProject" => self.pick_new_project_parent(window, cx),
            "file.newWindow" => self.open_new_window(window, cx),
            "file.newTab" | "workbench.newTab" => self.open_new_tab(window, cx),
            "file.newFile" => self.open_new_file_prompt(window, cx),
            "file.newFolder" => self.open_new_folder_prompt(window, cx),
            "file.newJavaType" => self.open_new_java_type_prompt(window, cx),
            "file.newJavaPackage" => self.open_new_java_package_prompt(window, cx),
            "file.save" => self.save_active_tab(window, cx),
            "file.saveAs" => self.save_active_tab_as(window, cx),
            "file.saveAll" => {
                // 真正的保存全部：当前标签走编辑区文本，后台标签走缓存文本。
                self.save_all_tabs(cx).detach();
            }
            "file.revert" => self.revert_active_file(window, cx),
            "file.closeFile" | "file.closeTab" => {
                if let Some(id) = self.active_tab.clone() {
                    self.close_tab(&id, window, cx);
                }
            }
            "file.closeOtherTabs" | "file.closeOthers" => self.close_other_tabs(window, cx),
            "file.closeTabsToLeft" => {
                if let Some(active) = self.active_tab.clone() {
                    self.close_tabs_to_left_of(active.as_ref(), window, cx);
                }
            }
            "file.closeTabsToRight" => self.close_tabs_to_right(window, cx),
            "file.closeAllTabs" | "file.closeAll" => self.close_all_tabs(window, cx),
            "file.closeSaved" => self.close_saved_tabs(window, cx),
            "file.reopenClosedTab" | "file.reopenClosed" => self.reopen_last_closed_tab(window, cx),
            "file.localHistory" => self.open_local_history(window, cx),
            "file.settings" | "tools.settings" => self.toggle_settings(window, cx),
            "file.exit" => self.request_quit(window, cx),
            // Edit > Go to Line：行号输入复用工作台 prompt 弹层，确认后由
            // 编辑器移动光标并滚动到目标行。
            "edit.gotoLine" => self.open_go_to_line_prompt(window, cx),
            // 别名命令：以下 id 只由快捷键、活动栏或工具条发送，不在应用菜单
            // 里出现，因此不需要进 `app_menu::command_handled` 的白名单。
            // `file.closeTab` / `file.closeOtherTabs` / `file.closeAllTabs` /
            // `file.reopenClosedTab` 是菜单 id 的旧拼写；`view.toolBar`、
            // `view.toggleDark`、`view.splitRight`、`view.splitDown`、
            // `view.quickOpen`、`navigate.*`、`git.commit` 同理，保持两条入口
            // 行为一致。
            "view.toolBar" | "window.toggleMenuBar" => self.toggle_menu_bar(window, cx),
            "view.toggleDark" | "view.appearance.dark" => {
                let dark = !self.settings.dark;
                self.settings.dark = dark;
                self.save_settings(cx);
                self.apply_theme_to_workbench(cx);
            }
            "view.wrap" => self.toggle_wrap(window, cx),
            "view.minimap" => self.toggle_editor_minimap(window, cx),
            "view.lineNumbers" => self.toggle_editor_line_numbers(window, cx),
            "view.renderWhitespace" => self.toggle_editor_render_whitespace(window, cx),
            // Zoom 系列按目标分发：底部终端工具窗活跃时缩放终端字号，否则
            // 缩放编辑器字号（对齐 Tauri `zoomIn/zoomOut/zoomReset` 按焦点
            // 目标分发到 editor/terminal 的语义；Tauri 同样不是全局 UI 缩放）。
            "view.zoomIn" => {
                if self.zoom_prefers_terminal() {
                    self.nudge_terminal_zoom(1.0, window, cx);
                } else {
                    self.nudge_editor_zoom(1.0, window, cx);
                }
            }
            "view.zoomOut" => {
                if self.zoom_prefers_terminal() {
                    self.nudge_terminal_zoom(-1.0, window, cx);
                } else {
                    self.nudge_editor_zoom(-1.0, window, cx);
                }
            }
            "view.zoomReset" => {
                if self.zoom_prefers_terminal() {
                    self.reset_terminal_zoom(window, cx);
                } else {
                    self.reset_editor_zoom(window, cx);
                }
            }
            "view.splitEditor" => self.toggle_editor_split(window, cx),
            "view.splitRight" => self.split_editor_right(window, cx),
            "view.splitDown" => {
                self.split_terminal(super::terminal::TerminalSplitAxis::Vertical, window, cx)
            }
            "view.commandPalette" | "tools.commandPalette" => self.open_palette(window, cx),
            "view.quickOpen" | "go.quickOpen" => self.open_quick_open(window, cx),
            "view.searchEverywhere" => self.show_tool(ToolWindow::Search, window, cx),
            "view.notifications" => self.toggle_notifications(window, cx),
            "view.activityBar" | "view.dock.left" | "view.fileExplorer" => {
                self.show_tool(ToolWindow::Project, window, cx)
            }
            "view.secondarySidebar" | "view.dock.right" => {
                self.set_dock_visible(DockAnchor::Right, !self.right_visible, cx)
            }
            "view.dock.bottom" => {
                self.set_dock_visible(DockAnchor::Bottom, !self.bottom_visible, cx)
            }
            "view.globalSearch" | "go.findInFiles" => {
                self.show_tool(ToolWindow::Search, window, cx);
                // 显式切回查找模式，避免残留上次的替换模式（open_find
                // 只切模式，显示工具窗由 show_tool 负责）。
                self.search.update(cx, |panel, panel_cx| {
                    panel.open_find(panel_cx);
                });
            }
            // Replace in Files：打开搜索面板并展开替换区（SearchPanel 的替换
            // 输入与 Replace / Replace all 在详情区内渲染），对齐 Tauri 搜索
            // 面板 SearchReplaceToggle 的展开态。
            "go.replaceInFiles" => {
                self.show_tool(ToolWindow::Search, window, cx);
                self.search.update(cx, |panel, panel_cx| {
                    panel.open_replace(panel_cx);
                });
            }
            "view.sourceControl" | "tools.git" | "git.commit" => {
                self.show_tool(ToolWindow::Changes, window, cx)
            }
            "view.diagnostics" => self.show_tool(ToolWindow::Problems, window, cx),
            "view.runAndDebug" => self.show_tool(ToolWindow::Run, window, cx),
            // View > GitHub 已从白名单移除（菜单灰置）：Tauri 侧它切换
            // GitHub 侧栏，而 GPUI 对应的 Pull Requests 工具窗仍是空壳，
            // 按「能点必有效果」原则禁用；不允许退回打开浏览器冒充。
            "navigate.back" | "go.back" => self.navigate_history(true, window, cx),
            "navigate.forward" | "go.forward" => self.navigate_history(false, window, cx),
            "navigate.nextTab" | "go.nextTab" => self.cycle_tab(1, window, cx),
            "navigate.previousTab" | "go.previousTab" => self.cycle_tab(-1, window, cx),
            "go.definition" => {
                self.dispatch_editor_action(command, "editor.action.revealDefinition", window, cx);
            }
            // Go to Implementation / Type Definition / References / Rename Symbol
            // 没有对应的原生能力（编辑器没有多结果 peek UI 与重命名控件，Core 的
            // 同文档兜底只覆盖 definition），菜单项已在 `command_handled` 里
            // 禁用；这些入口落地前不要在这里留空转发。
            "terminal.new" => self.new_terminal(window, cx),
            "terminal.split" => {
                self.split_terminal(super::terminal::TerminalSplitAxis::Horizontal, window, cx)
            }
            "terminal.splitDown" => {
                self.split_terminal(super::terminal::TerminalSplitAxis::Vertical, window, cx)
            }
            "terminal.clear" => {
                if let Some(id) = self.active_terminal.clone() {
                    self.clear_terminal_session(&id, cx);
                }
            }
            "terminal.close" => {
                if let Some(id) = self.active_terminal.clone() {
                    self.close_terminal_session(&id, window, cx);
                }
            }
            "run.run" => {
                self.show_tool(ToolWindow::Run, window, cx);
                self.run_panel
                    .update(cx, |panel, panel_cx| panel.run_selected(panel_cx));
            }
            // View > Run 与活动栏「运行」、Shift+F10 同一条路径：只切面板不启动，
            // 与 Tauri `toggleRunPane` 一致。`run.run` 才是“运行选中配置”。
            "run.toggleWindow" | "view.tool.run" => self.toggle_tool(ToolWindow::Run, window, cx),
            // gpui 构建没有调试器：Tauri 的 `debug.start` 在这里降级为打开
            // Debug 工具窗。工具窗还是空壳，菜单项已按「不放行空壳」禁用，
            // 因此本分支当前没有真实入口（活动栏 debug 图标直接调
            // toggle_tool，不经命令）；调试器落地后改回启动调试会话。
            "run.debug" => self.show_tool(ToolWindow::Debug, window, cx),
            // Run Configurations…：打开设置覆盖层的「Run Configurations」页，
            // 对齐 openidea Run 菜单 EditConfigs 的「进入配置编辑界面」语义，
            // 不再退化成只切 Run 工具窗。同时保持 Run 工具窗可见：覆盖层关闭
            // 后用户直接落在输出与配置列表上下文；定位到具体配置的编辑入口
            // 由 Run 面板详情页的「Edit Configuration…」承担。
            "run.configurations" => {
                self.show_tool(ToolWindow::Run, window, cx);
                self.open_run_settings(window, cx);
            }
            // Stop Debugging：停止当前运行会话。Tauri 的 `debug.stop` 停止当前
            // 调试会话；gpui 构建没有调试器，语义映射为停止当前活跃的运行会话
            // （`stop_active`：优先选中配置，否则停止所有仍在启动/运行的会话），
            // 与菜单 `run_running` 的启用条件严格对应，点击必有真实效果。
            // `run.toggleBreakpoint` 没有断点模型，白名单不放行，由此永远到不
            // 了派发。
            "run.stop" => {
                self.run_panel
                    .update(cx, |panel, panel_cx| panel.stop_active(panel_cx));
            }
            "tools.agent" => self.show_tool(ToolWindow::Agent, window, cx),
            // Database / Services 工具窗还是空壳（dock.rs 渲染占位说明），
            // 菜单入口在 app_menu.rs 里禁用；分支保留给内容落地后放行。
            "tools.database" => self.show_tool(ToolWindow::Database, window, cx),
            "tools.services" => self.show_tool(ToolWindow::Services, window, cx),
            // Tools > Web Inspector 已移除入口：GPUI 构建没有 WebView，
            // `open_devtools` 是空壳；菜单项在 `command_handled` 里禁用。
            "tools.keyboardShortcuts" | "help.keyboardShortcuts" => {
                self.open_keymap_settings(window, cx)
            }
            "window.minimize" => window.minimize_window(),
            // Maximize 走 native zoom；Fullscreen 用 gpui `Window::toggle_fullscreen`
            // （此前误映射成 zoom_window，F11 变成了最大化/还原）。语义对齐
            // Tauri `setFullscreen(!isFullscreen)`。
            "window.zoom" => window.zoom_window(),
            "window.fullscreen" => window.toggle_fullscreen(),
            // 关闭窗口等于退出这个工作区实例：先把布局和标签会话落盘，
            // 否则节流窗口里的最后一次变化会丢。
            "window.close" => {
                self.flush_layout_persist();
                window.remove_window();
            }
            // Help 菜单 URL 统一走 `lithe_ui::links` 常量（真源为
            // `git remote -v` 的 origin `1lck/Lithe-IDEA`，与 Tauri
            // services.json 一致），不再出现裸 URL 字符串。
            "help.documentation" => {
                self.platform.open_url(links::DOCS_URL);
            }
            "help.repository" => {
                self.platform.open_url(links::REPOSITORY_URL);
            }
            "help.whatsNew" => {
                self.platform.open_url(links::RELEASES_URL);
            }
            "help.changelog" => {
                self.platform.open_url(links::CHANGELOG_URL);
            }
            "help.reportBug" => {
                // 对齐 Tauri：先把环境信息写入剪贴板，再打开模板化 issue 表单。
                lithe_features::bug_report::copy_environment_report(cx);
                self.platform.open_url(links::BUG_REPORT_URL);
            }
            "help.requestFeature" => {
                self.platform.open_url(links::FEATURE_REQUEST_URL);
            }
            // 检查更新与 Updates 页按钮走同一状态机入口：落到 Updates 页并触发
            // 一次检查（本构建结果只能落在 Unavailable，页面文案给出下载页）。
            // Tauri 的对应动作是 menu_check_updates → updater。
            "help.checkUpdates" => self.open_update_check_settings(window, cx),
            "help.about" => {
                self.push_notification(
                    "Lithe",
                    Some(format!("Lithe {}", env!("CARGO_PKG_VERSION")).into()),
                    super::notifications::NotificationKind::Info,
                );
            }
            cmd if cmd.starts_with("view.tool.") => {
                // View > Tool Windows 的每一项都是勾选项，对齐 macOS `openTool`
                //（WorkbenchView.swift:1390）：已打开时再点一次关闭，而不是
                // 只把可见性再置一次 true。`view.tool.run` 已在上面单独走
                // toggle，这里覆盖其余工具窗。
                if let Some(tool) = ToolWindow::from_id(&cmd["view.tool.".len()..]) {
                    self.toggle_tool(tool, window, cx);
                }
            }
            cmd if cmd.starts_with("view.theme.") => {
                let id = &cmd["view.theme.".len()..];
                self.settings.theme = id.to_string();
                self.save_settings(cx);
                self.apply_theme_to_workbench(cx);
            }
            // 语言切换目前只在设置页（General › Language）提供入口；保留
            // `view.language.{code}` 前缀供后续菜单语言子菜单复用，当前没有
            // 菜单项生成这些 id（不是未接线，而是尚无调用方）。
            cmd if cmd.starts_with("view.language.") => {
                let code = &cmd["view.language.".len()..];
                self.settings.language = code.to_string();
                self.save_settings(cx);
                lithe_ui::i18n::set_language(code);
                self.install_menus(cx);
                cx.notify();
            }
            // 兜底：菜单层只会发送 `app_menu::command_handled` 放行过的 id，
            // 其余调用方（快捷键/活动栏）如果传错 id，这里只写一条 debug 日志，
            // 不再静默丢弃，便于用日志时间线定位未接线入口。
            other => {
                lithe_features::logging::log_event(
                    lithe_features::logging::Level::Debug,
                    "application",
                    format!("Unhandled menu command: {other}"),
                );
            }
        }
    }

    /// 把菜单命令翻译成编辑器 action 并派发；`run_command` 返回 false 表示
    /// 编辑器没有接线（action 未映射或没有打开的文档），写 debug 日志而不是
    /// 静默吞掉，避免菜单出现「点了没反应」的假可用。
    fn dispatch_editor_action(
        &mut self,
        menu_command: &str,
        editor_action: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let handled = self.editor.update(cx, |editor, editor_cx| {
            editor.run_command(editor_action, window, editor_cx)
        });
        if !handled {
            lithe_features::logging::log_event(
                lithe_features::logging::Level::Debug,
                "application",
                format!("Menu command had no effect: {menu_command}"),
            );
        }
    }
}

impl BranchMenuView {
    pub(super) fn new(
        owner: WeakEntity<Workbench>,
        palette: Entity<CommandState>,
        _cx: &mut Context<Self>,
    ) -> Self {
        Self {
            owner,
            palette,
            local: Vec::new(),
            remote: Vec::new(),
            current: SharedString::default(),
            loading: false,
            error: None,
            has_repository: false,
            revision: 0,
            items: None,
            cache: None,
        }
    }

    /// 工作台推入最新快照；内容未变时不碰缓存，避免无谓重建。
    pub(super) fn set_snapshot(
        &mut self,
        local: Vec<BranchEntry>,
        remote: Vec<BranchEntry>,
        current: SharedString,
        loading: bool,
        error: Option<SharedString>,
        has_repository: bool,
        cx: &mut Context<Self>,
    ) {
        if self.local == local
            && self.remote == remote
            && self.current == current
            && self.loading == loading
            && self.error == error
            && self.has_repository == has_repository
        {
            return;
        }
        self.local = local;
        self.remote = remote;
        self.current = current;
        self.loading = loading;
        self.error = error;
        self.has_repository = has_repository;
        self.revision = self.revision.wrapping_add(1);
        cx.notify();
    }

    /// 取当前查询对应的模型；「查询 + 数据版本」都没变时复用缓存。
    fn cache_for(&mut self, query: &str) -> &BranchMenuCache {
        // 第一层：分支行模型只随数据版本变化。输入查询不重建每个
        // `CommandItem`（自定义行内容的闭包、文案、关键字都在这里只做一次）。
        let items_stale = self
            .items
            .as_ref()
            .is_none_or(|items| items.revision != self.revision);
        if items_stale {
            let owner = self.owner.clone();
            let loading = self.loading;
            let local_rows: Rc<Vec<BranchMenuRow>> = Rc::new(
                self.local
                    .iter()
                    .cloned()
                    .map(BranchMenuRow::Checkout)
                    .collect(),
            );
            let remote_rows: Rc<Vec<BranchMenuRow>> = Rc::new(
                self.remote
                    .iter()
                    .cloned()
                    .map(BranchMenuRow::Checkout)
                    .collect(),
            );
            let local_items = local_rows
                .iter()
                .filter_map(|row| match row {
                    BranchMenuRow::Checkout(entry) => {
                        Some(branch_item(entry, &owner, loading, true))
                    }
                    BranchMenuRow::Create(_) => None,
                })
                .collect::<Vec<_>>();
            let remote_items = remote_rows
                .iter()
                .filter_map(|row| match row {
                    BranchMenuRow::Checkout(entry) => {
                        Some(branch_item(entry, &owner, loading, false))
                    }
                    BranchMenuRow::Create(_) => None,
                })
                .collect::<Vec<_>>();
            self.items = Some(BranchItemCache {
                revision: self.revision,
                local_items,
                remote_items,
                local_rows,
                remote_rows,
            });
        }
        let items = self
            .items
            .as_ref()
            .expect("branch item cache is built on miss");

        // 第二层：`Command` 模型只依赖「查询 + 数据版本」；例如窗口缩放
        // 触发的重绘会直接命中这层缓存。
        let fresh = self
            .cache
            .as_ref()
            .is_some_and(|cache| cache.query == query && cache.revision == self.revision);
        if !fresh {
            let current = self.current.to_string();
            // 「新建分支」行只在查询词能构成新分支名时出现（对齐 Tauri
            // `getCreateBranchName`），并且必须排在最前（section 0）。
            let create_name = creatable_branch_name(&self.local, &current, query);
            let mut entries: Vec<CommandEntry> = Vec::new();
            if let Some(name) = create_name.as_ref() {
                entries.push(CommandEntry::Item(create_branch_item(
                    name,
                    self.loading,
                )));
            }
            // 本地 / 远程两组始终写入模型，即便某组为空：`Command` 对空组
            // 只是不渲染标题，却仍递增 section 下标，这样过滤不会打乱
            // 确认回调的行定位。
            entries.push(CommandEntry::Group(
                CommandGroup::new()
                    .label(tr("Local"))
                    .items(items.local_items.clone()),
            ));
            entries.push(CommandEntry::Group(
                CommandGroup::new()
                    .label(tr("Remote"))
                    .items(items.remote_items.clone()),
            ));

            self.cache = Some(BranchMenuCache {
                query: query.to_string(),
                revision: self.revision,
                entries,
                has_create: create_name.is_some(),
                create_name,
                local_rows: items.local_rows.clone(),
                remote_rows: items.remote_rows.clone(),
            });
        }

        self.cache
            .as_ref()
            .expect("branch menu cache is built on miss")
    }
}

/// 把 `Command` 回调里的 (section, row) 还原成动作行。
///
/// 分组顺序固定为 [新建?] [本地] [远程]；空组也占一个 section，所以这里
/// 只按「是否存在新建行」做偏移。
fn branch_menu_row_at(
    section: usize,
    row: usize,
    has_create: bool,
    create_name: Option<&str>,
    local_rows: &[BranchMenuRow],
    remote_rows: &[BranchMenuRow],
) -> Option<BranchMenuRow> {
    if has_create && section == 0 {
        return create_name.map(|name| BranchMenuRow::Create(name.to_string()));
    }
    let group = section.checked_sub(has_create as usize)?;
    let rows = match group {
        0 => local_rows,
        1 => remote_rows,
        _ => return None,
    };
    rows.get(row).cloned()
}

impl Render for BranchMenuView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let tokens = current_tokens(cx);
        let query = self.palette.read(cx).query(cx).trim().to_string();
        let (entries, has_create, create_name, local_rows, remote_rows) = {
            let cache = self.cache_for(&query);
            (
                cache.entries.clone(),
                cache.has_create,
                cache.create_name.clone(),
                cache.local_rows.clone(),
                cache.remote_rows.clone(),
            )
        };
        let loading = self.loading;
        let empty_error = self.error.clone();
        let header_error = self.error.clone();
        let empty_query = !query.is_empty();
        let owner = self.owner.clone();
        let query_owner = cx.weak_entity();
        let cancel_owner = owner.clone();
        let footer_owner = owner.clone();
        let footer_local = self.local.clone();
        let footer_current = self.current.to_string();
        let footer_local_count = self.local.len();
        let footer_remote_count = self.remote.len();
        let has_repository = self.has_repository;

        let mut command = Command::new(&self.palette)
            .bordered(false)
            .bg(tokens.raised)
            .text_color(tokens.primary_text)
            .placeholder(tr("Search branches"))
            .max_h(layout::TOP_MENU_LIST_MAX_HEIGHT)
            // 查询只重绘本实体：工作台（编辑器 / 项目树 / 工具窗）不再因为
            // 输入一个字而整棵树重建。
            .on_query(move |_, _, cx| {
                let _ = query_owner.update(cx, |_view, cx| cx.notify());
            })
            .on_confirm(move |index, window, cx| {
                // `Command` 的本地过滤只影响可见行；确认回调拿到的仍是原始
                // (section, row)，按固定分组顺序映射回创建行或分支行。
                let Some(row) = branch_menu_row_at(
                    index.section,
                    index.row,
                    has_create,
                    create_name.as_deref(),
                    &local_rows,
                    &remote_rows,
                ) else {
                    return;
                };
                let _ = owner.update(cx, |this, cx| match row {
                    BranchMenuRow::Create(name) => this.create_branch(name, window, cx),
                    BranchMenuRow::Checkout(entry) => this.checkout_branch(entry, window, cx),
                });
            })
            .on_cancel(move |_window, cx| {
                let _ = cancel_owner.update(cx, |this, cx| this.close_menus(cx));
            })
            .empty(move |_, _, _| {
                let (message, color) = match (&empty_error, loading, empty_query) {
                    (Some(error), _, _) => (error.clone(), tokens.error),
                    (None, true, _) => (SharedString::from(tr("Loading…")), tokens.tertiary_text),
                    (None, false, true) => (
                        SharedString::from(tr("No matching branches")),
                        tokens.tertiary_text,
                    ),
                    (None, false, false) => {
                        (SharedString::from(tr("No branches")), tokens.tertiary_text)
                    }
                };
                div()
                    .w_full()
                    .py(px(14.))
                    .px(px(10.))
                    .text_center()
                    .text_size(px(12.))
                    .text_color(color)
                    .child(message)
                    .into_any_element()
            })
            .footer(move |state, _window, cx| {
                // 底部动作按点击当时的查询词求值（对齐 Tauri footer 的
                // New Branch / Refresh）。
                let query = state.query(cx).trim().to_string();
                let create_name = creatable_branch_name(&footer_local, &footer_current, &query);
                let new_owner = footer_owner.clone();
                let refresh_owner = footer_owner.clone();
                let manage_owner = footer_owner.clone();
                let worktrees_owner = footer_owner.clone();
                h_flex()
                    .w_full()
                    .items_center()
                    .gap(px(4.))
                    .px(px(8.))
                    .h(px(34.))
                    .border_t(px(1.))
                    .border_color(tokens.divider)
                    .child(branch_footer_action(
                        "branch-footer-new",
                        Some(LitheIcon::Plus),
                        tr("New Branch"),
                        create_name.is_some() && !loading,
                        tokens,
                        move |window, cx| {
                            let Some(name) = create_name.clone() else {
                                return;
                            };
                            let _ = new_owner
                                .update(cx, |this, cx| this.create_branch(name, window, cx));
                        },
                    ))
                    .child(branch_footer_action(
                        "branch-footer-refresh",
                        Some(LitheIcon::Refresh),
                        tr("Refresh"),
                        !loading,
                        tokens,
                        move |window, cx| {
                            let _ =
                                refresh_owner.update(cx, |this, cx| this.load_branches(window, cx));
                        },
                    ))
                    // 工作树 / 分支管理器入口：打开工作台已有的 Git 对话框，
                    // 弹窗内不重复实现工作树列表。宽度受限时这两个入口用图标
                    // + tooltip（tooltip 同时作为无障碍标签）。
                    .child(branch_footer_icon_action(
                        "branch-footer-manage",
                        LitheIcon::GitBranch,
                        tr("Manage Branches"),
                        has_repository,
                        tokens,
                        move |window, cx| {
                            let _ = manage_owner.update(cx, |this, cx| {
                                this.open_git_dialog(GitDialogKind::Branches, window, cx);
                            });
                        },
                    ))
                    .child(branch_footer_icon_action(
                        "branch-footer-worktrees",
                        LitheIcon::FolderOpen,
                        tr("Manage Worktrees…"),
                        has_repository,
                        tokens,
                        move |window, cx| {
                            let _ = worktrees_owner.update(cx, |this, cx| {
                                this.open_git_dialog(GitDialogKind::Worktrees, window, cx);
                            });
                        },
                    ))
                    .child(div().flex_1())
                    .child(
                        div()
                            .flex_shrink_0()
                            .max_w(px(120.))
                            .truncate()
                            .text_size(px(11.))
                            .text_color(tokens.tertiary_text)
                            .child(branch_count_label(
                                footer_local_count,
                                footer_remote_count,
                            )),
                    )
                    .into_any_element()
            });

        if footer_local_count > 0 || footer_remote_count > 0 {
            if let Some(error) = header_error {
                // 列表非空时（刷新失败但保留旧数据）也把错误暴露出来，不再
                // 只在空列表分支里显示；空列表由 `empty` 槽单独展示。
                command = command.header(move |_, _, cx| {
                    let tokens = current_tokens(cx);
                    h_flex()
                        .w_full()
                        .items_center()
                        .gap(px(6.))
                        .px(px(10.))
                        .py(px(6.))
                        .child(
                            Icon::new(IconName::CircleAlert)
                                .with_size(px(12.))
                                .text_color(tokens.error),
                        )
                        .child(
                            div()
                                .min_w(px(0.))
                                .flex_1()
                                .truncate()
                                .text_size(px(11.))
                                .text_color(tokens.error)
                                .child(error.clone()),
                        )
                        .into_any_element()
                });
            }
        }

        for entry in entries {
            command = match entry {
                CommandEntry::Item(item) => command.item(item),
                CommandEntry::Group(group) => command.group(group),
                CommandEntry::Separator => command.separator(),
            };
        }

        v_flex().w_full().child(command).into_any_element()
    }
}

fn menu_empty_row(label: &'static str, tokens: LitheTokens) -> AnyElement {
    div()
        .w_full()
        .px(px(12.))
        .py(px(8.))
        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
        .text_color(tokens.tertiary_text)
        .child(label)
        .into_any_element()
}

fn project_menu_row(
    owner: WeakEntity<Workbench>,
    path: PathBuf,
    is_current: bool,
    tokens: LitheTokens,
) -> AnyElement {
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .map(str::to_string)
        .unwrap_or_else(|| path.to_string_lossy().into_owned());
    let path_display = path.to_string_lossy().into_owned();
    let open_path = path.clone();

    let open_path_str = open_path.to_string_lossy().into_owned();

    h_flex()
        .id(format!("lithe-recent-project:{open_path_str}"))
        .w_full()
        .items_center()
        .justify_between()
        .px(px(12.))
        .py(px(6.))
        .hover(|this| this.bg(tokens.hover))
        .cursor_pointer()
        .on_click(move |_event: &ClickEvent, window, cx| {
            let open_path = open_path.clone();
            let _ = owner.update(cx, |this, cx| {
                this.close_menus(cx);
                this.open_project(open_path, window, cx);
            });
        })
        .child(
            v_flex()
                .flex_1()
                .min_w(px(0.))
                .child(
                    div()
                        .w_full()
                        .truncate()
                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                        .font_weight(if is_current {
                            FontWeight::SEMIBOLD
                        } else {
                            FontWeight::NORMAL
                        })
                        .text_color(tokens.primary_text)
                        .child(name),
                )
                .child(
                    div()
                        .w_full()
                        .truncate()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.tertiary_text)
                        .child(path_display),
                ),
        )
        .when(is_current, |this| {
            this.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.accent)
                    .child("✓"),
            )
        })
        .into_any_element()
}

/// 「新建分支」行：查询词能构成新分支名时排在列表最前（对齐 Tauri
/// `createBranchName` + `CommandItemRow` 的 Plus 行）。
fn create_branch_item(name: &str, disabled: bool) -> CommandItem {
    let name = name.to_string();
    let label = format!("{} “{}”", tr("New Branch"), name);
    let child_name = name.clone();
    CommandItem::new()
        .label(label)
        .keywords([name])
        .child(move |_, cx| {
            let tokens = current_tokens(cx);
            let text = format!("{} “{}”", tr("New Branch"), child_name);
            h_flex()
                .w_full()
                .items_center()
                .gap(px(6.))
                .child(
                    icon(LitheIcon::Plus)
                        .with_size(px(13.))
                        .text_color(tokens.secondary_text),
                )
                .child(
                    div()
                        .min_w(px(0.))
                        .truncate()
                        .text_size(px(12.))
                        .text_color(tokens.primary_text)
                        .child(text),
                )
                .into_any_element()
        })
        .disabled(disabled)
}

/// 一个分支行：当前分支用对勾 + `Current` 徽标，本地非当前分支带 `⋯`
/// 动作入口（Checkout / Delete）；远程分支用同一分支图标，只提供检出。
fn branch_item(
    entry: &BranchEntry,
    owner: &WeakEntity<Workbench>,
    disabled: bool,
    offer_delete: bool,
) -> CommandItem {
    let entry = entry.clone();
    let owner = owner.clone();
    CommandItem::new()
        .label(entry.short_name.clone())
        .keywords([entry.full_name.clone()])
        .child(move |_, cx| {
            let tokens = current_tokens(cx);
            let is_current = entry.is_current;
            let leading = if is_current {
                Icon::new(IconName::Check)
                    .with_size(px(13.))
                    .text_color(tokens.success)
            } else {
                icon(LitheIcon::GitBranch)
                    .with_size(px(13.))
                    .text_color(tokens.secondary_text)
            };
            h_flex()
                .w_full()
                .items_center()
                .gap(px(6.))
                .child(leading)
                .child(
                    div()
                        .min_w(px(0.))
                        .truncate()
                        .text_size(px(12.))
                        .text_color(tokens.primary_text)
                        .child(entry.short_name.clone()),
                )
                // ahead/behind 只来自 Core 对本地分支上游的计算；远程分支
                // Core 返回 0，这里也不会显示 0/0。
                .when(entry.ahead > 0 || entry.behind > 0, |this| {
                    this.child(
                        div()
                            .flex_shrink_0()
                            .text_size(px(11.))
                            .text_color(tokens.secondary_text)
                            .child(format!("↑{} ↓{}", entry.ahead, entry.behind)),
                    )
                })
                .child(div().flex_1())
                .when(is_current, |this| this.child(current_badge(tokens)))
                .when(!is_current && offer_delete, |this| {
                    let entry = entry.clone();
                    let owner = owner.clone();
                    this.child(branch_row_actions(entry, owner, disabled, tokens))
                })
                .into_any_element()
        })
        .disabled(disabled)
}

/// 分支行尾的 `⋯` 按钮：打开 Checkout / Delete 动作菜单（对齐 Tauri
/// `BranchRow` 的 DropdownMenu；Merge / Rebase 留在 Git Log 引用面板）。
fn branch_row_actions(
    entry: BranchEntry,
    owner: WeakEntity<Workbench>,
    disabled: bool,
    tokens: LitheTokens,
) -> AnyElement {
    let id = SharedString::from(format!("branch-more:{}", entry.full_name));
    div()
        .id(id)
        .flex_shrink_0()
        .size(px(18.))
        .rounded(px(3.))
        .flex()
        .items_center()
        .justify_center()
        .when(!disabled, |this| {
            this.cursor_pointer()
                .hover(|style| style.bg(tokens.hover))
                .on_click(move |event: &ClickEvent, window, cx| {
                    // 行本身也是可点击的（确认 = checkout），这里必须先拦住
                    // 冒泡，否则点 `⋯` 会顺带切分支。
                    cx.stop_propagation();
                    let entry = entry.clone();
                    let _ = owner.update(cx, |this, cx| {
                        this.open_branch_row_menu(entry, event.position(), window, cx);
                    });
                })
        })
        .child(
            icon(LitheIcon::More)
                .with_size(px(14.))
                .text_color(tokens.tertiary_text),
        )
        .into_any_element()
}

fn current_badge(tokens: LitheTokens) -> AnyElement {
    div()
        .flex_shrink_0()
        .h(px(16.))
        .px(px(5.))
        .rounded(px(3.))
        .bg(tokens.success.alpha(0.14))
        .text_size(px(10.))
        .text_color(tokens.success)
        .child(tr("Current"))
        .into_any_element()
}

/// 分支弹窗底部的文字动作（New Branch / Refresh）。
fn branch_footer_action(
    id: &'static str,
    icon_name: Option<LitheIcon>,
    label: &'static str,
    enabled: bool,
    tokens: LitheTokens,
    action: impl Fn(&mut Window, &mut gpui_kit::App) + 'static,
) -> AnyElement {
    let mut content = h_flex().items_center().gap(px(4.));
    if let Some(icon_name) = icon_name {
        content = content.child(icon(icon_name).with_size(px(13.)).text_color(if enabled {
            tokens.secondary_text
        } else {
            tokens.tertiary_text
        }));
    }
    content = content.child(
        div()
            .text_size(px(11.5))
            .text_color(if enabled {
                tokens.primary_text
            } else {
                tokens.tertiary_text
            })
            .child(label),
    );

    Button::new(id)
        .ghost()
        .h(px(24.))
        .px(px(6.))
        .rounded(px(4.))
        .disabled(!enabled)
        .child(content)
        .on_click(move |_, window, cx| action(window, cx))
        .into_any_element()
}

/// 分支弹窗底部的图标动作（管理分支 / 工作树）。文案走 tooltip，
/// 375pt 的弹窗宽度里放得下两个图标入口。
fn branch_footer_icon_action(
    id: &'static str,
    icon_name: LitheIcon,
    tooltip: &'static str,
    enabled: bool,
    tokens: LitheTokens,
    action: impl Fn(&mut Window, &mut gpui_kit::App) + 'static,
) -> AnyElement {
    Button::new(id)
        .ghost()
        .h(px(24.))
        .px(px(6.))
        .rounded(px(4.))
        .disabled(!enabled)
        .tooltip(tooltip)
        .accessibility_label(tooltip)
        .child(
            icon(icon_name).with_size(px(14.)).text_color(if enabled {
                tokens.secondary_text
            } else {
                tokens.tertiary_text
            }),
        )
        .on_click(move |_, window, cx| action(window, cx))
        .into_any_element()
}

/// 底部分支计数：只显示真实存在的本地 / 远程分支数量。
fn branch_count_label(local: usize, remote: usize) -> String {
    if remote == 0 {
        format!("{local} {}", tr("Branches"))
    } else {
        format!("{local} {} · {remote} {}", tr("Local"), tr("Remote"))
    }
}

/// 把分支列表拆成本地 / 远程两组（弹窗按组渲染）。
fn split_branches(branches: &[BranchEntry]) -> (Vec<BranchEntry>, Vec<BranchEntry>) {
    let mut local = Vec::new();
    let mut remote = Vec::new();
    for entry in branches {
        if entry.is_remote() {
            remote.push(entry.clone());
        } else {
            local.push(entry.clone());
        }
    }
    (local, remote)
}

/// 查询词能直接创建的新分支名：非空、不是当前分支、也不与现有本地分支同名
/// （大小写不敏感，对齐 Tauri `getCreateBranchName`）。远程分支同名不算冲突：
/// Git 允许本地 `main` 与 `origin/main` 同时存在。
fn creatable_branch_name(branches: &[BranchEntry], current: &str, query: &str) -> Option<String> {
    let name = query.trim();
    if name.is_empty() || name == current {
        return None;
    }
    if branches
        .iter()
        .any(|branch| !branch.is_remote() && branch.short_name.eq_ignore_ascii_case(name))
    {
        return None;
    }
    Some(name.to_string())
}

/// 解析 `git.references` 的本地分支与远程跟踪分支。
///
/// 分组排序：本地在前（当前分支置顶，其余按名字），远程在后（按名字）。
/// `fullName` 直接取 Core 的原值（`refs/remotes/origin/main` 这类带远端
/// 前缀的完整引用不能靠短名重组）。
pub(super) fn parse_branches(value: &Value) -> Vec<BranchEntry> {
    let mut entries = Vec::new();
    // Core `git.references` 响应：顶层 `references` 数组，字段 camelCase
    // （fullName / shortName / kind / isCurrent / ahead / behind）。
    // 之前误按 `data.references` + `name`/`is_head` 解析，分支菜单永远为空。
    let Some(references) = value.get("references").and_then(Value::as_array) else {
        return entries;
    };

    for item in references {
        let kind = item.get("kind").and_then(Value::as_str).unwrap_or_default();
        if kind != "local" && kind != "remote" {
            // 标签不在这个弹窗里出现（Git Log 引用面板负责）。
            continue;
        }
        let Some(short_name) = item.get("shortName").and_then(Value::as_str) else {
            continue;
        };
        let Some(full_name) = item.get("fullName").and_then(Value::as_str) else {
            continue;
        };
        let is_current = item
            .get("isCurrent")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let ahead = item.get("ahead").and_then(Value::as_u64).unwrap_or(0) as usize;
        let behind = item.get("behind").and_then(Value::as_u64).unwrap_or(0) as usize;

        entries.push(BranchEntry {
            full_name: full_name.to_string(),
            short_name: short_name.to_string(),
            kind: kind.to_string(),
            is_current,
            ahead,
            behind,
        });
    }

    entries.sort_by(|a, b| {
        (a.is_remote(), !a.is_current, &a.short_name).cmp(&(
            b.is_remote(),
            !b.is_current,
            &b.short_name,
        ))
    });

    entries
}
