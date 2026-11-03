use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use gpui_kit::component::TitleBar;
use gpui_kit::{
    AppContext as _, Context, SharedString, Task, Window, WindowBounds, WindowOptions, px, size,
};
use lithe_features::editor::DiskChangeOutcome;
use lithe_features::settings::SettingsContext;
use lithe_features::{AppSettings, format_memory, process_memory_bytes};
use lithe_ui::i18n::tr;
use lithe_ui::install_theme;

use super::dock::ToolWindow;
use super::notifications::NotificationKind;
use super::{MEMORY_REFRESH_INTERVAL, Workbench, theme_kind_for};
use crate::layout;
use crate::workspace_layout;

/// 布局/会话落盘的去抖窗口，对齐 macOS `scheduleWorkspaceSessionPersistence`
/// 的 150ms 节流：连续切标签只在最后一次之后写一次盘。
const LAYOUT_PERSIST_DELAY: Duration = Duration::from_millis(150);

/// 外部磁盘变更的去抖窗口：事件到达后再等这一小段，把构建、批量保存这类
/// 连续磁盘活动合成一次项目树刷新和一次活动文档检查。
const FILE_WATCH_DEBOUNCE: Duration = Duration::from_millis(200);

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
            // 切走之前把旧工作区的锚点布局和标签会话一起落盘，并取消还在
            // 排队的节流任务，避免旧快照在新状态之后才写入磁盘。
            let previous = previous.clone();
            self.persist_layout_now(&previous);
        }

        // 会话与锚点布局同一次读取：旧文件没有会话字段时就是空列表。
        let stored = workspace_layout::load(&root);
        let (open_paths, active_path) = (stored.open_paths.clone(), stored.active_path.clone());

        self.project_root = Some(root.clone());
        self.java_language
            .update(cx, |model, cx| model.set_root(Some(root.clone()), cx));
        self.apply_layout(stored, cx);
        self.layout_root = Some(root.clone());
        self.layout_restored = true;
        self.platform.remember_project(&root);
        lithe_features::logging::log_info(
            "app",
            format!("opened project {}", root.display()),
        );
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
        // 项目一打开就开始监听磁盘：项目树、Git 元数据和当前文档都要跟随
        // 外部变化。监听失败只提示，不会让项目打不开。
        self.start_file_watcher(&root, window, cx);
        // 标签、编辑器文档和打开代次都已就绪，最后按顺序恢复上次的编辑器
        // 会话；恢复异步读盘，失败的文件由它自己汇总提示。
        self.restore_session_tabs(open_paths, active_path, window, cx);
        if self.settings_visible {
            self.sync_settings_context(cx);
        }
        cx.notify();
    }

    pub(super) fn clear_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // 提交差异页属于上一个工作区：关掉页面、清空旧根并丢弃待确认的
        // 丢弃请求，否则差异仍渲染旧仓库内容，hunk 按钮也会继续作用于旧
        // 仓库（数据安全）。
        self.close_commit_diff(cx);
        self.commit_diff
            .update(cx, |view, diff_cx| view.set_root(None, diff_cx));
        // 作废所有在途读盘与会话恢复：旧项目的结果不能再装进新工作区或
        // 已经关闭的工作区。恢复任务在派生时记录代次，这里递增后随之启动
        // 的恢复任务记录的是递增后的值，不会被自己误伤。
        self.open_generation = self.open_generation.wrapping_add(1);
        self._read_task = Task::ready(());
        self._watch_read_task = Task::ready(());
        self.pending_reveal = None;
        self.close_editor_split(cx);
        self.tabs.clear();
        self.active_tab = None;
        self.pending_close_tab = None;
        self.pending_close_queue.clear();
        self.pending_close_saving = false;
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
        self.maven.update(cx, |panel, panel_cx| {
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

    pub(crate) fn pick_project(&mut self, window: &mut Window, cx: &mut Context<Self>) {
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

    pub(super) fn close_current_project(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(root) = self.project_root.take() else {
            return;
        };
        // 项目已经关闭：先停掉监视并作废所有在途事件，再清理编辑器状态。
        self.stop_file_watcher();
        self.java_language
            .update(cx, |model, cx| model.stop(cx));
        self.persist_layout_now(&root);
        self.layout_root = None;
        // 关项目必须与 `open_project` 对称：标签、编辑器文档、右分栏、Markdown
        // 预览和导航历史都属于上一个工作区。留下任何一项，新项目都会看到旧
        // 文件内容，`sync_editor_secondary` 还会对已关闭的文件继续发指令。
        self.clear_editor(window, cx);
        self.closed_tabs.clear();
        self.nav_back.clear();
        self.nav_forward.clear();
        self.status_message = None;
        self.branch_refresh_generation = self.branch_refresh_generation.wrapping_add(1);
        self._branch_task = Task::ready(());
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
        self.apply_git_preferences(cx);
        self.apply_hidden_patterns(cx);
        // 提交区的 AI 按钮可用性跟着设置页里的开关走。
        let ai_commit_enabled = self.settings.ai_commit_enabled;
        self.git.update(cx, |panel, cx| {
            panel.set_ai_commit_enabled(ai_commit_enabled, cx)
        });
        self.git_log.update(cx, |panel, cx| {
            panel.set_ai_commit_enabled(ai_commit_enabled, cx)
        });
        if language_changed {
            self.refresh_localized_views(cx);
            cx.refresh_windows();
        }
        cx.notify();
    }

    /// 把 Git 设置注入两个 Git 面板（提交区 + 日志）。
    pub(super) fn apply_git_preferences(&mut self, cx: &mut Context<Self>) {
        let folder_view = self.settings.git_changes_folder_view;
        let confirm_discard = self.settings.git_confirm_discard;
        let show_untracked = self.settings.git_show_untracked;
        let show_staged_first = self.settings.git_show_staged_first;
        let show_changelists = self.settings.show_git_changelists;
        for panel in [self.git.clone(), self.git_log.clone()] {
            panel.update(cx, |panel, panel_cx| {
                panel.set_git_preferences(
                    folder_view,
                    confirm_discard,
                    show_untracked,
                    show_staged_first,
                    panel_cx,
                );
                // changelist 栏可见性跟随设置（Tauri `showGitChangelists`）。
                panel.set_changelist_preferences(show_changelists, panel_cx);
            });
        }
    }

    /// 把隐藏路径模式注入项目树；模式变化时树会自动重载。
    pub(super) fn apply_hidden_patterns(&mut self, cx: &mut Context<Self>) {
        let directories = self.settings.hidden_directory_patterns.clone();
        let files = self.settings.hidden_file_patterns.clone();
        self.project_tree.update(cx, |tree, tree_cx| {
            tree.set_hidden_patterns(directories, files, tree_cx);
        });
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
                    Some(SharedString::from(error.to_string())),
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

    pub(super) fn apply_layout(
        &mut self,
        layout: workspace_layout::WorkspaceLayout,
        cx: &mut Context<Self>,
    ) {
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
    }

    /// 当前工作区要写盘的完整快照：锚点布局 + 编辑器标签会话。
    ///
    /// `root` 必须是被持久化的工作区根：切项目时调用点的 `project_root` 可能
    /// 已经改成了新项目，标签相对路径必须相对旧根计算。
    fn workspace_layout_snapshot(&self, root: &Path) -> workspace_layout::WorkspaceLayout {
        workspace_layout::WorkspaceLayout {
            active_left: self.active_left.id().to_string(),
            active_bottom: self.active_bottom.map(|t| t.id().to_string()),
            active_right: self.active_right.map(|t| t.id().to_string()),
            left_visible: self.left_visible,
            bottom_visible: self.bottom_visible,
            right_visible: self.right_visible,
            left_width: self.left_width,
            right_width: self.right_width,
            bottom_height: self.bottom_height,
            open_paths: self.session_open_paths(root),
            active_path: self.session_active_path(root),
        }
    }

    /// 会话里记录的标签路径（工作区相对、`/` 分隔、按标签顺序）。
    ///
    /// 未命名标签没有磁盘路径，直接跳过；工作区外的文件也不记录，恢复时
    /// 不会被带回来。
    fn session_open_paths(&self, root: &Path) -> Vec<String> {
        let mut paths: Vec<String> = Vec::new();
        let mut seen: Vec<String> = Vec::new();
        for tab in &self.tabs {
            if tab.id.starts_with("untitled:") {
                continue;
            }
            let Some(relative) = super::tabs::workspace_relative_option(root, &tab.absolute_path)
            else {
                continue;
            };
            // Windows 上同一文件可能因为大小写不同产生两个 id，恢复前先去重。
            let identity = super::tabs::file_identity(&tab.absolute_path);
            if seen.contains(&identity) {
                continue;
            }
            seen.push(identity);
            paths.push(relative);
        }
        paths
    }

    /// 上次的活动标签；未命名标签或空工作区记 `None`，恢复时退回最后一个标签。
    fn session_active_path(&self, root: &Path) -> Option<String> {
        if self.is_active_tab_untitled() {
            return None;
        }
        let absolute = self.active_tab_path()?;
        super::tabs::workspace_relative_option(root, &absolute)
    }

    /// 立即把某个工作区的完整状态写盘，并取消还在排队的节流任务。
    ///
    /// 切项目、关闭项目、退出这类「马上就不会再有当前状态」的时机必须走这里，
    /// 不能等去抖窗口。
    pub(super) fn persist_layout_now(&mut self, root: &Path) {
        self.pending_layout = None;
        self.layout_persist_pending = false;
        self._layout_persist_task = Task::ready(());
        workspace_layout::save(root, &self.workspace_layout_snapshot(root));
    }

    /// 当前工作区的即时写盘，用于退出入口。
    pub(super) fn flush_layout_persist(&mut self) {
        let Some(root) = self.layout_root.clone() else {
            return;
        };
        self.persist_layout_now(&root);
    }

    /// 标签变化后的排队写盘：150ms 内的连续操作只写最后一次。
    ///
    /// 快照在调用线程上同步取好（GPUI 状态只能在主线程读取），去抖窗口结束
    /// 后在主线程用现有的原子写落盘：文件很小，一次写入只有几毫秒，换来的是
    /// 不会和即时写盘并发覆盖同一个 store。已有排队任务时不重复派生，它醒来
    /// 时取的是最新快照。
    pub(super) fn schedule_layout_persist(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.layout_root.clone() else {
            return;
        };
        let layout = self.workspace_layout_snapshot(&root);
        self.pending_layout = Some((root, layout));
        if self.layout_persist_pending {
            return;
        }
        self.layout_persist_pending = true;
        self._layout_persist_task = cx.spawn(async move |this, cx| {
            cx.background_executor().timer(LAYOUT_PERSIST_DELAY).await;
            let _ = this.update(cx, |this, _cx| {
                this.layout_persist_pending = false;
                if let Some((root, layout)) = this.pending_layout.take() {
                    workspace_layout::save(&root, &layout);
                }
            });
        });
    }

    /// 启动（或重启）当前项目的递归文件监视。
    ///
    /// 生命周期对齐 macOS `MacDirectoryWatcher`：一个工作区一个监视器，
    /// 切换/关闭项目时整体丢弃。启动失败只提示一次并继续工作，不能因为
    /// 监视失败就让项目打不开。
    pub(super) fn start_file_watcher(
        &mut self,
        root: &Path,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.stop_file_watcher();
        self.watch_generation = self.watch_generation.wrapping_add(1);
        let generation = self.watch_generation;

        let (sender, receiver) = std::sync::mpsc::channel::<lithe_platform::WatchEvent>();
        match lithe_platform::watch_tree(root, move |event| {
            // notify 的后台线程：只把事件交给接收任务，不碰 UI 状态。
            let _ = sender.send(event);
        }) {
            Ok(watcher) => self._file_watcher = Some(watcher),
            Err(error) => {
                self.status_message = Some(
                    SharedString::from(format!(
                        "{}: {error}",
                        tr("File watching is unavailable for this project.")
                    )),
                );
                self.push_notification(
                    tr("File watching is unavailable for this project."),
                    Some(SharedString::from(error)),
                    NotificationKind::Warning,
                );
                cx.notify();
            }
        }

        // 接收任务阻塞在一段后台 future 的 `recv` 上：事件到达即醒，不轮询，
        // 也不阻塞 UI 线程。监视器被丢弃时发送端随之关闭，`recv` 返回错误，
        // 任务自行结束（与 `stop_file_watcher` 的丢弃顺序配合）。
        let slot = Arc::new(Mutex::new(Some(receiver)));
        self._watch_task = cx.spawn_in(window, async move |this, cx| loop {
            let slot = slot.clone();
            let received = cx
                .background_spawn(async move {
                    // 先把接收端取出来再阻塞：`MutexGuard` 不跨线程持有，
                    // 阻塞期间也不占着锁。
                    let receiver = slot.lock().ok()?.take()?;
                    let event = receiver.recv().ok();
                    if let Ok(mut slot) = slot.lock() {
                        *slot = Some(receiver);
                    }
                    event
                })
                .await;
            let Some(event) = received else {
                break;
            };
            let alive = this.update_in(cx, move |this, window, cx| {
                // 旧项目的在途事件：代次已经变了，直接丢弃。
                if this.watch_generation != generation {
                    return;
                }
                this.accept_watch_event(event, window, cx);
            });
            if alive.is_err() {
                break;
            }
        });
    }

    /// 停止文件监视并丢弃所有待处理事件。
    pub(super) fn stop_file_watcher(&mut self) {
        // 先递增代次：即使还有事件被搬回 UI 线程，也会在入口被丢弃。
        self.watch_generation = self.watch_generation.wrapping_add(1);
        // 丢 watcher：它的回调持有发送端，接收任务随后拿到错误并结束。
        self._file_watcher = None;
        self._watch_task = Task::ready(());
        self._watch_flush_task = Task::ready(());
        self._watch_read_task = Task::ready(());
        self.pending_watch_paths.clear();
        self.pending_watch_rescan = false;
        self.watch_flush_pending = false;
    }

    /// 接收一批磁盘事件：先累积，等去抖窗口结束统一处理。
    fn accept_watch_event(
        &mut self,
        event: lithe_platform::WatchEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if event.paths.is_empty() && !event.requires_rescan {
            return;
        }
        self.pending_watch_paths.extend(event.paths);
        self.pending_watch_rescan |= event.requires_rescan;
        self.schedule_watch_flush(window, cx);
    }

    /// 外部变更的去抖：200ms 内的连续事件只处理一次。
    ///
    /// 与 [`Self::schedule_layout_persist`] 同一套写法：已有排队任务时不再
    /// 重复派生，它醒来时处理的是累积后的完整批次。
    fn schedule_watch_flush(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.watch_flush_pending {
            return;
        }
        self.watch_flush_pending = true;
        self._watch_flush_task = cx.spawn_in(window, async move |this, cx| {
            cx.background_executor().timer(FILE_WATCH_DEBOUNCE).await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.watch_flush_pending = false;
                this.flush_watch_events(window, cx);
            });
        });
    }

    /// 去抖窗口结束后的实际处理：刷新项目树，并检查活动文档。
    fn flush_watch_events(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let paths = std::mem::take(&mut self.pending_watch_paths);
        let rescan = std::mem::replace(&mut self.pending_watch_rescan, false);
        let Some(root) = self.project_root.clone() else {
            return;
        };
        let generation = self.watch_generation;

        // 自己保存和项目元数据（`.git` / `.lithe`）都不改变项目内容：
        // 前者按写盘时间窗口识别，后者与项目树无关。
        let mut changed: Vec<PathBuf> = Vec::with_capacity(paths.len());
        for path in paths {
            if is_workspace_metadata_path(&root, &path) {
                continue;
            }
            if self
                .editor
                .update(cx, |editor, _| editor.is_recent_self_write(&path))
            {
                continue;
            }
            changed.push(path);
        }

        if changed.is_empty() && !rescan {
            return;
        }

        // a. 项目树整树刷新：清空目录缓存后按已展开路径重新请求，保留展开状态。
        self.refresh_project_tree(window, cx);

        // b. 命中事件的已打开标签：活动文档交给编辑器决定重载还是提示冲突；
        //    后台标签也按各自路径同步磁盘文本，否则切回后保存会把磁盘上的
        //    新内容覆盖掉。
        let active = self
            .active_tab_path()
            .filter(|_| !self.is_active_tab_untitled());
        let active_identity = active.as_deref().map(super::tabs::file_identity);

        // 未命中的标签不读盘：构建、批量保存这类活动会带来大量事件，逐个
        // 读盘只会白白拖慢 UI 线程和 Core。事件路径先去重成集合，避免为每个
        // 标签把整批路径再扫一遍。
        let changed_identities: std::collections::HashSet<String> = changed
            .iter()
            .map(|path| super::tabs::file_identity(path))
            .collect();
        let mut active_target: Option<(PathBuf, String)> = None;
        let mut background_targets: Vec<(PathBuf, String)> = Vec::new();
        let mut background_conflicts: usize = 0;
        for tab in &self.tabs {
            if tab.id.starts_with("untitled:") {
                continue;
            }
            let identity = super::tabs::file_identity(&tab.absolute_path);
            let hit = rescan || changed_identities.contains(&identity);
            if !hit {
                continue;
            }
            // 删除/重命名给的是已经不存在的路径：不重载，保留用户内容。
            if !tab.absolute_path.exists() {
                continue;
            }
            let Some(relative) = super::tabs::workspace_relative_option(&root, &tab.absolute_path)
            else {
                continue;
            };
            if Some(identity.as_str()) == active_identity.as_deref() {
                active_target = Some((tab.absolute_path.clone(), relative));
            } else if tab.modified {
                // 有未保存修改的后台标签不能自动覆盖：本轮只在状态栏汇总
                // 提示，逐标签的冲突 UI 留给后续迭代。
                background_conflicts += 1;
            } else {
                background_targets.push((tab.absolute_path.clone(), relative));
            }
        }

        if background_conflicts > 0 {
            self.status_message = Some(
                format!(
                    "{} ({})",
                    tr("Background tabs changed on disk while having unsaved edits"),
                    background_conflicts
                )
                .into(),
            );
        }
        if active_target.is_none() && background_targets.is_empty() {
            if background_conflicts > 0 {
                cx.notify();
            }
            return;
        }

        let client = self.client;
        let read_root = root.clone();
        let task_root = root.clone();
        let active_identity_for_task = active_identity.clone();
        self._watch_read_task = cx.spawn_in(window, async move |this, cx| {
            // 同一批事件命中多个文件时顺序读盘：结果顺序稳定，也不会同时
            // 向 Core 压上一串并发请求。
            let mut active_text: Option<(PathBuf, String)> = None;
            if let Some((absolute, relative)) = active_target {
                let read_root = read_root.clone();
                if let Ok(file) = cx
                    .background_spawn(async move { client.read_file(&read_root, &relative) })
                    .await
                {
                    active_text = Some((absolute, file.text));
                }
            }
            let mut background_texts: Vec<(PathBuf, String)> = Vec::new();
            for (absolute, relative) in background_targets {
                let read_root = read_root.clone();
                let Ok(file) = cx
                    .background_spawn(async move { client.read_file(&read_root, &relative) })
                    .await
                else {
                    // 读取失败（权限、编码、已删除）：保留标签里的旧内容，
                    // 不制造假的外部修改。
                    continue;
                };
                background_texts.push((absolute, file.text));
            }

            let _ = this.update_in(cx, move |this, window, cx| {
                // 项目已关闭或切换：这批结果属于旧工作区。
                if this.watch_generation != generation {
                    return;
                }
                let mut needs_notify = false;

                // c. 活动文档：用户在读盘期间切了标签的话，结果不再属于当前
                //    文档，直接丢弃。
                if let Some((read_path, text)) = active_text {
                    let still_active = this
                        .active_tab_path()
                        .map(|path| super::tabs::file_identity(&path))
                        .as_deref()
                        == active_identity_for_task.as_deref();
                    if still_active && read_path.exists() {
                        let outcome = this.editor.update(cx, |editor, editor_cx| {
                            editor.handle_disk_change(
                                &task_root,
                                &read_path,
                                text.clone(),
                                window,
                                editor_cx,
                            )
                        });
                        match outcome {
                            DiskChangeOutcome::Reloaded => {
                                let identity = super::tabs::file_identity(&read_path);
                                if let Some(tab) = this.tabs.iter_mut().find(|tab| {
                                    super::tabs::file_identity(&tab.absolute_path) == identity
                                }) {
                                    // 标签缓存必须跟着磁盘内容走，否则切走
                                    // 再切回来会重新装回旧文本。
                                    tab.text = text.clone();
                                    tab.modified = false;
                                }
                                this.status_message =
                                    Some(tr("Loaded file-system version").into());
                                this.push_notification(
                                    tr("Loaded file-system version"),
                                    Some(super::tabs::file_title(&read_path)),
                                    NotificationKind::Info,
                                );
                                // 分屏只读窗格与 Markdown 预览都展示同一份
                                // 内容，跟着重载结果一起刷新。
                                this.sync_editor_secondary(window, cx);
                                this.sync_preview_with_active_tab(cx);
                                needs_notify = true;
                            }
                            DiskChangeOutcome::Conflict => {
                                this.status_message = Some(
                                    tr("External edits conflict with unsaved changes").into(),
                                );
                                needs_notify = true;
                            }
                            DiskChangeOutcome::Ignored => {}
                        }
                    }
                }

                // d. 后台标签：只同步读盘期间仍然未修改、且仍然不是活动
                //    文档的标签，避免覆盖用户刚输入的内容。
                let active_now = this
                    .active_tab_path()
                    .map(|path| super::tabs::file_identity(&path));
                for (path, text) in background_texts {
                    let identity = super::tabs::file_identity(&path);
                    if active_now.as_deref() == Some(identity.as_str()) {
                        // 读盘期间用户切到了这个标签：交给活动文档流程。
                        continue;
                    }
                    let Some(tab) = this
                        .tabs
                        .iter_mut()
                        .find(|tab| super::tabs::file_identity(&tab.absolute_path) == identity)
                    else {
                        continue;
                    };
                    if tab.modified || tab.text == text {
                        continue;
                    }
                    tab.text = text.clone();
                    // 后台标签不在编辑区，只能同步文本缓存；切回时
                    // `open_file` 会从这里装回最新磁盘内容。
                    this.editor.update(cx, |editor, _editor_cx| {
                        editor.replace_cached_text(&task_root, &path, text);
                    });
                    needs_notify = true;
                }

                if needs_notify {
                    cx.notify();
                }
            });
        });
    }

    /// 某个工作区是否选择过「对此工作区始终继续」。
    pub(super) fn java_build_always_continue(&self, root: &Path) -> bool {
        let key = super::tabs::file_identity(root);
        self.settings
            .java_build_failure_always_continue
            .iter()
            .any(|entry| super::tabs::file_identity(Path::new(entry)) == key)
    }

    /// 记录或清除工作区的 Java 构建失败策略。
    pub(super) fn set_java_build_always_continue(
        &mut self,
        root: &Path,
        enabled: bool,
        cx: &mut Context<Self>,
    ) {
        let key = super::tabs::file_identity(root);
        self.settings
            .java_build_failure_always_continue
            .retain(|entry| super::tabs::file_identity(Path::new(entry)) != key);
        if enabled {
            self.settings.java_build_failure_always_continue.push(key);
        }
        self.save_settings(cx);
        cx.notify();
    }
}

/// 路径是否位于项目元数据目录（`.git` / `.lithe`）内部。
///
/// 这两类目录的变化不改变项目树结构：`.git` 由 Git 面板自己刷新，`.lithe`
/// 是本应用写会话/布局的位置（工作区的 walrus 数据也在应用数据目录，不在
/// 项目内）。把它们挡在外面，避免每次保存或切标签都触发整树重扫。
///
/// 相对路径解析复用工作台统一的 `workspace_relative_option`：Windows 上
/// 项目根和事件路径的大小写/分隔符写法可能不同。
fn is_workspace_metadata_path(root: &Path, path: &Path) -> bool {
    let Some(relative) = super::tabs::workspace_relative_option(root, path) else {
        return false;
    };
    let first = relative.split('/').next().unwrap_or_default();
    first.eq_ignore_ascii_case(".git") || first.eq_ignore_ascii_case(".lithe")
}
