//! General 页：外观、语言、项目落点、Git 策略、自动保存与隐藏路径。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{AnyElement, ClickEvent, Context, IntoElement, ParentElement as _, Styled, Window, div, px};
use lithe_platform::{DarkMode, system_appearance};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens};

use crate::settings::controls::{
    choice_row, on_off, pattern_textarea_field, section_card, setting_row, switch_control,
};
use crate::settings::state::{
    APPEARANCE_MODES, GIT_STRATEGIES, LANGUAGES, PROJECT_OPEN_DESTINATIONS, ChoiceAction,
    SETTINGS_BUTTON_HEIGHT, SETTINGS_BUTTON_RADIUS, SETTINGS_CONTROL_GAP, SETTINGS_OPTION_MIN_WIDTH,
    SETTINGS_SECTION_GAP, THEMES,
};
use crate::settings::SettingsView;

impl SettingsView {
    pub(in crate::settings) fn render_general(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        // Tauri General › Appearance：颜色主题 + 外观模式。
        let appearance = div()
            .w_full()
            .flex()
            .flex_col()
            .child(choice_row(
                "Color Theme",
                "lithe-settings:theme",
                &THEMES,
                &self.settings.theme,
                ChoiceAction::Theme,
                cx,
                tokens,
            ))
            .child(choice_row(
                "Appearance mode",
                "lithe-settings:appearance-mode",
                &APPEARANCE_MODES,
                &self.settings.appearance_mode,
                ChoiceAction::AppearanceMode,
                cx,
                tokens,
            ));

        let language = div().w_full().flex().flex_col().child(choice_row(
            "Language",
            "lithe-settings:language",
            &LANGUAGES,
            &self.settings.language,
            ChoiceAction::Language,
            cx,
            tokens,
        ));

        // Tauri General › Projects：打开另一个项目时的默认落点。
        let projects = div().w_full().flex().flex_col().child(choice_row(
            "Open projects in",
            "lithe-settings:project-open-destination",
            &PROJECT_OPEN_DESTINATIONS,
            &self.settings.project_open_destination,
            ChoiceAction::ProjectOpenDestination,
            cx,
            tokens,
        ));

        // Tauri General › Files：保存后自动保存。
        let files = div().w_full().flex().flex_col().child(setting_row(
            "Save changed files automatically",
            switch_control(
                "lithe-settings:auto-save",
                self.settings.auto_save,
                "Save changed files automatically",
                cx.listener(|this, checked: &bool, window, cx| {
                    this.set_auto_save(*checked, window, cx);
                }),
            ),
            on_off(self.settings.auto_save),
            tokens,
        ));

        // Tauri General › Git strategy：这是未持久化的本地 state（与 Tauri 一致，
        // 仅会话内记忆），不写入 AppSettings。
        let git_strategy = div().w_full().flex().flex_col().child(
            v_flex()
                .w_full()
                .gap(px(SETTINGS_CONTROL_GAP))
                .child(
                    h_flex().flex_wrap().gap(px(SETTINGS_CONTROL_GAP)).children(
                        GIT_STRATEGIES.iter().map(|&(value, title)| {
                            let is_selected = self.git_strategy == value;
                            Button::new(format!("lithe-settings:git-strategy:{value}"))
                                .small()
                                .h(px(SETTINGS_BUTTON_HEIGHT))
                                .rounded(px(SETTINGS_BUTTON_RADIUS))
                                .min_w(px(SETTINGS_OPTION_MIN_WIDTH))
                                .when(is_selected, |button| button.primary())
                                .when(!is_selected, |button| button.secondary())
                                .label(tr(title))
                                .on_click(cx.listener(
                                    move |this, _: &ClickEvent, _window, cx| {
                                        this.set_git_strategy(value, cx);
                                    },
                                ))
                        }),
                    ),
                )
                .child(
                    div()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.tertiary_text)
                        .child(tr(
                            "How local changes are kept before a checkout or rebase. The choice is remembered for this session only.",
                        )),
                ),
        );

        // Tauri General › Hidden paths：目录与文件模式 + Apply（多行 Textarea）。
        let hidden_paths = div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(10.0))
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr(
                        "One entry per line. Directory names hide matching folders; file entries support * and ?.",
                    )),
            )
            .child(pattern_textarea_field(
                "Directories",
                &self.hidden_directories,
                tokens,
            ))
            .child(pattern_textarea_field("File patterns", &self.hidden_files, tokens))
            .child(
                div().w_full().flex().justify_end().child(
                    Button::new("lithe-settings:hidden-paths:apply")
                        .small()
                        .h(px(SETTINGS_BUTTON_HEIGHT))
                        .rounded(px(SETTINGS_BUTTON_RADIUS))
                        .primary()
                        .label(tr("Apply"))
                        .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                            this.apply_hidden_patterns(window, cx);
                        })),
                ),
            );

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                "Appearance",
                None,
                appearance.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Language",
                None,
                language.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Projects",
                None,
                projects.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Git strategy",
                None,
                git_strategy.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Files",
                None,
                files.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Hidden paths",
                None,
                hidden_paths.into_any_element(),
                tokens,
            ))
            .into_any_element()
    }

    // -----------------------------------------------------------------
    // General 写入方法
    // -----------------------------------------------------------------

    pub(in crate::settings) fn set_theme(
        &mut self,
        theme: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.theme.eq_ignore_ascii_case(theme) {
            return;
        }
        self.settings.theme = theme.to_string();
        self.commit(window, cx);
    }

    pub(in crate::settings) fn set_language(
        &mut self,
        language: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.language.eq_ignore_ascii_case(language) {
            return;
        }
        self.settings.language = language.to_string();
        // 先切全局语言，下一次渲染就会取到新词条。
        lithe_ui::i18n::set_language(language);
        self.commit(window, cx);
    }

    /// 外观模式：`system` 跟随系统深浅色（platform adapter；不可用时保持当前值）。
    pub(in crate::settings) fn set_appearance_mode(
        &mut self,
        mode: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.appearance_mode == mode {
            return;
        }
        self.settings.appearance_mode = mode.to_string();
        match mode {
            "dark" => self.settings.dark = true,
            "light" => self.settings.dark = false,
            // `system`：一次性的系统外观消费；后续系统切换的重读由设置页
            // 重新打开触发（区域内的命令查询不适合放进渲染循环轮询）。
            _ => {
                if let Some(dark) = system_appearance() {
                    self.settings.dark = dark == DarkMode::Dark;
                }
            }
        }

        self.commit(window, cx);
    }

    /// 打开项目时的默认落点。GPUI 目前按 `this-window` 打开；其余值先持久化。
    pub(in crate::settings) fn set_project_open_destination(
        &mut self,
        destination: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.project_open_destination == destination {
            return;
        }
        self.settings.project_open_destination = destination.to_string();
        self.commit(window, cx);
    }

    pub(in crate::settings) fn set_auto_save(
        &mut self,
        checked: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.auto_save == checked {
            return;
        }
        self.settings.auto_save = checked;
        self.commit(window, cx);
    }

    /// Git 策略选择。Tauri 把它放在 General 页的非持久化本地 state；这里
    /// 同样只保留在会话内，供后续重写入口消费。
    pub(in crate::settings) fn set_git_strategy(&mut self, strategy: &'static str, cx: &mut Context<Self>) {
        if self.git_strategy == strategy {
            return;
        }
        self.git_strategy = strategy;
        cx.notify();
    }

    /// 保存隐藏路径模式：按行或逗号切分，空项丢弃。
    pub(in crate::settings) fn apply_hidden_patterns(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let parse = |value: String| -> Vec<String> {
            value
                .split(['\n', ','])
                .map(str::trim)
                .filter(|entry| !entry.is_empty())
                .map(str::to_string)
                .collect()
        };

        let directories = parse(self.hidden_directories.read(cx).value().to_string());
        let files = parse(self.hidden_files.read(cx).value().to_string());
        if self.settings.hidden_directory_patterns == directories
            && self.settings.hidden_file_patterns == files
        {
            return;
        }
        self.settings.hidden_directory_patterns = directories;
        self.settings.hidden_file_patterns = files;
        self.commit(window, cx);
    }
}
