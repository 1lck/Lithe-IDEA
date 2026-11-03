//! 变更树的多选、批量动作、预览与破坏性确认。
//!
//! 拆分自原 `git.rs`（selection / discard confirm）并补齐 plan-02 §4.D 的
//! 多选语义：点击 = 单选，Ctrl/Cmd = 累加，Shift = 范围（对齐 Tauri
//! `selectTreeEntries`）；行首复选框 = 「纳入本次提交」，分组头复选框对
//! 整组生效。预览走 `git_diff` 的工作区差异页（对齐 Tauri `viewFileDiff`
//! 的 `working-tree` 差异页）；文件删除与 Tauri `platformDeletePath` 对齐，
//! 这里用跨平台标准库 `std::fs`（`lithe-platform` 本轮没有对应能力）。

use std::collections::HashSet;

use gpui_kit::component::button::Button;
use gpui_kit::component::button::ButtonVariants as _;
use gpui_kit::component::{Sizable as _, h_flex, v_flex};
use gpui_kit::{
    AnyElement, AppContext as _, Context, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens};

use super::model::{in_group, split_path};
use super::{ChangeAction, ChangeGroup, GitPanel, PendingAction, Selection, execute_git_command};

impl GitPanel {
    /// 该行当前是否被选中（单选或多选集合内）。
    pub(crate) fn is_selected(&self, selection: &Selection) -> bool {
        self.selected.as_ref() == Some(selection)
            || self.multi_selected.contains(selection)
    }

    /// 当前变更树的全部可选行，顺序与渲染顺序一致（分组顺序跟随
    /// 「暂存优先」设置）。Shift 范围选择依赖顺序。
    pub(crate) fn visible_selections(&self) -> Vec<Selection> {
        let Some(status) = self.status.as_ref() else {
            return Vec::new();
        };
        let groups: &[ChangeGroup] = if self.git_show_staged_first {
            &[
                ChangeGroup::Staged,
                ChangeGroup::Worktree,
                ChangeGroup::Untracked,
            ]
        } else {
            &[
                ChangeGroup::Worktree,
                ChangeGroup::Staged,
                ChangeGroup::Untracked,
            ]
        };
        let mut ordered = Vec::new();
        for group in groups.iter().copied() {
            if group == ChangeGroup::Untracked && !self.git_show_untracked {
                continue;
            }
            // 汇总的未跟踪目录行不参与行选择（展开后才有文件行）。
            ordered.extend(status.changes.iter().filter_map(|change| {
                if !in_group(change, group) || change.is_untracked_directory() {
                    return None;
                }
                Some(Selection {
                    path: change.path.clone(),
                    group,
                })
            }));
        }
        ordered
    }

    /// 点击行的选择处理：普通点击重置多选，Ctrl/Cmd 累加一行，Shift 范围。
    /// 空路径的 Shift 锚点按单选回落。
    pub(crate) fn select_change_with_modifiers(
        &mut self,
        selection: Selection,
        additive_modifier: bool,
        range_modifier: bool,
        cx: &mut Context<Self>,
    ) {
        if range_modifier {
            let Some(anchor) = self.anchor.clone() else {
                // 没有锚点时，Shift 点击退化成单选。
                self.select_change(selection, cx);
                return;
            };
            let ordered = self.visible_selections();
            let start = ordered
                .iter()
                .position(|item| item == &anchor)
                .unwrap_or(0);
            let end = ordered
                .iter()
                .position(|item| item == &selection)
                .unwrap_or(ordered.len());
            let (lo, hi) = if start <= end {
                (start, end)
            } else {
                (end, start)
            };
            let mut selected: HashSet<Selection> =
                ordered[lo..=hi.min(ordered.len() - 1)].iter().cloned().collect();
            // 加号修饰保留行外的既有选择；行为对齐 `selectTreeEntries`。
            if additive_modifier {
                selected.extend(self.multi_selected.iter().cloned());
            }
            self.multi_selected = selected;
            self.selected = Some(selection.clone());
            cx.notify();
            return;
        }

        if additive_modifier {
            if !self.multi_selected.remove(&selection) {
                self.multi_selected.insert(selection.clone());
            }
            self.selected = Some(selection);
            cx.notify();
            return;
        }

        self.multi_selected.clear();
        self.select_change(selection, cx);
    }

    /// 选中一个变更。与 Tauri 一致，面板内不再渲染补丁；真正打开 diff 由
    /// 双击（`open_change`）交给上层编辑器完成。
    pub(crate) fn select_change(&mut self, selection: Selection, cx: &mut Context<Self>) {
        if self.selected.as_ref() == Some(&selection) {
            return;
        }
        self.selected = Some(selection);
        self.anchor = self.selected.clone();
        cx.notify();
    }

    /// 预览的文件：staged 优先，其次工作区与未跟踪（对齐 Tauri
    /// `previewFirstChange`：可见列表的第一个文件）。
    pub(crate) fn first_change_path(&self) -> Option<Selection> {
        self.visible_selections().into_iter().next()
    }

    /// Eye 按钮 = 预览第一处变更（staged 优先）。未提交的差异在中央编辑器
    /// 打开（对齐 Tauri `viewFileDiff` → `working-tree` 差异页）。
    pub(crate) fn preview_first_change(
        &mut self,
        window: &mut gpui_kit::Window,
        cx: &mut Context<Self>,
    ) {
        let Some(selection) = self.first_change_path() else {
            return;
        };
        self.preview_change_paths(vec![selection.path.clone()], window, cx);
    }

    /// 打开一批文件的未提交差异预览（Eye 与右键 View Diff 共用）。
    ///
    /// 单文件时按该行的分组判定维度：Staged 行走 `staged: true`，未跟踪
    /// 路径追加 `untracked: true`（Core 展开为新增行），其它走未暂存维度。
    /// 多文件按「行分组占多数」统一取一个维度。
    pub(crate) fn preview_change_paths(
        &mut self,
        paths: Vec<String>,
        window: &mut gpui_kit::Window,
        cx: &mut Context<Self>,
    ) {
        if paths.is_empty() {
            return;
        }
        let Some(handler) = self.on_open_diff_source.clone() else {
            // 没有注册差异回调（独立预览面板）：回落到打开文件本身。
            if let Some(path) = paths.first() {
                self.open_change(path, window, cx);
            }
            return;
        };
        let status = self.status.clone();
        let mut staged = true;
        let mut untracked = false;
        if let Some(status) = status {
            for path in &paths {
                let Some(change) = status
                    .changes
                    .iter()
                    .find(|change| &change.path == path)
                else {
                    continue;
                };
                if change.untracked {
                    untracked = true;
                    staged = false;
                } else if change.worktree && !change.staged {
                    staged = false;
                }
            }
        } else {
            staged = false;
        }
        let source = super::GitDiffSource::WorkingTree { staged, untracked };
        handler(source, paths.into_iter().next().unwrap_or_default(), window, cx);
    }

    /// 分组头复选框：整组（未跟踪目录行除外）一次性暂存 / 取消暂存。
    ///
    /// 三态聚合的判断在渲染处（`render_group_header`）完成；这里只执行。
    pub(crate) fn toggle_group_staging(
        &mut self,
        group: ChangeGroup,
        staged: bool,
        cx: &mut Context<Self>,
    ) {
        let Some(status) = self.status.clone() else {
            return;
        };
        let paths: Vec<String> = status
            .changes
            .iter()
            .filter(|change| {
                in_group(change, group)
                    && change.can_toggle_staging
                    && !change.is_untracked_directory()
                    && change.staged != staged
            })
            .map(|change| change.path.clone())
            .collect();
        if paths.is_empty() {
            return;
        }
        let action = if staged {
            ChangeAction::Stage
        } else {
            ChangeAction::Unstage
        };
        self.execute_action(
            PendingAction::Paths { paths, action },
            cx,
        );
    }

    /// 批量暂存所选（右键菜单 / 右键 Add to VCS 复用）。
    pub(crate) fn stage_paths(&mut self, paths: &[String], cx: &mut Context<Self>) {
        self.stage_unstage_paths(paths, ChangeAction::Stage, cx);
    }

    /// 批量取消暂存所选。
    pub(crate) fn unstage_paths(&mut self, paths: &[String], cx: &mut Context<Self>) {
        self.stage_unstage_paths(paths, ChangeAction::Unstage, cx);
    }

    fn stage_unstage_paths(
        &mut self,
        paths: &[String],
        action: ChangeAction,
        cx: &mut Context<Self>,
    ) {
        if paths.is_empty() {
            return;
        }
        self.execute_action(
            PendingAction::Paths {
                paths: paths.to_vec(),
                action,
            },
            cx,
        );
    }

    /// 批量 Rollback（丢弃）所选：统一走一次确认（对齐 Tauri 的
    /// Rolldown all 一份确认的语义）；确认后一条命令里带全部路径。
    pub(crate) fn rollback_paths(&mut self, paths: &[String], cx: &mut Context<Self>) {
        self.confirm_discard_paths(paths, cx);
    }

    // -----------------------------------------------------------------------
    // 未跟踪目录展开（Core `git.untrackedDirectory`）
    // -----------------------------------------------------------------------

    /// 切换未跟踪目录的展开状态；展开时加载目录内文件（缓存一次）。
    pub(crate) fn toggle_untracked_directory(
        &mut self,
        directory: &str,
        _window: &mut gpui_kit::Window,
        cx: &mut Context<Self>,
    ) {
        if self.untracked_expanded.contains(directory) {
            self.untracked_expanded.remove(directory);
            cx.notify();
            return;
        }
        self.untracked_expanded.insert(directory.to_string());
        if !self.untracked_files.contains_key(directory) {
            self.load_untracked_files(directory, cx);
        }
        cx.notify();
    }

    /// 拉取一个目录里的全部未跟踪文件（汇总行的展开内容）。
    pub(crate) fn load_untracked_files(&mut self, directory: &str, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = super::model::root_text(&root) else {
            return;
        };
        if self.loading_untracked.contains(directory) {
            return;
        }
        self.loading_untracked.insert(directory.to_string());
        let generation = self.generation;
        let client = self.client;
        // 展开请求与回包缓存都以目录路径为键；闭包必须拥有它（spawn 要求
        // 'static），同时 Core 的请求要求路径带尾部 `/`。
        let directory_key = directory.to_string();
        let payload_directory = directory.trim_end_matches('/').to_string();
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(
                        &client,
                        "git.untrackedDirectory",
                        serde_json::json!({
                            "root": root_text,
                            "directory": payload_directory,
                        }),
                    )
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.loading_untracked.remove(&directory_key);
                match raw {
                    Ok(value) => {
                        // Core `git.untrackedDirectory` 返回 `changes`（GitChange
                        // 数组），路径在每条的 `path` 字段里。
                        let files: Vec<String> = value
                            .get("changes")
                            .and_then(serde_json::Value::as_array)
                            .map(|items| {
                                items
                                    .iter()
                                    .filter_map(|item| {
                                        item.get("path")
                                            .and_then(serde_json::Value::as_str)
                                            .map(String::from)
                                    })
                                    .collect()
                            })
                            .unwrap_or_default();
                        this.untracked_files.insert(directory_key.clone(), files);
                    }
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 展开目录下的文件列表（无缓存时为空，加载完成后自动出现）。
    pub(crate) fn untracked_child_files(&self, directory: &str) -> Option<&Vec<String>> {
        self.untracked_files.get(directory)
    }

    pub(crate) fn is_untracked_loading(&self, directory: &str) -> bool {
        self.loading_untracked.contains(directory)
    }

    // -----------------------------------------------------------------------
    // 破坏性确认：丢弃 / 全部丢弃 / 删除
    // -----------------------------------------------------------------------

    /// 批量丢弃（右键 Rollback / 工具栏 Discard selected）。一次性确认后
    /// 打包成 `PendingAction::Paths`。
    pub(crate) fn confirm_discard_paths(&mut self, paths: &[String], cx: &mut Context<Self>) {
        if self.pending_action.is_some() || self.committing {
            return;
        }
        if !self.git_confirm_discard {
            self.execute_discard_batch(paths, cx);
            return;
        }
        let selections = self
            .visible_selections()
            .into_iter()
            .filter(|selection| paths.iter().any(|path| *path == selection.path))
            .collect::<Vec<_>>();
        self.batch_discard = selections;
        self.pending_discard = None;
        self.pending_discard_all = false;
        self.pending_delete = None;
        cx.notify();
    }

    /// 丢弃一批路径：把批量的「checkout -- path」合并成一条参数数组的命令。
    pub(crate) fn execute_discard_batch(&mut self, paths: &[String], cx: &mut Context<Self>) {
        if paths.is_empty() {
            return;
        }
        self.pending_discard = None;
        self.batch_discard.clear();
        self.pending_discard_all = false;
        self.execute_action(
            PendingAction::Paths {
                paths: paths.to_vec(),
                action: ChangeAction::Discard,
            },
            cx,
        );
    }

    pub(crate) fn cancel_batch_discard(&mut self, cx: &mut Context<Self>) {
        self.pending_discard = None;
        if !self.batch_discard.is_empty() {
            self.batch_discard.clear();
            cx.notify();
        } else {
            cx.notify();
        }
    }

    /// 右键 Delete：确认后从磁盘删除文件（未跟踪或已跟踪都一样；对齐
    /// Tauri `deleteEntries` 的 `platformDeletePath` 每文件一删 + 刷新）。
    pub(crate) fn request_delete_files(&mut self, paths: &[String], cx: &mut Context<Self>) {
        if self.pending_action.is_some() || self.committing || paths.is_empty() {
            return;
        }
        self.pending_delete = Some(paths.to_vec());
        cx.notify();
    }

    pub(crate) fn cancel_delete_files(&mut self, cx: &mut Context<Self>) {
        if self.pending_delete.take().is_some() {
            cx.notify();
        }
    }

    /// 执行已确认的删除。std::fs 在三大平台等价（跨平台标准库）；目录条目
    /// 汇总行不会进入这里，路径永远是文件。删除失败的文件留在状态行。
    /// 阻塞 IO 放在 `background_spawn`（与其它 Core 调用同一约定）。
    pub(crate) fn confirm_delete_files(&mut self, cx: &mut Context<Self>) {
        let Some(paths) = self.pending_delete.take() else {
            return;
        };
        let Some(root) = self.root.clone() else {
            return;
        };
        let absolute: Vec<std::path::PathBuf> = paths
            .iter()
            .map(|path| root.join(path))
            .collect();
        cx.spawn(async move |this, cx| {
            let outcome = cx
                .background_spawn(async move {
                    let mut failures: Vec<String> = Vec::new();
                    for (relative, absolute) in paths.iter().zip(absolute.into_iter()) {
                        let result = if absolute.is_dir() {
                            std::fs::remove_dir_all(&absolute)
                        } else {
                            std::fs::remove_file(&absolute)
                        };
                        if let Err(error) = result {
                            failures.push(format!("{relative}: {error}"));
                        }
                    }
                    failures
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                // `background_spawn` 的 await 直接得到闭包返回值（失败是任务
                // 取消/崩溃，不会在这里变成 Result）。
                if outcome.is_empty() {
                    this.reload_all(cx);
                    this.notice = Some(SharedString::from(tr("Deleted files")));
                } else {
                    this.error = Some(SharedString::from(delete_failure_text(&outcome)));
                    this.reload_all(cx);
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }

    // -----------------------------------------------------------------------
    // 确认覆盖层渲染
    // -----------------------------------------------------------------------

    /// 丢弃确认覆盖层（单个 / 批量共用一条；确认里先单条再批量）。
    pub(crate) fn render_discard_confirm(
        &self,
        path: String,
        group: ChangeGroup,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let confirm_path = path.clone();
        let display = split_path(&path).0;
        // 总目标数 = 确认单条（pending_discard）+ 批量余下条（batch_discard）；
        // 仅批量时首位也在 batch_discard 里，不重复计数。
        let total = if self.pending_discard.is_some() {
            1 + self.batch_discard.len()
        } else {
            self.batch_discard.len()
        };
        let (title, message) = if total > 1 {
            (
                tr("Discard changes?"),
                format!(
                    "{} ({})",
                    tr("This action cannot be undone by Lithe."),
                    tr("{count} files").replace("{count}", &total.to_string())
                ),
            )
        } else {
            (
                tr("Discard changes?"),
                format!("{}: {display}", tr("This action cannot be undone by Lithe.")),
            )
        };

        div()
            .id("lithe-git-discard-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .on_click(cx.listener(move |this, _, _, cx| this.cancel_batch_discard(cx)))
            .child(
                v_flex()
                    .id("lithe-git-discard-dialog")
                    .w(px(420.0))
                    .rounded(px(LitheMetrics::MENU_RADIUS))
                    .border_1()
                    .border_color(tokens.panel_border)
                    .bg(tokens.raised)
                    .p(px(16.0))
                    .gap(px(10.0))
                    .on_click(cx.listener(|_, _, _, cx| cx.stop_propagation()))
                    .child(
                        div()
                            .text_size(px(14.0))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.primary_text)
                            .child(title),
                    )
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(message),
                    )
                    .child(
                        h_flex()
                            .w_full()
                            .justify_end()
                            .gap(px(8.0))
                            .child(
                                Button::new("lithe-git-discard-cancel")
                                    .ghost()
                                    .small()
                                    .label(tr("Cancel"))
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.cancel_batch_discard(cx);
                                    })),
                            )
                            .child(
                                Button::new("lithe-git-discard-confirm")
                                    .danger()
                                    .small()
                                    .label(tr("Discard"))
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        // 单条 = pending_discard（或仅批量的首位），
                                        // 余下条目在 batch_discard；一次性合并执行。
                                        let mut targets: Vec<String> = Vec::new();
                                        if this.pending_discard.is_some() {
                                            targets.push(confirm_path.clone());
                                        }
                                        let mut rest: Vec<String> = this
                                            .batch_discard
                                            .iter()
                                            .map(|selection| selection.path.clone())
                                            .collect();
                                        targets.append(&mut rest);
                                        if targets.is_empty() {
                                            targets.push(confirm_path.clone());
                                        }
                                        let _ = &group;
                                        this.execute_discard_batch(&targets, cx);
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }

    /// 「丢弃全部」确认覆盖层；确认后走 Core `git.write discardAll`。
    pub(crate) fn render_discard_all_confirm(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        div()
            .id("lithe-git-discard-all-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .on_click(cx.listener(move |this, _, _, cx| {
                this.pending_discard_all = false;
                cx.notify();
            }))
            .child(
                v_flex()
                    .id("lithe-git-discard-all-dialog")
                    .w(px(420.0))
                    .rounded(px(LitheMetrics::MENU_RADIUS))
                    .border_1()
                    .border_color(tokens.panel_border)
                    .bg(tokens.raised)
                    .p(px(16.0))
                    .gap(px(10.0))
                    .on_click(|_, _, cx| cx.stop_propagation())
                    .child(
                        div()
                            .text_size(px(14.0))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.primary_text)
                            .child(tr("Discard all changes?")),
                    )
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(tr("This action cannot be undone by Lithe.")),
                    )
                    .child(
                        h_flex()
                            .w_full()
                            .justify_end()
                            .gap(px(8.0))
                            .child(
                                Button::new("lithe-git-discard-all-cancel")
                                    .ghost()
                                    .small()
                                    .label(tr("Cancel"))
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.pending_discard_all = false;
                                        cx.notify();
                                    })),
                            )
                            .child(
                                Button::new("lithe-git-discard-all-confirm")
                                    .danger()
                                    .small()
                                    .label(tr("Discard"))
                                    .on_click(cx.listener(
                                        move |this, _, _, cx| {
                                            this.pending_discard_all = false;
                                            this.execute_discard_all(cx);
                                        },
                                    )),
                            ),
                    ),
            )
            .into_any_element()
    }

    /// 文件删除确认覆盖层。
    pub(crate) fn render_delete_confirm(
        &self,
        paths: &[String],
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let count = paths.len();
        let summary = if count == 1 {
            paths.first().cloned().unwrap_or_default()
        } else {
            tr("{count} files").replace("{count}", &count.to_string())
        };
        div()
            .id("lithe-git-delete-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .on_click(cx.listener(|this, _, _, cx| this.cancel_delete_files(cx)))
            .child(
                v_flex()
                    .id("lithe-git-delete-dialog")
                    .w(px(420.0))
                    .rounded(px(LitheMetrics::MENU_RADIUS))
                    .border_1()
                    .border_color(tokens.panel_border)
                    .bg(tokens.raised)
                    .p(px(16.0))
                    .gap(px(10.0))
                    .on_click(|_, _, cx| cx.stop_propagation())
                    .child(
                        div()
                            .text_size(px(14.0))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.primary_text)
                            .child(if count == 1 {
                                tr("Delete file?").to_string()
                            } else {
                                tr("Delete {count} files?")
                                    .replace("{count}", &count.to_string())
                            }),
                    )
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(summary),
                    )
                    .child(
                        h_flex()
                            .w_full()
                            .justify_end()
                            .gap(px(8.0))
                            .child(
                                Button::new("lithe-git-delete-cancel")
                                    .ghost()
                                    .small()
                                    .label(tr("Cancel"))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.cancel_delete_files(cx);
                                    })),
                            )
                            .child(
                                Button::new("lithe-git-delete-confirm")
                                    .danger()
                                    .small()
                                    .label(tr("Delete"))
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.confirm_delete_files(cx);
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }
}

/// 删除失败的兜底文案。
///
/// 删除走 `std::fs`（跨平台标准库，行为在 Windows/macOS/Linux 一致：
/// 文件 `remove_file`、目录 `remove_dir_all`）；本轮 `lithe-platform` 没有
/// 删除 adapter，将来补上后把这里替换为 adapter 调用即可。
fn delete_failure_text(failures: &[String]) -> String {
    failures.join("; ")
}