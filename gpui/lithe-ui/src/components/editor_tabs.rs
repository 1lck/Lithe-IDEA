//! 编辑区标签条。
//!
//! 与 IDEA 一致使用多行换行（`flex_wrap`）而不是单行滚动：标签超出宽度后
//! 换到下一行，每行 34pt。活动标签有 3pt 主题下划线。

use std::rc::Rc;

use gpui_kit::component::Sizable as _;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, ElementId, InteractiveElement as _, IntoElement, ParentElement, RenderOnce, SharedString,
    StatefulInteractiveElement as _, Styled, Window, div, px, transparent_black,
};

use crate::icons::{LitheIcon, icon};
use crate::{LitheMetrics, current_tokens};

pub struct EditorTabItem {
    pub id: SharedString,
    pub title: SharedString,
    pub icon: Option<LitheIcon>,
    pub modified: bool,
}

impl EditorTabItem {
    pub fn new(id: impl Into<SharedString>, title: impl Into<SharedString>) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            icon: None,
            modified: false,
        }
    }
}

type SelectHandler = Rc<dyn Fn(SharedString, &mut Window, &mut App) + 'static>;
type CloseHandler = Rc<dyn Fn(SharedString, &mut Window, &mut App) + 'static>;

#[derive(IntoElement)]
pub struct EditorTabs {
    id: ElementId,
    tabs: Vec<EditorTabItem>,
    active: Option<SharedString>,
    on_select: Option<SelectHandler>,
    on_close: Option<CloseHandler>,
}

impl EditorTabs {
    pub fn new(id: impl Into<ElementId>) -> Self {
        Self {
            id: id.into(),
            tabs: Vec::new(),
            active: None,
            on_select: None,
            on_close: None,
        }
    }

    pub fn tabs(mut self, tabs: impl IntoIterator<Item = EditorTabItem>) -> Self {
        self.tabs = tabs.into_iter().collect();
        self
    }

    pub fn active(mut self, id: impl Into<SharedString>) -> Self {
        self.active = Some(id.into());
        self
    }

    pub fn on_select(
        mut self,
        handler: impl Fn(SharedString, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.on_select = Some(Rc::new(handler));
        self
    }

    pub fn on_close(
        mut self,
        handler: impl Fn(SharedString, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.on_close = Some(Rc::new(handler));
        self
    }
}

impl RenderOnce for EditorTabs {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let tokens = current_tokens(cx);
        let EditorTabs {
            id,
            tabs,
            active,
            on_select,
            on_close,
        } = self;

        let root_id = id.to_string();
        let mut bar = div()
            .id(id)
            .w_full()
            .flex()
            .flex_row()
            .flex_wrap()
            .items_center()
            .flex_shrink_0()
            // 对齐 macOS `multipleRowsEditorTabLayout`：标签条四周留 2pt
            //（EditorAreaView.swift:347-348），标签之间水平 4pt
            //（EditorAreaView.swift:344）。
            .p(px(LitheMetrics::EDITOR_TAB_STRIP_PADDING))
            .gap(px(LitheMetrics::EDITOR_TAB_ITEM_SPACING))
            // 标签条底色取编辑器底色：macOS 的非活动标签是透明的，
            // 露出的就是 `LitheTheme.editor`（EditorAreaView.swift:343-350）。
            .bg(tokens.editor);

        for tab in tabs {
            let EditorTabItem {
                id: tab_id,
                title,
                icon: tab_icon,
                modified,
            } = tab;

            let is_active = active.as_ref() == Some(&tab_id);
            let foreground = if is_active {
                tokens.primary_text
            } else {
                tokens.secondary_text
            };
            // 非活动标签不画下划线：用透明色占位，保持每个标签的盒模型一致，
            // 换行时不会因为 3pt 边框出现跳动。
            let underline = if is_active {
                tokens.accent
            } else {
                transparent_black()
            };

            let select = on_select.clone();
            let click_id = tab_id.clone();
            let mut tab_element = div()
                .id(format!("{root_id}:tab:{tab_id}"))
                .flex()
                .flex_row()
                .items_center()
                .flex_shrink_0()
                .h(px(LitheMetrics::EDITOR_TAB_HEIGHT))
                // 对齐 macOS `editorTabContent`：文字左内边距 8
                //（EditorAreaView.swift:743），关闭按钮到右边缘 4
                //（EditorAreaView.swift:724）。
                .pl(px(LitheMetrics::EDITOR_TAB_LEADING_PADDING))
                .pr(px(LitheMetrics::EDITOR_TAB_CLOSE_TRAILING))
                .border_b(px(LitheMetrics::TAB_UNDERLINE_HEIGHT))
                .border_color(underline)
                .when(is_active, |this| this.bg(tokens.editor))
                .when(!is_active, |this| {
                    this.hover(|style| style.bg(tokens.hover))
                })
                .cursor_pointer()
                .on_click(move |_, window, cx| {
                    if let Some(handler) = &select {
                        handler(click_id.clone(), window, cx);
                    }
                });

            // 图标 / 标题 / 修改点是一个 7pt 间距的整体
            //（EditorAreaView.swift:737 的 `HStack(spacing: 7)`）；关闭按钮
            // 紧贴其后，所以间距只加在标签内容内部，不加在标签根节点上。
            let mut label = div()
                .flex()
                .flex_row()
                .items_center()
                .min_w(px(0.0))
                .gap(px(LitheMetrics::EDITOR_TAB_GAP));

            if let Some(tab_icon) = tab_icon {
                label = label.child(
                    icon(tab_icon)
                        .with_size(px(LitheMetrics::TOOLBAR_ICON_SIZE))
                        .text_color(foreground),
                );
            }

            label = label.child(
                div()
                    .min_w(px(0.0))
                    .truncate()
                    // 对齐 macOS 编辑器标签的 13pt（EditorAreaView.swift:765）。
                    .text_size(px(LitheMetrics::EDITOR_TAB_FONT_SIZE))
                    .text_color(foreground)
                    .child(title),
            );

            if modified {
                label = label.child(
                    div()
                        .size(px(LitheMetrics::MODIFIED_DOT_SIZE))
                        .rounded_full()
                        .flex_shrink_0()
                        // 对齐 macOS `EditorTabDirtyIndicator` 的 primaryText
                        // 填充（EditorAreaView.swift:1685）。
                        .bg(tokens.primary_text),
                );
            }

            tab_element = tab_element.child(label);

            if let Some(close) = on_close.clone() {
                let close_id = tab_id.clone();
                tab_element = tab_element.child(
                    div()
                        .id(format!("{root_id}:tab:{tab_id}:close"))
                        // 对齐 macOS 关闭按钮的 22×22 点击区
                        //（LitheToolWindowTabStyle.swift:231）。
                        .size(px(LitheMetrics::EDITOR_TAB_CLOSE_SIZE))
                        .flex()
                        .items_center()
                        .justify_center()
                        .flex_shrink_0()
                        // macOS 的圆形悬停底由 CloseHovered SVG 提供
                        //（LitheToolWindowTabStyle.swift:216），这里用圆形背景等价表达。
                        .rounded_full()
                        .hover(|style| style.bg(tokens.hover))
                        .cursor_pointer()
                        // 关闭按钮位于标签内部，必须阻止点击继续冒泡到标签本体，
                        // 否则关闭的同时又触发一次选中。
                        .on_click(move |_, window, cx| {
                            cx.stop_propagation();
                            // `close` 已经从 Option 中取出，直接调用即可；
                            // 这里再判一次空会把 Rc 当成 Option，导致类型不匹配。
                            close(close_id.clone(), window, cx);
                        })
                        .child(
                            icon(LitheIcon::Close)
                                .with_size(px(LitheMetrics::EDITOR_TAB_CLOSE_ICON_SIZE))
                                .text_color(tokens.secondary_text),
                        ),
                );
            }

            bar = bar.child(tab_element);
        }

        bar
    }
}
