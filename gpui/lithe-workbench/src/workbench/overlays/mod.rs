//! 工作台覆盖层系统（设置页、命令面板、命名弹窗、关闭确认）。

use gpui_kit::{AnyElement, Context, Window};

use super::Workbench;

mod close_confirm;
mod palette;
mod prompt;
mod settings;

pub(crate) mod git_dialogs;
// `git_dialogs_manage.rs` 在 `impl GitDialogView` 上补充 Branch/Worktree/
// Patch/Rebase 的渲染与动作；不声明该模块时 git_dialogs.rs 对这些方法的
// 调用会报“不存在”。
pub(crate) mod git_dialogs_manage;
pub(crate) mod git_dialogs_pull;

pub(crate) use palette::PaletteMode;
pub(crate) use prompt::PromptAction;

impl Workbench {
    /// 覆盖层入口。没有覆盖层打开时不返回任何元素。
    pub(crate) fn render_overlay(
        &self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if self.pending_quit {
            Some(self.render_quit_confirm_overlay(window, cx))
        } else if self.pending_close_tab.is_some()
            && self
                .tabs
                .iter()
                .any(|tab| Some(&tab.id) == self.pending_close_tab.as_ref())
        {
            Some(self.render_close_confirm_overlay(window, cx))
        } else if self.settings_visible {
            Some(self.render_settings_overlay(window, cx))
        } else if self.palette_visible {
            Some(self.render_palette_overlay(window, cx))
        } else if self.prompt.is_some() {
            Some(self.render_prompt_overlay(window, cx))
        } else {
            None
        }
    }

    /// 关闭所有覆盖层。
    pub(crate) fn close_overlay(&mut self, cx: &mut Context<Self>) {
        if !self.settings_visible
            && !self.palette_visible
            && !self.notifications_visible
            && self.pending_close_tab.is_none()
            && !self.pending_quit
            && self.prompt.is_none()
        {
            return;
        }
        self.settings_visible = false;
        self.palette_visible = false;
        self.palette_mode = PaletteMode::Commands;
        self.history_snapshots.clear();
        self.history_target = None;
        self.notifications_visible = false;
        self.pending_close_tab = None;
        self.pending_quit = false;
        self.prompt = None;
        self.prompt_action = None;
        self.pending_new_project_parent = None;
        cx.notify();
    }
}
