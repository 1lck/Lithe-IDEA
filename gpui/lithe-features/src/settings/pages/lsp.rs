//! LSP 页：语言服务开关与 Java 项目导入方式。

use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::component::{Sizable as _, h_flex, v_flex};
use gpui_kit::{AnyElement, Context, IntoElement, ParentElement as _, SharedString, Styled, Window, div, px};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens};

use crate::settings::controls::{caption_line, choice_row, described_row, section_card, setting_row, switch_control};
use crate::settings::state::{SETTINGS_SECTION_GAP, ChoiceAction};
use crate::settings::SettingsView;

impl SettingsView {
    pub(in crate::settings) fn render_lsp(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let rows = v_flex()
            .w_full()
            .child(described_row(
                "Auto completion",
                Some(SharedString::from(tr(
                    "Show completion suggestions from the active language server.",
                ))),
                switch_control(
                    "lithe-settings:lsp-auto-completion",
                    self.settings.auto_completion,
                    "Auto completion",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.apply_toggle(
                            crate::settings::state::ToggleAction::AutoCompletion,
                            *checked,
                            window,
                            cx,
                        )
                    }),
                ),
                tokens,
            ))
            .child(setting_row(
                "Parameter hints",
                switch_control(
                    "lithe-settings:lsp-parameter-hints",
                    self.settings.parameter_hints,
                    "Parameter hints",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.apply_toggle(
                            crate::settings::state::ToggleAction::ParameterHints,
                            *checked,
                            window,
                            cx,
                        )
                    }),
                ),
                SharedString::default(),
                tokens,
            ))
            .child(setting_row(
                "Semantic highlighting",
                switch_control(
                    "lithe-settings:lsp-semantic-tokens",
                    self.settings.semantic_tokens,
                    "Semantic highlighting",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.apply_toggle(
                            crate::settings::state::ToggleAction::SemanticTokens,
                            *checked,
                            window,
                            cx,
                        )
                    }),
                ),
                SharedString::default(),
                tokens,
            ))
            .child(choice_row(
                "Import Java projects on open",
                "lithe-settings:lsp-java-import",
                &[
                    ("automatic", "Automatically"),
                    ("ask", "Ask"),
                    ("manual", "Manually"),
                ],
                &self.settings.java_project_import_on_open,
                ChoiceAction::JavaProjectImport,
                cx,
                tokens,
            ))
            .child(caption_line(
                SharedString::from(tr(
                    "Ask lets you adjust Maven settings first. Manual waits until you open a Java file, run code, or reload Maven.",
                )),
                tokens,
            ));

        let detected = v_flex().w_full().child(
            div()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(tr(
                    "Language servers are detected from installed language extensions and start when a supported file opens.",
                )),
        );

        v_flex()
            .w_full()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                "Language services",
                None,
                rows.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Detected language servers",
                None,
                detected.into_any_element(),
                tokens,
            ))
            .into_any_element()
    }

    /// Java 项目打开时的导入方式；对齐 Tauri `javaProjectImportOnOpen`。
    pub(in crate::settings) fn set_java_project_import_on_open(
        &mut self,
        value: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.java_project_import_on_open == value {
            return;
        }
        self.settings.java_project_import_on_open = value.to_string();
        self.commit(window, cx);
    }
}
