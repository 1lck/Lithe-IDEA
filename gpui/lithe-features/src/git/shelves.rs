//! 本地「Saved Changes」（shelves）：把当前工作区导出为补丁并持久化，
//! 之后可恢复或删除。
//!
//! Tauri 的 `git-saved-changes.tsx` 由两半组成：仓库里的 stash 与本地的
//! shelf（`git-shelf-api`：导出补丁、保存在应用数据目录、恢复时应用补丁）。
//! stash 一半已由 `stash_view.rs` 覆盖；本文件用**既有 Core 接口**实现
//! shelf 一半：
//! - 保存：`git.patchExport { source: "workingTree", includeUntracked }`
//!   得到补丁文本，写入应用数据目录（`changelists.json` 同级的
//!   `git-shelves.json`，不写安装目录 / bundle）；
//! - 恢复：`git.patchPreview` 前向校验拿 `expectedState`，再
//!   `git.patchApply` 应用到工作区；
//! - 删除：只移除本地记录。
//!
//! 文件是 `{ "shelves": [{ root, id, name, patch, includeUntracked }] }`，
//! 按仓库根过滤读取；补丁文本内联保存，避免额外目录生命周期。

use std::path::{Path, PathBuf};

use serde_json::Value;

const STORE_FILE_NAME: &str = "git-shelves.json";

/// 一条已保存的更改（最小展示字段；补丁文本只在恢复时读取）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SavedShelf {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) patch: String,
    pub(crate) include_untracked: bool,
}

fn disk_path() -> Option<PathBuf> {
    super::super::settings::app_data_dir().map(|directory| directory.join(STORE_FILE_NAME))
}

fn read_all() -> Vec<Value> {
    let Some(path) = disk_path() else {
        return Vec::new();
    };
    let Ok(text) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    let Ok(value) = serde_json::from_str::<Value>(&text) else {
        return Vec::new();
    };
    value
        .get("shelves")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

fn write_all(shelves: &[Value]) {
    let Some(path) = disk_path() else {
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let payload = serde_json::json!({ "shelves": shelves });
    let _ = std::fs::write(path, payload.to_string());
}

fn root_key(root: &Path) -> String {
    root.to_string_lossy().to_string()
}

/// 列出某个仓库根的 shelf（按保存顺序，最新在后）。
pub(crate) fn list(root: &Path) -> Vec<SavedShelf> {
    let key = root_key(root);
    read_all()
        .into_iter()
        .filter(|item| item.get("root").and_then(Value::as_str) == Some(key.as_str()))
        .filter_map(|item| {
            Some(SavedShelf {
                id: item.get("id").and_then(Value::as_str)?.to_string(),
                name: item.get("name").and_then(Value::as_str)?.to_string(),
                patch: item
                    .get("patch")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                include_untracked: item
                    .get("includeUntracked")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            })
        })
        .collect()
}

/// 保存一条 shelf；返回新 id。
pub(crate) fn create(
    root: &Path,
    name: &str,
    patch: &str,
    include_untracked: bool,
) -> Option<String> {
    let name = name.trim();
    if name.is_empty() || patch.trim().is_empty() {
        return None;
    }
    let id = format!("shelf-{}", unique_suffix());
    let mut all = read_all();
    all.push(serde_json::json!({
        "root": root_key(root),
        "id": id,
        "name": name,
        "patch": patch,
        "includeUntracked": include_untracked,
    }));
    write_all(&all);
    Some(id)
}

/// 删除一条 shelf（只移除本地记录）。
pub(crate) fn delete(root: &Path, id: &str) {
    let key = root_key(root);
    let mut all = read_all();
    all.retain(|item| {
        !(item.get("root").and_then(Value::as_str) == Some(key.as_str())
            && item.get("id").and_then(Value::as_str) == Some(id))
    });
    write_all(&all);
}

/// 读取一条 shelf 的补丁文本。
pub(crate) fn read_patch(root: &Path, id: &str) -> Option<String> {
    list(root)
        .into_iter()
        .find(|shelf| shelf.id == id)
        .map(|shelf| shelf.patch)
        .filter(|patch| !patch.trim().is_empty())
}

fn unique_suffix() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let count = COUNTER.fetch_add(1, Ordering::Relaxed);
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    format!("{stamp:x}{count:x}")
}

// ---------------------------------------------------------------------------
// 面板状态与动作（Stash 分段里的「Saved Changes」区）
// ---------------------------------------------------------------------------

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, h_flex, v_flex};
use gpui_kit::{
    AnyElement, AppContext as _, Context, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::LitheMetrics;

use super::model::root_text;
use super::{GitPanel, execute_git_command};

impl GitPanel {
    /// 读取当前仓库的 shelf 列表（磁盘 IO 放后台线程）。
    pub(crate) fn load_shelves(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        cx.spawn(async move |this, cx| {
            let shelves = cx.background_spawn(async move { list(&root) }).await;
            let _ = this.update(cx, |this, cx| {
                this.shelves = shelves;
                cx.notify();
            });
        })
        .detach();
    }

    /// 打开「保存当前更改为 shelf」弹窗。
    pub(crate) fn request_shelf_create(&mut self, cx: &mut Context<Self>) {
        if self.pending_action.is_some()
            || self.committing
            || self.shelf_busy
            || self.stash_busy
        {
            return;
        }
        self.pending_shelf_create = true;
        self.shelf_name_input = None;
        cx.notify();
    }

    pub(crate) fn cancel_shelf_create(&mut self, cx: &mut Context<Self>) {
        if self.pending_shelf_create {
            self.pending_shelf_create = false;
            self.shelf_name_input = None;
            cx.notify();
        }
    }

    /// 惰性创建名称输入框（需要 Window，只能在 render 期调用）。
    pub(crate) fn ensure_shelf_name_input(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.pending_shelf_create || self.shelf_name_input.is_some() {
            return;
        }
        let input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(tr("Saved changes name"))
        });
        self.shelf_name_input = Some(input);
        cx.notify();
    }

    /// 保存当前工作区为 shelf：`git.patchExport` → 写本地文件。
    pub(crate) fn confirm_shelf_create(&mut self, cx: &mut Context<Self>) {
        let Some(input) = self.shelf_name_input.clone() else {
            return;
        };
        let name = input.read(cx).value().trim().to_string();
        if name.is_empty() {
            return;
        }
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root_text(&root) else {
            return;
        };
        self.pending_shelf_create = false;
        self.shelf_name_input = None;
        self.shelf_busy = true;
        self.error = None;
        self.notice = None;
        let generation = self.generation;
        let client = self.client;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let outcome = cx
                .background_spawn(async move {
                    let exported = execute_git_command(
                        &client,
                        "git.patchExport",
                        serde_json::json!({
                            "root": root_text,
                            "source": "workingTree",
                            "paths": [],
                            "includeUntracked": true,
                        }),
                    )
                    .map_err(|error| error.to_string())?;
                    let patch = exported
                        .get("patch")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    if patch.trim().is_empty() {
                        return Err(tr("No textual changes").to_string());
                    }
                    Ok(create(&root, &name, &patch, true))
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.shelf_busy = false;
                match outcome {
                    Ok(Some(_)) => {
                        this.load_shelves(cx);
                        this.notice = Some(SharedString::from(tr("Changes saved")));
                    }
                    Ok(None) => {
                        this.error = Some(SharedString::from(tr("Saved changes name is empty")));
                    }
                    Err(detail) => {
                        this.error = Some(SharedString::from(detail));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 恢复一条 shelf：`git.patchPreview` 拿令牌 → `git.patchApply`。
    pub(crate) fn restore_shelf(&mut self, id: String, cx: &mut Context<Self>) {
        if self.shelf_busy || self.pending_action.is_some() || self.committing {
            return;
        }
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root_text(&root) else {
            return;
        };
        let generation = self.generation;
        let client = self.client;
        self.shelf_busy = true;
        self.error = None;
        self.notice = None;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let outcome = cx
                .background_spawn(async move {
                    let Some(patch) = read_patch(&root, &id) else {
                        return Err(tr("Saved changes are no longer available").to_string());
                    };
                    // 预览与 apply 用同一份补丁/根：第一次用引用序列化，
                    // 避免提前 move 掉后面还要用的值。
                    let preview = execute_git_command(
                        &client,
                        "git.patchPreview",
                        serde_json::json!({
                            "root": &root_text,
                            "patch": &patch,
                            "target": "worktree",
                        }),
                    )
                    .map_err(|error| error.to_string())?;
                    let applicable = preview
                        .get("applicable")
                        .and_then(serde_json::Value::as_bool)
                        .unwrap_or(false);
                    let Some(expected_state) = preview
                        .get("expectedState")
                        .and_then(serde_json::Value::as_str)
                    else {
                        return Err(preview
                            .get("diagnostic")
                            .and_then(serde_json::Value::as_str)
                            .map(str::to_string)
                            .unwrap_or_else(|| {
                                tr("Saved changes are not applicable").to_string()
                            }));
                    };
                    if !applicable {
                        return Err(preview
                            .get("diagnostic")
                            .and_then(serde_json::Value::as_str)
                            .map(str::to_string)
                            .unwrap_or_else(|| {
                                tr("Saved changes are not applicable").to_string()
                            }));
                    }
                    execute_git_command(
                        &client,
                        "git.patchApply",
                        serde_json::json!({
                            "root": root_text,
                            "patch": patch,
                            "target": "worktree",
                            "expectedState": expected_state,
                        }),
                    )
                    .map_err(|error| error.to_string())
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.shelf_busy = false;
                match outcome {
                    Ok(_) => {
                        this.reload_all(cx);
                        this.notice = Some(SharedString::from(tr("Changes restored")));
                    }
                    Err(detail) => {
                        this.error = Some(SharedString::from(detail));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(crate) fn request_delete_shelf(&mut self, id: String, cx: &mut Context<Self>) {
        if self.shelf_busy {
            return;
        }
        self.pending_shelf_delete = Some(id);
        cx.notify();
    }

    pub(crate) fn cancel_delete_shelf(&mut self, cx: &mut Context<Self>) {
        if self.pending_shelf_delete.take().is_some() {
            cx.notify();
        }
    }

    pub(crate) fn confirm_delete_shelf(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.pending_shelf_delete.take() else {
            return;
        };
        let Some(root) = self.root.clone() else {
            return;
        };
        cx.spawn(async move |this, cx| {
            cx.background_spawn(async move { delete(&root, &id) }).await;
            let _ = this.update(cx, |this, cx| {
                this.load_shelves(cx);
                this.notice = Some(SharedString::from(tr("Saved changes deleted")));
                cx.notify();
            });
        })
        .detach();
    }

    /// Stash 分段底部的「Saved Changes」区。
    pub(crate) fn render_shelves_section(
        &self,
        tokens: lithe_ui::LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mut section = v_flex()
            .id("lithe-git-shelves")
            .w_full()
            .gap(px(4.0))
            .px(px(10.0))
            .py(px(8.0))
            .border_t_1()
            .border_color(tokens.divider)
            .child(
                h_flex()
                    .w_full()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.secondary_text)
                            .child(tr("Saved Changes")),
                    )
                    .child(
                        Button::new("lithe-git:shelf-create")
                            .ghost()
                            .xsmall()
                            .icon(Icon::new(gpui_kit::assets::IconName::Archive))
                            .label(tr("Save changes"))
                            .disabled(self.shelf_busy)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.request_shelf_create(cx);
                            })),
                    ),
            );

        if self.shelves.is_empty() {
            section = section.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(tr("No saved changes")),
            );
            return section.into_any_element();
        }

        for shelf in &self.shelves {
            let id_for_restore = shelf.id.clone();
            let id_for_delete = shelf.id.clone();
            section = section.child(
                h_flex()
                    .id(SharedString::from(format!(
                        "lithe-git:shelf:{}",
                        shelf.id
                    )))
                    .w_full()
                    .h(px(28.0))
                    .items_center()
                    .gap(px(8.0))
                    .rounded(px(4.0))
                    .hover(|style| style.bg(tokens.hover))
                    .child(
                        Icon::new(gpui_kit::assets::IconName::Archive)
                            .with_size(px(13.0))
                            .text_color(tokens.secondary_text),
                    )
                    .child(
                        div()
                            .min_w(px(0.0))
                            .flex_1()
                            .truncate()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.primary_text)
                            .child(shelf.name.clone()),
                    )
                    .child(
                        Button::new(SharedString::from(format!(
                            "lithe-git:shelf-restore:{}",
                            shelf.id
                        )))
                        .ghost()
                        .xsmall()
                        .label(tr("Restore"))
                        .disabled(self.shelf_busy)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.restore_shelf(id_for_restore.clone(), cx);
                        })),
                    )
                    .child(
                        Button::new(SharedString::from(format!(
                            "lithe-git:shelf-delete:{}",
                            shelf.id
                        )))
                        .ghost()
                        .xsmall()
                        .label(tr("Delete"))
                        .disabled(self.shelf_busy)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.request_delete_shelf(id_for_delete.clone(), cx);
                        })),
                    ),
            );
        }
        section.into_any_element()
    }

    /// Saved Changes 的弹窗（保存命名 / 删除确认）。
    pub(crate) fn render_shelf_overlays(
        &mut self,
        window: &mut Window,
        tokens: lithe_ui::LitheTokens,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if self.pending_shelf_create {
            self.ensure_shelf_name_input(window, cx);
        }

        let body = if self.pending_shelf_create {
            let mut dialog = v_flex()
                .id("lithe-git-shelf-create")
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
                        .child(tr("Save changes")),
                )
                .child(
                    div()
                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                        .text_color(tokens.secondary_text)
                        .child(tr(
                            "Exports the current working tree as a local patch that can be restored later.",
                        )),
                );
            if let Some(input) = self.shelf_name_input.as_ref() {
                dialog = dialog.child(Input::new(input).small().w_full());
            }
            dialog = dialog.child(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap(px(8.0))
                    .child(
                        Button::new("lithe-git-shelf-create-cancel")
                            .ghost()
                            .small()
                            .label(tr("Cancel"))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.cancel_shelf_create(cx);
                            })),
                    )
                    .child(
                        Button::new("lithe-git-shelf-create-ok")
                            .primary()
                            .small()
                            .label(tr("Save"))
                            .disabled(self.shelf_busy)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.confirm_shelf_create(cx);
                            })),
                    ),
            );
            div()
                .id("lithe-git-shelf-create-backdrop")
                .absolute()
                .inset_0()
                .flex()
                .items_center()
                .justify_center()
                .bg(tokens.window.alpha(0.62))
                .on_click(cx.listener(|this, _, _, cx| this.cancel_shelf_create(cx)))
                .child(dialog)
                .into_any_element()
        } else {
            let id = self.pending_shelf_delete.clone()?;
            let name = self
                .shelves
                .iter()
                .find(|shelf| shelf.id == id)
                .map(|shelf| shelf.name.clone())
                .unwrap_or_else(|| id.clone());
            div()
                .id("lithe-git-shelf-delete-backdrop")
                .absolute()
                .inset_0()
                .flex()
                .items_center()
                .justify_center()
                .bg(tokens.window.alpha(0.62))
                .on_click(cx.listener(|this, _, _, cx| this.cancel_delete_shelf(cx)))
                .child(
                    v_flex()
                        .id("lithe-git-shelf-delete")
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
                                .child(tr("Delete saved changes?")),
                        )
                        .child(
                            div()
                                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                                .text_color(tokens.secondary_text)
                                .child(name),
                        )
                        .child(
                            h_flex()
                                .w_full()
                                .justify_end()
                                .gap(px(8.0))
                                .child(
                                    Button::new("lithe-git-shelf-delete-cancel")
                                        .ghost()
                                        .small()
                                        .label(tr("Cancel"))
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.cancel_delete_shelf(cx);
                                        })),
                                )
                                .child(
                                    Button::new("lithe-git-shelf-delete-confirm")
                                        .danger()
                                        .small()
                                        .label(tr("Delete"))
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.confirm_delete_shelf(cx);
                                        })),
                                ),
                        ),
                )
                .into_any_element()
        };
        Some(body)
    }
}
