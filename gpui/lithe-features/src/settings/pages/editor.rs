//! Editor 页：字体族、字号、连字、预览、Code Lens、minimap、标签布局、缩进与
//! gpui 独有开关。

use std::sync::OnceLock;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenu, PopupMenuItem};
use gpui_kit::component::{Sizable as _};
use gpui_kit::{
    AnyElement, ClickEvent, Context, IntoElement, ParentElement as _, SharedString, Styled,
    Window, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens};

use crate::settings::controls::{
    choice_row, font_preview, on_off, section_card, setting_row, stepper_row, switch_control,
};
use crate::settings::state::{
    ChoiceAction, DEFAULT_EDITOR_FONT_SIZE, MAX_EDITOR_FONT_SIZE, MIN_EDITOR_FONT_SIZE,
    SETTINGS_BUTTON_HEIGHT, SETTINGS_BUTTON_RADIUS, SETTINGS_SECTION_GAP, StepperAction,
    TAB_LAYOUTS, TAB_WIDTHS,
};
use crate::settings::SettingsView;

/// 编辑器可选的等宽字体候选；交叉本机安装列表后展示。
///
/// Tauri 用 DirectWrite/NSFontManager 检测等宽属性；gpui 的文本系统不暴露
/// 字体度量枚举，这里退化为「常见等宽字体候选 ∩ 已安装字体」，下拉只列等宽
/// 字体（差异已在 plan-01 §4.4 注明）。
const MONO_FONT_CANDIDATES: [&str; 14] = [
    "JetBrains Mono",
    "Cascadia Code",
    "Cascadia Mono",
    "Consolas",
    "SF Mono",
    "Menlo",
    "Monaco",
    "DejaVu Sans Mono",
    "Liberation Mono",
    "Noto Sans Mono",
    "Fira Code",
    "Source Code Pro",
    "IBM Plex Mono",
    "Courier New",
];

static MONO_FONT_CHOICES: OnceLock<Vec<String>> = OnceLock::new();

/// 在拿到 `Window` 的渲染帧里刷新等宽字体清单（进程内稳定，只算一次）。
/// `Window::text_system` 直接可取，不依赖 Context deref。
pub(in crate::settings) fn snapshot_editor_font_choices(window: &Window) {
    let installed = window.text_system().all_font_names();
    MONO_FONT_CHOICES.get_or_init(|| {
        MONO_FONT_CANDIDATES
            .iter()
            .filter(|candidate| {
                installed
                    .iter()
                    .any(|name| name.eq_ignore_ascii_case(candidate))
            })
            .map(|candidate| (*candidate).to_string())
            .collect()
    });
}

impl SettingsView {
    pub(in crate::settings) fn render_editor(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let selected_family = self
            .settings
            .editor_font_family
            .clone()
            .unwrap_or_default();

        let display = div()
            .w_full()
            .flex()
            .flex_col()
            .child(self.render_editor_font_family(&selected_family, tokens, cx))
            .child(stepper_row(
                "Font size",
                "lithe-settings:editor-font-size",
                self.settings.editor_font_size,
                MIN_EDITOR_FONT_SIZE,
                MAX_EDITOR_FONT_SIZE,
                DEFAULT_EDITOR_FONT_SIZE,
                StepperAction::EditorFontSize,
                SharedString::from(format!(
                    "{} pt",
                    self.settings.editor_font_size.round() as i32
                )),
                cx,
                tokens,
            ))
            .child(setting_row(
                "Font Ligatures",
                switch_control(
                    "lithe-settings:editor-font-ligatures",
                    self.settings.editor_font_ligatures,
                    "Font Ligatures",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.set_editor_font_ligatures(*checked, window, cx);
                    }),
                ),
                on_off(self.settings.editor_font_ligatures),
                tokens,
            ))
            .child(font_preview(
                &selected_family,
                self.settings.editor_font_size,
                self.settings.editor_font_ligatures,
                tokens,
            ))
            .child(choice_row(
                "Editor tabs layout",
                "lithe-settings:editor-tab-layout",
                &TAB_LAYOUTS,
                &self.settings.editor_tab_layout,
                ChoiceAction::EditorTabLayout,
                cx,
                tokens,
            ))
            .child(setting_row(
                "Show usages and Git author",
                switch_control(
                    "lithe-settings:editor-code-lens",
                    self.settings.editor_code_lens,
                    "Show usages and Git author",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.set_editor_code_lens(*checked, window, cx);
                    }),
                ),
                on_off(self.settings.editor_code_lens),
                tokens,
            ))
            .child(setting_row(
                "Wrap lines",
                switch_control(
                    "lithe-settings:editor-wrap",
                    self.settings.editor_wrap,
                    "Wrap lines",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.set_editor_wrap(*checked, window, cx);
                    }),
                ),
                on_off(self.settings.editor_wrap),
                tokens,
            ))
            .child(setting_row(
                "Minimap",
                switch_control(
                    "lithe-settings:editor-minimap",
                    self.settings.editor_minimap,
                    "Show minimap",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.set_editor_minimap(*checked, window, cx);
                    }),
                ),
                on_off(self.settings.editor_minimap),
                tokens,
            ))
            .child(setting_row(
                "Line numbers",
                switch_control(
                    "lithe-settings:editor-line-numbers",
                    self.settings.editor_line_numbers,
                    "Show line numbers",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.set_editor_line_numbers(*checked, window, cx);
                    }),
                ),
                on_off(self.settings.editor_line_numbers),
                tokens,
            ))
            .child(setting_row(
                "Render Whitespace",
                switch_control(
                    "lithe-settings:editor-render-whitespace",
                    self.settings.editor_render_whitespace,
                    "Render Whitespace",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.set_editor_render_whitespace(*checked, window, cx);
                    }),
                ),
                on_off(self.settings.editor_render_whitespace),
                tokens,
            ))
            .child(setting_row(
                "Scroll beyond last line",
                switch_control(
                    "lithe-settings:editor-scroll-beyond",
                    self.settings.editor_scroll_beyond_last_line,
                    "Scroll beyond last line",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.set_editor_scroll_beyond_last_line(*checked, window, cx);
                    }),
                ),
                on_off(self.settings.editor_scroll_beyond_last_line),
                tokens,
            ));

        // Tauri Editor › Indentation：Tab 宽度。
        let indentation = div().w_full().flex().flex_col().child(choice_row(
            "Tab width",
            "lithe-settings:editor-tab-size",
            &TAB_WIDTHS,
            &self.settings.editor_tab_size.to_string(),
            ChoiceAction::EditorTabSize,
            cx,
            tokens,
        ));

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                "Display",
                None,
                display.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Indentation",
                None,
                indentation.into_any_element(),
                tokens,
            ))
            .into_any_element()
    }

    /// 字体族选择：gpui-kit `Button.dropdown_menu` 的 PopupMenu，与 Git 页
    /// 白名单字段同一形态（gpui-kit 的 SelectState 需要 Entity + 数据提供者，
    /// 对一行设置而言过重；引擎与本页一致选 popup）。
    fn render_editor_font_family(
        &self,
        selected_family: &str,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let label = if selected_family.trim().is_empty() {
            tr("Default (built-in monospace)").to_string()
        } else {
            // 字体族名是语言无关标识，不经过 i18n。
            selected_family.to_string()
        };
        let selected = selected_family.to_string();
        let choices = MONO_FONT_CHOICES.get().cloned().unwrap_or_default();
        let owner = cx.weak_entity();

        setting_row(
            "Font family",
            Button::new("lithe-settings:editor-font-family")
                .small()
                .h(px(SETTINGS_BUTTON_HEIGHT))
                .rounded(px(SETTINGS_BUTTON_RADIUS))
                .secondary()
                .label(SharedString::from(label.to_string()))
                .dropdown_menu(move |menu: PopupMenu, _, _| {
                    let mut menu = menu;
                    for choice in &choices {
                        let owner = owner.clone();
                        let choice = choice.clone();
                        let checked = choice.eq_ignore_ascii_case(&selected);
                        let label = SharedString::from(choice.clone());
                        menu = menu.item(
                            PopupMenuItem::new(label)
                                .checked(checked)
                                .on_click(move |_, _, cx| {
                                    let _ = owner.update(cx, |this, cx| {
                                        this.pending_editor_font_family(Some(choice.clone()));
                                        cx.notify();
                                    });
                                }),
                        );
                    }
                    // 恢复默认：写回空（内置等宽字体）。
                    let owner = owner.clone();
                    menu.item(
                        PopupMenuItem::new(tr("Default (built-in monospace)"))
                            .checked(selected.trim().is_empty())
                            .on_click(move |_, _, cx| {
                                let _ = owner.update(cx, |this, cx| {
                                    this.pending_editor_font_family(None);
                                    cx.notify();
                                });
                            }),
                    )
                })
                .into_any_element(),
            SharedString::default(),
            tokens,
        )
    }

    pub(in crate::settings) fn adjust_editor_font_size(
        &mut self,
        delta: i32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let next = crate::settings::state::normalized_font_size(
            self.settings.editor_font_size + delta as f32,
            DEFAULT_EDITOR_FONT_SIZE,
        );
        if (next - self.settings.editor_font_size).abs() < f32::EPSILON {
            return;
        }
        self.settings.editor_font_size = next;
        self.commit(window, cx);
    }

    pub(in crate::settings) fn set_editor_tab_layout(
        &mut self,
        value: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.editor_tab_layout == value {
            return;
        }
        self.settings.editor_tab_layout = value.to_string();
        self.commit(window, cx);
    }

    /// 字体下拉没有 Window / App 的 Context 路径，先挂 pending，Render 里
    /// 与其它输入框回填同一帧应用（模式与 git 身份回填一致）。
    pub(in crate::settings) fn pending_editor_font_family(&mut self, family: Option<String>) {
        self.editor_font_pending = Some(family);
    }

    /// Render 帧应用字体选择：`None` 表示清除回内置等宽字体。
    pub(in crate::settings) fn apply_editor_font_pending(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(family) = self.editor_font_pending.take() {
            self.settings.editor_font_family =
                Some(family.unwrap_or_default().trim().to_string())
                    .filter(|value| !value.is_empty());
            self.commit(window, cx);
        }
    }

    pub(in crate::settings) fn set_editor_wrap(&mut self, wrap: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.settings.editor_wrap == wrap {
            return;
        }
        self.settings.editor_wrap = wrap;
        self.commit(window, cx);
    }

    pub(in crate::settings) fn set_editor_minimap(
        &mut self,
        minimap: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.editor_minimap == minimap {
            return;
        }
        self.settings.editor_minimap = minimap;
        self.commit(window, cx);
    }

    pub(in crate::settings) fn set_editor_font_ligatures(
        &mut self,
        enabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.editor_font_ligatures == enabled {
            return;
        }
        self.settings.editor_font_ligatures = enabled;
        self.commit(window, cx);
    }

    pub(in crate::settings) fn set_editor_code_lens(
        &mut self,
        enabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.editor_code_lens == enabled {
            return;
        }
        self.settings.editor_code_lens = enabled;
        self.commit(window, cx);
    }

    pub(in crate::settings) fn set_editor_tab_size(
        &mut self,
        size: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Ok(size) = size.parse::<u32>() else {
            return;
        };
        if self.settings.editor_tab_size == size {
            return;
        }
        self.settings.editor_tab_size = size;
        self.commit(window, cx);
    }

    pub(in crate::settings) fn set_editor_line_numbers(
        &mut self,
        enabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.editor_line_numbers == enabled {
            return;
        }
        self.settings.editor_line_numbers = enabled;
        self.commit(window, cx);
    }

    pub(in crate::settings) fn set_editor_render_whitespace(
        &mut self,
        enabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.editor_render_whitespace == enabled {
            return;
        }
        self.settings.editor_render_whitespace = enabled;
        self.commit(window, cx);
    }

    pub(in crate::settings) fn set_editor_scroll_beyond_last_line(
        &mut self,
        enabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.editor_scroll_beyond_last_line == enabled {
            return;
        }
        self.settings.editor_scroll_beyond_last_line = enabled;
        self.commit(window, cx);
    }
}
