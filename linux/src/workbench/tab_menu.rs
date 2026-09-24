//! 标签页右键菜单：Windows `tab-context-menu.tsx` 按键帽外子集。
//!
//! 顺序固定为关闭／关闭其他／关闭到右侧／关闭全部｜复制路径／复制相对路径／
//! 在文件管理器中显示／在终端中打开／重新加载。文案经
//! `crate::i18n::menu_text` 取 `tabs.*` 与 `files.*`，缺 key 回退为空。
//! 触发与显隐走上游 `ContextMenuExt::context_menu`（右键冒泡打开，点选或点外
//! 自动关闭，浮层 absolute 不占布局）；`EditorView::context_menu_tab` 只做
//! “右键目标”记账，右键按下时记 `idx`，选中动作与点外关闭时清 `None`。

use gpui_kit::assets::IconName;
use gpui_kit::component::h_flex;
use gpui_kit::component::menu::{PopupMenu, PopupMenuItem};
use gpui_kit::{div, ClipboardItem, Context, Entity, ParentElement as _, Styled as _, Window};

use super::editor::{EditorTabEvent, EditorView};
use crate::theme::ThemeColors;

/// 右键菜单构造器：`view` 与 `idx` 以 owned 方式 move 进 `Fn` 闭包
/// （`context_menu` 的 builder 要求 `Fn + 'static`，每次打开时调用）。
pub fn tab_context_menu(
    view: Entity<EditorView>,
    idx: usize,
) -> impl Fn(PopupMenu, &mut Window, &mut Context<PopupMenu>) -> PopupMenu + 'static {
    move |menu, _window, cx| build_tab_menu(menu, cx, &view, idx)
}

/// 取绝对路径父目录（终端打开与文件管理器显示共用）。
fn parent_dir(abs: &str) -> &str {
    abs.rsplit_once('/').map(|(dir, _)| dir).unwrap_or(abs)
}

/// 在文件管理器中显示所在目录（Linux-frame：`xdg-open`，失败忽略）。
fn reveal_in_file_manager(dir: &str) {
    let _ = std::process::Command::new("xdg-open").arg(dir).spawn();
}

fn build_tab_menu(
    mut menu: PopupMenu,
    cx: &mut Context<PopupMenu>,
    view: &Entity<EditorView>,
    idx: usize,
) -> PopupMenu {
    // ---- 关闭组（Windows `close/close-others/close-right/close-all`） ----
    // 关闭带右侧 `Ctrl+W` 展示文本，用 element 自定义行（仿 `toolbar.rs`）。
    let v = view.clone();
    let close_label = crate::i18n::menu_text(cx, "tabs.close").to_string();
    menu = menu.item(
        PopupMenuItem::element(move |_window, _cx| {
            let label = close_label.clone();
            h_flex()
                .w_full()
                .items_center()
                .gap_2()
                .child(
                    div()
                        .flex_1()
                        .text_xs()
                        .text_color(ThemeColors::foreground())
                        .child(label),
                )
                .child(
                    div()
                        .text_xs()
                        .text_color(ThemeColors::subtle_foreground())
                        .child("Ctrl+W"),
                )
        })
        .icon(IconName::Close)
        .on_click(move |_, _, cx| {
            v.update(cx, |this, cx| {
                this.close_tab(idx, cx);
                this.context_menu_tab = None;
                cx.notify();
            });
        }),
    );

    let v = view.clone();
    let close_others_label = crate::i18n::menu_text(cx, "tabs.closeOthers").to_string();
    menu = menu.item(
        PopupMenuItem::new(close_others_label).on_click(move |_, _, cx| {
            v.update(cx, |this, cx| {
                this.close_others_at(idx, cx);
                this.context_menu_tab = None;
                cx.notify();
            });
        }),
    );

    let v = view.clone();
    let close_right_label = crate::i18n::menu_text(cx, "tabs.closeToRight").to_string();
    menu = menu.item(
        PopupMenuItem::new(close_right_label).on_click(move |_, _, cx| {
            v.update(cx, |this, cx| {
                this.close_to_right_at(idx, cx);
                this.context_menu_tab = None;
                cx.notify();
            });
        }),
    );

    let v = view.clone();
    let close_all_label = crate::i18n::menu_text(cx, "tabs.closeAll").to_string();
    menu = menu.item(
        PopupMenuItem::new(close_all_label).on_click(move |_, _, cx| {
            v.update(cx, |this, cx| {
                this.close_all_tabs(cx);
                this.context_menu_tab = None;
                cx.notify();
            });
        }),
    );

    menu = menu.separator();

    // ---- 路径组（复制路径用绝对路径，相对路径用 `tab.path` 原样） ----
    let v = view.clone();
    let copy_path_label = crate::i18n::menu_text(cx, "files.copyPath").to_string();
    menu = menu.item(
        PopupMenuItem::new(copy_path_label)
            .icon(IconName::Copy)
            .on_click(move |_, _, cx| {
                v.update(cx, |this, cx| {
                    if let Some(abs) = this.tab_abs_path(idx) {
                        cx.write_to_clipboard(ClipboardItem::new_string(abs));
                    }
                    this.context_menu_tab = None;
                    cx.notify();
                });
            }),
    );

    let v = view.clone();
    let copy_rel_label = crate::i18n::menu_text(cx, "files.copyRelativePath").to_string();
    menu = menu.item(
        PopupMenuItem::new(copy_rel_label)
            .icon(IconName::Copy)
            .on_click(move |_, _, cx| {
                v.update(cx, |this, cx| {
                    if let Some(rel) = this.tabs.get(idx).map(|tab| tab.path.clone()) {
                        cx.write_to_clipboard(ClipboardItem::new_string(rel));
                    }
                    this.context_menu_tab = None;
                    cx.notify();
                });
            }),
    );

    let v = view.clone();
    let reveal_label = crate::i18n::menu_text(cx, "files.reveal").to_string();
    menu = menu.item(
        PopupMenuItem::new(reveal_label)
            .icon(IconName::FolderOpen)
            .on_click(move |_, _, cx| {
                v.update(cx, |this, cx| {
                    if let Some(abs) = this.tab_abs_path(idx) {
                        reveal_in_file_manager(parent_dir(&abs));
                    }
                    this.context_menu_tab = None;
                    cx.notify();
                });
            }),
    );

    let v = view.clone();
    let terminal_label = crate::i18n::menu_text(cx, "files.openInTerminal").to_string();
    menu = menu.item(
        PopupMenuItem::new(terminal_label)
            .icon(IconName::Terminal)
            .on_click(move |_, _, cx| {
                v.update(cx, |this, cx| {
                    if let Some(abs) = this.tab_abs_path(idx) {
                        let dir = parent_dir(&abs).to_string();
                        cx.emit(EditorTabEvent::OpenInTerminal { dir });
                    }
                    this.context_menu_tab = None;
                    cx.notify();
                });
            }),
    );

    let v = view.clone();
    let reload_label = crate::i18n::menu_text(cx, "tabs.reload").to_string();
    menu = menu.item(
        PopupMenuItem::new(reload_label)
            .icon(IconName::RotateCw)
            .on_click(move |_, _, cx| {
                v.update(cx, |this, cx| {
                    this.reload_tab(idx, cx);
                    this.context_menu_tab = None;
                    cx.notify();
                });
            }),
    );

    menu
}
