use std::path::PathBuf;

use gpui_kit::component::{Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::private::serde_json::{self, Value};
use gpui_kit::{
    AnyElement, AppContext as _, ClickEvent, Context, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _,
    WeakEntity, Window, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::icons::{LitheIcon, icon};
use lithe_ui::links;
use lithe_ui::{LitheMetrics, LitheTokens, current_tokens};

use super::dock::{DockAnchor, ToolWindow};
use super::tabs::file_identity;
use super::{TOP_MENU_CONTEXT, Workbench, theme_id_for, theme_kind_for};
use crate::app_menu::{self, MenuCommand, MenuState};
use crate::layout;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct BranchEntry {
    pub(super) full_name: String,
    pub(super) short_name: String,
    pub(super) is_current: bool,
    pub(super) ahead: usize,
    pub(super) behind: usize,
}

impl Workbench {
    pub(super) fn render_top_menu(
        &self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if !self.project_menu_visible && !self.branch_menu_visible {
            return None;
        }

        let tokens = current_tokens(cx);
        let backdrop_owner = cx.weak_entity();
        let panel = if self.project_menu_visible {
            self.render_project_menu(cx)
        } else {
            self.render_branch_menu(cx)
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
                        .top(px(LitheMetrics::TOP_BAR_HEIGHT + layout::TOP_MENU_TOP_GAP))
                        .left(layout::TOP_MENU_LEFT)
                        .w(layout::TOP_MENU_WIDTH)
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

    pub(super) fn render_branch_menu(&self, cx: &mut Context<Self>) -> AnyElement {
        let tokens = current_tokens(cx);
        let mut list = v_flex()
            .id("lithe-branch-menu-list")
            .w_full()
            .max_h(layout::TOP_MENU_LIST_MAX_HEIGHT)
            .py(px(4.))
            .overflow_y_scroll();

        if self.branches_loading {
            list = list.child(menu_empty_row(tr("Loading…"), tokens));
        }
        if let Some(error) = &self.branch_error {
            list = list.child(
                div()
                    .w_full()
                    .px(px(12.))
                    .py(px(8.))
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.error)
                    .child(error.clone()),
            );
        }
        if self.branches.is_empty() {
            if !self.branches_loading && self.branch_error.is_none() {
                let empty = if self.project_root.is_some() {
                    tr("No branches")
                } else {
                    tr("No project open")
                };
                list = list.child(menu_empty_row(empty, tokens));
            }
        } else {
            for entry in &self.branches {
                list = list.child(branch_menu_row(cx.weak_entity(), entry.clone(), tokens));
            }
        }

        v_flex()
            .w_full()
            .child(
                h_flex()
                    .w_full()
                    .items_center()
                    .px(px(12.))
                    .h(px(30.))
                    .border_b(px(1.))
                    .border_color(tokens.divider)
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.secondary_text)
                            .child(tr("Branches")),
                    ),
            )
            .child(list)
            .into_any_element()
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
        } else {
            self.project_menu_visible = false;
            self.branch_menu_visible = true;
            self.overlay_focus.focus(window, cx);
            self.load_branches(window, cx);
        }
        cx.notify();
    }

    pub(super) fn close_menus(&mut self, cx: &mut Context<Self>) {
        if self.tab_context_menu.is_some() {
            self.tab_context_menu = None;
            self._tab_context_menu_subscription = None;
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
            self.branch = SharedString::from(tr("main"));
            self.git_change_count = 0;
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
                .background_spawn(async move { client.execute_raw("git.status", payload) })
                .await;

            let _ = this.update_in(cx, |this, _window, cx| {
                if this.branch_refresh_generation != generation {
                    return;
                }
                match result {
                    Ok(value) => {
                        // CoreClient 已解包响应的 `data`，分支和变更都在顶层；
                        // 之前误读 `data.branch`，顶部一直停留在 `main`。
                        if let Some(branch) = value.get("branch").and_then(Value::as_str) {
                            this.branch = SharedString::from(branch.to_string());
                        }
                        let changes = value
                            .get("changes")
                            .and_then(Value::as_array)
                            .map(|array| array.len())
                            .unwrap_or(0);
                        this.git_change_count = changes;
                    }
                    Err(_) => {
                        this.git_change_count = 0;
                    }
                }
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
            cx.notify();
            return;
        };

        self.branch_generation = self.branch_generation.wrapping_add(1);
        let generation = self.branch_generation;
        self.branches_loading = true;
        self.branch_error = None;
        cx.notify();

        cx.spawn_in(window, async move |this, cx| {
            let client = lithe_core_client::CoreClient::new();
            // Core 的 GitReferencesRequest 契约字段是 `root`（曾误用 `path`
            // 导致分支菜单报 invalid_request: missing field 'root'）。
            let payload = serde_json::json!({ "root": root.to_string_lossy() });
            let result = cx
                .background_spawn(async move { client.execute_raw("git.references", payload) })
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
                cx.notify();
            });
        })
        .detach();
    }

    pub(super) fn checkout_branch(
        &mut self,
        short_name: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(root) = self.project_root.clone() else {
            return;
        };

        self.close_menus(cx);
        self.status_message = Some(format!("{} {short_name}…", tr("Checking out")).into());
        cx.notify();

        cx.spawn_in(window, async move |this, cx| {
            let client = lithe_core_client::CoreClient::new();
            let payload = serde_json::json!({
                "path": root.to_string_lossy(),
                "branch": short_name,
            });
            let result = cx
                .background_spawn(async move { client.execute_raw("git.checkout", payload) })
                .await;

            let _ = this.update_in(cx, |this, window, cx| {
                match result {
                    Ok(_) => {
                        this.status_message = None;
                        this.refresh_branch(window, cx);
                        this.refresh_project_tree(window, cx);
                    }
                    Err(error) => {
                        this.status_message = Some(SharedString::from(error.to_string()));
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

    pub(super) fn menu_state(&self, cx: &Context<Self>) -> MenuState {
        MenuState {
            has_project: self.project_root.is_some(),
            has_active_tab: self.active_tab.is_some(),
            recent_projects: self.recent_projects.clone(),
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
            terminal_has_split: self.terminal_secondary.is_some(),
        }
    }

    pub(super) fn install_menus(&mut self, cx: &mut Context<Self>) {
        let state = self.menu_state(cx);
        let menus = app_menu::build_menus(&state);
        self.menu_bar
            .update(cx, |bar, bar_cx| bar.set_menus(menus, bar_cx));
        self.menu_signature = state.signature();
        self.menu_installed = true;
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
                self.terminal.update(cx, |p, pcx| p.clear(pcx));
                if let Some(p) = self.terminal_secondary.clone() {
                    p.update(cx, |p, pcx| p.clear(pcx));
                }
            }
            "terminal.close" => {
                if self.bottom_visible && self.active_bottom == Some(ToolWindow::Terminal) {
                    self.set_dock_visible(DockAnchor::Bottom, false, cx);
                }
                self.close_terminal_split(cx);
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
            "window.close" => window.remove_window(),
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
                if let Some(tool) = ToolWindow::from_id(&cmd["view.tool.".len()..]) {
                    self.show_tool(tool, window, cx);
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

fn branch_menu_row(
    owner: WeakEntity<Workbench>,
    entry: BranchEntry,
    tokens: LitheTokens,
) -> AnyElement {
    let short_name = entry.short_name.clone();
    let full_name = entry.full_name.clone();
    h_flex()
        .id(format!("lithe-branch-item:{full_name}"))
        .w_full()
        .items_center()
        .justify_between()
        .px(px(12.))
        .py(px(6.))
        .hover(|this| this.bg(tokens.hover))
        .cursor_pointer()
        .on_click(move |_event: &ClickEvent, window, cx| {
            let short_name = short_name.clone();
            let _ = owner.update(cx, |this, cx| {
                this.checkout_branch(short_name, window, cx);
            });
        })
        .child(
            h_flex()
                .items_center()
                .gap(px(6.))
                .child(icon(LitheIcon::GitBranch).with_size(px(14.)).text_color(
                    if entry.is_current {
                        tokens.accent
                    } else {
                        tokens.secondary_text
                    },
                ))
                .child(
                    div()
                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                        .font_weight(if entry.is_current {
                            FontWeight::SEMIBOLD
                        } else {
                            FontWeight::NORMAL
                        })
                        .text_color(tokens.primary_text)
                        .child(entry.short_name),
                ),
        )
        .child(
            h_flex()
                .items_center()
                .gap(px(6.))
                .when(entry.ahead > 0 || entry.behind > 0, |this| {
                    this.child(
                        div()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(format!("↑{} ↓{}", entry.ahead, entry.behind)),
                    )
                })
                .when(entry.is_current, |this| {
                    this.child(
                        div()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.accent)
                            .child("✓"),
                    )
                }),
        )
        .into_any_element()
}

pub(super) fn parse_branches(value: &Value) -> Vec<BranchEntry> {
    let mut entries = Vec::new();
    // Core `git.references` 响应：顶层 `references` 数组，字段 camelCase
    // （fullName / shortName / kind / isCurrent / ahead / behind）。
    // 之前误按 `data.references` + `name`/`is_head` 解析，分支菜单永远为空。
    let Some(references) = value.get("references").and_then(Value::as_array) else {
        return entries;
    };

    for item in references {
        if item.get("kind").and_then(Value::as_str) != Some("local") {
            continue;
        }
        let Some(short_name) = item.get("shortName").and_then(Value::as_str) else {
            continue;
        };
        let is_current = item
            .get("isCurrent")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let ahead = item.get("ahead").and_then(Value::as_u64).unwrap_or(0) as usize;
        let behind = item.get("behind").and_then(Value::as_u64).unwrap_or(0) as usize;

        entries.push(BranchEntry {
            full_name: format!("refs/heads/{short_name}"),
            short_name: short_name.to_string(),
            is_current,
            ahead,
            behind,
        });
    }

    entries.sort_by(|a, b| match (a.is_current, b.is_current) {
        (true, false) => std::cmp::Ordering::Less,
        (false, true) => std::cmp::Ordering::Greater,
        _ => a.short_name.cmp(&b.short_name),
    });

    entries
}
