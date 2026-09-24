use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, rgba, Context, EventEmitter, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, StatefulInteractiveElement as _, Styled as _, Window,
};

use crate::theme::ThemeColors;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SettingsCategory {
    General,
    Editor,
    Git,
    Terminal,
}

#[derive(Debug, Clone)]
pub enum SettingsEvent {
    Close,
}

/// 居中设置面板（宽 640px，高 440px）
pub struct SettingsDialog {
    pub active_category: SettingsCategory,
    // General 设置
    pub theme_name: String,
    pub ui_scale: String,
    pub language: String,
    // Editor 设置
    pub font_size: usize,
    pub tab_size: usize,
    pub show_line_numbers: bool,
    pub word_wrap: bool,
    // Git 设置
    pub git_auto_fetch: bool,
    pub git_format_on_commit: bool,
    pub git_gpg_sign: bool,
    // Terminal 设置
    pub default_shell: String,
    pub scrollback_lines: usize,
}

impl EventEmitter<SettingsEvent> for SettingsDialog {}

impl SettingsDialog {
    pub fn new() -> Self {
        Self {
            active_category: SettingsCategory::General,
            theme_name: "Dark Default".to_string(),
            ui_scale: "100%".to_string(),
            language: "English".to_string(),
            font_size: 14,
            tab_size: 4,
            show_line_numbers: true,
            word_wrap: false,
            git_auto_fetch: true,
            git_format_on_commit: true,
            git_gpg_sign: false,
            default_shell: std::env::var("SHELL").unwrap_or_else(|_| "/bin/bash".to_string()),
            scrollback_lines: 1000,
        }
    }

    pub fn set_category(&mut self, cat: SettingsCategory, cx: &mut Context<Self>) {
        self.active_category = cat;
        cx.notify();
    }
}

impl Render for SettingsDialog {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 全屏半透明遮罩
        div()
            .id("settings-dialog-backdrop")
            .absolute()
            .inset_0()
            .bg(rgba(0x00000088))
            .flex()
            .items_center()
            .justify_center()
            .on_mouse_down(
                gpui_kit::MouseButton::Left,
                cx.listener(|_this, _event, _window, cx| {
                    cx.emit(SettingsEvent::Close);
                }),
            )
            .child(
                // 居中模态面板：宽 640px，高 440px
                v_flex()
                    .id("settings-dialog-card")
                    .w(px(640.0))
                    .h(px(440.0))
                    .bg(ThemeColors::bg_sidebar())
                    .border_1()
                    .border_color(ThemeColors::border())
                    .rounded_lg()
                    .shadow_lg()
                    .overflow_hidden()
                    .on_mouse_down(
                        gpui_kit::MouseButton::Left,
                        cx.listener(|_this, _event, _window, _cx| {
                            // 阻止向遮罩冒泡
                        }),
                    )
                    .child(
                        // 1. 头部标题栏：带 IconName::Settings 标题与 IconName::Close 关闭按钮
                        h_flex()
                            .h(px(42.0))
                            .w_full()
                            .items_center()
                            .justify_between()
                            .px_4()
                            .border_b_1()
                            .border_color(ThemeColors::border())
                            .bg(ThemeColors::bg_titlebar())
                            .child(
                                h_flex()
                                    .items_center()
                                    .gap_2()
                                    .child(
                                        Icon::new(IconName::Settings)
                                            .size(px(16.0))
                                            .text_color(ThemeColors::accent_blue()),
                                    )
                                    .child(
                                        div()
                                            .text_sm()
                                            .font_weight(FontWeight::BOLD)
                                            .text_color(ThemeColors::text_primary())
                                            .child("Settings"),
                                    ),
                            )
                            .child(
                                Button::new("close-settings-btn")
                                    .small()
                                    .ghost()
                                    .icon(IconName::Close)
                                    .tooltip("Close")
                                    .on_click(cx.listener(|_this, _event, _window, cx| {
                                        cx.emit(SettingsEvent::Close);
                                    })),
                            ),
                    )
                    .child(
                        // 2. 主体区（左侧分类导航 + 右侧设置内容）
                        h_flex()
                            .flex_1()
                            .w_full()
                            .child(
                                // 左侧分类导航
                                v_flex()
                                    .w(px(160.0))
                                    .h_full()
                                    .bg(ThemeColors::bg_sidebar())
                                    .border_r_1()
                                    .border_color(ThemeColors::border())
                                    .py_2()
                                    .gap_1()
                                    .child(self.render_nav_item(
                                        "nav-general",
                                        IconName::SlidersHorizontal,
                                        "General",
                                        self.active_category == SettingsCategory::General,
                                        SettingsCategory::General,
                                        cx,
                                    ))
                                    .child(self.render_nav_item(
                                        "nav-editor",
                                        IconName::FileCode,
                                        "Editor",
                                        self.active_category == SettingsCategory::Editor,
                                        SettingsCategory::Editor,
                                        cx,
                                    ))
                                    .child(self.render_nav_item(
                                        "nav-git",
                                        IconName::GitBranch,
                                        "Git",
                                        self.active_category == SettingsCategory::Git,
                                        SettingsCategory::Git,
                                        cx,
                                    ))
                                    .child(self.render_nav_item(
                                        "nav-terminal",
                                        IconName::Terminal,
                                        "Terminal",
                                        self.active_category == SettingsCategory::Terminal,
                                        SettingsCategory::Terminal,
                                        cx,
                                    )),
                            )
                            .child(
                                // 右侧设置内容详情
                                div()
                                    .flex_1()
                                    .h_full()
                                    .bg(ThemeColors::bg_editor())
                                    .p_4()
                                    .overflow_y_scrollbar()
                                    .child(match self.active_category {
                                        SettingsCategory::General => {
                                            self.render_general_settings(cx).into_any_element()
                                        }
                                        SettingsCategory::Editor => {
                                            self.render_editor_settings(cx).into_any_element()
                                        }
                                        SettingsCategory::Git => {
                                            self.render_git_settings(cx).into_any_element()
                                        }
                                        SettingsCategory::Terminal => {
                                            self.render_terminal_settings(cx).into_any_element()
                                        }
                                    }),
                            ),
                    ),
            )
    }
}

impl SettingsDialog {
    fn render_nav_item(
        &self,
        id: &'static str,
        icon: IconName,
        label: &'static str,
        is_active: bool,
        cat: SettingsCategory,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        h_flex()
            .id(id)
            .h(px(32.0))
            .w_full()
            .items_center()
            .gap_2p5()
            .px_3()
            .cursor_pointer()
            .text_xs()
            .when(is_active, |row| {
                row.bg(ThemeColors::subtle_selection())
                    .border_l_2()
                    .border_color(ThemeColors::accent_blue())
                    .text_color(ThemeColors::text_primary())
                    .font_weight(FontWeight::BOLD)
            })
            .when(!is_active, |row| {
                row.text_color(ThemeColors::text_muted()).hover(|h| {
                    h.bg(ThemeColors::bg_tab_hover())
                        .text_color(ThemeColors::text_primary())
                })
            })
            .child(
                Icon::new(icon)
                    .size(px(14.0))
                    .text_color(if is_active {
                        ThemeColors::accent_blue()
                    } else {
                        ThemeColors::text_muted()
                    }),
            )
            .child(label)
            .on_click(cx.listener(move |this, _event, _window, cx| {
                this.set_category(cat, cx);
            }))
    }

    fn render_general_settings(&self, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .size_full()
            .gap_4()
            .child(self.render_section_title("Appearance & General"))
            // 外观主题
            .child(self.render_setting_row(
                "Theme",
                "Color theme for editor and workbench interface",
                h_flex()
                    .gap_1p5()
                    .child(self.render_choice_pill(
                        "theme-dark",
                        "Dark Default",
                        self.theme_name == "Dark Default",
                        cx.listener(|this, _event, _window, cx| {
                            this.theme_name = "Dark Default".to_string();
                            cx.notify();
                        }),
                    ))
                    .child(self.render_choice_pill(
                        "theme-contrast",
                        "High Contrast",
                        self.theme_name == "High Contrast",
                        cx.listener(|this, _event, _window, cx| {
                            this.theme_name = "High Contrast".to_string();
                            cx.notify();
                        }),
                    )),
            ))
            // 界面缩放
            .child(self.render_setting_row(
                "UI Scale",
                "Display scaling factor for the entire workspace",
                h_flex()
                    .gap_1p5()
                    .child(self.render_choice_pill(
                        "scale-100",
                        "100%",
                        self.ui_scale == "100%",
                        cx.listener(|this, _event, _window, cx| {
                            this.ui_scale = "100%".to_string();
                            cx.notify();
                        }),
                    ))
                    .child(self.render_choice_pill(
                        "scale-125",
                        "125%",
                        self.ui_scale == "125%",
                        cx.listener(|this, _event, _window, cx| {
                            this.ui_scale = "125%".to_string();
                            cx.notify();
                        }),
                    )),
            ))
            // 语言
            .child(self.render_setting_row(
                "Language",
                "Application display and localization language",
                h_flex()
                    .gap_1p5()
                    .child(self.render_choice_pill(
                        "lang-en",
                        "English",
                        self.language == "English",
                        cx.listener(|this, _event, _window, cx| {
                            this.language = "English".to_string();
                            cx.notify();
                        }),
                    ))
                    .child(self.render_choice_pill(
                        "lang-zh",
                        "简体中文",
                        self.language == "简体中文",
                        cx.listener(|this, _event, _window, cx| {
                            this.language = "简体中文".to_string();
                            cx.notify();
                        }),
                    )),
            ))
    }

    fn render_editor_settings(&self, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .size_full()
            .gap_4()
            .child(self.render_section_title("Editor Settings"))
            // 字体大小
            .child(self.render_setting_row(
                "Font Size",
                "Controls editor text font size in pixels",
                h_flex()
                    .gap_1p5()
                    .child(self.render_choice_pill(
                        "font-13",
                        "13px",
                        self.font_size == 13,
                        cx.listener(|this, _event, _window, cx| {
                            this.font_size = 13;
                            cx.notify();
                        }),
                    ))
                    .child(self.render_choice_pill(
                        "font-14",
                        "14px",
                        self.font_size == 14,
                        cx.listener(|this, _event, _window, cx| {
                            this.font_size = 14;
                            cx.notify();
                        }),
                    ))
                    .child(self.render_choice_pill(
                        "font-16",
                        "16px",
                        self.font_size == 16,
                        cx.listener(|this, _event, _window, cx| {
                            this.font_size = 16;
                            cx.notify();
                        }),
                    )),
            ))
            // Tab 缩进
            .child(self.render_setting_row(
                "Tab Size",
                "Number of spaces per indentation level",
                h_flex()
                    .gap_1p5()
                    .child(self.render_choice_pill(
                        "tab-2",
                        "2 Spaces",
                        self.tab_size == 2,
                        cx.listener(|this, _event, _window, cx| {
                            this.tab_size = 2;
                            cx.notify();
                        }),
                    ))
                    .child(self.render_choice_pill(
                        "tab-4",
                        "4 Spaces",
                        self.tab_size == 4,
                        cx.listener(|this, _event, _window, cx| {
                            this.tab_size = 4;
                            cx.notify();
                        }),
                    )),
            ))
            // 显示行号
            .child(self.render_setting_row(
                "Line Numbers",
                "Display line number gutter in code editor",
                h_flex()
                    .gap_1p5()
                    .child(self.render_choice_pill(
                        "ln-show",
                        "Show",
                        self.show_line_numbers,
                        cx.listener(|this, _event, _window, cx| {
                            this.show_line_numbers = true;
                            cx.notify();
                        }),
                    ))
                    .child(self.render_choice_pill(
                        "ln-hide",
                        "Hide",
                        !self.show_line_numbers,
                        cx.listener(|this, _event, _window, cx| {
                            this.show_line_numbers = false;
                            cx.notify();
                        }),
                    )),
            ))
            // 自动换行
            .child(self.render_setting_row(
                "Word Wrap",
                "Wrap long lines to fit the editor viewport width",
                h_flex()
                    .gap_1p5()
                    .child(self.render_choice_pill(
                        "wrap-on",
                        "On",
                        self.word_wrap,
                        cx.listener(|this, _event, _window, cx| {
                            this.word_wrap = true;
                            cx.notify();
                        }),
                    ))
                    .child(self.render_choice_pill(
                        "wrap-off",
                        "Off",
                        !self.word_wrap,
                        cx.listener(|this, _event, _window, cx| {
                            this.word_wrap = false;
                            cx.notify();
                        }),
                    )),
            ))
    }

    fn render_git_settings(&self, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .size_full()
            .gap_4()
            .child(self.render_section_title("Version Control & Git"))
            // 自动拉取
            .child(self.render_setting_row(
                "Auto Fetch",
                "Automatically fetch remote branch status periodically",
                h_flex()
                    .gap_1p5()
                    .child(self.render_choice_pill(
                        "fetch-on",
                        "Enabled",
                        self.git_auto_fetch,
                        cx.listener(|this, _event, _window, cx| {
                            this.git_auto_fetch = true;
                            cx.notify();
                        }),
                    ))
                    .child(self.render_choice_pill(
                        "fetch-off",
                        "Disabled",
                        !self.git_auto_fetch,
                        cx.listener(|this, _event, _window, cx| {
                            this.git_auto_fetch = false;
                            cx.notify();
                        }),
                    )),
            ))
            // Commit 前格式化
            .child(self.render_setting_row(
                "Format on Commit",
                "Run code formatter on staged changes before committing",
                h_flex()
                    .gap_1p5()
                    .child(self.render_choice_pill(
                        "format-on",
                        "Enabled",
                        self.git_format_on_commit,
                        cx.listener(|this, _event, _window, cx| {
                            this.git_format_on_commit = true;
                            cx.notify();
                        }),
                    ))
                    .child(self.render_choice_pill(
                        "format-off",
                        "Disabled",
                        !self.git_format_on_commit,
                        cx.listener(|this, _event, _window, cx| {
                            this.git_format_on_commit = false;
                            cx.notify();
                        }),
                    )),
            ))
            // GPG 签名
            .child(self.render_setting_row(
                "GPG Commit Signing",
                "Sign commits with user default GPG signing key",
                h_flex()
                    .gap_1p5()
                    .child(self.render_choice_pill(
                        "gpg-on",
                        "Enabled",
                        self.git_gpg_sign,
                        cx.listener(|this, _event, _window, cx| {
                            this.git_gpg_sign = true;
                            cx.notify();
                        }),
                    ))
                    .child(self.render_choice_pill(
                        "gpg-off",
                        "Disabled",
                        !self.git_gpg_sign,
                        cx.listener(|this, _event, _window, cx| {
                            this.git_gpg_sign = false;
                            cx.notify();
                        }),
                    )),
            ))
    }

    fn render_terminal_settings(&self, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .size_full()
            .gap_4()
            .child(self.render_section_title("Terminal & PTY"))
            // 默认终端
            .child(self.render_setting_row(
                "Default Shell",
                "System shell binary used for bottom terminal panel",
                h_flex()
                    .gap_1p5()
                    .child(self.render_choice_pill(
                        "shell-bash",
                        "/bin/bash",
                        self.default_shell.contains("bash"),
                        cx.listener(|this, _event, _window, cx| {
                            this.default_shell = "/bin/bash".to_string();
                            cx.notify();
                        }),
                    ))
                    .child(self.render_choice_pill(
                        "shell-zsh",
                        "/bin/zsh",
                        self.default_shell.contains("zsh"),
                        cx.listener(|this, _event, _window, cx| {
                            this.default_shell = "/bin/zsh".to_string();
                            cx.notify();
                        }),
                    ))
                    .child(self.render_choice_pill(
                        "shell-sh",
                        "/bin/sh",
                        self.default_shell == "/bin/sh",
                        cx.listener(|this, _event, _window, cx| {
                            this.default_shell = "/bin/sh".to_string();
                            cx.notify();
                        }),
                    )),
            ))
            // 滚动缓冲区大小
            .child(self.render_setting_row(
                "Scrollback Buffer",
                "Maximum number of terminal output lines kept in memory",
                h_flex()
                    .gap_1p5()
                    .child(self.render_choice_pill(
                        "scroll-1000",
                        "1000 lines",
                        self.scrollback_lines == 1000,
                        cx.listener(|this, _event, _window, cx| {
                            this.scrollback_lines = 1000;
                            cx.notify();
                        }),
                    ))
                    .child(self.render_choice_pill(
                        "scroll-5000",
                        "5000 lines",
                        self.scrollback_lines == 5000,
                        cx.listener(|this, _event, _window, cx| {
                            this.scrollback_lines = 5000;
                            cx.notify();
                        }),
                    )),
            ))
    }

    fn render_section_title(&self, title: &'static str) -> impl IntoElement {
        div()
            .text_sm()
            .font_weight(FontWeight::BOLD)
            .text_color(ThemeColors::text_primary())
            .pb_1()
            .border_b_1()
            .border_color(ThemeColors::border())
            .child(title)
    }

    fn render_setting_row(
        &self,
        label: &'static str,
        desc: &'static str,
        control: impl IntoElement,
    ) -> impl IntoElement {
        h_flex()
            .w_full()
            .items_center()
            .justify_between()
            .gap_4()
            .child(
                v_flex()
                    .flex_1()
                    .gap_0p5()
                    .child(
                        div()
                            .text_xs()
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(ThemeColors::text_primary())
                            .child(label),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(ThemeColors::text_muted())
                            .child(desc),
                    ),
            )
            .child(control)
    }

    fn render_choice_pill(
        &self,
        id: &'static str,
        label: &'static str,
        is_selected: bool,
        click_handler: impl Fn(&gpui_kit::ClickEvent, &mut Window, &mut gpui_kit::App) + 'static,
    ) -> impl IntoElement {
        h_flex()
            .id(id)
            .items_center()
            .px_2p5()
            .py(px(3.0))
            .rounded(px(4.0))
            .border_1()
            .cursor_pointer()
            .text_xs()
            .when(is_selected, |pill| {
                pill.bg(ThemeColors::accent_blue())
                    .border_color(ThemeColors::accent_blue())
                    .text_color(ThemeColors::text_primary())
                    .font_weight(FontWeight::BOLD)
            })
            .when(!is_selected, |pill| {
                pill.bg(ThemeColors::bg_tab_bar())
                    .border_color(ThemeColors::border())
                    .text_color(ThemeColors::text_muted())
                    .hover(|h| {
                        h.bg(ThemeColors::bg_tab_hover())
                            .text_color(ThemeColors::text_primary())
                    })
            })
            .child(label)
            .on_click(click_handler)
    }
}
