use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{h_flex, Sizable as _};
use gpui_kit::{
    div, px, rgb, Context, EventEmitter, IntoElement, ParentElement as _,
    Render, Styled as _, Window,
};

#[derive(Debug, Clone)]
pub enum ToolbarEvent {
    Save,
    Run,
    ToggleTerminal,
}

pub struct ToolbarView {
    pub workspace_name: String,
    pub git_branch: Option<String>,
}

impl EventEmitter<ToolbarEvent> for ToolbarView {}

impl ToolbarView {
    pub fn new(workspace_root: &str) -> Self {
        let name = workspace_root
            .rsplit_once('/')
            .map(|(_, n)| n.to_string())
            .unwrap_or_else(|| workspace_root.to_string());

        Self {
            workspace_name: name,
            git_branch: None,
        }
    }

    #[allow(dead_code)]
    pub fn set_git_branch(&mut self, branch: Option<String>, cx: &mut Context<Self>) {
        self.git_branch = branch;
        cx.notify();
    }
}

impl Render for ToolbarView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let branch = self.git_branch.as_deref().unwrap_or("main");

        h_flex()
            .h(px(40.0))
            .w_full()
            .bg(rgb(0x10111a))
            .border_b_1()
            .border_color(rgb(0x23263b))
            .items_center()
            .justify_between()
            .px_3()
            .child(
                // 左侧：项目名称与分支信息
                h_flex()
                    .items_center()
                    .gap_3()
                    .child(
                        div()
                            .text_sm()
                            .text_color(rgb(0xffffff))
                            .child(format!("⚡ Lithe | {}", self.workspace_name)),
                    )
                    .child(
                        div()
                            .px_2()
                            .py(px(2.0))
                            .rounded_sm()
                            .bg(rgb(0x1e2030))
                            .text_xs()
                            .text_color(rgb(0x10b981))
                            .child(format!("⎇ {}", branch)),
                    ),
            )
            .child(
                // 中间：运行与调试配置
                h_flex()
                    .items_center()
                    .gap_2()
                    .child(
                        Button::new("tb-run")
                            .small()
                            .primary()
                            .label("▶ Run")
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                cx.emit(ToolbarEvent::Run);
                            })),
                    )
                    .child(
                        Button::new("tb-debug")
                            .small()
                            .ghost()
                            .label("🐞 Debug")
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                cx.emit(ToolbarEvent::Run);
                            })),
                    ),
            )
            .child(
                // 右侧：保存与面板切换
                h_flex()
                    .items_center()
                    .gap_2()
                    .child(
                        Button::new("tb-save")
                            .small()
                            .ghost()
                            .label("💾 Save")
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                cx.emit(ToolbarEvent::Save);
                            })),
                    )
                    .child(
                        Button::new("tb-terminal")
                            .small()
                            .ghost()
                            .label("⌨ Terminal")
                            .on_click(cx.listener(|_this, _event, _window, cx| {
                                cx.emit(ToolbarEvent::ToggleTerminal);
                            })),
                    ),
            )
    }
}
