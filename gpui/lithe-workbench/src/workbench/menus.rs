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

    pub(super) fn menu_state(&self) -> MenuState {
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
        }
    }

    pub(super) fn install_menus(&mut self, cx: &mut Context<Self>) {
        let state = self.menu_state();
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
            "edit.findNext" => Some("editor.action.nextMatchFindAction"),
            "edit.findPrevious" => Some("editor.action.previousMatchFindAction"),
            "edit.toggleComment" => Some("editor.action.commentLine"),
            "edit.format" => Some("editor.action.formatDocument"),
            "edit.formatSelection" => Some("editor.action.formatSelection"),
            "edit.gotoLine" => Some("editor.action.gotoLine"),
            "edit.quickFix" => Some("editor.action.quickFix"),
            "edit.triggerParameterHints" => Some("editor.action.triggerParameterHints"),
            "edit.showHover" => Some("editor.action.showHover"),
            "edit.duplicateLine" => Some("editor.action.copyLinesDownAction"),
            "edit.deleteLine" => Some("editor.action.deleteLines"),
            "edit.moveLineUp" => Some("editor.action.moveLinesUpAction"),
            "edit.moveLineDown" => Some("editor.action.moveLinesDownAction"),
            _ => None,
        };

        if let Some(action) = editor_command {
            self.editor.update(cx, |editor, editor_cx| {
                editor.run_command(action, editor_cx);
            });
            return;
        }

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
                self.editor.update(cx, |e, ecx| e.save_all(ecx));
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
            "file.exit" => cx.quit(),
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
            "view.zoomIn" => self.nudge_editor_zoom(1.0, window, cx),
            "view.zoomOut" => self.nudge_editor_zoom(-1.0, window, cx),
            "view.zoomReset" => self.reset_editor_zoom(window, cx),
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
            "view.globalSearch" | "go.findInFiles" | "go.replaceInFiles" => {
                self.show_tool(ToolWindow::Search, window, cx)
            }
            "view.sourceControl" | "tools.git" | "git.commit" => {
                self.show_tool(ToolWindow::Changes, window, cx)
            }
            "view.diagnostics" => self.show_tool(ToolWindow::Problems, window, cx),
            "view.runAndDebug" => self.show_tool(ToolWindow::Run, window, cx),
            "view.github" => {
                self.platform
                    .open_url("https://github.com/Lithe-IDEA/Lithe-IDEA");
            }
            "navigate.back" | "go.back" => self.navigate_history(true, window, cx),
            "navigate.forward" | "go.forward" => self.navigate_history(false, window, cx),
            "navigate.nextTab" | "go.nextTab" => self.cycle_tab(1, window, cx),
            "navigate.previousTab" | "go.previousTab" => self.cycle_tab(-1, window, cx),
            "go.definition" => {
                self.editor.update(cx, |e, ecx| {
                    e.run_command("editor.action.revealDefinition", ecx);
                });
            }
            "go.implementation" => {
                self.editor.update(cx, |e, ecx| {
                    e.run_command("editor.action.goToImplementation", ecx);
                });
            }
            "go.typeDefinition" => {
                self.editor.update(cx, |e, ecx| {
                    e.run_command("editor.action.goToTypeDefinition", ecx);
                });
            }
            "go.references" => {
                self.editor.update(cx, |e, ecx| {
                    e.run_command("editor.action.referenceSearch.trigger", ecx);
                });
            }
            "go.renameSymbol" => {
                self.editor.update(cx, |e, ecx| {
                    e.run_command("editor.action.rename", ecx);
                });
            }
            "terminal.new" => self.show_tool(ToolWindow::Terminal, window, cx),
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
            "run.debug" => self.show_tool(ToolWindow::Debug, window, cx),
            "run.configurations" => self.show_tool(ToolWindow::Run, window, cx),
            "run.stop" | "run.toggleBreakpoint" => {}
            "tools.agent" => self.show_tool(ToolWindow::Agent, window, cx),
            "tools.database" => self.show_tool(ToolWindow::Database, window, cx),
            "tools.services" => self.show_tool(ToolWindow::Services, window, cx),
            "tools.webInspector" => {
                self.editor
                    .update(cx, |editor, editor_cx| editor.open_devtools(editor_cx));
            }
            "tools.keyboardShortcuts" | "help.keyboardShortcuts" => {
                self.toggle_settings(window, cx)
            }
            "window.minimize" => window.minimize_window(),
            "window.zoom" | "window.fullscreen" => window.zoom_window(),
            "window.close" => window.remove_window(),
            "help.documentation" | "help.repository" => {
                self.platform
                    .open_url("https://github.com/Lithe-IDEA/Lithe-IDEA");
            }
            "help.whatsNew" => {
                self.platform
                    .open_url("https://github.com/Lithe-IDEA/Lithe-IDEA/releases");
            }
            "help.changelog" => {
                self.platform
                    .open_url("https://github.com/Lithe-IDEA/Lithe-IDEA/blob/preview/CHANGELOG.md");
            }
            "help.reportBug" => {
                self.platform.open_url(
                    "https://github.com/Lithe-IDEA/Lithe-IDEA/issues/new?template=bug_report.yml",
                );
            }
            "help.requestFeature" => {
                self.platform.open_url("https://github.com/Lithe-IDEA/Lithe-IDEA/issues/new?template=feature_request.yml");
            }
            "help.checkUpdates" => {
                self.push_notification(
                    tr("Updates"),
                    Some(tr("Updates are not available in this GPUI build.").into()),
                    super::notifications::NotificationKind::Info,
                );
            }
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
            cmd if cmd.starts_with("view.language.") => {
                let code = &cmd["view.language.".len()..];
                self.settings.language = code.to_string();
                self.save_settings(cx);
                lithe_ui::i18n::set_language(code);
                self.install_menus(cx);
                cx.notify();
            }
            _ => {}
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
