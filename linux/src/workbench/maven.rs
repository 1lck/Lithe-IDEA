//! 右侧 Maven 导航工具窗口：项目树 + 生命周期阶段，对齐 Tauri
//! `windows/tauri/src/features/maven/` 的导航语义。
//!
//! 本面板只负责导航展示与事件发射：双击/点击阶段行发射
//! [`MavenEvent::RunGoal`]，实际命令执行由外部经底部 Terminal 完成。

use std::collections::HashSet;

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, Context, EventEmitter, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, StatefulInteractiveElement as _, Styled as _, Window,
};

use crate::theme::ThemeColors;

/// 对齐 Tauri `MAVEN_LIFECYCLE_PHASES` 的 Maven 生命周期阶段。
pub const MAVEN_LIFECYCLE_PHASES: [&str; 9] = [
    "clean", "validate", "compile", "test", "package", "verify", "install", "site", "deploy",
];

/// pom 扫描最大递归深度。
const MAX_POM_SCAN_DEPTH: usize = 5;

/// pom 扫描跳过的目录名：构建产物与常见工具目录。
const POM_SCAN_SKIP_DIRS: [&str; 9] = [
    "target",
    "node_modules",
    ".git",
    ".idea",
    "dist",
    "build",
    "out",
    ".vscode",
    "vendor",
];

/// 递归扫描 root 下的 `pom.xml`，返回排序后的绝对路径列表，不新增依赖。
pub fn find_pom_files(root: &str) -> Vec<String> {
    let mut out = Vec::new();
    let base = std::path::PathBuf::from(root);
    let base = if base.is_absolute() {
        base
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(&base))
            .unwrap_or(base)
    };
    walk_pom_dir(&base, 0, &mut out);
    out.sort();
    out
}

fn walk_pom_dir(dir: &std::path::Path, depth: usize, out: &mut Vec<String>) {
    if depth > MAX_POM_SCAN_DEPTH {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        if path.is_dir() {
            if POM_SCAN_SKIP_DIRS.contains(&name.as_str()) {
                continue;
            }
            walk_pom_dir(&path, depth + 1, out);
        } else if name == "pom.xml" {
            out.push(path.to_string_lossy().into_owned());
        }
    }
}

/// Lifecycle 组的展开键。
fn lifecycle_key(pom: &str) -> String {
    format!("{pom}#lifecycle")
}

/// phase 行的稳定节点 id，同时用作选中键。
fn phase_id(pom: &str, phase: &str) -> String {
    format!("{pom}#lifecycle#{phase}")
}

/// pom 行的显示路径：相对 root，根 pom 显示 `pom.xml`。
fn display_pom_path(root: &str, pom: &str) -> String {
    std::path::Path::new(pom)
        .strip_prefix(root)
        .map(|rel| {
            let s = rel.to_string_lossy().into_owned();
            if s.is_empty() {
                pom.to_string()
            } else {
                s
            }
        })
        .unwrap_or_else(|_| pom.to_string())
}

/// Maven 导航面板派发的事件：执行只发射，由外部经底部 Terminal 执行。
#[derive(Debug, Clone)]
pub enum MavenEvent {
    RunGoal { pom_path: String, phase: String },
    Close,
}

/// 右侧 Maven 导航工具窗口：项目树 + 生命周期阶段。
pub struct MavenView {
    pub root: String,
    poms: Vec<String>,
    expanded: HashSet<String>,
    selected: Option<String>,
}

impl EventEmitter<MavenEvent> for MavenView {}

impl MavenView {
    pub fn new(root: String, _cx: &mut Context<Self>) -> Self {
        let mut view = Self {
            root,
            poms: Vec::new(),
            expanded: HashSet::new(),
            selected: None,
        };
        view.rescan();
        view
    }

    pub fn set_root(&mut self, root: String, cx: &mut Context<Self>) {
        self.root = root;
        self.rescan();
        cx.notify();
    }

    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        self.rescan();
        cx.notify();
    }

    pub fn has_projects(&self) -> bool {
        !self.poms.is_empty()
    }

    /// 重扫 pom 列表并默认展开全部 pom 节点与 Lifecycle 组。
    fn rescan(&mut self) {
        self.poms = find_pom_files(&self.root);
        self.expanded.clear();
        for pom in &self.poms {
            self.expanded.insert(pom.clone());
            self.expanded.insert(lifecycle_key(pom));
        }
    }

    fn toggle_node(&mut self, key: &str, cx: &mut Context<Self>) {
        if !self.expanded.remove(key) {
            self.expanded.insert(key.to_string());
        }
        cx.notify();
    }
}

impl Render for MavenView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 快照后构建行，避免在 `.children` 闭包里同时借用 self 与 cx。
        let root = self.root.clone();
        let poms = self.poms.clone();
        let expanded = self.expanded.clone();
        let selected = self.selected.clone();
        let has_projects = !poms.is_empty();

        let mut rows = Vec::new();
        for pom in &poms {
            let pom_expanded = expanded.contains(pom);
            let chevron = if pom_expanded {
                IconName::ChevronDown
            } else {
                IconName::ChevronRight
            };
            let display = display_pom_path(&root, pom);
            rows.push(
                h_flex()
                    .id(pom.clone())
                    .h(px(24.0))
                    .w_full()
                    .items_center()
                    .cursor_pointer()
                    .rounded_sm()
                    .pl(px(6.0))
                    .pr_2()
                    .gap_1p5()
                    .text_xs()
                    .text_color(ThemeColors::text_primary())
                    .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                    .child(
                        Icon::new(chevron)
                            .size(px(12.0))
                            .text_color(ThemeColors::text_muted()),
                    )
                    .child(
                        Icon::new(IconName::Box)
                            .size(px(14.0))
                            .text_color(ThemeColors::accent_blue()),
                    )
                    .child(div().flex_1().truncate().child(display))
                    .on_click(cx.listener({
                        let pom = pom.clone();
                        move |this, _event, _window, cx| {
                            this.toggle_node(&pom, cx);
                        }
                    }))
                    .into_any_element(),
            );
            if !pom_expanded {
                continue;
            }

            let group_key = lifecycle_key(pom);
            let group_expanded = expanded.contains(&group_key);
            let group_chevron = if group_expanded {
                IconName::ChevronDown
            } else {
                IconName::ChevronRight
            };
            rows.push(
                h_flex()
                    .id(group_key.clone())
                    .h(px(24.0))
                    .w_full()
                    .items_center()
                    .cursor_pointer()
                    .rounded_sm()
                    .pl(px(18.0))
                    .pr_2()
                    .gap_1p5()
                    .text_xs()
                    .text_color(ThemeColors::text_primary())
                    .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                    .child(
                        Icon::new(group_chevron)
                            .size(px(12.0))
                            .text_color(ThemeColors::text_muted()),
                    )
                    .child(
                        Icon::new(IconName::Package)
                            .size(px(14.0))
                            .text_color(ThemeColors::accent_blue()),
                    )
                    .child(div().flex_1().truncate().child("Lifecycle"))
                    .on_click(cx.listener({
                        let group_key = group_key.clone();
                        move |this, _event, _window, cx| {
                            this.toggle_node(&group_key, cx);
                        }
                    }))
                    .into_any_element(),
            );
            if !group_expanded {
                continue;
            }

            for phase in MAVEN_LIFECYCLE_PHASES {
                let row_id = phase_id(pom, phase);
                let is_selected = selected.as_deref() == Some(row_id.as_str());
                rows.push(
                    h_flex()
                        .id(row_id.clone())
                        .h(px(24.0))
                        .w_full()
                        .items_center()
                        .cursor_pointer()
                        .rounded_sm()
                        .pl(px(30.0))
                        .pr_2()
                        .gap_1p5()
                        .text_xs()
                        .when(is_selected, |row| {
                            row.bg(ThemeColors::subtle_selection())
                                .text_color(ThemeColors::text_primary())
                        })
                        .when(!is_selected, |row| {
                            row.text_color(ThemeColors::text_primary())
                                .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                        })
                        .child(
                            Icon::new(IconName::Play)
                                .size(px(12.0))
                                .text_color(ThemeColors::text_muted()),
                        )
                        .child(div().flex_1().truncate().child(phase))
                        .on_click(cx.listener({
                            let pom = pom.clone();
                            let phase = phase.to_string();
                            move |this, _event, _window, cx| {
                                this.selected = Some(phase_id(&pom, &phase));
                                cx.emit(MavenEvent::RunGoal {
                                    pom_path: pom.clone(),
                                    phase: phase.clone(),
                                });
                                cx.notify();
                            }
                        }))
                        .into_any_element(),
                );
            }
        }

        v_flex()
            .size_full()
            .bg(ThemeColors::bg_sidebar())
            .border_l_1()
            .border_color(ThemeColors::border())
            .child(
                h_flex()
                    .h(px(32.0))
                    .w_full()
                    .bg(ThemeColors::bg_sidebar())
                    .border_b_1()
                    .border_color(ThemeColors::border())
                    .items_center()
                    .justify_between()
                    .px_3()
                    .child(
                        div()
                            .text_xs()
                            .font_weight(FontWeight::BOLD)
                            .text_color(ThemeColors::text_muted())
                            .child("Maven"),
                    )
                    .child(
                        h_flex()
                            .items_center()
                            .gap_1()
                            .child(
                                Button::new("maven-refresh")
                                    .small()
                                    .ghost()
                                    .icon(IconName::RotateCw)
                                    .tooltip("Refresh")
                                    .on_click(cx.listener(|this, _event, _window, cx| {
                                        this.refresh(cx);
                                    })),
                            )
                            .child(
                                Button::new("maven-close")
                                    .small()
                                    .ghost()
                                    .icon(IconName::Close)
                                    .tooltip("Close")
                                    .on_click(cx.listener(|_this, _event, _window, cx| {
                                        cx.emit(MavenEvent::Close);
                                    })),
                            ),
                    ),
            )
            .child(if has_projects {
                div()
                    .flex_1()
                    .w_full()
                    .overflow_y_scrollbar()
                    .children(rows)
                    .into_any_element()
            } else {
                div()
                    .flex_1()
                    .w_full()
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_xs()
                    .text_color(ThemeColors::text_muted())
                    .child("No Maven projects found")
                    .into_any_element()
            })
    }
}
