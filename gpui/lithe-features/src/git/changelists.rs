//! 本地 changelist 存储（对齐 Tauri `git-changelists.store.ts` +
//! `git-changelist-storage.ts`：本质是本地持久化的「变更分组」标签）。
//!
//! 持久化到应用数据目录的 `changelists.json`（复用 settings 的
//! `app_data_dir`：Windows `%APPDATA%\Lithe`、macOS `Application Support/Lithe`、
//! Linux `$XDG_CONFIG_HOME/lithe`）。只写平台可写目录，不触碰安装目录。

use std::collections::BTreeMap;
use std::path::PathBuf;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::radio::Radio;
use gpui_kit::component::{Sizable as _, h_flex, v_flex};
use gpui_kit::{
    AnyElement, AppContext as _, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::LitheMetrics;
use serde_json::Value;

use super::GitPanel;

const STORE_FILE_NAME: &str = "changelists.json";

/// 一个本地 changelist：名字 + 是否默认（默认项不可删除 / 重命名）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Changelist {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) default: bool,
}

/// `file → changelist_id` 的本地映射；文件按工作区相对路径作键。
#[derive(Debug, Clone, Default)]
pub(crate) struct ChangelistStore {
    lists: Vec<Changelist>,
    active_id: String,
    file_map: BTreeMap<String, String>,
}

impl ChangelistStore {
    /// 构建并从磁盘加载；加载失败时回退到只含默认项的空 store。
    pub(crate) fn load() -> Self {
        let mut store = Self {
            lists: vec![Changelist {
                id: "default".to_string(),
                name: tr("Default Changelist").to_string(),
                default: true,
            }],
            active_id: "default".to_string(),
            file_map: BTreeMap::new(),
        };
        store.absorb(store.read_disk());
        store
    }

    fn disk_path() -> Option<PathBuf> {
        super::super::settings::app_data_dir().map(|directory| directory.join(STORE_FILE_NAME))
    }

    fn read_disk(&self) -> Option<Value> {
        let path = Self::disk_path()?;
        let text = std::fs::read_to_string(path).ok()?;
        serde_json::from_str(&text).ok()
    }

    /// 把磁盘 JSON 合并进 store；形状不对的字段直接忽略。
    fn absorb(&mut self, value: Option<Value>) {
        let Some(value) = value else {
            return;
        };
        if let Some(lists) = value.get("lists").and_then(Value::as_array) {
            for item in lists {
                let id = item
                    .get("id")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                if id.is_empty() || self.lists.iter().any(|list| list.id == id) {
                    continue;
                }
                self.lists.push(Changelist {
                    id: id.clone(),
                    name: item
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or(&id)
                        .to_string(),
                    default: false,
                });
            }
        }
        if let Some(active) = value.get("activeId").and_then(Value::as_str) {
            if self.lists.iter().any(|list| list.id == active) {
                self.active_id = active.to_string();
            }
        }
        if let Some(map) = value.get("files").and_then(Value::as_object) {
            for (path, id) in map {
                if let Some(id) = id.as_str() {
                    self.file_map.insert(path.clone(), id.to_string());
                }
            }
        }
    }

    /// 序列化到磁盘；写失败静默（下次修改再试），不阻塞界面。
    fn persist(&self) {
        let Some(path) = Self::disk_path() else {
            return;
        };
        let value = serde_json::json!({
            "lists": self.lists.iter().map(|list| serde_json::json!({
                "id": list.id,
                "name": list.name,
                "default": list.default,
            })).collect::<Vec<_>>(),
            "activeId": self.active_id,
            "files": self.file_map,
        });
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(path, value.to_string());
    }

    pub(crate) fn names(&self) -> Vec<(String, String)> {
        self.lists
            .iter()
            .map(|list| (list.id.clone(), list.name.clone()))
            .collect()
    }

    pub(crate) fn active_name(&self) -> String {
        self.lists
            .iter()
            .find(|list| list.id == self.active_id)
            .map(|list| list.name.clone())
            .unwrap_or_else(|| tr("Default Changelist").to_string())
    }

    /// 非 default 的激活列表才可以编辑 / 删除。
    pub(crate) fn can_edit_active(&self) -> bool {
        self.active_id != "default"
            && self
                .lists
                .iter()
                .any(|list| list.id == self.active_id && !list.default)
    }

    pub(crate) fn set_active(&mut self, id: &str) {
        if self.lists.iter().any(|list| list.id == id) {
            self.active_id = id.to_string();
            self.persist();
        }
    }

    /// 当前激活列表的 id（Move to Changelist 的默认目标）。
    pub(crate) fn active_id(&self) -> String {
        self.active_id.clone()
    }

    pub(crate) fn create(&mut self, name: &str) {
        let name = name.trim();
        if name.is_empty() {
            return;
        }
        let id = format!("list-{}", uuid_like());
        self.lists.push(Changelist {
            id: id.clone(),
            name: name.to_string(),
            default: false,
        });
        self.active_id = id;
        self.persist();
    }

    pub(crate) fn rename_active(&mut self, name: &str) {
        let name = name.trim();
        if name.is_empty() || !self.can_edit_active() {
            return;
        }
        if let Some(list) = self
            .lists
            .iter_mut()
            .find(|list| list.id == self.active_id)
        {
            list.name = name.to_string();
        }
        self.persist();
    }

    pub(crate) fn delete_active(&mut self) {
        if !self.can_edit_active() {
            return;
        }
        let removed = self.active_id.clone();
        self.lists.retain(|list| list.id != removed);
        // 文件映射回到默认列表。
        self.file_map.retain(|_, id| id != &removed);
        self.active_id = "default".to_string();
        self.persist();
    }

    /// 把文件移入激活的 changelist（右键 Move to Changelist）。
    pub(crate) fn move_files(&mut self, paths: &[String], target_id: &str) {
        for path in paths {
            self.file_map.insert(path.clone(), target_id.to_string());
        }
        self.persist();
    }

    /// 某个文件归属的 changelist 名（changelist 栏高亮用，暂未在行上展示）。
    #[allow(dead_code)]
    pub(crate) fn list_of_file(&self, path: &str) -> Option<String> {
        let id = self.file_map.get(path)?;
        Some(
            self.lists
                .iter()
                .find(|list| &list.id == id)
                .map(|list| list.name.clone())
                .unwrap_or_else(|| tr("Default Changelist").to_string()),
        )
    }
}

/// 无 uuid 依赖的稳定 id：纳秒时钟 + 计数即可满足本地唯一性。
fn uuid_like() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let count = COUNTER.fetch_add(1, Ordering::Relaxed);
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    format!("{stamp:x}{count:x}")
}

/// changelist 输入弹窗的操作类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ChangelistPrompt {
    New,
    Rename,
}

impl GitPanel {
    /// 打开新建 / 重命名 changelist 的输入弹窗。
    pub(crate) fn request_changelist_name(
        &mut self,
        prompt: ChangelistPrompt,
        window: &mut gpui_kit::Window,
        cx: &mut gpui_kit::Context<Self>,
    ) {
        if self.pending_action.is_some() || self.committing {
            return;
        }
        self.changelist_prompt = Some(prompt);
        self.changelist_input = None;
        // 事件回调里已经拿到 Window，输入框在弹窗打开时创建一次；
        // 不在 render 里补建，否则弹窗首帧会没有输入框。
        self.ensure_changelist_input(window, cx);
        cx.notify();
    }

    /// 惰性创建 changelist 输入框；InputState::new 需要 Window，只能在 render 期调用。
    pub(crate) fn ensure_changelist_input(
        &mut self,
        window: &mut gpui_kit::Window,
        cx: &mut gpui_kit::Context<Self>,
    ) {
        if self.changelist_prompt.is_none() || self.changelist_input.is_some() {
            return;
        }
        let initial = match self.changelist_prompt {
            Some(ChangelistPrompt::Rename) => self.changelists.active_name(),
            _ => String::new(),
        };
        let input = cx.new(|cx| {
            gpui_kit::component::input::InputState::new(window, cx)
                .placeholder(tr("Changelist name"))
                .default_value(initial)
        });
        self.changelist_input = Some(input);
        cx.notify();
    }

    pub(crate) fn submit_changelist_prompt(&mut self, cx: &mut gpui_kit::Context<Self>) {
        let Some(prompt) = self.changelist_prompt.take() else {
            return;
        };
        let value = self
            .changelist_input
            .take()
            .map(|input| input.read(cx).value().trim().to_string())
            .unwrap_or_default();
        if !value.is_empty() {
            match prompt {
                ChangelistPrompt::New => self.changelists.create(&value),
                ChangelistPrompt::Rename => self.changelists.rename_active(&value),
            }
        }
        cx.notify();
    }

    pub(crate) fn cancel_changelist_prompt(&mut self, cx: &mut gpui_kit::Context<Self>) {
        if self.changelist_prompt.take().is_some() {
            self.changelist_input = None;
            cx.notify();
        }
    }

    pub(crate) fn delete_active_changelist(&mut self, cx: &mut gpui_kit::Context<Self>) {
        if !self.changelists.can_edit_active() {
            return;
        }
        self.changelists.delete_active();
        cx.notify();
    }

    /// 右键 Move to Changelist：进入选择弹窗（列表单选 + 确认）。
    pub(crate) fn request_move_to_changelist(
        &mut self,
        paths: Vec<String>,
        cx: &mut gpui_kit::Context<Self>,
    ) {
        if paths.is_empty() {
            return;
        }
        self.pending_move_to_changelist = Some(paths);
        self.move_target_id = Some(self.changelists.active_id());
        cx.notify();
    }

    pub(crate) fn confirm_move_to_changelist(&mut self, cx: &mut gpui_kit::Context<Self>) {
        let Some(paths) = self.pending_move_to_changelist.take() else {
            return;
        };
        let target = self.move_target_id.clone().unwrap_or_else(|| "default".into());
        self.changelists.move_files(&paths, &target);
        cx.notify();
    }

    pub(crate) fn cancel_move_to_changelist(&mut self, cx: &mut gpui_kit::Context<Self>) {
        if self.pending_move_to_changelist.take().is_some() {
            cx.notify();
        }
    }

    /// changelist 输入 / Move 弹窗覆盖层（与丢弃确认同一模态结构）。
    pub(crate) fn render_changelist_overlays(
        &self,
        tokens: lithe_ui::LitheTokens,
        cx: &mut gpui_kit::Context<Self>,
    ) -> Option<AnyElement> {
        // Move to Changelist 选择弹窗。
        if let Some(paths) = self.pending_move_to_changelist.as_ref() {
            let owner = cx.weak_entity();
            let mut dialog = v_flex()
                .id("lithe-git-move-changelist")
                .w(px(420.0))
                .rounded(px(LitheMetrics::MENU_RADIUS))
                .border_1()
                .border_color(tokens.panel_border)
                .bg(tokens.raised)
                .p(px(16.0))
                .gap(px(10.0))
                .on_click(cx.listener(|_, _, _, cx| cx.stop_propagation()));
            dialog = dialog.child(
                div()
                    .text_size(px(14.0))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.primary_text)
                    .child(tr("Move to Changelist")),
            );
            for (id, name) in self.changelists.names() {
                let checked = self.move_target_id.as_deref() == Some(id.as_str());
                // 每个闭包各自持有一份 owner 与 id：`move` 闭包在循环里逐个
                // 构造，不能共享同一个捕获值。
                let owner = owner.clone();
                let id_for_click = id.clone();
                // 互斥选择用 `Radio`，不用 `Checkbox`：读屏会把复选框播报成
                // 可多选，而这里同一时间只能有一个目标。
                dialog = dialog.child(
                    Radio::new(SharedString::from(format!("lithe-git:move-target:{id}")))
                        .small()
                        .w_full()
                        .checked(checked)
                        .label(name)
                        .on_change(move |checked: &bool, _window, cx| {
                            if !checked {
                                return;
                            }
                            let _ = owner.update(cx, |this, cx| {
                                this.move_target_id = Some(id_for_click.clone());
                                cx.notify();
                            });
                        }),
                );
            }
            dialog = dialog.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(
                        tr("{count} files")
                            .replace("{count}", &paths.len().to_string()),
                    ),
            );
            dialog = dialog.child(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap(px(8.0))
                    .child(
                        Button::new("lithe-git-move-cancel")
                            .ghost()
                            .small()
                            .label(tr("Cancel"))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.cancel_move_to_changelist(cx);
                            })),
                    )
                    .child(
                        Button::new("lithe-git-move-confirm")
                            .primary()
                            .small()
                            .label(tr("Move"))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.confirm_move_to_changelist(cx);
                            })),
                    ),
            );
            return Some(
                div()
                    .id("lithe-git-move-changelist-backdrop")
                    .absolute()
                    .inset_0()
                    .flex()
                    .items_center()
                    .justify_center()
                    .bg(tokens.window.alpha(0.62))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.cancel_move_to_changelist(cx);
                    }))
                    .child(dialog)
                    .into_any_element(),
            );
        }

        // 新建 / 重命名输入弹窗。
        let prompt = self.changelist_prompt?;
        let title = match prompt {
            ChangelistPrompt::New => tr("New Changelist"),
            ChangelistPrompt::Rename => tr("Rename Changelist"),
        };
        let mut dialog = v_flex()
            .id("lithe-git-changelist-prompt")
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
            );
        if let Some(input) = self.changelist_input.as_ref() {
            dialog = dialog.child(
                gpui_kit::component::input::Input::new(input)
                    .small()
                    .w_full(),
            );
        }
        dialog = dialog.child(
            h_flex()
                .w_full()
                .justify_end()
                .gap(px(8.0))
                .child(
                    Button::new("lithe-git-changelist-cancel")
                        .ghost()
                        .small()
                        .label(tr("Cancel"))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.cancel_changelist_prompt(cx);
                        })),
                )
                .child(
                    Button::new("lithe-git-changelist-ok")
                        .primary()
                        .small()
                        .label(tr("Save"))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.submit_changelist_prompt(cx);
                        })),
                ),
        );
        Some(
            div()
                .id("lithe-git-changelist-backdrop")
                .absolute()
                .inset_0()
                .flex()
                .items_center()
                .justify_center()
                .bg(tokens.window.alpha(0.62))
                .on_click(cx.listener(|this, _, _, cx| this.cancel_changelist_prompt(cx)))
                .child(dialog)
                .into_any_element(),
        )
    }
}
