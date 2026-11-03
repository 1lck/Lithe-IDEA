use std::path::{Path, PathBuf};

use gpui_kit::component::menu::{PopupMenu, PopupMenuItem};
use gpui_kit::{
    AppContext as _, Context, DismissEvent, Focusable as _, Pixels, Point, SharedString, Window,
};
use lithe_core_client::FileReadResult;
use lithe_ui::i18n::tr;
use lithe_ui::icons::LitheIcon;

use super::notifications::NotificationKind;
use super::Workbench;

/// 一个打开的文件标签。
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct OpenTab {
    pub(super) id: SharedString,
    pub(super) title: SharedString,
    pub(super) display_path: SharedString,
    pub(super) absolute_path: PathBuf,
    pub(super) text: String,
    pub(super) icon: LitheIcon,
    pub(super) modified: bool,
}

impl Workbench {
    pub(super) fn open_file_from_tree(
        &mut self,
        requested: PathBuf,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.open_file_from_tree_with_history(requested, true, window, cx);
    }

    /// 打开文件并跳转到指定行（搜索结果、诊断等入口）。
    ///
    /// 行号是 1-based；打开沿用 `open_file_from_tree` 的完整链路（含历史、
    /// 去重与标签激活）。目标已经是活动文档时当场跳行；需要读盘时只记下
    /// 待跳转请求，等 `install_file` 把文档真正装上后再交给编辑器，避免
    /// 对着还没打开的上一个文档定位。
    pub(super) fn open_file_at_line(
        &mut self,
        requested: PathBuf,
        line: u32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.open_file_from_tree(requested.clone(), window, cx);

        // 打开失败（无工作区、越界路径）时 `open_file_from_tree` 已经给出
        // 提示；这里解析不出绝对路径就直接放弃跳行。
        let Some(root) = self.project_root.clone() else {
            return;
        };
        let Ok((absolute, _relative)) = resolve_project_file(&root, &requested) else {
            return;
        };

        if self.active_tab_path().as_deref() == Some(absolute.as_path()) {
            self.editor.update(cx, |editor, editor_cx| {
                editor.go_to_line(line, window, editor_cx);
            });
            return;
        }

        // 记下代次，切换工作区后不再消费旧项目的请求。
        self.pending_reveal = Some((absolute, line, self.open_generation));
    }

    /// 文档装上后执行待跳转行；路径或打开代次不匹配时丢弃请求。
    fn apply_pending_reveal(
        &mut self,
        absolute: &Path,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some((path, line, generation)) = self.pending_reveal.take() else {
            return;
        };
        if generation != self.open_generation || file_identity(&path) != file_identity(absolute) {
            return;
        }
        self.editor.update(cx, |editor, editor_cx| {
            editor.go_to_line(line, window, editor_cx);
        });
    }

    pub(super) fn open_file_from_tree_with_history(
        &mut self,
        requested: PathBuf,
        record_history: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(root) = self.project_root.clone() else {
            self.status_message = Some(tr("Open a project first").into());
            cx.notify();
            return;
        };

        // 打开真实文件时收起提交差异页：差异页占用整个编辑区，
        // 继续显示会让用户点文件后看不到内容。
        self.close_commit_diff(cx);

        let (absolute, relative) = match resolve_project_file(&root, &requested) {
            Ok(resolved) => resolved,
            Err(message) => {
                self.status_message = Some(message);
                cx.notify();
                return;
            }
        };

        let tab_id: SharedString = file_identity(&absolute).into();
        if let Some(index) = self.tabs.iter().position(|tab| tab.id == tab_id) {
            self.activate_index(index, window, cx);
            return;
        }

        if record_history {
            if let Some(current) = self.active_tab_path() {
                if current != absolute {
                    self.nav_back.push(current);
                    self.nav_forward.clear();
                }
            }
        }

        self.load_file(root, absolute, relative, tab_id, window, cx);
    }

    pub(super) fn load_file(
        &mut self,
        root: PathBuf,
        absolute: PathBuf,
        relative: String,
        tab_id: SharedString,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let client = self.client;
        let generation = self.open_generation;
        let root_for_read = root.clone();
        let relative_for_read = relative.clone();
        let display_path: SharedString = relative.into();
        let title = file_title(&absolute);
        let icon_kind = file_icon(&absolute);

        self._read_task = cx.spawn_in(window, async move |this, cx| {
            let result = cx
                .background_spawn(
                    async move { client.read_file(&root_for_read, &relative_for_read) },
                )
                .await;

            let _ = this.update_in(cx, move |this, window, cx| {
                if this.open_generation != generation {
                    return;
                }
                match result {
                    Ok(file) => this.install_file(
                        root,
                        absolute,
                        display_path,
                        tab_id,
                        title,
                        icon_kind,
                        file,
                        window,
                        cx,
                    ),
                    Err(error) => {
                        this.status_message =
                            Some(format!("{}: {error}", tr("Could not open file")).into());
                        cx.notify();
                    }
                }
            });
        });
    }

    pub(super) fn install_file(
        &mut self,
        root: PathBuf,
        absolute: PathBuf,
        display_path: SharedString,
        tab_id: SharedString,
        title: SharedString,
        icon_kind: LitheIcon,
        file: FileReadResult,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // `open_file` 按值接收路径；跳行还要用，先留一份。
        let reveal_path = absolute.clone();
        let display_path = if file.path.is_empty() {
            display_path
        } else {
            SharedString::from(file.path.clone())
        };

        if let Some(index) = self.tabs.iter().position(|tab| tab.id == tab_id) {
            self.tabs[index].text = file.text;
            self.status_message = None;
            self.activate_index(index, window, cx);
            self.apply_pending_reveal(&reveal_path, window, cx);
            return;
        }

        self.tabs.push(OpenTab {
            id: tab_id.clone(),
            title,
            display_path,
            absolute_path: absolute.clone(),
            text: file.text.clone(),
            icon: icon_kind,
            modified: false,
        });
        self.active_tab = Some(tab_id);
        self.status_message = None;

        self.editor.update(cx, |editor, editor_cx| {
            editor.open_file(root, absolute, file.text, window, editor_cx);
            editor.focus(window, editor_cx);
        });
        self.sync_editor_secondary(window, cx);
        self.sync_preview_with_active_tab(cx);
        self.apply_pending_reveal(&reveal_path, window, cx);
        // 打开标签要立即进入待写盘的会话，下次打开项目才能恢复它。
        self.schedule_layout_persist(cx);
        cx.notify();
    }

    /// 恢复上次工作区会话里打开的标签。
    ///
    /// 只恢复真实文件标签：`open_paths` 是相对项目根的路径，逐条经
    /// [`resolve_project_file`] 归一化（与项目树点击同一条路径解析），读盘
    /// 沿用 `CoreClient::read_file`。整批在一次任务里顺序读完再统一建标签：
    /// `_read_task` 被下一次打开覆盖时会取消上一个任务，逐个文件调用
    /// `load_file` 只会剩下最后一个。读取失败的文件跳过并汇总提示一次。
    pub(super) fn restore_session_tabs(
        &mut self,
        open_paths: Vec<String>,
        active_path: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if open_paths.is_empty() {
            return;
        }
        let Some(root) = self.project_root.clone() else {
            return;
        };

        // 越界或重复的条目在这里就丢掉，避免恢复出一个工作区外的标签。
        let mut targets: Vec<(PathBuf, String)> = Vec::new();
        let mut seen: Vec<String> = Vec::new();
        for relative in open_paths {
            let Ok((absolute, normalised)) = resolve_project_file(&root, Path::new(&relative))
            else {
                continue;
            };
            let identity = file_identity(&absolute);
            if seen.contains(&identity) {
                continue;
            }
            seen.push(identity);
            targets.push((absolute, normalised));
        }
        if targets.is_empty() {
            return;
        }

        let active_identity = active_path.and_then(|path| {
            resolve_project_file(&root, Path::new(&path))
                .ok()
                .map(|(absolute, _)| file_identity(&absolute))
        });

        let generation = self.open_generation;
        let client = self.client;
        self._read_task = cx.spawn_in(window, async move |this, cx| {
            let mut restored: Vec<(PathBuf, String, FileReadResult)> = Vec::new();
            let mut missing: Vec<String> = Vec::new();
            for (absolute, relative) in targets {
                let read_root = root.clone();
                let relative_for_read = relative.clone();
                let result = cx
                    .background_spawn(
                        async move { client.read_file(&read_root, &relative_for_read) },
                    )
                    .await;
                match result {
                    Ok(file) => restored.push((absolute, relative, file)),
                    // 已删除、已重命名或读取失败：跳过并汇总，不中断恢复。
                    Err(_) => missing.push(relative),
                }
            }
            let _ = this.update_in(cx, move |this, window, cx| {
                // 工作区已经切换：这批结果属于上一个项目，直接丢弃。
                if this.open_generation != generation {
                    return;
                }
                this.install_restored_tabs(restored, active_identity, missing, window, cx);
            });
        });
    }

    /// 把读好的文件装上标签，并激活上次的活动标签。
    ///
    /// 恢复期间用户可能已经手动打开了同一个文件：按标签 id 去重，不重复建
    /// 标签，也不改动编辑区里已有的内容；`modified` 一律为 `false`，恢复
    /// 本身不会产生脏文档或「外部修改」。
    fn install_restored_tabs(
        &mut self,
        restored: Vec<(PathBuf, String, FileReadResult)>,
        active_identity: Option<String>,
        missing: Vec<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        for (absolute, relative, file) in restored {
            let tab_id: SharedString = file_identity(&absolute).into();
            if self.tabs.iter().any(|tab| tab.id == tab_id) {
                continue;
            }
            let display_path: SharedString = if file.path.is_empty() {
                relative.into()
            } else {
                SharedString::from(file.path)
            };
            self.tabs.push(OpenTab {
                id: tab_id,
                title: file_title(&absolute),
                display_path,
                absolute_path: absolute.clone(),
                text: file.text,
                icon: file_icon(&absolute),
                modified: false,
            });
        }

        if !self.tabs.is_empty() {
            // 活动标签缺失（已删除或读取失败）时退回最后一个标签，对齐
            // macOS `restoreDocuments` 的 `?? openDocuments.last?.id`。
            let index = active_identity
                .and_then(|identity| {
                    self.tabs
                        .iter()
                        .position(|tab| tab.id.as_ref() == identity.as_str())
                })
                .unwrap_or(self.tabs.len() - 1);
            self.activate_index(index, window, cx);
        }

        if !missing.is_empty() {
            // 一次汇总提示：恢复不中断，只告诉用户哪些文件被跳过。
            let shown = missing
                .iter()
                .take(3)
                .cloned()
                .collect::<Vec<_>>()
                .join(", ");
            let description = if missing.len() > 3 {
                format!(
                    "{shown}; {}",
                    tr("and {count} more files")
                        .replace("{count}", &(missing.len() - 3).to_string())
                )
            } else {
                shown
            };
            self.status_message =
                Some(format!("{}: {description}", tr("Could not open file")).into());
            self.push_notification(
                tr("Could not open file"),
                Some(SharedString::from(description)),
                NotificationKind::Error,
            );
        }
        cx.notify();
    }

    pub(super) fn activate_index(
        &mut self,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(tab) = self.tabs.get(index) else {
            return;
        };
        let tab_id = tab.id.clone();
        let root = self.project_root.clone().unwrap_or_default();
        let absolute = tab.absolute_path.clone();
        let text = tab.text.clone();

        self.active_tab = Some(tab_id);
        self.editor.update(cx, |editor, editor_cx| {
            editor.open_file(root, absolute, text, window, editor_cx);
            editor.focus(window, editor_cx);
        });
        self.sync_preview_with_active_tab(cx);
        self.sync_editor_secondary(window, cx);
        // 活动标签是会话的一部分（下次打开项目要回到这里）。
        self.schedule_layout_persist(cx);
        cx.notify();
    }

    pub(super) fn select_tab(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(index) = self.tabs.iter().position(|tab| tab.id.as_ref() == id) {
            // 切回普通文件时收起提交差异页，否则差异会一直盖住选中的文件。
            self.close_commit_diff(cx);
            self.activate_index(index, window, cx);
        }
    }

    pub(super) fn close_tab(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(index) = self.tabs.iter().position(|tab| tab.id.as_ref() == id) else {
            return;
        };

        if !self.tabs[index].modified {
            self.close_tab_now(id, window, cx);
            return;
        }

        // 上一次批量关闭可能已经处理完目标标签却还留着确认项；先清理，
        // 避免新的关闭请求被一个失效的 pending id 挡住。
        if self
            .pending_close_tab
            .as_ref()
            .is_some_and(|pending| !self.tabs.iter().any(|tab| &tab.id == pending))
        {
            self.pending_close_tab = None;
            self.pending_close_queue.clear();
        }

        let pending_id = self.tabs[index].id.clone();
        if self.pending_close_tab.is_none() {
            self.settings_visible = false;
            self.palette_visible = false;
            self.notifications_visible = false;
            self.project_menu_visible = false;
            self.branch_menu_visible = false;
            self.pending_close_tab = Some(pending_id);
            self.overlay_focus.focus(window, cx);
        } else if self.pending_close_tab.as_ref() != Some(&pending_id)
            && !self.pending_close_queue.contains(&pending_id)
        {
            // 批量关闭（Close All / Close Others 等）：脏标签排队，逐个确认。
            self.pending_close_queue.push(pending_id);
        }
        cx.notify();
    }

    pub(super) fn close_tab_now(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(index) = self.tabs.iter().position(|tab| tab.id.as_ref() == id) else {
            return;
        };

        let active_was_closed = self
            .active_tab
            .as_ref()
            .is_some_and(|active| active.as_ref() == id);
        let closed = self.tabs.remove(index);

        if !closed.id.starts_with("untitled:") && !self.closed_tabs.contains(&closed.absolute_path)
        {
            self.closed_tabs.push(closed.absolute_path.clone());
            if self.closed_tabs.len() > 20 {
                self.closed_tabs.remove(0);
            }
        }

        let closed_path = closed.absolute_path.clone();
        self.editor.update(cx, |editor, editor_cx| {
            editor.close_file(closed_path, window, editor_cx);
        });
        if let Some(secondary) = self.editor_secondary.clone() {
            secondary.update(cx, |editor, editor_cx| {
                editor.close_file(closed.absolute_path, window, editor_cx);
            });
        }

        if !active_was_closed {
            // 关闭非活动标签也要立即更新持久化会话，否则下次打开项目会
            // 复活用户已经手动关掉的标签。
            self.schedule_layout_persist(cx);
            cx.notify();
            return;
        }

        if self.tabs.is_empty() {
            self.active_tab = None;
            self.hide_preview();
            self.close_editor_split(cx);
            self.editor
                .update(cx, |editor, editor_cx| editor.clear(window, editor_cx));
        } else {
            let next = index.min(self.tabs.len() - 1);
            self.activate_index(next, window, cx);
        }
        self.schedule_layout_persist(cx);
        cx.notify();
    }

    pub(super) fn discard_pending_close(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.pending_close_tab.take() else {
            return;
        };
        self.close_tab_now(id.as_ref(), window, cx);
        self.advance_pending_close(window, cx);
    }

    /// 保存当前待确认关闭的标签，成功后再关闭并继续处理队列。
    ///
    /// 待确认的标签不一定是活动标签（Close Others / Close All），因此必须
    /// 走 [`Self::save_tabs`] 的后台文本路径，不能调用活动文档的保存。
    /// 保存失败或未命名标签无法写盘时保留标签与确认弹层，并把错误通知出去。
    pub(super) fn save_pending_close(&mut self, cx: &mut Context<Self>) {
        if self.pending_close_saving {
            return;
        }
        let Some(id) = self.pending_close_tab.clone() else {
            return;
        };
        self.pending_close_saving = true;
        let task = self.save_tabs(std::slice::from_ref(&id), cx);
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update_in(cx, move |this, window, cx| {
                this.pending_close_saving = false;
                if result.is_err() || this.pending_close_tab.as_ref() != Some(&id) {
                    cx.notify();
                    return;
                }
                this.pending_close_tab = None;
                this.close_tab_now(id.as_ref(), window, cx);
                this.advance_pending_close(window, cx);
            });
        })
        .detach();
    }

    /// 处理完当前确认后弹出下一个待确认的脏标签。
    pub(super) fn advance_pending_close(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        while !self.pending_close_queue.is_empty() {
            let next = self.pending_close_queue.remove(0);
            let Some(index) = self.tabs.iter().position(|tab| tab.id == next) else {
                continue;
            };
            if !self.tabs[index].modified {
                self.close_tab_now(next.as_ref(), window, cx);
                continue;
            }
            self.pending_close_tab = Some(next);
            self.overlay_focus.focus(window, cx);
            cx.notify();
            return;
        }
        self.pending_close_tab = None;
        cx.notify();
    }

    /// 取消关闭确认。对齐 macOS `cancelPendingClose`：取消整个批量，
    /// 不再追问队列里的其他标签。
    pub(super) fn cancel_pending_close(&mut self, cx: &mut Context<Self>) {
        let had_pending = self.pending_close_tab.take().is_some();
        let had_queue = !self.pending_close_queue.is_empty();
        self.pending_close_queue.clear();
        self.pending_close_saving = false;
        if had_pending || had_queue {
            cx.notify();
        }
    }

    pub(super) fn project_name(&self) -> SharedString {
        self.project_root
            .as_ref()
            .and_then(|root| root.file_name())
            .and_then(|name| name.to_str())
            .map(SharedString::from)
            .unwrap_or_else(|| SharedString::from(tr("No Project")))
    }

    pub(super) fn current_tab(&self) -> Option<&OpenTab> {
        let active = self.active_tab.as_ref()?;
        self.tabs.iter().find(|tab| &tab.id == active)
    }

    pub(super) fn active_tab_path(&self) -> Option<PathBuf> {
        self.current_tab().map(|tab| tab.absolute_path.clone())
    }

    pub(super) fn is_active_tab_untitled(&self) -> bool {
        self.active_tab
            .as_ref()
            .is_some_and(|id| id.starts_with("untitled:"))
    }

    pub(super) fn save_active_as(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(path) = self.active_tab_path() else {
            return;
        };
        let default_name = path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "untitled".to_string());
        let platform = self.platform.clone();
        let title = tr("Save As…").to_string();
        cx.spawn_in(window, async move |this, cx| {
            let target = platform
                .pick_save_path(title, default_name, Vec::new())
                .await;
            let Some(target) = target else {
                return;
            };
            let _ = this.update_in(cx, |this, _window, editor_cx| {
                this.editor.update(editor_cx, |editor, editor_cx| {
                    editor.save_as(target, editor_cx);
                });
            });
        })
        .detach();
    }

    pub(super) fn save_active_tab(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.is_active_tab_untitled() {
            self.save_active_as(window, cx);
        } else {
            self.editor.update(cx, |editor, editor_cx| {
                editor.save(editor_cx);
            });
        }
    }

    pub(super) fn save_active_tab_as(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.save_active_as(window, cx);
    }

    /// 保存全部脏标签（File > Save All 与退出确认）。
    ///
    /// 返回 `Ok(())` 表示这一批目标都已经写盘；`Err(message)` 表示有文件
    /// 写盘失败或被跳过（未命名标签）。错误同时会推送通知并写到状态栏，
    /// 调用方（退出确认）据此决定是否允许退出。
    pub(super) fn save_all_tabs(
        &mut self,
        cx: &mut Context<Self>,
    ) -> gpui_kit::Task<Result<(), String>> {
        let ids: Vec<SharedString> = self
            .tabs
            .iter()
            .filter(|tab| tab.modified)
            .map(|tab| tab.id.clone())
            .collect();
        self.save_tabs(&ids, cx)
    }

    /// 把一组标签的最新文本写盘。
    ///
    /// 当前活动标签从编辑区取文本（包含最新输入），后台标签使用
    /// `EditorSurface::cached_text`。未命名标签没有磁盘路径，不写盘，
    /// 只作为失败原因上报，避免把内容静默写到猜出来的位置。
    pub(super) fn save_tabs(
        &mut self,
        ids: &[SharedString],
        cx: &mut Context<Self>,
    ) -> gpui_kit::Task<Result<(), String>> {
        let Some(root) = self.project_root.clone() else {
            let message = tr("Open a project first").to_string();
            self.push_notification(
                tr("Save Failed"),
                Some(SharedString::from(message.clone())),
                NotificationKind::Error,
            );
            cx.notify();
            return gpui_kit::Task::ready(Err(message));
        };

        let targets: Vec<(SharedString, PathBuf)> = ids
            .iter()
            .filter_map(|id| {
                self.tabs
                    .iter()
                    .find(|tab| &tab.id == id)
                    .map(|tab| (tab.id.clone(), tab.absolute_path.clone()))
            })
            .collect();

        // (绝对路径, 工作区相对路径, 文本)
        let mut writes: Vec<(PathBuf, String, String)> = Vec::new();
        let mut untitled: Vec<String> = Vec::new();
        let mut missing: Vec<String> = Vec::new();

        for (id, absolute) in targets {
            let Some(tab) = self.tabs.iter().find(|tab| tab.id == id && tab.modified) else {
                continue;
            };
            if tab.id.starts_with("untitled:") {
                untitled.push(tab.title.to_string());
                continue;
            }
            let is_active = self.active_tab.as_ref() == Some(&id);
            let text = self.editor.update(cx, |editor, editor_cx| {
                if is_active {
                    Some(editor.current_text(editor_cx))
                } else {
                    editor.cached_text(&root, &absolute, editor_cx)
                }
            });
            let Some(text) = text else {
                // 后台标签缓存缺失时宁可失败，也不能用旧文本覆盖磁盘。
                missing.push(absolute.display().to_string());
                continue;
            };
            writes.push((absolute.clone(), workspace_relative(&root, &absolute), text));
        }

        if writes.is_empty() {
            let failure = save_failure_message(&untitled, &missing, None);
            if let Some(message) = failure {
                self.status_message = Some(SharedString::from(message.clone()));
                self.push_notification(
                    tr("Save Failed"),
                    Some(SharedString::from(message.clone())),
                    NotificationKind::Error,
                );
                cx.notify();
                return gpui_kit::Task::ready(Err(message));
            }
            return gpui_kit::Task::ready(Ok(()));
        }

        let single = !ids.is_empty() && ids.len() == 1;
        let client = self.client;
        cx.spawn(async move |this, cx| {
            let mut saved: Vec<(PathBuf, String)> = Vec::new();
            let mut write_error: Option<String> = None;
            for (absolute, relative, text) in writes {
                let result = cx
                    .background_spawn({
                        let root = root.clone();
                        let relative = relative.clone();
                        let text = text.clone();
                        let client = client;
                        async move { client.write_file(&root, &relative, &text) }
                    })
                    .await;
                match result {
                    Ok(_) => saved.push((absolute, text)),
                    Err(error) => {
                        write_error = Some(format!("{}: {error}", absolute.display()));
                        break;
                    }
                }
            }

            let result = this.update(cx, |this, cx| {
                for (path, text) in &saved {
                    this.editor.update(cx, |editor, _editor_cx| {
                        editor.mark_saved(path, text.clone());
                    });
                    let identity = file_identity(path);
                    if let Some(tab) = this
                        .tabs
                        .iter_mut()
                        .find(|tab| file_identity(&tab.absolute_path) == identity)
                    {
                        tab.text = text.clone();
                        tab.modified = false;
                    }
                    lithe_features::local_history::record(path, text);
                    this.java_language.update(cx, |model, _model_cx| {
                        model.notify_document_saved(path.clone(), text.clone());
                    });
                    if single {
                        let file_name = path
                            .file_name()
                            .and_then(|name| name.to_str())
                            .unwrap_or_default()
                            .to_string();
                        this.push_notification(
                            tr("Saved"),
                            Some(SharedString::from(file_name)),
                            NotificationKind::Success,
                        );
                    }
                }

                let failure = save_failure_message(&untitled, &missing, write_error.as_deref());
                if let Some(message) = &failure {
                    this.status_message = Some(SharedString::from(message.clone()));
                    this.push_notification(
                        tr("Save Failed"),
                        Some(SharedString::from(message.clone())),
                        NotificationKind::Error,
                    );
                } else if !saved.is_empty() {
                    this.status_message = Some(tr("Saved").into());
                }
                cx.notify();
                match failure {
                    Some(message) => Err(message),
                    None => Ok(()),
                }
            });

            result.unwrap_or_else(|_| Err(tr("Save failed").to_string()))
        })
    }

    /// 启动前保存当前文档，并等写盘完成后再返回。
    ///
    /// 对齐 macOS `saveJavaWorkspaceForLaunch`：保存失败必须中止启动，不能
    /// 带着旧内容去编译。原生编辑器只持有一个文档，后台标签的文本缓存不保证
    /// 是最新内容，因此这里不冒险用缓存覆盖磁盘。
    pub(super) fn save_all_before_launch(
        &mut self,
        cx: &mut Context<Self>,
    ) -> gpui_kit::Task<Result<Option<PathBuf>, String>> {
        let Some(path) = self.active_tab_path() else {
            return gpui_kit::Task::ready(Ok(None));
        };
        if self.is_active_tab_untitled() {
            return gpui_kit::Task::ready(Ok(Some(path)));
        }
        let Some(root) = self.project_root.clone() else {
            return gpui_kit::Task::ready(Ok(Some(path)));
        };
        let text = self
            .editor
            .update(cx, |editor, editor_cx| editor.current_text(editor_cx));
        let client = self.client;
        let relative = workspace_relative(&root, &path);
        let save_path = path.clone();
        let save_text = text.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move {
                    client.write_file(&root, &relative, &save_text)
                })
                .await;
            match result {
                Ok(_) => {
                    let _ = this.update(cx, |this, cx| {
                        this.editor.update(cx, |editor, _editor_cx| {
                            editor.mark_saved(&save_path, text.clone());
                        });
                        if let Some(tab) = this
                            .tabs
                            .iter_mut()
                            .find(|tab| tab.absolute_path == save_path)
                        {
                            tab.text = text.clone();
                            tab.modified = false;
                        }
                        this.java_language.update(cx, |model, _model_cx| {
                            model.notify_document_saved(save_path.clone(), text.clone());
                        });
                        cx.notify();
                    });
                    Ok(Some(path))
                }
                Err(error) => Err(error.to_string()),
            }
        })
    }

    pub(super) fn close_other_tabs(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let active = self.active_tab.clone();
        if let Some(active) = active {
            self.close_other_tabs_of(active.as_ref(), window, cx);
        }
    }

    pub(super) fn close_other_tabs_of(
        &mut self,
        anchor_id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let ids: Vec<String> = self
            .tabs
            .iter()
            .map(|tab| tab.id.to_string())
            .filter(|id| id.as_str() != anchor_id)
            .collect();
        for id in ids {
            self.close_tab(&id, window, cx);
        }
    }

    pub(super) fn close_tabs_to_right(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let active = self.active_tab.clone();
        if let Some(active) = active {
            self.close_tabs_to_right_of(active.as_ref(), window, cx);
        }
    }

    pub(super) fn close_tabs_to_right_of(
        &mut self,
        anchor_id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(index) = self.tabs.iter().position(|tab| tab.id.as_ref() == anchor_id) {
            let ids: Vec<String> = self.tabs[index + 1..]
                .iter()
                .map(|tab| tab.id.to_string())
                .collect();
            for id in ids {
                self.close_tab(&id, window, cx);
            }
        }
    }

    pub(super) fn close_tabs_to_left_of(
        &mut self,
        anchor_id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(index) = self.tabs.iter().position(|tab| tab.id.as_ref() == anchor_id) {
            let ids: Vec<String> = self.tabs[..index]
                .iter()
                .map(|tab| tab.id.to_string())
                .collect();
            for id in ids {
                self.close_tab(&id, window, cx);
            }
        }
    }

    pub(super) fn close_saved_tabs(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let ids: Vec<String> = self
            .tabs
            .iter()
            .filter(|tab| !tab.modified)
            .map(|tab| tab.id.to_string())
            .collect();
        for id in ids {
            self.close_tab(&id, window, cx);
        }
    }

    pub(super) fn reload_tab(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(index) = self.tabs.iter().position(|tab| tab.id.as_ref() == id) else {
            return;
        };
        let tab = &self.tabs[index];
        if tab.id.starts_with("untitled:") {
            return;
        }
        let Some(root) = self.project_root.clone() else {
            return;
        };
        let absolute = tab.absolute_path.clone();
        let relative = tab.display_path.to_string();
        let tab_id = tab.id.clone();
        self.load_file(root, absolute, relative, tab_id, window, cx);
    }

    pub(super) fn close_all_tabs(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let ids: Vec<String> = self.tabs.iter().map(|tab| tab.id.to_string()).collect();
        for id in ids {
            self.close_tab(&id, window, cx);
        }
    }

    pub(super) fn reopen_last_closed_tab(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(path) = self.closed_tabs.pop() {
            self.open_file_from_tree(path, window, cx);
        }
    }

    pub(super) fn cycle_tab(&mut self, offset: isize, window: &mut Window, cx: &mut Context<Self>) {
        if self.tabs.is_empty() {
            return;
        }
        let current_index = self
            .active_tab
            .as_ref()
            .and_then(|active| self.tabs.iter().position(|tab| &tab.id == active))
            .unwrap_or(0);
        let next_index =
            (current_index as isize + offset).rem_euclid(self.tabs.len() as isize) as usize;
        self.activate_index(next_index, window, cx);
    }

    pub(super) fn navigate_history(
        &mut self,
        back: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if back {
            if let Some(path) = self.nav_back.pop() {
                if let Some(current) = self.active_tab_path() {
                    self.nav_forward.push(current);
                }
                self.open_file_from_tree_with_history(path, false, window, cx);
            }
        } else {
            if let Some(path) = self.nav_forward.pop() {
                if let Some(current) = self.active_tab_path() {
                    self.nav_back.push(current);
                }
                self.open_file_from_tree_with_history(path, false, window, cx);
            }
        }
    }

    pub(super) fn open_new_tab(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.untitled_counter += 1;
        let counter = self.untitled_counter;
        let title_str = if counter == 1 {
            tr("Untitled").to_string()
        } else {
            format!("{}-{counter}", tr("Untitled"))
        };
        let tab_id: SharedString = format!("untitled:{counter}").into();
        let title: SharedString = title_str.clone().into();
        let display_path: SharedString = title_str.clone().into();
        let absolute_path = self
            .project_root
            .as_ref()
            .map(|root| root.join(&title_str))
            .unwrap_or_else(|| PathBuf::from(&title_str));

        let open_tab = OpenTab {
            id: tab_id.clone(),
            title,
            display_path,
            absolute_path: absolute_path.clone(),
            text: String::new(),
            icon: LitheIcon::File,
            modified: false,
        };

        self.tabs.push(open_tab);
        self.active_tab = Some(tab_id);
        self.status_message = None;

        let root = self
            .project_root
            .clone()
            .unwrap_or_else(|| PathBuf::from("."));
        self.editor.update(cx, |editor, editor_cx| {
            editor.open_file(root, absolute_path, String::new(), window, editor_cx);
            editor.focus(window, editor_cx);
        });
        self.sync_editor_secondary(window, cx);
        self.sync_preview_with_active_tab(cx);
        cx.notify();
    }

    pub(super) fn open_tab_context_menu(
        &mut self,
        tab_id: SharedString,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(index) = self.tabs.iter().position(|tab| tab.id == tab_id) else {
            return;
        };

        let target_tab = self.tabs[index].clone();
        let target_id = target_tab.id.clone();
        let is_virtual = target_tab.id.starts_with("untitled:");
        let has_other_tabs = self.tabs.len() > 1;
        let has_tabs_to_right = index + 1 < self.tabs.len();
        let has_tabs_to_left = index > 0;
        let has_saved_tabs = self.tabs.iter().any(|tab| !tab.modified);
        let has_split = self.editor_secondary.is_some();
        let owner = cx.weak_entity();

        let popup = PopupMenu::build(window, cx, move |mut menu, _window, _cx| {
            let id = target_id.clone();
            let close_owner = owner.clone();
            menu = menu.item(
                PopupMenuItem::new(tr("Close")).on_click(move |_, window, cx| {
                    let _ = close_owner.update(cx, |this, cx| {
                        this.close_tab(id.as_ref(), window, cx);
                    });
                }),
            );

            let id = target_id.clone();
            let close_others_owner = owner.clone();
            menu = menu.item(
                PopupMenuItem::new(tr("Close Other Tabs"))
                    .disabled(!has_other_tabs)
                    .on_click(move |_, window, cx| {
                        let _ = close_others_owner.update(cx, |this, cx| {
                            this.close_other_tabs_of(id.as_ref(), window, cx);
                        });
                    }),
            );

            let id = target_id.clone();
            let close_right_owner = owner.clone();
            menu = menu.item(
                PopupMenuItem::new(tr("Close Tabs to the Right"))
                    .disabled(!has_tabs_to_right)
                    .on_click(move |_, window, cx| {
                        let _ = close_right_owner.update(cx, |this, cx| {
                            this.close_tabs_to_right_of(id.as_ref(), window, cx);
                        });
                    }),
            );

            let id = target_id.clone();
            let close_left_owner = owner.clone();
            menu = menu.item(
                PopupMenuItem::new(tr("Close Tabs to the Left"))
                    .disabled(!has_tabs_to_left)
                    .on_click(move |_, window, cx| {
                        let _ = close_left_owner.update(cx, |this, cx| {
                            this.close_tabs_to_left_of(id.as_ref(), window, cx);
                        });
                    }),
            );

            let close_saved_owner = owner.clone();
            menu = menu.item(
                PopupMenuItem::new(tr("Close Saved Tabs"))
                    .disabled(!has_saved_tabs)
                    .on_click(move |_, window, cx| {
                        let _ = close_saved_owner.update(cx, |this, cx| {
                            this.close_saved_tabs(window, cx);
                        });
                    }),
            );

            let close_all_owner = owner.clone();
            menu = menu.item(
                PopupMenuItem::new(tr("Close All Tabs")).on_click(move |_, window, cx| {
                    let _ = close_all_owner.update(cx, |this, cx| {
                        this.close_all_tabs(window, cx);
                    });
                }),
            );

            menu = menu.separator();

            let id = target_id.clone();
            let split_owner = owner.clone();
            menu = menu.item(
                PopupMenuItem::new(tr("Split Right"))
                    .disabled(has_split)
                    .on_click(move |_, window, cx| {
                        let _ = split_owner.update(cx, |this, cx| {
                            this.select_tab(id.as_ref(), window, cx);
                            this.split_editor_right(window, cx);
                        });
                    }),
            );

            menu = menu.separator();

            let abs_path = strip_verbatim_prefix(&target_tab.absolute_path);
            let copy_path_owner = owner.clone();
            menu = menu.item(
                PopupMenuItem::new(tr("Copy Path"))
                    .disabled(is_virtual)
                    .on_click(move |_, _window, cx| {
                        let _ = copy_path_owner.update(cx, |this, cx| {
                            cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string(
                                abs_path.display().to_string(),
                            ));
                            this.status_message = Some(tr("Copied").into());
                            cx.notify();
                        });
                    }),
            );

            let disp_path = target_tab.display_path.clone();
            let copy_rel_owner = owner.clone();
            menu = menu.item(
                PopupMenuItem::new(tr("Copy Relative Path"))
                    .disabled(is_virtual)
                    .on_click(move |_, _window, cx| {
                        let _ = copy_rel_owner.update(cx, |this, cx| {
                            cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string(
                                disp_path.to_string(),
                            ));
                            this.status_message = Some(tr("Copied").into());
                            cx.notify();
                        });
                    }),
            );

            let reveal_path = target_tab.absolute_path.clone();
            let reveal_owner = owner.clone();
            let reveal_label = if cfg!(target_os = "macos") {
                tr("Show in Finder")
            } else {
                tr("Reveal in File Explorer")
            };
            menu = menu.item(
                PopupMenuItem::new(reveal_label)
                    .disabled(is_virtual)
                    .on_click(move |_, _window, cx| {
                        let _ = reveal_owner.update(cx, |this, _cx| {
                            this.platform.reveal_path(&reveal_path);
                        });
                    }),
            );

            menu = menu.separator();

            let id = target_id.clone();
            let reload_owner = owner.clone();
            menu = menu.item(
                PopupMenuItem::new(tr("Reload Tab"))
                    .disabled(is_virtual)
                    .on_click(move |_, window, cx| {
                        let _ = reload_owner.update(cx, |this, cx| {
                            this.reload_tab(id.as_ref(), window, cx);
                        });
                    }),
            );

            menu
        });

        let focus_handle = popup.read(cx).focus_handle(cx);
        if !focus_handle.contains_focused(window, cx) {
            focus_handle.focus(window, cx);
        }

        let subscription =
            cx.subscribe_in(&popup, window, |this, _, _: &DismissEvent, _window, cx| {
                this.tab_context_menu = None;
                this._tab_context_menu_subscription = None;
                cx.notify();
            });
        self.tab_context_menu = Some((popup, position));
        self._tab_context_menu_subscription = Some(subscription);
        cx.notify();
    }
}

pub(super) fn file_identity(path: &Path) -> String {
    let normalised = path.to_string_lossy().replace('\\', "/");
    if cfg!(windows) {
        normalised.to_lowercase()
    } else {
        normalised
    }
}

/// 汇总保存全部时无法写盘的原因。未命名标签没有磁盘路径，只报告不写盘。
fn save_failure_message(
    untitled: &[String],
    missing: &[String],
    write_error: Option<&str>,
) -> Option<String> {
    let mut parts: Vec<String> = Vec::new();
    if let Some(error) = write_error {
        parts.push(error.to_string());
    }
    if !untitled.is_empty() {
        parts.push(format!("{}: {}", tr("Untitled"), untitled.join(", ")));
    }
    if !missing.is_empty() {
        parts.push(format!("{}: {}", tr("Save failed"), missing.join(", ")));
    }
    if parts.is_empty() {
        None
    } else {
        Some(parts.join("\n"))
    }
}

/// 工作区相对路径，`CoreClient::write_file` 使用 `/` 分隔。
fn workspace_relative(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .map(|relative| relative.to_string_lossy().replace('\\', "/"))
        .unwrap_or_else(|_| {
            let root = file_identity(root);
            let file = file_identity(path);
            file.strip_prefix(&format!("{}/", root.trim_end_matches('/')))
                .map(str::to_string)
                .unwrap_or_else(|| path.to_string_lossy().replace('\\', "/"))
        })
}

/// 工作区相对路径（`/` 分隔）；不在工作区内时返回 `None`。
///
/// 持久化会话只接受工作区内的真实文件：绝对路径写进 JSON 后换目录、换机器
/// 都会失效，越界路径也不该在恢复时被打开。Windows 上项目根的写法可能和
/// 规范化后的标签路径大小写不同，这里补一次不区分大小写的切分。
pub(super) fn workspace_relative_option(root: &Path, path: &Path) -> Option<String> {
    if let Ok(relative) = path.strip_prefix(root) {
        let text = relative.to_string_lossy().replace('\\', "/");
        return (!text.is_empty()).then_some(text);
    }

    let root_text = root.to_string_lossy().replace('\\', "/");
    let root_text = root_text.trim_end_matches('/');
    let path_text = path.to_string_lossy().replace('\\', "/");
    if root_text.is_empty()
        || path_text.len() <= root_text.len()
        || !path_text.is_char_boundary(root_text.len())
    {
        return None;
    }
    let (prefix, rest) = path_text.split_at(root_text.len());
    let matches = prefix == root_text || (cfg!(windows) && prefix.eq_ignore_ascii_case(root_text));
    if !matches || !rest.starts_with('/') {
        return None;
    }
    let rest = rest.trim_start_matches('/');
    (!rest.is_empty()).then(|| rest.to_string())
}

pub(super) fn file_title(path: &Path) -> SharedString {
    path.file_name()
        .and_then(|name| name.to_str())
        .map(SharedString::from)
        .unwrap_or_else(|| SharedString::from(path.to_string_lossy().into_owned()))
}

pub(super) fn file_icon(path: &Path) -> LitheIcon {
    let extension = path
        .extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or_default();

    if extension.eq_ignore_ascii_case("java") {
        LitheIcon::Java
    } else if is_markdown_path(path) {
        LitheIcon::Markdown
    } else {
        LitheIcon::File
    }
}

pub(super) fn is_markdown_path(path: &Path) -> bool {
    let extension = path
        .extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or_default();
    matches!(
        extension.to_ascii_lowercase().as_str(),
        "md" | "markdown" | "mdown" | "mkd" | "mkdn"
    )
}

/// 移除 Windows canonicalize 产生的 `\\?\` 或 `\\?\UNC\` 前缀，保证暴露给 UI 和系统剪贴板的路径是纯净的原生格式。
pub(super) fn strip_verbatim_prefix(path: &Path) -> PathBuf {
    let text = path.to_string_lossy();
    if let Some(rest) = text.strip_prefix(r"\\?\UNC\") {
        PathBuf::from(format!(r"\\{rest}"))
    } else if let Some(rest) = text.strip_prefix(r"\\?\") {
        PathBuf::from(rest)
    } else {
        path.to_path_buf()
    }
}

fn resolve_project_file(root: &Path, requested: &Path) -> Result<(PathBuf, String), SharedString> {
    let absolute = if requested.is_absolute() {
        requested.to_path_buf()
    } else {
        root.join(requested)
    };

    let canonical_root = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    let canonical_target = absolute.canonicalize().unwrap_or_else(|_| absolute.clone());

    if let Ok(relative) = canonical_target.strip_prefix(&canonical_root) {
        let text = relative.to_string_lossy().replace('\\', "/");
        return Ok((strip_verbatim_prefix(&canonical_target), text));
    }

    if let Ok(relative) = absolute.strip_prefix(root) {
        let text = relative.to_string_lossy().replace('\\', "/");
        return Ok((strip_verbatim_prefix(&absolute), text));
    }

    Err(tr("File is outside the project").into())
}
