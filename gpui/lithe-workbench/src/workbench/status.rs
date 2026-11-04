use std::path::{Path, PathBuf};
use std::rc::Rc;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::scroll::Scrollbar;
use gpui_kit::component::{
    Disableable as _, InteractiveElementExt as _, Selectable as _, Sizable as _, h_flex, v_flex,
    v_virtual_list,
};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    Anchor, AnyElement, AppContext as _, Context, Hsla, InteractiveElement as _, IntoElement,
    ParentElement as _, RenderOnce as _, SharedString, Size, StatefulInteractiveElement as _,
    Styled as _, WeakEntity, Window, div, px, size,
};
use lithe_features::language::problems::{PreviewFailure, ProblemsScope};
use lithe_features::language::status as java_status;
use lithe_ui::components::status_bar::{LitheStatusBar, StatusBarItem};
use lithe_ui::i18n::tr;
use lithe_ui::icons::{LitheIcon, icon};
use lithe_ui::{LitheMetrics, LitheTokens, MONO_FONT_FAMILY, current_tokens};

use super::tabs::file_icon;
use super::{Workbench, theme_display_name, theme_kind_for};

/// Problems 面板的严重级别位掩码，与 `DiagnosticItem::severity` 同一编码。
const PROBLEM_SEVERITY_ERROR: u8 = 8;
const PROBLEM_SEVERITY_WARNING: u8 = 4;
const PROBLEM_SEVERITY_INFORMATION: u8 = 2;
const PROBLEM_SEVERITY_HINT: u8 = 1;
const PROBLEM_SEVERITY_ALL: u8 = PROBLEM_SEVERITY_ERROR
    | PROBLEM_SEVERITY_WARNING
    | PROBLEM_SEVERITY_INFORMATION
    | PROBLEM_SEVERITY_HINT;

/// View Options 菜单顺序对齐 macOS `DiagnosticSeverity.allCases`。
const PROBLEM_SEVERITY_OPTIONS: [(u8, &'static str); 4] = [
    (PROBLEM_SEVERITY_ERROR, "Errors"),
    (PROBLEM_SEVERITY_WARNING, "Warnings"),
    (PROBLEM_SEVERITY_INFORMATION, "Information"),
    (PROBLEM_SEVERITY_HINT, "Hint"),
];

/// 内容区首行（范围分段 + 计数）的高度。
const PROBLEM_SCOPE_BAR_HEIGHT: f32 = 34.0;
/// 左侧竖排工具栏宽度，对齐 macOS Problems 工具栏的图标按钮列。
const PROBLEM_TOOLBAR_WIDTH: f32 = 28.0;
const PROBLEM_TOOLBAR_BUTTON_SIZE: f32 = 22.0;
const PROBLEM_TOOLBAR_ICON_SIZE: f32 = 14.0;
/// 文件分组行与诊断行高度（`LitheTreeList` 的单行高度）。
const PROBLEM_FILE_ROW_HEIGHT: f32 = 26.0;
const PROBLEM_ROW_HEIGHT: f32 = 22.0;
/// 源码预览的单行高度与行号槽宽度。
const PROBLEM_PREVIEW_LINE_HEIGHT: f32 = 18.0;
const PROBLEM_PREVIEW_GUTTER_WIDTH: f32 = 44.0;

impl Workbench {
    /// 当前过滤条件下该严重级别是否展示。
    pub(super) fn problem_severity_enabled(&self, severity: u8) -> bool {
        self.problem_severity_filter & severity != 0
    }

    /// View Options 菜单里切换单个严重级别；与 macOS 一样允许关掉全部级别。
    pub(crate) fn toggle_problem_severity(&mut self, severity: u8, cx: &mut Context<Self>) {
        self.problem_severity_filter ^= severity;
        cx.notify();
    }

    /// View Options 菜单的「全部级别」：恢复四种级别的展示。
    pub(crate) fn show_all_problem_severities(&mut self, cx: &mut Context<Self>) {
        if self.problem_severity_filter != PROBLEM_SEVERITY_ALL {
            self.problem_severity_filter = PROBLEM_SEVERITY_ALL;
            cx.notify();
        }
    }

    /// 标题栏刷新：JDT 按文件增量推送诊断，这里重新读取语言服务的当前快照，
    /// 让面板与语言服务内存中的权威结果重新对齐。
    pub(crate) fn refresh_problems(&mut self, cx: &mut Context<Self>) {
        self.problems = self.java_language.read(cx).diagnostics().to_vec();
        cx.notify();
    }

    pub(super) fn render_status_bar(
        &self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mut left = vec![
            StatusBarItem::new("lithe-status-project", self.project_name())
                .icon(LitheIcon::Project),
            StatusBarItem::new(
                "lithe-status-git-count",
                format!("{} {}", self.git_change_count, tr("changes")),
            )
            .icon(LitheIcon::Changes),
        ];

        if let Some(tab) = self.current_tab() {
            left.push(
                StatusBarItem::new("lithe-status-file", tab.display_path.clone()).icon(tab.icon),
            );
        }

        if let Some(message) = &self.status_message {
            left.push(StatusBarItem::new("lithe-status-message", message.clone()));
        }

        let position = format!(
            "{} {}, {} {}",
            tr("Ln"),
            self.cursor_line,
            tr("Col"),
            self.cursor_column
        );

        let theme = format!(
            "{} · {}",
            theme_display_name(theme_kind_for(&self.settings.theme)),
            if self.settings.dark {
                tr("Dark")
            } else {
                tr("Light")
            }
        );

        let memory = format!("{} {}", tr("RAM"), self.memory_text);

        let mut right = Vec::new();
        // Java 项目准备状态紧挨内存之前，与 macOS 状态栏顺序一致。
        if let Some(item) = java_status::status_item(
            self.java_language.read(cx),
            self.java_language.downgrade(),
            current_tokens(cx),
        ) {
            right.push(item);
        }
        right.extend([
            StatusBarItem::new("lithe-status-memory", memory),
            StatusBarItem::new("lithe-status-theme", theme),
            StatusBarItem::new("lithe-status-position", position),
            StatusBarItem::new("lithe-status-encoding", tr("UTF-8")),
            StatusBarItem::new("lithe-status-indent", tr("4 spaces")),
        ]);

        LitheStatusBar::new(left, right)
            .render(window, cx)
            .into_any_element()
    }

    /// 状态栏展开的 Java 项目准备面板；与服务状态共用同一份快照。
    pub(super) fn render_java_preparation_panel(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let tokens = current_tokens(cx);
        let owner = self.java_language.downgrade();
        let workbench = cx.weak_entity();
        let settings_owner = workbench.clone();
        let logs_owner = workbench;
        java_status::render_panel(
            self.java_language.read(cx),
            tokens,
            owner,
            move |window, cx| {
                let _ = settings_owner.update(cx, |this, cx| {
                    this.open_language_service_settings(window, cx);
                });
            },
            move |window, cx| {
                let _ = logs_owner.update(cx, |this, cx| {
                    this.open_log_settings(window, cx);
                });
            },
        )
    }

    /// Problems 工具窗：对齐 macOS `ProblemsView`。
    ///
    /// 结构：内容区首行是范围分段与错误/警告计数（标题、折叠由 dock 的通用
    /// 标题栏提供）→ 左侧竖排工具栏（View Options、源码预览开关）→ 按文件
    /// 分组的虚拟化诊断列表。打开预览时列表右侧显示选中诊断的只读源码。
    pub(super) fn render_problems(&self, cx: &mut Context<Self>) -> AnyElement {
        let tokens = current_tokens(cx);
        let owner = cx.weak_entity();
        let scope = self.java_language.read(cx).problems_panel().scope;
        let preview_enabled = self.java_language.read(cx).problems_panel().preview_enabled;
        let current_file = self.problems_current_file();
        let visible = self.visible_problem_indices(scope, current_file.as_deref());

        let error_count = visible
            .iter()
            .filter(|index| self.problems[**index].severity & PROBLEM_SEVERITY_ERROR != 0)
            .count();
        let warning_count = visible
            .iter()
            .filter(|index| self.problems[**index].severity & PROBLEM_SEVERITY_WARNING != 0)
            .count();

        let scope_bar = self.render_problems_scope_bar(
            scope,
            visible.len(),
            error_count,
            warning_count,
            tokens,
            owner.clone(),
        );

        let body = if visible.is_empty() {
            // 空状态时工具栏仍然存在（macOS 的 `listWithToolbar` 一直包含它），
            // 预览按钮因为列表为空而禁用。
            h_flex()
                .flex_1()
                .h_full()
                .min_h(px(0.))
                .min_w(px(0.))
                .items_stretch()
                .child(self.render_problems_toolbar(false, preview_enabled, owner, tokens))
                .child(render_problems_empty_state(
                    scope,
                    &current_file,
                    self.problem_severity_filter,
                    tokens,
                ))
                .into_any_element()
        } else {
            let collapsed = self
                .java_language
                .read(cx)
                .problems_panel()
                .collapsed_files
                .clone();
            let rows = Rc::new(self.build_problem_rows(&visible, &collapsed));
            let item_sizes = Rc::new(
                rows.iter()
                    .map(|row| match row {
                        ProblemRowKind::File { .. } => {
                            size(px(0.), px(PROBLEM_FILE_ROW_HEIGHT))
                        }
                        ProblemRowKind::Item { .. } => size(px(0.), px(PROBLEM_ROW_HEIGHT)),
                    })
                    .collect::<Vec<_>>(),
            );
            let list = self.render_problem_list(rows, item_sizes, tokens, cx);

            let mut content = h_flex()
                .flex_1()
                .h_full()
                .min_h(px(0.))
                .min_w(px(0.))
                .items_stretch()
                .child(self.render_problems_toolbar(true, preview_enabled, owner, tokens))
                .child(list);

            if preview_enabled {
                content = content
                    .child(div().w(px(1.)).h_full().bg(tokens.divider))
                    .child(
                        div()
                            .flex_1()
                            .h_full()
                            .min_w(px(0.))
                            .min_h(px(0.))
                            .child(self.render_problem_preview(tokens, cx)),
                    );
            }
            content.into_any_element()
        };

        v_flex()
            .id("lithe-problems")
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            // 与编辑器使用同一背景 token，深色/浅色切换时保持视觉连续。
            .bg(tokens.editor)
            .child(scope_bar)
            .child(body)
            .into_any_element()
    }

    /// Problems 面板左侧的竖排工具栏（对齐 macOS `ProblemsView.toolbar`）。
    ///
    /// 一级是 View Options（严重级别过滤），二级是源码预览开关；预览按钮在
    /// 列表为空时禁用，和 macOS `disabled(selectedDiagnostic == nil)` 一致。
    fn render_problems_toolbar(
        &self,
        can_preview: bool,
        preview_enabled: bool,
        owner: WeakEntity<Workbench>,
        tokens: LitheTokens,
    ) -> AnyElement {
        let filter = self.problem_severity_filter;
        let all_checked = filter == PROBLEM_SEVERITY_ALL;
        let toggle_owner = owner.clone();
        let open_owner = owner.clone();

        let options = Button::new("lithe-problems-view-options")
            .ghost()
            .with_size(px(PROBLEM_TOOLBAR_BUTTON_SIZE))
            .rounded(px(LitheMetrics::TOOLBAR_ICON_BUTTON_RADIUS))
            .icon(
                icon(LitheIcon::Sliders)
                    .with_size(px(PROBLEM_TOOLBAR_ICON_SIZE))
                    .text_color(tokens.tool_window_button_text),
            )
            .tooltip(tr("View options"))
            .accessibility_label(tr("View options"))
            .dropdown_menu_with_anchor(Anchor::TopRight, move |mut menu, _, _| {
                let all_owner = toggle_owner.clone();
                menu = menu
                    .item(
                        PopupMenuItem::new(tr("All severities"))
                            .checked(all_checked)
                            .on_click(move |_, _, cx| {
                                let _ = all_owner.update(cx, |this, cx| {
                                    this.show_all_problem_severities(cx);
                                });
                            }),
                    )
                    .item(PopupMenuItem::separator());

                for (severity, label) in PROBLEM_SEVERITY_OPTIONS {
                    let severity_owner = toggle_owner.clone();
                    menu = menu.item(
                        PopupMenuItem::new(tr(label))
                            .checked(filter & severity != 0)
                            .on_click(move |_, _, cx| {
                                let _ = severity_owner.update(cx, |this, cx| {
                                    this.toggle_problem_severity(severity, cx);
                                });
                            }),
                    );
                }
                menu
            })
            .on_open_change(move |open, _window, cx| {
                let _ = open_owner.update(cx, |this, cx| this.set_menu_open(*open, cx));
            });

        let preview_owner = owner;
        let preview = Button::new("lithe-problems-preview-toggle")
            .ghost()
            .selected(preview_enabled)
            .disabled(!can_preview)
            .with_size(px(PROBLEM_TOOLBAR_BUTTON_SIZE))
            .rounded(px(LitheMetrics::TOOLBAR_ICON_BUTTON_RADIUS))
            .icon(
                icon(LitheIcon::File)
                    .with_size(px(PROBLEM_TOOLBAR_ICON_SIZE))
                    .text_color(tokens.tool_window_button_text),
            )
            .tooltip(tr("Show Editor Preview"))
            .accessibility_label(tr("Show Editor Preview"))
            .on_click(move |_, _window, cx| {
                let _ = preview_owner.update(cx, |this, cx| this.toggle_problem_preview(cx));
            });

        v_flex()
            .id("lithe-problems-toolbar")
            .w(px(PROBLEM_TOOLBAR_WIDTH))
            .h_full()
            .flex_shrink_0()
            .items_center()
            .gap(px(2.))
            .py(px(5.))
            .border_r_1()
            .border_color(tokens.divider)
            .child(options)
            .child(preview)
            .into_any_element()
    }

    pub(super) fn problem_display_path(&self, path: &Path) -> SharedString {
        if let Some(root) = self.project_root.as_deref() {
            if let Ok(relative) = path.strip_prefix(root) {
                let text = relative.to_string_lossy().replace('\\', "/");
                if !text.is_empty() {
                    return text.into();
                }
            }
        }
        path.to_string_lossy().into_owned().into()
    }

    pub(super) fn open_problem(
        &mut self,
        path: PathBuf,
        line: u32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let requested = match self.project_root.as_deref() {
            Some(root) => path
                .strip_prefix(root)
                .map(|relative| relative.to_path_buf())
                .unwrap_or_else(|_| path.to_path_buf()),
            None => path,
        };
        // 诊断行号是 1-based，直接交给统一的「打开并跳行」入口。
        self.open_file_at_line(requested, line, window, cx);
    }

    /// Problems 内容区首行：范围分段（File / Project Errors）与错误/警告计数。
    ///
    /// 标题、折叠与隐藏由 `dock.rs` 的通用标题栏提供（macOS 把 scope 与计数
    /// 直接放在标题栏里；GPUI 这里放在内容区第一行，避免出现两个 41pt 标题栏）。
    fn render_problems_scope_bar(
        &self,
        scope: ProblemsScope,
        visible_count: usize,
        error_count: usize,
        warning_count: usize,
        tokens: LitheTokens,
        owner: WeakEntity<Workbench>,
    ) -> AnyElement {
        let mut tabs = h_flex().items_center().gap(px(8.));
        for (tab_scope, label) in [
            (ProblemsScope::File, tr("File")),
            (ProblemsScope::ProjectErrors, tr("Project Errors")),
        ] {
            let tab_owner = owner.clone();
            let selected = scope == tab_scope;
            let count = (selected && visible_count > 0).then_some(visible_count);
            let mut tab = h_flex()
                .id(format!("lithe-problems-scope:{}", problem_scope_id(tab_scope)))
                .items_center()
                .gap(px(6.))
                .px(px(8.))
                .py(px(3.))
                .rounded(px(5.))
                .cursor_pointer()
                .when(selected, |this| this.bg(tokens.selection))
                .when(!selected, |this| this.hover(|style| style.bg(tokens.hover)))
                .on_click(move |_, _window, cx| {
                    let _ =
                        tab_owner.update(cx, |this, cx| this.set_problem_scope(tab_scope, cx));
                })
                .child(
                    div()
                        .text_size(px(LitheMetrics::UI_FONT_SIZE))
                        .text_color(tokens.primary_text)
                        .child(label),
                );
            if let Some(count) = count {
                tab = tab.child(
                    div()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.secondary_text)
                        .child(count.to_string()),
                );
            }
            tabs = tabs.child(tab);
        }

        h_flex()
            .id("lithe-problems-scope-bar")
            .w_full()
            .h(px(PROBLEM_SCOPE_BAR_HEIGHT))
            .flex_shrink_0()
            .items_center()
            .gap(px(8.))
            .px(px(8.))
            .bg(tokens.editor)
            .border_b_1()
            .border_color(tokens.divider)
            .child(tabs)
            .child(div().flex_1())
            .children(
                (error_count > 0)
                    .then(|| problem_count(tokens.error, error_count, tokens)),
            )
            .children(
                (warning_count > 0)
                    .then(|| problem_count(tokens.warning, warning_count, tokens)),
            )
            .into_any_element()
    }

    /// 切换 Problems 面板范围。
    pub(crate) fn set_problem_scope(&mut self, scope: ProblemsScope, cx: &mut Context<Self>) {
        self.java_language
            .update(cx, |model, _| model.problems_panel_mut().set_scope(scope));
        cx.notify();
    }

    /// 当前编辑器文件。macOS 的 scope 只跟随文本编辑器；GPUI 的工作台标签
    /// 都是文件页，因此直接取活动标签路径，并去掉 Windows canonicalize 留下
    /// 的 `\\?\` 前缀——JDT 诊断路径是普通盘符路径，带前缀会失配。
    fn problems_current_file(&self) -> Option<PathBuf> {
        self.active_tab_path()
            .map(|path| super::tabs::strip_verbatim_prefix(&path))
    }

    /// 当前范围与严重级别过滤后可见诊断在 `self.problems` 中的下标。
    ///
    /// 只做索引投影，不复制诊断条目；`problems` 已经按 path/line/column
    /// 排序，因此同文件的条目天然连续。
    fn visible_problem_indices(
        &self,
        scope: ProblemsScope,
        current_file: Option<&Path>,
    ) -> Vec<usize> {
        let mut visible = Vec::new();
        for (index, problem) in self.problems.iter().enumerate() {
            if scope == ProblemsScope::File {
                let Some(current) = current_file else {
                    continue;
                };
                if !same_path(&problem.path, current) {
                    continue;
                }
            }
            if self.problem_severity_enabled(problem.severity) {
                visible.push(index);
            }
        }
        visible
    }

    /// 把可见诊断投影成"文件头 + 诊断行"的虚拟列表行。
    fn build_problem_rows(
        &self,
        visible: &[usize],
        collapsed: &[PathBuf],
    ) -> Vec<ProblemRowKind> {
        let mut rows = Vec::with_capacity(visible.len() + 8);
        let mut cursor = 0;
        while cursor < visible.len() {
            let path = &self.problems[visible[cursor]].path;
            let mut end = cursor + 1;
            while end < visible.len() && same_path(&self.problems[visible[end]].path, path) {
                end += 1;
            }
            let is_collapsed = collapsed.iter().any(|entry| same_path(entry, path));
            rows.push(ProblemRowKind::File {
                path: path.clone(),
                count: end - cursor,
                collapsed: is_collapsed,
            });
            if !is_collapsed {
                for index in &visible[cursor..end] {
                    rows.push(ProblemRowKind::Item { index: *index });
                }
            }
            cursor = end;
        }
        rows
    }

    /// 虚拟化诊断列表：只构建视口附近的行走 `v_virtual_list`。
    fn render_problem_list(
        &self,
        rows: Rc<Vec<ProblemRowKind>>,
        item_sizes: Rc<Vec<Size<gpui_kit::Pixels>>>,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let handle = self
            .java_language
            .read(cx)
            .problems_panel()
            .list_scroll
            .clone();
        let list_rows = rows;
        div()
            .relative()
            .flex_1()
            .min_w(px(0.))
            .min_h(px(0.))
            .child(
                v_virtual_list(
                    cx.entity(),
                    "lithe-problems-list",
                    item_sizes,
                    move |this, range, _window, cx| {
                        range
                            .map(|index| this.render_problem_row(&list_rows, index, tokens, cx))
                            .collect::<Vec<_>>()
                    },
                )
                .track_scroll(&handle)
                .size_full(),
            )
            .child(div().absolute().inset_0().child(
                Scrollbar::vertical(&handle).id("lithe-problems-scrollbar"),
            ))
            .into_any_element()
    }

    /// 渲染虚拟列表中的一行。
    fn render_problem_row(
        &self,
        rows: &[ProblemRowKind],
        index: usize,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(row) = rows.get(index) else {
            return div().into_any_element();
        };
        match row {
            ProblemRowKind::File {
                path,
                count,
                collapsed,
            } => self.render_problem_file_row(index, path, *count, *collapsed, tokens, cx),
            ProblemRowKind::Item { index: problem_index } => {
                self.render_problem_diagnostic_row(*problem_index, tokens, cx)
            }
        }
    }

    /// 文件分组头：折叠箭头、文件图标、文件名、相对目录与诊断数。
    fn render_problem_file_row(
        &self,
        row_index: usize,
        path: &Path,
        count: usize,
        collapsed: bool,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let owner = cx.weak_entity();
        let click_path = path.to_path_buf();
        let name = path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.to_string_lossy().into_owned());
        let directory = path
            .parent()
            .map(|parent| self.problem_display_path(parent))
            .filter(|text| !text.is_empty())
            .unwrap_or_default();

        h_flex()
            .id(format!("lithe-problem-file:{row_index}"))
            .w_full()
            .h(px(PROBLEM_FILE_ROW_HEIGHT))
            .flex_shrink_0()
            .items_center()
            .gap(px(6.))
            .px(px(12.))
            .cursor_pointer()
            .hover(|style| style.bg(tokens.hover))
            .on_click(move |_, _window, cx| {
                let target = click_path.clone();
                let _ =
                    owner.update(cx, |this, cx| this.toggle_problem_group(target, cx));
            })
            .child(
                icon(if collapsed {
                    LitheIcon::ChevronRight
                } else {
                    LitheIcon::ChevronDown
                })
                .with_size(px(12.))
                .text_color(tokens.tertiary_text),
            )
            .child(
                icon(file_icon(path))
                    .with_size(px(14.))
                    .text_color(tokens.secondary_text),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .truncate()
                    .text_size(px(12.5))
                    .text_color(tokens.primary_text)
                    .child(name),
            )
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .truncate()
                    .text_size(px(11.))
                    .text_color(tokens.secondary_text)
                    .child(directory),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .text_size(px(11.))
                    .text_color(tokens.secondary_text)
                    .child(count.to_string()),
            )
            .into_any_element()
    }

    /// 诊断行：严重级别圆点、消息、`:line:column`、来源与原因摘要。
    fn render_problem_diagnostic_row(
        &self,
        row_index: usize,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(problem) = self.problems.get(row_index) else {
            return div().into_any_element();
        };
        let selected = self
            .java_language
            .read(cx)
            .problems_panel()
            .selected
            .as_deref()
            == Some(problem.id.as_str());
        let owner = cx.weak_entity();
        let open_owner = owner.clone();
        let open_path = problem.path.clone();
        let open_line = problem.line;
        let message = problem.message.replace('\n', " ");
        let position = format!(":{}:{}", problem.line, problem.column);
        let source = problem.source.clone();
        let reason = problem.reason_summary().map(str::to_string);
        let color = problem_severity_color(problem.severity, tokens);
        let target = row_index;

        h_flex()
            .id(format!("lithe-problem-row:{}", problem.id))
            .w_full()
            .h(px(PROBLEM_ROW_HEIGHT))
            .flex_shrink_0()
            .items_center()
            .gap(px(6.))
            .px(px(12.))
            .cursor_pointer()
            .when(selected, |this| this.bg(tokens.selection))
            .hover(|style| style.bg(tokens.hover))
            .on_click(move |_, window, cx| {
                let _ = owner.update(cx, |this, cx| this.activate_problem(target, window, cx));
            })
            .on_double_click(move |_, window, cx| {
                let path = open_path.clone();
                let _ =
                    open_owner.update(cx, |this, cx| this.open_problem(path, open_line, window, cx));
            })
            .child(div().size(px(6.)).flex_shrink_0().rounded_full().bg(color))
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .truncate()
                    .text_size(px(12.))
                    .text_color(tokens.primary_text)
                    .child(message),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .text_size(px(11.))
                    .text_color(tokens.tertiary_text)
                    .child(position),
            )
            .children(source.map(|source| {
                div()
                    .flex_shrink_0()
                    .text_size(px(11.))
                    .text_color(tokens.secondary_text)
                    .child(source)
            }))
            .children(reason.map(|reason| {
                div()
                    .flex_shrink_0()
                    .text_size(px(11.))
                    .text_color(tokens.secondary_text)
                    .child(reason)
            }))
            .into_any_element()
    }

    /// 点击诊断行：选中；预览关闭时同时打开文件（对齐 macOS `onClick`）。
    fn activate_problem(
        &mut self,
        problem_index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(problem) = self.problems.get(problem_index) else {
            return;
        };
        let id = problem.id.clone();
        let path = problem.path.clone();
        let line = problem.line;
        let row = problem.line.saturating_sub(1) as usize;
        let column = problem.column.saturating_sub(1) as usize;
        let preview_enabled = self.java_language.read(cx).problems_panel().preview_enabled;
        self.java_language
            .update(cx, |model, _| model.problems_panel_mut().select(&id));
        if preview_enabled {
            self.load_problem_preview(path, row, column, cx);
        } else {
            self.open_problem(path, line, window, cx);
        }
        cx.notify();
    }

    /// 切换文件分组的折叠状态。
    fn toggle_problem_group(&mut self, path: PathBuf, cx: &mut Context<Self>) {
        self.java_language.update(cx, |model, _| {
            model.problems_panel_mut().toggle_collapsed(&path)
        });
        cx.notify();
    }

    /// 切换源码预览；打开时选中并加载第一条可见诊断（对齐 macOS
    /// `selectedDiagnostic ?? diagnostics.first`）。
    fn toggle_problem_preview(&mut self, cx: &mut Context<Self>) {
        let enabled = !self.java_language.read(cx).problems_panel().preview_enabled;
        let target = if enabled {
            self.first_visible_problem(cx)
        } else {
            None
        };
        self.java_language.update(cx, |model, _| {
            let panel = model.problems_panel_mut();
            panel.preview_enabled = enabled;
            if !enabled {
                panel.discard_preview();
            }
        });
        if let Some((id, path, row, column)) = target {
            self.java_language
                .update(cx, |model, _| model.problems_panel_mut().select(&id));
            self.load_problem_preview(path, row, column, cx);
        }
        cx.notify();
    }

    /// 当前范围内第一条可见诊断：(id, 路径, 0 基行, 0 基列)。
    fn first_visible_problem(
        &self,
        cx: &gpui_kit::App,
    ) -> Option<(String, PathBuf, usize, usize)> {
        let scope = self.java_language.read(cx).problems_panel().scope;
        let current_file = self.problems_current_file();
        let visible = self.visible_problem_indices(scope, current_file.as_deref());
        let index = *visible.first()?;
        let problem = self.problems.get(index)?;
        Some((
            problem.id.clone(),
            problem.path.clone(),
            problem.line.saturating_sub(1) as usize,
            problem.column.saturating_sub(1) as usize,
        ))
    }

    /// 后台读取预览文档并写回语言服务上的面板状态；代次过期时丢弃。
    fn load_problem_preview(
        &mut self,
        path: PathBuf,
        row: usize,
        column: usize,
        cx: &mut Context<Self>,
    ) {
        let generation = {
            let path = path.clone();
            self.java_language.update(cx, |model, _| {
                model
                    .problems_panel_mut()
                    .begin_preview(path, row, column)
            })
        };
        let java = self.java_language.clone();
        let source = path;
        cx.spawn(async move |_this, cx| {
            let result = cx
                .background_spawn(async move {
                    lithe_features::language::problems::read_preview(&source)
                })
                .await;
            java.update(cx, |model, cx| {
                if model
                    .problems_panel_mut()
                    .finish_preview(generation, result)
                {
                    cx.notify();
                }
            });
        })
        .detach();
        cx.notify();
    }

    /// 右侧只读源码预览：虚拟化整份文件，目标行高亮。
    fn render_problem_preview(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let (loading, failure, target_row, line_count, handle) = {
            let panel = self.java_language.read(cx).problems_panel();
            (
                panel.preview.loading,
                panel.preview.failure,
                panel.preview.target_row,
                panel.preview.lines.len(),
                panel.preview_scroll.clone(),
            )
        };

        if loading {
            return preview_note(tr("Loading…"), tokens);
        }
        if let Some(failure) = failure {
            let text = match failure {
                PreviewFailure::TooLarge => tr("This file is too large to preview"),
                PreviewFailure::ReadFailed => tr("Could not load file preview"),
            };
            return preview_note(text, tokens);
        }
        if line_count == 0 {
            return preview_note(tr("Select a problem to preview"), tokens);
        }

        let item_sizes = Rc::new(
            (0..line_count)
                .map(|_| size(px(0.), px(PROBLEM_PREVIEW_LINE_HEIGHT)))
                .collect::<Vec<_>>(),
        );
        let gutter = PROBLEM_PREVIEW_GUTTER_WIDTH;
        div()
            .relative()
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .child(
                v_virtual_list(
                    cx.entity(),
                    "lithe-problems-preview",
                    item_sizes,
                    move |this, range, _window, cx| {
                        range
                            .map(|index| {
                                this.render_problem_preview_line(
                                    index,
                                    gutter,
                                    target_row,
                                    tokens,
                                    cx,
                                )
                            })
                            .collect::<Vec<_>>()
                    },
                )
                .track_scroll(&handle)
                .size_full(),
            )
            .child(div().absolute().inset_0().child(
                Scrollbar::vertical(&handle).id("lithe-problems-preview-scrollbar"),
            ))
            .into_any_element()
    }

    /// 预览中的一行：行号槽 + 等宽文本，目标行用选中色标出。
    fn render_problem_preview_line(
        &self,
        index: usize,
        gutter: f32,
        target_row: usize,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let text = {
            let panel = self.java_language.read(cx).problems_panel();
            panel.preview.lines.get(index).cloned()
        };
        let Some(text) = text else {
            return div().into_any_element();
        };
        h_flex()
            .id(format!("lithe-problem-preview-line:{index}"))
            .w_full()
            .h(px(PROBLEM_PREVIEW_LINE_HEIGHT))
            .flex_shrink_0()
            .items_center()
            .when(index == target_row, |this| this.bg(tokens.selection))
            .child(
                div()
                    .w(px(gutter))
                    .pr(px(8.))
                    .flex_shrink_0()
                    .text_right()
                    .text_size(px(11.))
                    .text_color(tokens.tertiary_text)
                    .child((index + 1).to_string()),
            )
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.))
                    .truncate()
                    .font_family(MONO_FONT_FAMILY)
                    .text_size(px(12.))
                    .text_color(tokens.primary_text)
                    .child(text),
            )
            .into_any_element()
    }
}

/// Problems 虚拟列表的一行。
#[derive(Clone, Debug)]
enum ProblemRowKind {
    /// 文件分组头；`count` 是过滤后该文件的诊断数。
    File {
        path: PathBuf,
        count: usize,
        collapsed: bool,
    },
    /// 一条诊断，指向工作台 `problems` 快照的下标。
    Item { index: usize },
}

/// 标题栏里的错误/警告计数：圆点 + 数字，对齐 macOS `severityCount`。
fn problem_count(color: Hsla, count: usize, tokens: LitheTokens) -> AnyElement {
    h_flex()
        .items_center()
        .gap(px(4.))
        .flex_shrink_0()
        .child(div().size(px(6.)).rounded_full().bg(color))
        .child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(count.to_string()),
        )
        .into_any_element()
}

/// 面板空状态：居中标题，下面一行过滤提示。
fn render_problems_empty_state(
    scope: ProblemsScope,
    current_file: &Option<PathBuf>,
    filter: u8,
    tokens: LitheTokens,
) -> AnyElement {
    let file_name = current_file
        .as_deref()
        .and_then(Path::file_name)
        .map(|name| name.to_string_lossy().into_owned());
    // 对齐 macOS `ProblemsEmptyState` 与 `ProblemsPanelScope.emptyTitle`：
    // 没有当前文件时不提示过滤（此时列表本来就该是空的）。
    let (title, show_filter_hint) = match (scope, file_name.as_deref()) {
        (ProblemsScope::File, Some(name)) => (
            tr("No problems in {file}").replace("{file}", name),
            filter != PROBLEM_SEVERITY_ALL,
        ),
        (ProblemsScope::File, None) => {
            (tr("Open file in editor to see problems").to_string(), false)
        }
        (ProblemsScope::ProjectErrors, _) => {
            (tr("No problems").to_string(), filter != PROBLEM_SEVERITY_ALL)
        }
    };

    let mut column = v_flex()
        .items_center()
        .gap(px(2.))
        .child(
            div()
                .text_size(px(13.))
                .text_color(tokens.secondary_text)
                .child(title),
        );
    if show_filter_hint {
        column = column.child(
            div()
                .text_size(px(13.))
                .text_color(tokens.secondary_text)
                .child(tr("Problems could be filtered out")),
        );
    }

    v_flex()
        .flex_1()
        .size_full()
        .min_h(px(0.))
        .min_w(px(0.))
        .items_center()
        .justify_center()
        .child(column)
        .into_any_element()
}

/// 预览区的居中提示（加载中、读取失败、未选中）。
fn preview_note(text: &'static str, tokens: LitheTokens) -> AnyElement {
    v_flex()
        .size_full()
        .min_h(px(0.))
        .min_w(px(0.))
        .items_center()
        .justify_center()
        .px(px(12.))
        .child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(text),
        )
        .into_any_element()
}

/// 按严重级别取圆点颜色：错误、警告、信息、提示各一档。
fn problem_severity_color(severity: u8, tokens: LitheTokens) -> Hsla {
    if severity & PROBLEM_SEVERITY_ERROR != 0 {
        tokens.error
    } else if severity & PROBLEM_SEVERITY_WARNING != 0 {
        tokens.warning
    } else if severity & PROBLEM_SEVERITY_INFORMATION != 0 {
        tokens.link
    } else {
        tokens.tertiary_text
    }
}

/// 两个路径是否指向同一文件：Windows 上盘符大小写与分隔符可能不同。
fn same_path(left: &Path, right: &Path) -> bool {
    if left == right {
        return true;
    }
    if cfg!(windows) {
        left.to_string_lossy()
            .eq_ignore_ascii_case(&right.to_string_lossy())
    } else {
        false
    }
}

fn problem_scope_id(scope: ProblemsScope) -> &'static str {
    match scope {
        ProblemsScope::File => "file",
        ProblemsScope::ProjectErrors => "project",
    }
}
