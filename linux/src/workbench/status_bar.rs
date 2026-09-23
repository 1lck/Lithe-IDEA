use gpui_kit::component::h_flex;
use gpui_kit::{
    div, px, Context, IntoElement, ParentElement as _, Render, Styled as _, Window,
};

use crate::theme::ThemeColors;

pub struct StatusBarView {
    pub git_branch: Option<String>,
    pub current_file: Option<String>,
    pub cursor_line: usize,
    pub cursor_col: usize,
    pub language: String,
    pub encoding: String,
}

impl StatusBarView {
    pub fn new() -> Self {
        Self {
            git_branch: None,
            current_file: None,
            cursor_line: 1,
            cursor_col: 1,
            language: "Plain Text".to_string(),
            encoding: "UTF-8".to_string(),
        }
    }

    pub fn set_file_info(
        &mut self,
        file: Option<String>,
        line: usize,
        col: usize,
        lang: String,
        cx: &mut Context<Self>,
    ) {
        self.current_file = file;
        self.cursor_line = line;
        self.cursor_col = col;
        self.language = lang;
        cx.notify();
    }

    #[allow(dead_code)]
    pub fn set_git_branch(&mut self, branch: Option<String>, cx: &mut Context<Self>) {
        self.git_branch = branch;
        cx.notify();
    }
}

impl Render for StatusBarView {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        let branch = self.git_branch.clone().unwrap_or_else(|| "main".to_string());
        let file_label = self
            .current_file
            .clone()
            .unwrap_or_else(|| "No file active".to_string());

        h_flex()
            .h(px(24.0))
            .w_full()
            .bg(ThemeColors::bg_statusbar())
            .border_t_1()
            .border_color(ThemeColors::border())
            .items_center()
            .justify_between()
            .px_3()
            .text_xs()
            .text_color(ThemeColors::text_muted())
            .child(
                // 左侧状态栏项目
                h_flex()
                    .items_center()
                    .gap_3()
                    .child(
                        h_flex()
                            .items_center()
                            .gap_1()
                            .text_color(ThemeColors::accent_green())
                            .child("⎇")
                            .child(branch),
                    )
                    .child(div().text_color(ThemeColors::border()).child("|"))
                    .child(
                        div()
                            .text_color(ThemeColors::text_primary())
                            .child(file_label),
                    ),
            )
            .child(
                // 右侧状态栏项目
                h_flex()
                    .items_center()
                    .gap_3()
                    .child(format!("Ln {}, Col {}", self.cursor_line, self.cursor_col))
                    .child(div().text_color(ThemeColors::border()).child("|"))
                    .child(self.language.clone())
                    .child(div().text_color(ThemeColors::border()).child("|"))
                    .child(self.encoding.clone())
                    .child(div().text_color(ThemeColors::border()).child("|"))
                    .child("4 spaces")
                    .child(div().text_color(ThemeColors::border()).child("|"))
                    .child(
                        div()
                            .text_color(ThemeColors::accent_blue())
                            .child("Lithe Core"),
                    ),
            )
    }
}
