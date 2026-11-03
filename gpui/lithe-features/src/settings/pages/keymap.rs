//! Keymap 页：预设、Vim 模式与当前快捷键表（可搜索）。
//!
//! 诚实边界：`app_menu.rs` 的菜单命令注册表是工作台私有（本构建没有暴露
//! 命令级 keymap 编辑通道），因此这里提供与 Tauri keyboard-settings 相同形态
//! 的搜索 + 表格；「逐行编辑 / 导入导出 / 重置全部」等待 keymap 覆盖通道落地，
//! 见 PR 报告遗留项。

use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::{AnyElement, Context, IntoElement, ParentElement as _, SharedString, Styled, Window, div, px};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens};

use crate::settings::controls::{
    choice_row, note_card, readonly_row, section_card, toggle_row,
};
use crate::settings::state::{KEYMAP_PRESETS, ChoiceAction, SETTINGS_SECTION_GAP, ToggleAction};
use crate::settings::SettingsView;

/// 工作台注册的快捷键（与 `workbench/mod.rs` 的 `cx.bind_keys` 一一对应，
/// 快捷键文案与 `app_menu.rs` 的菜单项一致；⌘ 在非 macOS 上是 Ctrl）。
const WORKBENCH_SHORTCUTS: [(&str, &str); 41] = [
    ("New Tab", "⌘N"),
    ("New Window", "⇧⌘N"),
    ("Open Folder", "⌘O"),
    ("Save", "⌘S"),
    ("Save As...", "⇧⌘S"),
    ("Save All", "⌥⌘S"),
    ("Close Tab", "⌘W"),
    ("Close Window", "⇧⌘W"),
    ("Reopen Closed Tab", "⇧⌘T"),
    ("Quit", "⌘Q"),
    ("Toggle Comment", "⌘/"),
    ("Find and Replace", "⌥⌘F"),
    ("Delete Line", "⇧⌘K"),
    ("Move Line Up", "⌥↑"),
    ("Move Line Down", "⌥↓"),
    ("Go to Line", "⌘G"),
    ("Command Palette", "⇧⌘P"),
    ("Toggle Activity Sidebar", "⌘B"),
    ("Toggle Secondary Sidebar", "⌘E"),
    ("Toggle Terminal", "⌘J"),
    ("Global Search", "⇧⌘F"),
    ("Diagnostics", "⇧⌘J"),
    ("File Explorer", "⇧⌘E"),
    ("Source Control", "⇧⌘G"),
    ("Toggle Wrap", "⌥Z"),
    ("Zoom In", "⌘="),
    ("Zoom Out", "⌘-"),
    ("Reset Zoom", "⌘0"),
    ("Quick Open", "⌘P"),
    ("Go to Definition", "F12"),
    ("Go Back", "⌃⌥←"),
    ("Go Forward", "⌃⌥→"),
    ("Next Tab", "⌥⌘→"),
    ("Previous Tab", "⌥⌘←"),
    ("Run", "F5"),
    ("Stop Debugging", "⇧F5"),
    ("Preferences", "⌘,"),
    ("Toggle Menu Bar", "⌥M"),
    ("Minimize", "⌥F9"),
    ("Maximize", "⌥F10"),
    ("Toggle Fullscreen", "F11"),
];

impl SettingsView {
    pub(in crate::settings) fn render_keymap(&mut self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let presets = v_flex()
            .w_full()
            .child(choice_row(
                "Keybinding Preset",
                "lithe-settings:keymap-preset",
                &KEYMAP_PRESETS,
                &self.settings.keymap_preset,
                ChoiceAction::KeymapPreset,
                cx,
                tokens,
            ))
            .child(
                // Tauri keyboard-settings 的覆盖率警告形态：gpui 的预设只有
                // Default/Vim 两档，工作台命令注册表尚未暴露给设置页，真实
                // 覆盖率无法诚实计算——这里不做假数字。
                note_card(
                    SharedString::from(tr(
                        "Preset coverage statistics unlock with the keymap registry channel; Default and Vim presets map the workbench menu bindings.",
                    )),
                    tokens,
                ),
            )
            .child(toggle_row(
                "Vim Mode",
                "lithe-settings:vim-mode",
                self.settings.vim_mode,
                ToggleAction::VimMode,
                cx,
                tokens,
            ));

        // 搜索 + 表格。
        let query = self.keymap_search.read(cx).value().trim().to_lowercase();
        let mut rows = v_flex().w_full();
        let mut matched = 0usize;
        for (action, shortcut) in WORKBENCH_SHORTCUTS {
            let label = tr(action);
            if !query.is_empty()
                && !label.to_lowercase().contains(&query)
                && !shortcut.to_lowercase().contains(&query)
            {
                continue;
            }
            matched += 1;
            rows = rows.child(readonly_row(
                action,
                lithe_ui::shortcut::display_shortcut(shortcut),
                tokens,
            ));
        }
        if matched == 0 {
            rows = rows.child(note_card(
                SharedString::from(tr("No shortcut matches this search.")),
                tokens,
            ));
        }
        let shortcut_table = v_flex()
            .w_full()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(
                Input::new(&self.keymap_search).small().w_full().prefix(
                    gpui_kit::component::Icon::new(gpui_kit::component::IconName::Search)
                        .with_size(px(14.0))
                        .text_color(tokens.tertiary_text),
                ),
            )
            .child(rows);

        v_flex()
            .w_full()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card("Keymap", None, presets.into_any_element(), tokens))
            .child(section_card(
                "Current shortcuts",
                Some("These shortcuts are registered by the GPUI workbench menus."),
                shortcut_table.into_any_element(),
                tokens,
            ))
            .child(note_card(
                SharedString::from(tr(
                    "Per-command editing, JSON import/export and “Reset all” wait for the keymap override channel in this build.",
                )),
                tokens,
            ))
            .into_any_element()
    }

    pub(in crate::settings) fn set_keymap_preset(
        &mut self,
        value: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.keymap_preset == value {
            return;
        }
        self.settings.keymap_preset = value.to_string();
        self.commit(window, cx);
    }
}
