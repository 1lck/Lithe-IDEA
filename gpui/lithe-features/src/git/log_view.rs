//! Git Log 主区：标题栏、过滤工具条、提交表、右侧检查器（文件树 + 说明），
//! 以及提交行的右键动作菜单。
//!
//! 拆分自原 `git.rs`。渲染结构对齐 Tauri `GitLogToolWindow` 的三栏工作台。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    Anchor, AnyElement, AppContext as _, ClickEvent, Context, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, SharedString, Stateful, StatefulInteractiveElement as _,
    Styled as _, Window, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, MONO_FONT_FAMILY, icon};

use super::model::{ACTION_HORIZONTAL_PADDING, CoreCommit, CoreReference, LOG_ROW_HEIGHT, hex};
use super::{CommitFilterScope, GitPanel, execute_git_command};

impl GitPanel {
    /// 提交记录模式：对齐 Tauri GitLogToolWindow 的专业三栏工作台布局。
    pub(crate) fn render_log_view(
        &mut self,
        window: &mut Window,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let content = v_flex()
            .id("lithe-git-log-view")
            .size_full()
            .min_w_0()
            .min_h_0()
            .bg(tokens.editor)
            .child(self.render_log_header(tokens, cx))
            .child(
                h_flex()
                    .flex_1()
                    .min_w_0()
                    .min_h_0()
                    .child(self.render_log_references_panel(tokens, cx))
                    .child(self.render_log_table(window, tokens, cx))
                    .child(self.render_log_inspector(tokens, cx)),
            );

        // 引用动作的确认弹窗与分支输入弹窗：与丢弃确认相同的模态覆盖模式。
        if let Some(confirm) = self.reference_confirm.clone() {
            return div()
                .relative()
                .size_full()
                .child(content)
                .child(self.render_reference_confirm(confirm, tokens, cx))
                .into_any_element();
        }
        if let Some((action, source)) = self.branch_prompt.clone() {
            return div()
                .relative()
                .size_full()
                .child(content)
                .child(self.render_branch_prompt(action, source, window, tokens, cx))
                .into_any_element();
        }

        // 提交动作：历史改写确认 / 编辑消息输入 / reset 模式选择 / 简单确认。
        if let Some(action) = self.commit_action.clone() {
            return div()
                .relative()
                .size_full()
                .child(content)
                .child(self.render_commit_action_overlay(action, window, tokens, cx))
                .into_any_element();
        }

        content.into_any_element()
    }

    /// Git Log 标题栏与 Tab 切换（对齐 Tauri 单层顶栏与模式 Tab）。
    fn render_log_header(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let title_row = h_flex()
            .w_full()
            .h(px(28.0))
            .items_center()
            .justify_between()
            .px(px(8.0))
            .bg(tokens.tool_header)
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                h_flex()
                    .items_center()
                    .gap(px(6.0))
                    .child(
                        Icon::new(gpui_kit::assets::IconName::GitBranch)
                            .with_size(px(13.0))
                            .text_color(tokens.primary_text),
                    )
                    .child(
                        div()
                            .text_size(px(LitheMetrics::TOOL_WINDOW_TITLE_FONT_SIZE))
                            .font_weight(FontWeight::BOLD)
                            .text_color(tokens.primary_text)
                            .child(tr("Git Log")),
                    )
                    .child(
                        h_flex()
                            .h(px(20.0))
                            .px(px(6.0))
                            .rounded(px(3.0))
                            .bg(tokens.sidebar)
                            .border_1()
                            .border_color(tokens.panel_border)
                            .items_center()
                            .gap(px(3.0))
                            .child(
                                div()
                                    .text_size(px(11.0))
                                    .text_color(tokens.primary_text)
                                    .child(tr("Log: All")),
                            )
                            .child(
                                Icon::new(gpui_kit::assets::IconName::ChevronDown)
                                    .with_size(px(9.0))
                                    .text_color(tokens.secondary_text),
                            ),
                    ),
            )
            .child(
                h_flex()
                    .items_center()
                    .gap(px(2.0))
                    .child(
                        Button::new("lithe-git-log:refresh")
                            .ghost()
                            .small()
                            .child(
                                Icon::new(gpui_kit::assets::IconName::RotateCw).with_size(px(12.0)),
                            )
                            .tooltip(tr("Refresh"))
                            .on_click(cx.listener(|this, _, window, cx| this.refresh(window, cx))),
                    )
                    .child(
                        Button::new("lithe-git-log:settings")
                            .ghost()
                            .small()
                            .child(
                                Icon::new(gpui_kit::assets::IconName::Settings).with_size(px(12.0)),
                            )
                            .tooltip(tr("Settings"))
                            // 对齐 Tauri `openSettingsDialog("git")`：打开设置页的
                            // Git 分类。回调由工作区在构造时注册。
                            .on_click(cx.listener(|this, _, window, cx| {
                                if let Some(handler) = this.on_open_git_settings.clone() {
                                    handler(window, cx);
                                }
                            })),
                    )
                    .child(
                        // 隐藏面板需要一个「请求收起底部 dock」的回调通道
                        // （对齐 Maven Output 的 on_hide + 工作台
                        // set_dock_visible(Bottom, false)）。回调字段还没落地，
                        // 按规则先禁用，不做点了没反应的按钮。
                        Button::new("lithe-git-log:minimize")
                            .ghost()
                            .small()
                            .disabled(true)
                            .child(Icon::new(gpui_kit::assets::IconName::Minus).with_size(px(12.0)))
                            .tooltip(tr("Minimize")),
                    ),
            );

        let tab_row = h_flex()
            .w_full()
            .h(px(24.0))
            .px(px(10.0))
            .items_center()
            .gap(px(14.0))
            .bg(tokens.tool_header)
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                div()
                    .h_full()
                    .flex()
                    .items_center()
                    .border_b(px(2.0))
                    .border_color(tokens.accent)
                    .text_size(px(11.5))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.primary_text)
                    .child(tr("Log")),
            )
            // Git 执行控制台（Tauri `git-execution-console.tsx`）依赖客户端持有
            // 命令流水记录；GPUI 构建目前没有执行记录 store，`git.consolePresentation`
            // 只是对客户端上传 records 的纯展示函数（`git.executionInspect` 是
            // 执行设置检查，不是日志）。这里保留为不可点击的占位标签，避免给出
            // 一个点了没反应的分段。
            .child(
                div()
                    .h_full()
                    .flex()
                    .items_center()
                    .text_size(px(11.5))
                    .text_color(tokens.tertiary_text)
                    .child(tr("Console")),
            );

        v_flex()
            .w_full()
            .child(title_row)
            .child(tab_row)
            .into_any_element()
    }

    /// Git Log 中栏：过滤搜索工具栏 + 彩色分支图轨提交表。
    pub(crate) fn render_log_table(
        &mut self,
        window: &mut Window,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // 文本过滤：按作用域大小写不敏感匹配（对齐 Tauri matchesGitLogCommit）。
        let filter = self.commit_filter.trim().to_lowercase();
        let scope = self.commit_filter_scope;
        let visible: Vec<&CoreCommit> = self
            .history
            .iter()
            .filter(|commit| scope.matches(commit, &filter))
            .collect();

        // 分支筛选标签：All branches 或当前选中的引用短名。
        let branch_label = self
            .selected_reference
            .clone()
            .unwrap_or_else(|| tr("All branches").to_string());

        // 惰性创建过滤输入框（InputState 需要 Window）。
        if self.filter_input.is_none() {
            let input = cx.new(|cx| InputState::new(window, cx).placeholder(tr("Filter by text…")));
            cx.subscribe_in(
                &input,
                window,
                |_this, _input, event: &InputEvent, _window, cx| {
                    if matches!(event, InputEvent::Change) {
                        // 由输入框自身持有文本；过滤读它，因此只需重绘。
                        cx.notify();
                    }
                },
            )
            .detach();
            self.filter_input = Some(input);
        }
        let filter_input = self.filter_input.clone();
        // 输入框是过滤关键字的真源：每次渲染同步回状态，过滤与计数都基于它。
        if let Some(input) = filter_input.as_ref() {
            self.commit_filter = input.read(cx).value().to_string();
        }
        let scope_for_menu = scope;
        let owner = cx.weak_entity();

        // 顶部过滤工具条（对齐 Tauri `GitCommitTable` 顶部工具条）。
        let filter_toolbar = h_flex()
            .w_full()
            .h(px(32.0))
            .items_center()
            .gap(px(8.0))
            .px(px(8.0))
            .bg(tokens.editor)
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                div().w(px(180.0)).child(
                    filter_input
                        .clone()
                        .map(|input| Input::new(&input).small().into_any_element())
                        .unwrap_or_else(|| div().into_any_element()),
                ),
            )
            // 过滤作用域选择（Text / Author / Branch，对齐 Tauri 的 scope 下拉）。
            .child(
                Button::new("git-log:filter-scope")
                    .ghost()
                    .small()
                    .rounded(px(4.0))
                    .label(scope.label())
                    .tooltip(tr("Filter scope"))
                    .dropdown_menu_with_anchor(Anchor::TopLeft, move |menu, _window, _cx| {
                        let mut menu = menu.min_w(px(140.0));
                        for (value, label) in [
                            (CommitFilterScope::Text, tr("Text")),
                            (CommitFilterScope::Author, tr("Author")),
                            (CommitFilterScope::Branch, tr("Branch")),
                        ] {
                            let owner = owner.clone();
                            menu = menu.item(
                                PopupMenuItem::new(label)
                                    .checked(value == scope_for_menu)
                                    .on_click(move |_, _, cx| {
                                        let _ = owner.update(cx, |this, cx| {
                                            this.commit_filter_scope = value;
                                            cx.notify();
                                        });
                                    }),
                            );
                        }
                        menu
                    }),
            )
            // 分支筛选选择（All branches + 每个引用）。
            .child({
                let owner = cx.weak_entity();
                let references: Vec<CoreReference> = self.references.clone();
                let selected = self.selected_reference.clone();
                Button::new("git-log:branch-filter")
                    .ghost()
                    .small()
                    .rounded(px(4.0))
                    .label(branch_label)
                    .tooltip(tr("Branch filter"))
                    .dropdown_menu_with_anchor(Anchor::TopLeft, move |menu, _window, _cx| {
                        let mut menu = menu.min_w(px(200.0));
                        let owner_all = owner.clone();
                        let is_all = selected.is_none();
                        menu = menu.item(
                            PopupMenuItem::new(tr("All branches"))
                                .checked(is_all)
                                .on_click(move |_, _, cx| {
                                    let _ = owner_all.update(cx, |this, cx| {
                                        this.select_reference(String::new(), cx);
                                    });
                                }),
                        );
                        for reference in references.iter() {
                            let owner = owner.clone();
                            let name = reference.short_name.clone();
                            let checked = selected.as_deref() == Some(name.as_str());
                            menu = menu.item(
                                PopupMenuItem::new(name.clone()).checked(checked).on_click(
                                    move |_, _, cx| {
                                        let name = name.clone();
                                        let _ = owner.update(cx, |this, cx| {
                                            this.select_reference(name, cx);
                                        });
                                    },
                                ),
                            );
                        }
                        menu
                    })
            })
            .child(div().flex_1())
            // 视图选项：装饰胶囊开关等（对齐 Tauri showDecorations）。
            .child({
                let owner = cx.weak_entity();
                let decorations_on = self.show_decorations;
                Button::new("git-log:view-options")
                    .ghost()
                    .with_size(px(24.0))
                    .rounded(px(4.0))
                    .tooltip(tr("View options"))
                    .child(Icon::new(gpui_kit::assets::IconName::Eye).with_size(px(14.0)))
                    .dropdown_menu_with_anchor(Anchor::TopRight, move |menu, _window, _cx| {
                        let owner = owner.clone();
                        menu.min_w(px(200.0)).item(
                            PopupMenuItem::new(tr("Show decorations"))
                                .checked(decorations_on)
                                .on_click(move |_, _, cx| {
                                    let _ = owner.update(cx, |this, cx| {
                                        this.show_decorations = !this.show_decorations;
                                        cx.notify();
                                    });
                                }),
                        )
                    })
            })
            .child(
                Button::new("git-log:locate-head")
                    .ghost()
                    .with_size(px(24.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Go to HEAD"))
                    .child(
                        Icon::new(gpui_kit::assets::IconName::ArrowDownToLine).with_size(px(14.0)),
                    )
                    // 定位 HEAD：选中当前分支的历史，与左栏的 HEAD 按钮同一条路径。
                    .on_click(cx.listener(|this, _, _window, cx| {
                        if let Some(current) = this
                            .references
                            .iter()
                            .find(|reference| reference.is_current)
                        {
                            this.select_reference(current.short_name.clone(), cx);
                        }
                    })),
            )
            .child(
                div()
                    .px(px(4.0))
                    .text_size(px(12.0))
                    .font_family(MONO_FONT_FAMILY)
                    .text_color(tokens.secondary_text)
                    // 真实计数：过滤后条数 / 缓冲区总条数。
                    .child(format!("{}/{}", visible.len(), self.history.len())),
            );

        // 提交数据表行（带彩色分支线和胶囊 Badge）
        let mut commit_list = v_flex()
            .id("lithe-git-log-table")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .bg(tokens.editor);

        let selected_hash = self
            .selected_commit_hash
            .clone()
            .or_else(|| self.history.first().map(|c| c.hash.clone()));

        // 彩色轨道颜色池（对齐 IntelliJ 图谱：绿、紫、蓝、橙）
        let graph_palette = [
            hex(0x57965C), // 绿色
            hex(0x9E6BD6), // 紫色
            hex(0x3871E1), // 蓝色
            hex(0xE8A033), // 橙色
        ];

        for (index, commit) in visible.iter().enumerate() {
            let is_selected = selected_hash.as_deref() == Some(&commit.hash);
            let track_color = graph_palette[index % graph_palette.len()];
            let hash = commit.hash.clone();
            let date_str = commit.date.clone();
            let commit_for_menu = (*commit).clone();

            commit_list = commit_list.child(
                h_flex()
                    .id(SharedString::from(format!(
                        "git-commit-row:{}",
                        commit.hash
                    )))
                    .w_full()
                    .h(px(22.0))
                    .px(px(6.0))
                    .items_center()
                    .gap(px(4.0))
                    .when(is_selected, |this| this.bg(tokens.subtle_selection))
                    .when(!is_selected, |this| this.hover(|s| s.bg(tokens.hover)))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        this.select_commit(hash.clone(), cx);
                    }))
                    // 右键：先选中该提交再打开动作菜单（对齐 Tauri onContextSelect）。
                    .on_mouse_down(
                        gpui_kit::MouseButton::Right,
                        cx.listener(move |this, event: &gpui_kit::MouseDownEvent, window, cx| {
                            this.select_commit(commit_for_menu.hash.clone(), cx);
                            this.open_commit_menu(
                                commit_for_menu.clone(),
                                event.position,
                                window,
                                cx,
                            );
                        }),
                    )
                    // 彩色图轨单元格
                    .child(
                        div()
                            .w(px(18.0))
                            .h_full()
                            .relative()
                            .flex()
                            .items_center()
                            .justify_center()
                            // 垂直轨道连线
                            .child(div().absolute().w(px(2.0)).h_full().bg(track_color))
                            // 节点实心圆圈
                            .child(
                                div()
                                    .size(px(6.0))
                                    .rounded_full()
                                    .border_1()
                                    .border_color(tokens.editor)
                                    .bg(track_color),
                            ),
                    )
                    // 提交标题正文
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(px(12.0))
                            .font_weight(if is_selected {
                                FontWeight::SEMIBOLD
                            } else {
                                FontWeight::NORMAL
                            })
                            .text_color(tokens.primary_text)
                            .child(commit.subject.clone()),
                    )
                    // 分支胶囊 Badge（紧凑药丸形）
                    .when(
                        self.show_decorations && !commit.decorations.is_empty(),
                        |this| {
                            this.child(
                                div()
                                    .px(px(4.0))
                                    .py(px(0.5))
                                    .rounded(px(3.0))
                                    .border_1()
                                    .border_color(track_color)
                                    .bg(track_color.alpha(0.18))
                                    .text_size(px(10.5))
                                    .text_color(track_color)
                                    .child(commit.decorations.clone()),
                            )
                        },
                    )
                    // 作者
                    .child(
                        div()
                            .w(px(90.0))
                            .px(px(6.0))
                            .truncate()
                            .text_size(px(11.5))
                            .text_color(tokens.secondary_text)
                            .child(commit.author_name.clone()),
                    )
                    // 日期（单行不折行）
                    .child(
                        div()
                            .w(px(120.0))
                            .truncate()
                            .text_size(px(11.5))
                            .text_color(tokens.tertiary_text)
                            .child(date_str),
                    ),
            );
        }

        v_flex()
            .flex_1()
            .h_full()
            .min_w_0()
            .child(filter_toolbar)
            .child(commit_list)
            .into_any_element()
    }

    /// Git Log 右栏：改动文件树（上半部分） + 提交详细说明（下半部分）。
    fn render_log_inspector(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let selected_commit = self
            .selected_commit_hash
            .as_ref()
            .and_then(|hash| self.history.iter().find(|c| &c.hash == hash))
            .or_else(|| self.history.first());

        let file_count = self.commit_files.len();

        // 上半部分：提交文件树
        let mut file_tree = v_flex()
            .id("lithe-git-log-file-tree")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .p(px(6.0))
            .gap(px(2.0));

        if self.commit_files.is_empty() {
            file_tree = file_tree.child(
                div()
                    .p(px(12.0))
                    .text_size(px(12.0))
                    .text_color(tokens.secondary_text)
                    .child(if self.loading_commit_files {
                        tr("Loading…")
                    } else {
                        tr("Select a commit to see its files.")
                    }),
            );
        } else {
            // 目录树：按 `/` 拆段建树，逐层缩进渲染文件夹与文件；
            // 折叠状态存于 `collapsed_commit_dirs`（对齐 Tauri 文件树的目录折叠）。
            let tree_root = build_commit_file_tree(&self.commit_files);
            file_tree = render_commit_tree_nodes(
                &tree_root,
                0,
                &self.collapsed_commit_dirs,
                self.selected_commit_file.as_deref(),
                tokens,
                cx,
                file_tree,
            );
        }

        let files_header = h_flex()
            .w_full()
            .h(px(28.0))
            .items_center()
            .justify_between()
            .px(px(8.0))
            .bg(tokens.sidebar)
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                div()
                    .text_size(px(12.0))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.primary_text)
                    .child(tr("Commit files")),
            )
            .child(
                div()
                    .text_size(px(11.0))
                    .text_color(tokens.secondary_text)
                    .child(format!("{} {}", file_count, tr("files"))),
            );

        let files_half = v_flex()
            .flex_1()
            .min_h_0()
            .border_b_1()
            .border_color(tokens.divider)
            .child(files_header)
            .child(file_tree);

        // 下半部分：提交正文与元数据。差异本身在**中央编辑区**打开
        //（`CommitDiffView`），右栏只保留文件树与说明，避免把 diff 挤在窄栏里。
        let message_half = v_flex()
            .id("lithe-git-log-message-half")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .p(px(12.0))
            .gap(px(8.0))
            .when_some(selected_commit, |this, commit| {
                this.child(
                    div()
                        .text_size(px(13.0))
                        .font_weight(FontWeight::BOLD)
                        .text_color(tokens.primary_text)
                        .child(commit.subject.clone()),
                )
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(tokens.secondary_text)
                        .child(format!("{} · {}", commit.author_name, commit.date)),
                )
                .child(
                    div()
                        .pt(px(4.0))
                        .text_size(px(12.0))
                        .font_family(MONO_FONT_FAMILY)
                        .text_color(tokens.tertiary_text)
                        .child(format!("commit {}", commit.hash)),
                )
            });

        v_flex()
            .id("lithe-git-log-inspector")
            .w(px(460.0))
            .h_full()
            .flex_shrink_0()
            .bg(tokens.editor)
            .border_l_1()
            .border_color(tokens.divider)
            .child(files_half)
            .child(message_half)
            .into_any_element()
    }

    /// 打开提交动作菜单。条目对齐 Tauri `git-commit-table` 的右键内容。
    pub(crate) fn open_commit_menu(
        &mut self,
        commit: CoreCommit,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let busy = self.is_reference_busy() || self.loading_rewrite_preview;
        let owner = cx.weak_entity();
        let is_head = self
            .history
            .first()
            .is_some_and(|first| first.hash == commit.hash);

        let popup =
            gpui_kit::component::menu::PopupMenu::build(window, cx, move |menu, _window, _cx| {
                let short_hash: String = commit.hash.chars().take(8).collect();
                let subject = commit.subject.clone();

                let item = |menu: gpui_kit::component::menu::PopupMenu,
                            owner: &gpui_kit::WeakEntity<GitPanel>,
                            action: &'static str,
                            label: &'static str,
                            disabled: bool|
                 -> gpui_kit::component::menu::PopupMenu {
                    let owner = owner.clone();
                    menu.item(PopupMenuItem::new(label).disabled(disabled).on_click(
                        move |_, _, cx| {
                            let _ = owner.update(cx, |this, cx| {
                                this.run_commit_action(action, cx);
                            });
                        },
                    ))
                };

                // 打开提交差异 / 与 HEAD 比较：GPUI 的 diff 渲染面尚未接入，
                // 这里按 Tauri 行为降级为加载该提交的文件列表。
                let menu = item(menu, &owner, "openDiff", tr("Open Commit Diff"), false);
                let menu = item(
                    menu,
                    &owner,
                    "compareWithHead",
                    tr("Compare with HEAD"),
                    false,
                );
                let menu = menu.separator();

                // 历史改写（undo / edit / delete）需要预览确认；undo 仅限 HEAD。
                let menu = item(menu, &owner, "undo", tr("Undo Commit"), busy || !is_head);
                let menu = item(menu, &owner, "edit", tr("Edit Commit Message"), busy);
                let menu = item(menu, &owner, "delete", tr("Delete Commit"), busy);
                let menu = item(menu, &owner, "reset", tr("Reset to Commit"), busy);
                let menu = item(
                    menu,
                    &owner,
                    "cherryPick",
                    tr("Cherry-pick Commit"),
                    busy || is_head,
                );
                let menu = item(menu, &owner, "revert", tr("Revert Commit"), busy);
                let menu = menu.separator();

                let copy = |menu: gpui_kit::component::menu::PopupMenu,
                            owner: gpui_kit::WeakEntity<GitPanel>,
                            text: String|
                 -> gpui_kit::component::menu::PopupMenu {
                    menu.item(PopupMenuItem::new(tr("Copy Commit Hash")).on_click(
                        move |_, window, cx| {
                            let _ = owner.update(cx, |this, cx| {
                                this.copy_text(&text.clone(), window, cx);
                            });
                        },
                    ))
                };
                let menu = copy(menu, owner.clone(), commit.hash.clone());
                let menu = copy(menu, owner.clone(), short_hash.clone());
                let menu = copy(menu, owner, subject);
                menu
            });

        cx.subscribe_in(
            &popup,
            window,
            |this, _, _: &gpui_kit::DismissEvent, _window, cx| {
                this.commit_menu = None;
                cx.notify();
            },
        )
        .detach();
        self.commit_menu = Some((popup, position));
        cx.notify();
    }

    /// 提交动作统一入口。
    pub(crate) fn run_commit_action(&mut self, action: &str, cx: &mut Context<Self>) {
        let Some(commit) = self.selected_commit() else {
            return;
        };
        let hash = commit.hash.clone();
        let subject = commit.subject.clone();
        match action {
            // 差异视图未接入前，选中提交即加载文件列表（与点击行一致）。
            "openDiff" | "compareWithHead" => {
                self.select_commit(hash, cx);
            }
            "undo" => self.begin_rewrite(super::RewriteOperation::UndoCommit, hash, cx),
            "edit" => self.begin_rewrite(super::RewriteOperation::EditCommitMessage, hash, cx),
            "delete" => self.begin_rewrite(super::RewriteOperation::DeleteCommit, hash, cx),
            "reset" => {
                let short_hash: String = hash.chars().take(8).collect();
                self.commit_action = Some(super::CommitAction::Reset { revision: hash });
                self.notice = Some(SharedString::from(format!(
                    "{}: {}",
                    tr("Reset to Commit"),
                    short_hash
                )));
                cx.notify();
            }
            "cherryPick" => {
                self.commit_action = Some(super::CommitAction::Simple {
                    operation: "cherryPick",
                    revision: hash,
                    title: tr("Cherry-pick Commit"),
                    message: format!("{} \"{}\"?", tr("Cherry-pick Commit"), subject),
                });
                cx.notify();
            }
            "revert" => {
                self.commit_action = Some(super::CommitAction::Simple {
                    operation: "revert",
                    revision: hash,
                    title: tr("Revert Commit"),
                    message: format!("{} \"{}\"?", tr("Revert Commit"), subject),
                });
                cx.notify();
            }
            _ => {}
        }
    }

    /// 当前选中的提交对象。
    pub(crate) fn selected_commit(&self) -> Option<&CoreCommit> {
        let hash = self.selected_commit_hash.as_ref()?;
        self.history.iter().find(|commit| &commit.hash == hash)
    }

    /// 选中某一个提交并异步获取该提交改动的文件列表（`git.commitFiles`）。
    pub(crate) fn select_commit(&mut self, hash: String, cx: &mut Context<Self>) {
        if self.selected_commit_hash.as_ref() == Some(&hash) {
            return;
        }
        self.selected_commit_hash = Some(hash.clone());
        self.commit_files.clear();
        self.loading_commit_files = true;
        let Some(root) = self.root.clone() else {
            return;
        };
        let client = self.client;
        cx.spawn(async move |this, cx| {
            let payload = serde_json::json!({
                "root": root.to_string_lossy(),
                "commit": hash,
            });
            let result = cx
                .background_spawn(async move { execute_git_command(&client, "git.commitFiles", payload) })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.loading_commit_files = false;
                if let Ok(value) = result {
                    if let Some(files) = value.get("files").and_then(serde_json::Value::as_array)
                    {
                        this.commit_files = files
                            .iter()
                            .filter_map(|item| {
                                item.get("path").and_then(serde_json::Value::as_str)
                            })
                            .map(String::from)
                            .collect();
                    }
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }

    /// 选中提交里的一个文件，并请求在**中央编辑区**打开它的差异
    /// （对齐 Tauri `openCommitDiff`：差异是编辑器页，不是 Log 右栏内容）。
    pub(crate) fn select_commit_file(
        &mut self,
        path: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.selected_commit_file = Some(path.clone());
        let Some(hash) = self.selected_commit_hash.clone() else {
            cx.notify();
            return;
        };
        if let Some(handler) = self.on_open_commit_diff.clone() {
            handler(hash, path, window, cx);
        }
        cx.notify();
    }
}

// --- 提交文件树 ------------------------------------------------------------

/// 提交文件树的节点：目录（含子节点）或文件。
///
/// `mod.rs` 重新导出该类型，供后续「提交树与变更树共用」的迭代使用；
/// 当前只在 `log_view.rs` 内部构建与渲染。
pub(crate) struct CommitTreeEntry {
    /// 展示名（目录的一段名或文件名）。
    name: String,
    /// 相对仓库根的完整路径；目录与文件都用它作为折叠/选中 key。
    path: String,
    /// 目录的子节点；文件为空。
    children: Vec<CommitTreeEntry>,
    /// 是否为目录。
    is_dir: bool,
}

/// 把扁平的提交文件列表按 `/` 拆成目录树。
///
/// 目录节点排在文件之前，同类按名字排序，结果稳定可复现。
fn build_commit_file_tree(files: &[String]) -> Vec<CommitTreeEntry> {
    fn insert(nodes: &mut Vec<CommitTreeEntry>, file: &str, segments: &[&str], prefix: &str) {
        let Some((head, rest)) = segments.split_first() else {
            return;
        };
        let path = if prefix.is_empty() {
            (*head).to_string()
        } else {
            format!("{prefix}/{head}")
        };
        if rest.is_empty() {
            nodes.push(CommitTreeEntry {
                name: (*head).to_string(),
                path,
                children: Vec::new(),
                is_dir: false,
            });
            return;
        }
        let index = match nodes
            .iter()
            .position(|node| node.is_dir && node.name == *head)
        {
            Some(index) => index,
            None => {
                nodes.push(CommitTreeEntry {
                    name: (*head).to_string(),
                    path: path.clone(),
                    children: Vec::new(),
                    is_dir: true,
                });
                nodes.len() - 1
            }
        };
        insert(&mut nodes[index].children, file, rest, &path);
    }

    fn sort(nodes: &mut Vec<CommitTreeEntry>) {
        nodes.sort_by(|a, b| {
            b.is_dir
                .cmp(&a.is_dir)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });
        for node in nodes.iter_mut() {
            sort(&mut node.children);
        }
    }

    let mut root = Vec::new();
    for file in files {
        let segments: Vec<&str> = file.split('/').filter(|s| !s.is_empty()).collect();
        insert(&mut root, file, &segments, "");
    }
    sort(&mut root);
    root
}

/// 递归渲染提交文件树节点。`Div` 的构建器是消费式的，因此按值进出。
fn render_commit_tree_nodes(
    nodes: &[CommitTreeEntry],
    depth: usize,
    collapsed: &super::model::ExpandedSet,
    selected_file: Option<&str>,
    tokens: LitheTokens,
    cx: &mut Context<GitPanel>,
    mut out: Stateful<gpui_kit::Div>,
) -> Stateful<gpui_kit::Div> {
    for node in nodes {
        let indent = px(6.0 + depth as f32 * 12.0);
        if node.is_dir {
            let is_collapsed = collapsed.contains(&node.path);
            let path = node.path.clone();
            out = out.child(
                h_flex()
                    .id(SharedString::from(format!("git-log-dir-row:{}", node.path)))
                    .w_full()
                    .h(px(22.0))
                    .pl(indent)
                    .pr(px(6.0))
                    .rounded(px(4.0))
                    .items_center()
                    .gap(px(4.0))
                    .hover(|s| s.bg(tokens.hover))
                    .cursor_pointer()
                    .child(
                        Icon::new(if is_collapsed {
                            gpui_kit::assets::IconName::ChevronRight
                        } else {
                            gpui_kit::assets::IconName::ChevronDown
                        })
                        .with_size(px(10.0))
                        .text_color(tokens.secondary_text),
                    )
                    .child(
                        Icon::new(gpui_kit::assets::IconName::Folder)
                            .with_size(px(13.0))
                            .text_color(tokens.secondary_text),
                    )
                    .child(
                        div()
                            .truncate()
                            .text_size(px(12.0))
                            .text_color(tokens.secondary_text)
                            .child(node.name.clone()),
                    )
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        if !this.collapsed_commit_dirs.remove(&path) {
                            this.collapsed_commit_dirs.insert(path.clone());
                        }
                        cx.notify();
                    })),
            );
            if !is_collapsed {
                out = render_commit_tree_nodes(
                    &node.children,
                    depth + 1,
                    collapsed,
                    selected_file,
                    tokens,
                    cx,
                    out,
                );
            }
        } else {
            let path_str = node.path.clone();
            let path_for_open = node.path.clone();
            let is_selected = selected_file == Some(node.path.as_str());
            let icon_kind = if node.name.ends_with(".java") {
                icon(LitheIcon::Java).with_size(px(13.0))
            } else if node.name.ends_with(".xml") {
                Icon::new(gpui_kit::assets::IconName::Code).with_size(px(13.0))
            } else {
                icon(LitheIcon::File).with_size(px(13.0))
            };
            out = out.child(
                h_flex()
                    .id(SharedString::from(format!(
                        "git-log-file-row:{}",
                        node.path
                    )))
                    .w_full()
                    .h(px(22.0))
                    .pl(indent + px(14.0))
                    .pr(px(6.0))
                    .rounded(px(4.0))
                    .items_center()
                    .gap(px(6.0))
                    // 单击选中加载 diff；双击在编辑器打开工作区文件
                    //（对齐 Tauri onOpen / onDoubleClick 分工）。
                    .when(is_selected, |this| this.bg(tokens.subtle_selection))
                    .when(!is_selected, |this| this.hover(|s| s.bg(tokens.hover)))
                    .cursor_pointer()
                    .child(icon_kind)
                    .child(
                        div()
                            .truncate()
                            .text_size(px(12.0))
                            .text_color(tokens.primary_text)
                            .child(node.name.clone()),
                    )
                    .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                        if event.click_count() >= 2 {
                            // 双击：在编辑器打开工作区的真实文件。
                            this.open_change(&path_for_open.clone(), window, cx);
                        } else {
                            // 单击：在中央编辑区打开该提交的差异。
                            this.select_commit_file(path_str.clone(), window, cx);
                        }
                    })),
            );
        }
    }
    out
}

#[allow(dead_code)]
fn render_log_row(commit: &CoreCommit, tokens: LitheTokens) -> AnyElement {
    let short_hash = if commit.short_hash.is_empty() {
        commit.hash.chars().take(8).collect::<String>()
    } else {
        commit.short_hash.clone()
    };
    let subject = if commit.subject.is_empty() {
        tr("(No subject)").to_string()
    } else {
        commit.subject.clone()
    };
    let meta = if commit.author_name.is_empty() {
        commit.date.clone()
    } else {
        format!("{} · {}", commit.author_name, commit.date)
    };

    v_flex()
        .id(format!("lithe-git:log:{}", commit.hash))
        .w_full()
        .flex_shrink_0()
        .h(px(LOG_ROW_HEIGHT))
        .justify_center()
        .gap(px(2.0))
        .px(px(ACTION_HORIZONTAL_PADDING))
        .hover(|style| style.bg(tokens.hover))
        .child(
            h_flex()
                .w_full()
                .min_w(px(0.0))
                .gap(px(6.0))
                .child(
                    div()
                        .flex_shrink_0()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .font_family(MONO_FONT_FAMILY)
                        .text_color(tokens.link)
                        .child(short_hash),
                )
                .child(
                    div()
                        .min_w(px(0.0))
                        .flex_1()
                        .truncate()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.primary_text)
                        .child(subject),
                ),
        )
        .child(
            div()
                .min_w(px(0.0))
                .truncate()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.tertiary_text)
                .child(meta),
        )
        .into_any_element()
}
