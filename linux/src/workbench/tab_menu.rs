//! 标签页右键菜单：Windows `tab-context-menu.tsx` 按键帽外子集。
//!
//! 顺序固定为固定／取消固定｜向右拆分／向下拆分｜锁定组｜
//! 关闭／关闭其他／关闭到右侧／关闭全部｜
//! 复制路径／复制相对路径／在文件管理器中显示／在终端中打开／重新加载。文案经
//! `crate::i18n::menu_text` 取 `tabs.*` 与 `files.*`，缺 key 回退为空。
//! 触发与显隐走上游 `ContextMenuExt::context_menu`（右键冒泡打开，点选或点外
//! 自动关闭，浮层 absolute 不占布局）；`EditorView::context_menu_tab` 只做
//! “右键目标”记账，右键按下时记 `idx`，选中动作与点外关闭时清 `None`。

use std::rc::Rc;

use gpui_kit::assets::IconName;
use gpui_kit::component::h_flex;
use gpui_kit::component::menu::{PopupMenu, PopupMenuItem};
use gpui_kit::{div, App, ClipboardItem, Context, Entity, ParentElement as _, Styled as _, Window};

use super::editor::{EditorTabEvent, EditorView};
use super::panes::{PaneId, SplitDir};
use crate::theme::ThemeColors;

/// 拆分回调：`Fn(pane_id, dir, window, cx)`，由工作台注入（内部经 workbench
/// entity 回写 `split_pane`），菜单点击时触发（`window` 供新建编辑器用）。
pub type SplitCallback = Rc<dyn Fn(PaneId, SplitDir, &mut Window, &mut App)>;
/// 锁定回调：`Fn(pane_id, cx)`，由工作台注入（内部经 workbench entity 回写
/// `toggle_lock`），菜单点击时触发。
pub type ToggleLockCallback = Rc<dyn Fn(PaneId, &mut App)>;

/// 右键菜单构造器：`view` 与 `idx` 以 owned 方式 move 进 `Fn` 闭包
/// （`context_menu` 的 builder 要求 `Fn + 'static`，每次打开时调用）。
/// `pane_id` 为标签所在窗格，`is_locked` 决定锁定项文案；拆分/锁定动作经
/// `on_split` / `on_toggle_lock` 回工作台执行，本层不直接改窗格树。
pub fn tab_context_menu(
    view: Entity<EditorView>,
    idx: usize,
    pane_id: PaneId,
    is_locked: bool,
    on_split: SplitCallback,
    on_toggle_lock: ToggleLockCallback,
) -> impl Fn(PopupMenu, &mut Window, &mut Context<PopupMenu>) -> PopupMenu + 'static {
    move |menu, _window, cx| {
        build_tab_menu(
            menu,
            cx,
            &view,
            idx,
            pane_id,
            is_locked,
            &on_split,
            &on_toggle_lock,
        )
    }
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
    pane_id: PaneId,
    is_locked: bool,
    on_split: &SplitCallback,
    on_toggle_lock: &ToggleLockCallback,
) -> PopupMenu {
    // ---- 固定组（Windows `pin` 首项，其后分隔线；`IconName` 无 Pin 变体故不用图标） ----
    let is_pinned = view.read(cx).tabs.get(idx).is_some_and(|tab| tab.is_pinned);
    let v = view.clone();
    let pin_label = if is_pinned {
        crate::i18n::menu_text(cx, "tabs.unpin").to_string()
    } else {
        crate::i18n::menu_text(cx, "tabs.pin").to_string()
    };
    menu = menu.item(PopupMenuItem::new(pin_label).on_click(move |_, _, cx| {
        v.update(cx, |this, cx| {
            this.toggle_pin_at(idx, cx);
            this.context_menu_tab = None;
            cx.notify();
        });
    }));

    menu = menu.separator();

    // ---- 拆分组（Windows `split-right/split-down`，其后分隔线） ----
    let cb = on_split.clone();
    let v = view.clone();
    let split_right_label = crate::i18n::menu_text(cx, "tabs.splitRight").to_string();
    menu = menu.item(
        PopupMenuItem::new(split_right_label).on_click(move |_, window, cx| {
            cb(pane_id, SplitDir::Horizontal, window, cx);
            v.update(cx, |this, cx| {
                this.context_menu_tab = None;
                cx.notify();
            });
        }),
    );

    let cb = on_split.clone();
    let v = view.clone();
    let split_down_label = crate::i18n::menu_text(cx, "tabs.splitDown").to_string();
    menu = menu.item(
        PopupMenuItem::new(split_down_label).on_click(move |_, window, cx| {
            cb(pane_id, SplitDir::Vertical, window, cx);
            v.update(cx, |this, cx| {
                this.context_menu_tab = None;
                cx.notify();
            });
        }),
    );

    menu = menu.separator();

    // ---- 锁定组（Windows `toggle-editor-group-lock`，其后分隔线） ----
    let cb = on_toggle_lock.clone();
    let v = view.clone();
    let lock_label = if is_locked {
        crate::i18n::menu_text(cx, "tabs.unlockEditorGroup").to_string()
    } else {
        crate::i18n::menu_text(cx, "tabs.lockEditorGroup").to_string()
    };
    menu = menu.item(PopupMenuItem::new(lock_label).on_click(move |_, _, cx| {
        cb(pane_id, cx);
        v.update(cx, |this, cx| {
            this.context_menu_tab = None;
            cx.notify();
        });
    }));

    menu = menu.separator();

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
