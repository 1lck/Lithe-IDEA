use std::path::{Path, PathBuf};

use gpui_kit::component::TitleBar;
use gpui_kit::{
    AppContext as _, Context, SharedString, Task, Window, WindowBounds, WindowOptions, px, size,
};
use lithe_features::settings::SettingsContext;
use lithe_features::{format_memory, process_memory_bytes, AppSettings};
use lithe_ui::i18n::tr;
use lithe_ui::install_theme;

use super::dock::ToolWindow;
use super::notifications::NotificationKind;
use super::{theme_kind_for, Workbench, MEMORY_REFRESH_INTERVAL};
use crate::layout;
use crate::workspace_layout;

impl Workbench {
    pub fn open_project(&mut self, root: PathBuf, window: &mut Window, cx: &mut Context<Self>) {
        if !root.is_dir() {
            self.status_message = Some(tr("Project folder is not available").into());
            cx.notify();
            return;
        }

        if let Some(previous) = self
            .project_root
            .as_ref()
            .filter(|previous| *previous != &root)
        {
            self.persist_layout_for(previous);
        }

        self.project_root = Some(root.clone());
        self.apply_layout(workspace_layout::load(&root), cx);
        self.layout_root = Some(root.clone());
        self.layout_restored = true;
        self.platform.remember_project(&root);
        self.project_menu_visible = false;
        self.branch_menu_visible = false;
        self.recent_projects = self.platform.recent_projects();

        self.project_tree.update(cx, |tree, tree_cx| {
            tree.set_root(root.clone(), window, tree_cx);
        });

        let welcome = self.welcome.clone();
        cx.defer_in(window, move |_this, _window, cx| {
            welcome.update(cx, |view, view_cx| view.refresh_recent(view_cx));
        });

        self.clear_editor(window, cx);
        self.status_message = None;

        self.branch = SharedString::from(tr("main"));
        self.git_change_count = 0;
        self.branch_refresh_generation = self.branch_refresh_generation.wrapping_add(1);
        self.branch_refresh_pending = false;
        self._branch_task = Task::ready(());

        self.branches.clear();
        self.branches_loading = false;
        self.branch_error = None;
        self.branch_generation = self.branch_generation.wrapping_add(1);
        self._branches_task = Task::ready(());
        self._checkout_task = Task::ready(());

        self.open_generation = self.open_generation.wrapping_add(1);
        self._read_task = Task::ready(());
        self.quick_files.clear();
        self.refresh_quick_index(window, cx);
        self.refresh_branch(window, cx);
        if self.settings_visible {
            self.sync_settings_context(cx);
        }
        cx.notify();
    }

    pub(super) fn clear_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.close_editor_split(cx);
        self.tabs.clear();
        self.active_tab = None;
        self.pending_close_tab = None;
        self.cursor_line = 1;
        self.cursor_column = 1;
        self.problems.clear();
        self.hide_preview();
        self.editor
            .update(cx, |editor, editor_cx| editor.clear(window, editor_cx));
        self.sync_panel_roots(window, cx);
    }

    pub(super) fn sync_panel_roots(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let root = self.project_root.clone().unwrap_or_default();
        self.git.update(cx, |panel, panel_cx| {
            panel.set_root(root.clone(), window, panel_cx)
        });
        self.git_log.update(cx, |panel, panel_cx| {
            panel.set_root(root.clone(), window, panel_cx)
        });
        self.search.update(cx, |panel, panel_cx| {
            panel.set_root(root.clone(), window, panel_cx)
        });
        self.run_panel.update(cx, |panel, panel_cx| {
            panel.set_root(root.clone(), window, panel_cx)
        });
        self.terminal.update(cx, |panel, panel_cx| {
            panel.set_root(root.clone(), window, panel_cx)
        });
        if let Some(panel) = self.terminal_secondary.clone() {
            panel.update(cx, |panel, panel_cx| {
                panel.set_root(root.clone(), window, panel_cx);
            });
        }
        self.agent
            .update(cx, |panel, panel_cx| panel.set_root(root, window, panel_cx));
    }

    pub(super) fn pick_project(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let platform = self.platform.clone();
        let title = tr("Open Project").to_string();
        cx.spawn_in(window, async move |this, cx| {
            let root = platform.pick_folder(title).await;
            let Some(root) = root else {
                return;
            };
            let _ = this.update_in(cx, |this, window, cx| {
                this.open_project(root, window, cx);
            });
        })
        .detach();
    }

    pub(super) fn close_current_project(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.project_root.take() else {
            return;
        };
        self.persist_layout_for(&root);
        self.layout_root = None;
        self.tabs.clear();
        self.active_tab = None;
        self.problems.clear();
        self.status_message = None;
        cx.notify();
    }

    pub(super) fn refresh_project_tree(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let tree = self.project_tree.clone();
        tree.update(cx, |t, cx| t.refresh(window, cx));
    }

    pub(super) fn start_memory_loop(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self._memory_task = cx.spawn_in(window, async move |this, cx| {
            loop {
                let measured = cx
                    .background_spawn(async { process_memory_bytes().map(format_memory) })
                    .await;
                let text = measured
                    .map(SharedString::from)
                    .unwrap_or_else(|| SharedString::from("—"));

                let alive = this.update_in(cx, move |this, _window, cx| {
                    let visible = this.settings_visible;
                    this.memory_text = text;
                    if visible {
                        this.sync_settings_context(cx);
                    }
                    cx.notify();
                });
                if alive.is_err() {
                    break;
                }

                cx.background_executor()
                    .timer(MEMORY_REFRESH_INTERVAL)
                    .await;
            }
        });
    }

    pub(super) fn settings_context(&self, cx: &Context<Self>) -> SettingsContext {
        SettingsContext {
            project_root: self.project_root.clone(),
            branch: self.branch.to_string(),
            memory: self.memory_text.to_string(),
            agent_status: self.agent.read(cx).status_summary(),
        }
    }

    pub(super) fn sync_settings_context(&mut self, cx: &mut Context<Self>) {
        let Some(view) = self.settings_view.clone() else {
            return;
        };
        let context = self.settings_context(cx);
        view.update(cx, |view, view_cx| view.set_context(context, view_cx));
    }

    pub(super) fn sync_settings_view(&mut self, cx: &mut Context<Self>) {
        let Some(view) = self.settings_view.clone() else {
            return;
        };
        let settings = self.settings.clone();
        view.update(cx, |view, view_cx| view.set_settings(settings, view_cx));
    }

    pub(super) fn apply_settings(
        &mut self,
        settings: AppSettings,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let theme_changed =
            settings.theme != self.settings.theme || settings.dark != self.settings.dark;
        let language_changed = settings.language != self.settings.language;
        self.settings = settings;
        if language_changed {
            lithe_ui::i18n::set_language(&self.settings.language);
        }
        if theme_changed {
            let kind = theme_kind_for(&self.settings.theme);
            install_theme(cx, kind, self.settings.dark);
        }
        self.apply_editor_preferences(window, cx);
        self.apply_terminal_preferences(window, cx);
        if language_changed {
            self.refresh_localized_views(cx);
            cx.refresh_windows();
        }
        cx.notify();
    }

    pub(super) fn refresh_localized_views(&mut self, cx: &mut Context<Self>) {
        self.project_tree.update(cx, |_, cx| cx.notify());
        self.editor.update(cx, |_, cx| cx.notify());
        self.git.update(cx, |_, cx| cx.notify());
        self.git_log.update(cx, |_, cx| cx.notify());
        self.search.update(cx, |_, cx| cx.notify());
        self.terminal.update(cx, |_, cx| cx.notify());
        if let Some(panel) = self.terminal_secondary.clone() {
            panel.update(cx, |_, cx| cx.notify());
        }
        self.agent.update(cx, |_, cx| cx.notify());
        self.run_panel.update(cx, |_, cx| cx.notify());
        self.welcome.update(cx, |_, cx| cx.notify());
    }

    pub(super) fn show_placeholder(&mut self, action: &'static str, cx: &mut Context<Self>) {
        self.status_message = Some(format!("{action} · {}", tr("Not available yet")).into());
        cx.notify();
    }

    pub(super) fn open_new_window(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        cx.defer_in(window, |this, _window, cx| {
            let mut titlebar = TitleBar::title_bar_options();
            titlebar.title = Some("Lithe".into());

            let options = WindowOptions {
                window_bounds: Some(WindowBounds::centered(size(px(1280.), px(800.)), cx)),
                window_min_size: Some(size(px(980.), px(640.))),
                titlebar: Some(titlebar),
                app_owns_titlebar_drag: true,
                #[cfg(target_os = "linux")]
                window_decorations: Some(gpui_kit::WindowDecorations::Client),
                app_id: Some("lithe-desktop".into()),
                ..TitleBar::window_options()
            };

            let opened = gpui_kit::open_window(options, cx, |window, app| {
                app.new(|app| Workbench::new(window, app))
            });

            if let Err(error) = opened {
                this.push_notification(
                    tr("New Window"),
                    SharedString::from(error.to_string()),
                    NotificationKind::Error,
                );
                cx.notify();
            }
        });
    }

    pub(super) fn apply_theme_to_workbench(&mut self, cx: &mut Context<Self>) {
        let kind = theme_kind_for(&self.settings.theme);
        install_theme(cx, kind, self.settings.dark);
        cx.notify();
    }

    pub(super) fn save_settings(&mut self, _cx: &mut Context<Self>) {
        self.settings.save();
    }

    pub(super) fn apply_layout(&mut self, layout: workspace_layout::WorkspaceLayout, cx: &mut Context<Self>) {
        self.active_left = ToolWindow::from_id(&layout.active_left)
            .filter(|tool| tool.anchor() == super::dock::DockAnchor::Left)
            .unwrap_or(ToolWindow::Project);
        self.active_bottom = layout
            .active_bottom
            .as_deref()
            .and_then(ToolWindow::from_id)
            .filter(|tool| tool.anchor() == super::dock::DockAnchor::Bottom);
        self.active_right = layout
            .active_right
            .as_deref()
            .and_then(ToolWindow::from_id)
            .filter(|tool| tool.anchor() == super::dock::DockAnchor::Right);
        self.left_visible = layout.left_visible;
        self.bottom_visible = layout.bottom_visible && self.active_bottom.is_some();
        self.right_visible = layout.right_visible && self.active_right.is_some();
        self.left_width = layout.left_width.clamp(
            layout::LEFT_PANEL_MIN_WIDTH.as_f32(),
            layout::LEFT_PANEL_MAX_WIDTH.as_f32(),
        );
        self.right_width = layout.right_width.clamp(
            layout::RIGHT_PANEL_MIN_WIDTH.as_f32(),
            layout::RIGHT_PANEL_MAX_WIDTH.as_f32(),
        );
        self.bottom_height = layout.bottom_height.clamp(
            layout::BOTTOM_PANEL_MIN_HEIGHT.as_f32(),
            layout::BOTTOM_PANEL_MAX_HEIGHT.as_f32(),
        );
        self.horizontal_state.update(cx, |state, _| state.clear());
        self.vertical_state.update(cx, |state, _| state.clear());
    }

    pub(super) fn persist_layout_for(&self, root: &Path) {
        let layout = workspace_layout::WorkspaceLayout {
            active_left: self.active_left.id().to_string(),
            active_bottom: self.active_bottom.map(|t| t.id().to_string()),
            active_right: self.active_right.map(|t| t.id().to_string()),
            left_visible: self.left_visible,
            bottom_visible: self.bottom_visible,
            right_visible: self.right_visible,
            left_width: self.left_width,
            right_width: self.right_width,
            bottom_height: self.bottom_height,
        };
        workspace_layout::save(root, &layout);
    }
}
