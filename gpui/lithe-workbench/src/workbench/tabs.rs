use std::path::{Path, PathBuf};

use gpui_kit::component::menu::{PopupMenu, PopupMenuItem};
use gpui_kit::{
    AppContext as _, Context, DismissEvent, Focusable as _, Pixels, Point, SharedString, Window,
};
use lithe_core_client::FileReadResult;
use lithe_ui::i18n::tr;
use lithe_ui::icons::LitheIcon;

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
    /// 去重与标签激活），只在文件真正装上之后才请求编辑器跳行，避免对还没
    /// 打开的文档发定位指令。
    pub(super) fn open_file_at_line(
        &mut self,
        requested: PathBuf,
        line: u32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.open_file_from_tree(requested.clone(), window, cx);

        // 目标是当前活动标签时才跳行：读取失败或索引不同步时不必报错。
        let Some(root) = self.project_root.clone() else {
            return;
        };
        let Ok((absolute, _relative)) = resolve_project_file(&root, &requested) else {
            return;
        };
        if self.active_tab_path().as_deref() != Some(absolute.as_path()) {
            return;
        }
        self.editor.update(cx, |editor, editor_cx| {
            editor.reveal_line(line, window, editor_cx);
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
        let display_path = if file.path.is_empty() {
            display_path
        } else {
            SharedString::from(file.path.clone())
        };

        if let Some(index) = self.tabs.iter().position(|tab| tab.id == tab_id) {
            self.tabs[index].text = file.text;
            self.status_message = None;
            self.activate_index(index, window, cx);
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
        });
        self.sync_editor_secondary(window, cx);
        self.sync_preview_with_active_tab(cx);
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
        });
        self.sync_preview_with_active_tab(cx);
        self.sync_editor_secondary(window, cx);
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

        let pending_id = self.tabs[index].id.clone();
        self.settings_visible = false;
        self.palette_visible = false;
        self.notifications_visible = false;
        self.project_menu_visible = false;
        self.branch_menu_visible = false;
        self.pending_close_tab = Some(pending_id);
        self.overlay_focus.focus(window, cx);
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
        cx.notify();
    }

    pub(super) fn discard_pending_close(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.pending_close_tab.take() else {
            return;
        };
        self.close_tab_now(id.as_ref(), window, cx);
        cx.notify();
    }

    pub(super) fn cancel_pending_close(&mut self, cx: &mut Context<Self>) {
        if self.pending_close_tab.take().is_some() {
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

    /// 启动前把所有脏缓冲写盘。
    ///
    /// Run 面板通过 `on_before_launch` 回调查调这里。与 File > Save All 走同一个
    /// 前端入口（Monaco 自己判断哪些模型需要保存），宿主不按自己的脏标记挑文件：
    /// Rust 侧的 `dirty` 有 150ms 防抖，刚敲完立刻点 Run 会漏掉最新修改。
    ///
    /// 保存本身是异步的（`saveAll` 发出后前端逐个提交 `save` 请求）。这里不做
    /// 阻塞等待：Run 启动也在后台线程里读文件，二者并发时最坏是跑到保存前的
    /// 版本，而不会丢用户的修改；真正的“等保存完成再启动”需要编辑器回报
    /// 保存完成事件，属于后续增强。
    pub(super) fn save_all_before_launch(&mut self, cx: &mut Context<Self>) {
        if self.tabs.is_empty() {
            return;
        }
        self.editor.update(cx, |editor, editor_cx| {
            editor.save_all(editor_cx);
        });
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
