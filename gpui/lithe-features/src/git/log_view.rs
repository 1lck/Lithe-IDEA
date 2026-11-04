//! Git Log 主区：标题栏、过滤工具条、提交表、右侧检查器（文件树 + 说明），
//! 以及提交行的右键动作菜单。
//!
//! 提交记录视图以 macOS `GitLogView` 为对齐目标（标题行、筛选条、三栏布局、
//! 右键菜单、分页与键盘导航）；提交文件树和控制台分别拆到
//! `commit_files_view.rs` 与 `log_console.rs`，保持本文件在 1500 行以内。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    Anchor, AnyElement, AppContext as _, Context, FontWeight, InteractiveElement as _,
    IntoElement, KeyDownEvent, ParentElement as _, SharedString,
    StatefulInteractiveElement as _, Styled as _, Window, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens, MONO_FONT_FAMILY};

use super::graph::{self, COMMIT_ROW_HEIGHT};
use super::model::{ACTION_HORIZONTAL_PADDING, CoreCommit, CoreReference, LOG_ROW_HEIGHT};
use super::{
    CommitFilesView, CommitFilterScope, GitDiffSource, GitLogPanel, GitPanel, execute_git_command,
};

impl GitPanel {
    /// 提交记录模式：对齐 macOS `GitLogView` 的三栏工作台布局。
    pub(crate) fn render_log_view(
        &mut self,
        window: &mut Window,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // 无仓库：macOS 用 `GitRepositoryEmptyView` 给出「初始化仓库 / Git 设置」
        // 两个出口，而不是把三栏空壳和错误行一起显示。等 status 返回后再判断，
        // 避免首帧把「还没加载」误判成「没有仓库」。
        if self.status.is_some() && !self.has_repository() {
            return self.render_log_repository_empty(tokens, cx);
        }
        let header = self.render_log_header(tokens, cx);
        // Log / Console 是真实的两个内容面：Console 不是只改高亮的分段。
        let body = if self.log_panel == GitLogPanel::Console {
            self.render_log_console(tokens)
        } else {
            h_flex()
                .flex_1()
                .min_w_0()
                .min_h_0()
                .child(self.render_log_references_panel(tokens, cx))
                .child(self.render_log_table(window, tokens, cx))
                .when(!self.details_collapsed, |this| {
                    this.child(self.render_log_inspector(tokens, cx))
                })
                .into_any_element()
        };

        // Log 模式同样需要一条可见的状态行：历史 / 引用加载失败、以及
        // 「Go to HEAD」找不到当前分支时的提示都落在这里。
        let status_line = self
            .error
            .clone()
            .map(|error| super::changes_view::status_line(tokens.error, error))
            .or_else(|| {
                self.notice
                    .clone()
                    .map(|notice| super::changes_view::status_line(tokens.success, notice))
            });

        let content = v_flex()
            .id("lithe-git-log-view")
            .size_full()
            .min_w_0()
            .min_h_0()
            .bg(tokens.editor)
            .child(header)
            .children(status_line)
            .child(body);

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

    /// Git 标题栏：单行 41pt，对齐 macOS `GitLogView.toolWindowHeader`
    /// （左侧 `Git` 标题 + Log / Console 分段与引用切换，右侧更多菜单 + 隐藏）。
    ///
    /// 刷新同时存在于提交列表工具条（macOS `GitLogView.swift:1140`），
    /// 这里不再单独放刷新按钮；设置入口收进「更多」菜单，保持标题行紧凑。
    fn render_log_header(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let fetch_owner = cx.weak_entity();
        let refresh_owner = cx.weak_entity();
        let settings_handler = self.on_open_git_settings.clone();

        h_flex()
            .id("lithe-git-log-header")
            .w_full()
            .h(px(41.0))
            .flex_shrink_0()
            .items_center()
            .gap(px(4.0))
            .pl(px(12.0))
            .pr(px(8.0))
            .bg(tokens.tool_header)
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                div()
                    .pr(px(8.0))
                    .text_size(px(13.0))
                    .font_weight(FontWeight::BOLD)
                    .text_color(tokens.primary_text)
                    .child(tr("Git")),
            )
            // macOS 的 Log / Worktrees / Console 三段里，Worktrees 还没有对应
            // 的 GPUI 视图，这里只保留真正有内容的两段（见跨层待办）。
            .child(self.render_log_tab(
                "lithe-git-log:tab-log",
                tr("Log"),
                GitLogPanel::Log,
                tokens,
                cx,
            ))
            .child(self.render_log_tab(
                "lithe-git-log:tab-console",
                tr("Console"),
                GitLogPanel::Console,
                tokens,
                cx,
            ))
            .when(self.log_panel == GitLogPanel::Log, |this| {
                this.child(self.render_reference_switcher(tokens, cx))
            })
            .child(div().flex_1())
            .child(
                Button::new("lithe-git-log:more")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Git tool window actions"))
                    .child(
                        Icon::new(gpui_kit::assets::IconName::EllipsisVertical)
                            .with_size(px(14.0))
                            .text_color(tokens.primary_text),
                    )
                    .dropdown_menu_with_anchor(Anchor::BottomRight, move |menu, _window, _cx| {
                        let fetch_owner = fetch_owner.clone();
                        let menu = menu.item(
                            PopupMenuItem::new(tr("Fetch")).on_click(
                                move |_, _window, cx| {
                                    let _ = fetch_owner.update(cx, |this, cx| {
                                        this.fetch_changes(cx);
                                    });
                                },
                            ),
                        );
                        let refresh_owner = refresh_owner.clone();
                        let menu = menu.item(
                            PopupMenuItem::new(tr("Refresh")).on_click(
                                move |_, window, cx| {
                                    let _ = refresh_owner.update(cx, |this, cx| {
                                        this.refresh(window, cx);
                                    });
                                },
                            ),
                        );
                        let menu = menu.separator();
                        let settings_handler = settings_handler.clone();
                        menu.item(
                            PopupMenuItem::new(tr("Settings")).on_click(
                                move |_, window, cx| {
                                    if let Some(handler) = settings_handler.clone() {
                                        handler(window, cx);
                                    }
                                },
                            ),
                        )
                    }),
            )
            .child(
                // 隐藏 = 收起 Git Log 所在的 dock；回调由工作台注册为
                // `set_dock_visible(GitLog 的 anchor, false)`。
                Button::new("lithe-git-log:hide")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Close"))
                    .child(
                        Icon::new(gpui_kit::assets::IconName::X)
                            .with_size(px(13.0))
                            .text_color(tokens.secondary_text),
                    )
                    .on_click(cx.listener(|this, _, window, cx| {
                        if let Some(handler) = this.on_hide.clone() {
                            handler(window, cx);
                        }
                    })),
            )
            .into_any_element()
    }

    /// 无仓库空状态：对齐 macOS `GitRepositoryEmptyView` 的两个出口
    /// （初始化仓库 / 打开 Git 设置）。
    fn render_log_repository_empty(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let settings_handler = self.on_open_git_settings.clone();
        v_flex()
            .id("lithe-git-log-empty")
            .size_full()
            .min_h_0()
            .bg(tokens.editor)
            .items_center()
            .justify_center()
            .gap(px(10.0))
            .child(
                Icon::new(gpui_kit::assets::IconName::GitBranch)
                    .with_size(px(30.0))
                    .text_color(tokens.tertiary_text),
            )
            .child(
                div()
                    .text_size(px(13.0))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.primary_text)
                    .child(tr("No Git repository")),
            )
            .child(
                div()
                    .max_w(px(360.0))
                    .text_size(px(12.0))
                    .text_color(tokens.secondary_text)
                    .child(tr("Initialize a repository to browse its history.")),
            )
            .child(
                h_flex()
                    .items_center()
                    .gap(px(8.0))
                    .child(
                        Button::new("lithe-git-log:init-repo")
                            .small()
                            .label(tr("Initialize Repository"))
                            .on_click(cx.listener(|this, _, _window, cx| {
                                this.initialize_repository(cx);
                            })),
                    )
                    .child(
                        Button::new("lithe-git-log:empty-settings")
                            .small()
                            .ghost()
                            .label(tr("Settings"))
                            .on_click(cx.listener(move |_this, _, window, cx| {
                                if let Some(handler) = settings_handler.clone() {
                                    handler(window, cx);
                                }
                            })),
                    ),
            )
            .into_any_element()
    }

    /// 顶栏的「Log: All / Log: <branch>」下拉：切换提交历史的引用过滤。
    fn render_reference_switcher(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let owner = cx.weak_entity();
        let references: Vec<CoreReference> = self.references.clone();
        let loading_references = self.loading_references;
        let selected = self.selected_reference.clone();
        let is_all = selected.is_none();
        let label = match selected.as_deref() {
            Some(name) => format!("{}: {name}", tr("Log")),
            None => tr("Log: All").to_string(),
        };

        Button::new("lithe-git-log:reference-filter")
            .ghost()
            .small()
            .rounded(px(3.0))
            .bg(tokens.sidebar)
            .border_1()
            .border_color(tokens.panel_border)
            .tooltip(tr("Branch filter"))
            .child(
                div()
                    .max_w(px(200.0))
                    .truncate()
                    .text_size(px(11.0))
                    .text_color(tokens.primary_text)
                    .child(label),
            )
            .child(
                Icon::new(gpui_kit::assets::IconName::ChevronDown)
                    .with_size(px(10.0))
                    .text_color(tokens.secondary_text),
            )
            .dropdown_menu_with_anchor(Anchor::BottomLeft, move |menu, _window, _cx| {
                let mut menu = menu.min_w(px(240.0));
                let owner_all = owner.clone();
                menu = menu.item(
                    PopupMenuItem::new(tr("All branches"))
                        .checked(is_all)
                        .on_click(move |_, _, cx| {
                            let _ = owner_all.update(cx, |this, cx| {
                                this.select_reference(String::new(), cx);
                            });
                        }),
                );
                // 引用还没返回时给出真实的加载提示，别让菜单看起来只有
                // 「All branches」这一项。
                if loading_references && references.is_empty() {
                    menu = menu.item(
                        PopupMenuItem::new(format!("{} {}", tr("Loading…"), tr("Branches")))
                            .disabled(true),
                    );
                }
                let mut previous_kind: Option<String> = None;
                for reference in references.iter() {
                    // 本地 / 远程 / 标签之间加分割线，菜单与引用树同序。
                    if previous_kind
                        .as_deref()
                        .is_some_and(|kind| kind != reference.kind)
                    {
                        menu = menu.separator();
                    }
                    previous_kind = Some(reference.kind.clone());
                    let owner = owner.clone();
                    let name = reference.short_name.clone();
                    let checked = selected.as_deref() == Some(name.as_str());
                    let name_for_click = name.clone();
                    menu = menu.item(
                        PopupMenuItem::new(name).checked(checked).on_click(
                            move |_, _, cx| {
                                let name = name_for_click.clone();
                                let _ = owner.update(cx, |this, cx| {
                                    this.select_reference(name, cx);
                                });
                            },
                        ),
                    );
                }
                menu
            })
            .into_any_element()
    }

    /// 一个 Log / Console 分段标签（对齐 macOS `LitheToolWindowTabStyle`：
    /// 选中项用浅色底，未选中只在悬停时着色）。
    fn render_log_tab(
        &self,
        id: &'static str,
        label: &'static str,
        panel: GitLogPanel,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let active = self.log_panel == panel;
        div()
            .id(id)
            .h(px(26.0))
            .px(px(8.0))
            .flex()
            .items_center()
            .rounded(px(4.0))
            .when(active, |this| this.bg(tokens.selection))
            .when(!active, |this| this.hover(|style| style.bg(tokens.hover)))
            .text_size(px(12.0))
            .font_weight(if active {
                FontWeight::SEMIBOLD
            } else {
                FontWeight::NORMAL
            })
            .text_color(if active {
                tokens.primary_text
            } else {
                tokens.tertiary_text
            })
            .cursor_pointer()
            .child(tr(label))
            .on_click(cx.listener(move |this, _, _window, cx| {
                if this.log_panel != panel {
                    this.log_panel = panel;
                    cx.notify();
                }
            }))
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

        // 顶部过滤工具条（对齐 Tauri `GitCommitTable` 顶部工具条）：行高 36，
        // 图标按钮 26、文字按钮 24（gpui-kit 的 `small`），避免出现贴着行边、
        // 上下被压扁的小按钮。
        let filter_toolbar = h_flex()
            .w_full()
            .h(px(36.0))
            .items_center()
            .gap(px(6.0))
            .px(px(8.0))
            .bg(tokens.editor)
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                filter_input
                    .clone()
                    .map(|input| {
                        Input::new(&input)
                            .small()
                            .w(px(220.0))
                            .cleanable(true)
                            .prefix(
                                Icon::new(gpui_kit::assets::IconName::Search)
                                    .with_size(px(12.0))
                                    .text_color(tokens.tertiary_text),
                            )
                            .into_any_element()
                    })
                    .unwrap_or_else(|| div().w(px(220.0)).into_any_element()),
            )
            // 过滤作用域选择（Text / Author / Branch，对齐 Tauri 的 scope 下拉）。
            .child(
                Button::new("git-log:filter-scope")
                    .ghost()
                    .small()
                    .rounded(px(4.0))
                    .label(scope.label())
                    .tooltip(tr("Filter scope"))
                    .dropdown_menu_with_anchor(Anchor::BottomLeft, move |menu, _window, _cx| {
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
                    .dropdown_menu_with_anchor(Anchor::BottomLeft, move |menu, _window, _cx| {
                        let mut menu = menu.min_w(px(220.0));
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
            // 刷新入口（macOS 把刷新放在提交列表工具条，`GitLogView.swift:1140`）。
            .child(
                Button::new("git-log:refresh")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Refresh"))
                    .child(
                        Icon::new(gpui_kit::assets::IconName::RotateCw)
                            .with_size(px(14.0))
                            .text_color(tokens.secondary_text),
                    )
                    .on_click(cx.listener(|this, _, window, cx| this.refresh(window, cx))),
            )
            // 详情栏折叠（对齐 macOS `sidebar.right` 按钮）。
            .child(
                Button::new("git-log:toggle-details")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(if self.details_collapsed {
                        tr("Show details")
                    } else {
                        tr("Hide details")
                    })
                    .child(
                        Icon::new(gpui_kit::assets::IconName::PanelRight)
                            .with_size(px(14.0))
                            .text_color(if self.details_collapsed {
                                tokens.tertiary_text
                            } else {
                                tokens.primary_text
                            }),
                    )
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.details_collapsed = !this.details_collapsed;
                        cx.notify();
                    })),
            )
            // 装饰胶囊开关（对齐 Tauri `showDecorations` 的 Eye 切换）。
            .child(
                Button::new("git-log:decorations")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Show decorations"))
                    .child(
                        Icon::new(if self.show_decorations {
                            gpui_kit::assets::IconName::Eye
                        } else {
                            gpui_kit::assets::IconName::EyeOff
                        })
                        .with_size(px(14.0))
                        .text_color(if self.show_decorations {
                            tokens.primary_text
                        } else {
                            tokens.tertiary_text
                        }),
                    )
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.show_decorations = !this.show_decorations;
                        cx.notify();
                    })),
            )
            .child(
                Button::new("git-log:locate-head")
                    .ghost()
                    .with_size(px(26.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Go to HEAD"))
                    .child(
                        Icon::new(gpui_kit::assets::IconName::Crosshair).with_size(px(14.0)),
                    )
                    // 定位 HEAD：与左栏 HEAD 按钮同一条路径（选中分支 + 滚动到 HEAD 行）。
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.goto_reference_head(cx);
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

        // 提交数据表：车道分支图（弯曲连线）+ 提交文本列。
        let mut commit_list = v_flex()
            .id("lithe-git-log-table")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .track_scroll(&self.log_scroll)
            // 键盘导航与 macOS `onMoveCommand` 一致：上下移动选中行，
            // 回车打开该提交的完整差异。
            .track_focus(&self.log_focus)
            .focusable()
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                match event.keystroke.key.as_str() {
                    "up" => this.move_commit_selection(-1, cx),
                    "down" => this.move_commit_selection(1, cx),
                    "enter" => this.open_selected_commit_diff(window, cx),
                    _ => {}
                }
            }))
            // 接近底部自动加载下一页（macOS `loadMoreGitHistory` 的滚动触发）。
            // 底部仍保留失败重试入口，但加载本身不依赖按钮。
            .on_scroll(cx.listener(|this, _event, _window, cx| {
                let offset = this.log_scroll.offset().y;
                let max = this.log_scroll.max_offset().y;
                // offset 是负值，滚到底时 offset + max == 0；距底部 240px 内触发。
                if max > px(0.0) && offset + max <= px(240.0) {
                    this.load_more_history(cx);
                }
            }))
            .bg(tokens.editor);

        // 定位请求（Go to HEAD / 选中的提交）：`scroll_to_item` 在 prepaint 阶段
        // 按直接子元素序号滚动，这里只登记目标行。
        if let Some(index) = self.log_reveal_index.take() {
            self.log_scroll.scroll_to_item(index);
        }

        // 与 macOS 一致：没有显式选中时不把第一行伪装成选中；首次进入
        // 详情栏显示占位，直到用户点击某一行或点「Go to HEAD」。
        let selected_hash = self.selected_commit_hash.clone();

        // 分支图：按父提交关系分配车道并绘制弯曲连线（对齐 macOS
        // `GitGraphGeometry` / `GitGraphColor` 的视觉效果）。
        let graph = graph::layout(
            &visible,
            gpui_kit::component::Theme::global(cx).is_dark(),
            tokens.primary_text,
        );
        let graph_lanes = graph.lane_count;

        if visible.is_empty() {
            commit_list = commit_list.child(
                div()
                    .w_full()
                    .p(px(16.0))
                    .text_size(px(12.0))
                    .text_color(tokens.secondary_text)
                    .child(if self.loading_history {
                        tr("Loading…")
                    } else if self.history.is_empty() {
                        tr("No commits")
                    } else {
                        tr("No results")
                    }),
            );
        }

        for (index, commit) in visible.iter().enumerate() {
            let is_selected = selected_hash.as_deref() == Some(&commit.hash);
            let hash = commit.hash.clone();
            let date_str = commit.date.clone();
            let commit_for_menu = (*commit).clone();
            let row_graph = graph.rows.get(index);
            // 装饰胶囊取该行节点色，保证同一分支的图线和胶囊同色。
            let accent = row_graph
                .map(|row| row.node_color())
                .unwrap_or(tokens.secondary_text);
            let graph_cell = match row_graph {
                Some(row) => row.render(COMMIT_ROW_HEIGHT, graph_lanes, tokens.editor),
                None => div().w(px(16.0)).into_any_element(),
            };

            commit_list = commit_list.child(
                h_flex()
                    .id(SharedString::from(format!(
                        "git-commit-row:{}",
                        commit.hash
                    )))
                    .w_full()
                    .h(px(COMMIT_ROW_HEIGHT))
                    .pl(px(4.0))
                    .pr(px(6.0))
                    .items_center()
                    .gap(px(4.0))
                    .when(is_selected, |this| this.bg(tokens.subtle_selection))
                    .when(!is_selected, |this| this.hover(|s| s.bg(tokens.hover)))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, window, cx| {
                        // 点击行同时把键盘焦点交给列表，上下键随后可用。
                        window.focus(&this.log_focus, cx);
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
                    // 分支图单元格：多条车道、弯曲分叉 / 合并线。
                    .child(graph_cell)
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
                                    .border_color(accent)
                                    .bg(accent.alpha(0.18))
                                    .text_size(px(10.5))
                                    .text_color(accent)
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
                            .w(px(130.0))
                            .truncate()
                            .text_size(px(11.5))
                            .text_color(tokens.tertiary_text)
                            .child(date_str),
                    ),
            );
        }

        // 分页状态行：加载中 / 失败重试 / 「继续滚动加载」提示三者互斥。
        // 它不是加载入口（加载由上面的滚动监听触发），只是状态反馈。
        let footer = if self.loading_more_history {
            Some(
                h_flex()
                    .w_full()
                    .h(px(28.0))
                    .flex_shrink_0()
                    .items_center()
                    .justify_center()
                    .gap(px(6.0))
                    .text_size(px(11.5))
                    .text_color(tokens.secondary_text)
                    .child(tr("Loading…"))
                    .into_any_element(),
            )
        } else if self.history_page_failed {
            Some(
                h_flex()
                    .w_full()
                    .h(px(28.0))
                    .flex_shrink_0()
                    .items_center()
                    .justify_center()
                    .gap(px(6.0))
                    .child(
                        Button::new("git-log:retry-page")
                            .ghost()
                            .small()
                            .label(tr("Retry"))
                            .on_click(cx.listener(|this, _, _window, cx| {
                                this.history_page_failed = false;
                                this.load_more_history(cx);
                            })),
                    )
                    .into_any_element(),
            )
        } else if self.history_has_more && self.history_cursor.is_some() {
            Some(
                h_flex()
                    .w_full()
                    .h(px(24.0))
                    .flex_shrink_0()
                    .items_center()
                    .justify_center()
                    .text_size(px(11.0))
                    .text_color(tokens.tertiary_text)
                    .child(tr("Scroll to load more commits"))
                    .into_any_element(),
            )
        } else {
            None
        };

        v_flex()
            .flex_1()
            .h_full()
            .min_w_0()
            .child(filter_toolbar)
            .child(commit_list)
            .children(footer)
            .into_any_element()
    }

    /// Git Log 右栏：改动文件树（上半部分） + 提交详细说明（下半部分）。
    fn render_log_inspector(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        // 与 macOS 一致：没有选中提交时显示占位，而不是默认把第一行当成选中。
        let selected_commit = self
            .selected_commit_hash
            .as_ref()
            .and_then(|hash| self.history.iter().find(|c| &c.hash == hash));

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
        } else if self.commit_files_view == CommitFilesView::Tree {
            // 目录树：按 `/` 拆段建树，逐层缩进渲染文件夹与文件；
            // 折叠状态存于 `collapsed_commit_dirs`（对齐 Tauri 文件树的目录折叠）。
            let tree_root = super::commit_files_view::build_commit_file_tree(&self.commit_files);
            file_tree = super::commit_files_view::render_commit_tree_nodes(
                &tree_root,
                0,
                &self.collapsed_commit_dirs,
                self.selected_commit_file.as_deref(),
                tokens,
                cx,
                file_tree,
            );
        } else {
            // 平铺列表：按路径排序，每行显示完整相对路径（对齐 macOS
            // 文件列表呈现）；单击打开该提交的差异，双击打开工作区文件。
            let mut files: Vec<&String> = self.commit_files.iter().collect();
            files.sort_by(|left, right| left.to_lowercase().cmp(&right.to_lowercase()));
            for path in files {
                file_tree = file_tree.child(self.render_commit_file_list_row(
                    path,
                    tokens,
                    cx,
                ));
            }
        }

        // 文件面板工具条（对齐 macOS `commitFilesPane`：左侧 Compare changes
        // 图标按钮，右侧保留 GPUI 的树/列表切换与文件计数）。
        let compare_enabled = self.selected_commit_file.is_some();
        let files_header = h_flex()
            .w_full()
            .h(px(32.0))
            .items_center()
            .gap(px(4.0))
            .px(px(8.0))
            .bg(tokens.tool_header)
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                Button::new("git-log:compare-file")
                    .ghost()
                    .with_size(px(24.0))
                    .rounded(px(4.0))
                    .tooltip(tr("Compare changes"))
                    .disabled(!compare_enabled)
                    .child(
                        Icon::new(gpui_kit::assets::IconName::GitCompare)
                            .with_size(px(13.0))
                            .text_color(if compare_enabled {
                                tokens.secondary_text
                            } else {
                                tokens.tertiary_text
                            }),
                    )
                    .on_click(cx.listener(|this, _, window, cx| {
                        if let Some(path) = this.selected_commit_file.clone() {
                            this.select_commit_file(path, window, cx);
                        }
                    })),
            )
            .child(div().flex_1())
            .child(
                div()
                    .text_size(px(11.0))
                    .text_color(tokens.secondary_text)
                    .child(format!("{} {}", file_count, tr("files"))),
            )
            // 树状 / 列表切换（GPUI 额外能力，macOS 只有树）。
            .child(self.render_commit_files_view_toggle(tokens, cx));

        let files_half = v_flex()
            .flex_1()
            .min_h_0()
            .border_b_1()
            .border_color(tokens.divider)
            .child(files_header)
            .child(file_tree);

        // 下半部分：提交正文与元数据。差异本身在**中央编辑区**打开
        //（`CommitDiffView`），右栏只保留文件树与说明，避免把 diff 挤在窄栏里。
        // 元数据行对齐 macOS `commitDetail`：`<shortHash> <author> <<email>> on <date>`
        // 加一行引用标签。
        let message_half = v_flex()
            .id("lithe-git-log-message-half")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .p(px(12.0))
            .gap(px(6.0))
            .when_some(selected_commit, |this, commit| {
                let short_hash = if commit.short_hash.is_empty() {
                    commit.hash.chars().take(8).collect::<String>()
                } else {
                    commit.short_hash.clone()
                };
                let author = if commit.author_email.is_empty() {
                    commit.author_name.clone()
                } else {
                    format!("{} <{}>", commit.author_name, commit.author_email)
                };
                let labels: Vec<String> = commit
                    .decorations
                    .split(',')
                    .map(str::trim)
                    .filter(|label| !label.is_empty())
                    .map(String::from)
                    .collect();
                this.child(
                    div()
                        .text_size(px(13.0))
                        .font_weight(FontWeight::BOLD)
                        .text_color(tokens.primary_text)
                        .child(commit.subject.clone()),
                )
                .child(
                    div()
                        .text_size(px(11.5))
                        .text_color(tokens.secondary_text)
                        .child(format!("{short_hash} {author} on {}", commit.date)),
                )
                .when(!labels.is_empty(), |this| {
                    this.child(
                        h_flex()
                            .flex_wrap()
                            .gap(px(4.0))
                            .pt(px(2.0))
                            .children(labels.into_iter().map(|label| {
                                div()
                                    .px(px(4.0))
                                    .py(px(1.0))
                                    .rounded(px(3.0))
                                    .bg(tokens.selection)
                                    .text_size(px(10.5))
                                    .text_color(tokens.secondary_text)
                                    .child(label)
                            })),
                    )
                })
            })
            .when(selected_commit.is_none(), |this| {
                this.child(
                    div()
                        .text_size(px(12.0))
                        .text_color(tokens.secondary_text)
                        .child(tr("Commit details")),
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

                let item = |menu: gpui_kit::component::menu::PopupMenu,
                            owner: &gpui_kit::WeakEntity<GitPanel>,
                            action: &'static str,
                            label: &'static str,
                            disabled: bool|
                 -> gpui_kit::component::menu::PopupMenu {
                    let owner = owner.clone();
                    menu.item(PopupMenuItem::new(label).disabled(disabled).on_click(
                        move |_, window, cx| {
                            let _ = owner.update(cx, |this, cx| {
                                this.run_commit_action(action, window, cx);
                            });
                        },
                    ))
                };

                // macOS 的提交菜单以「复制 hash」开头（GitGraphView.swift:57-77）。
                let copy = |menu: gpui_kit::component::menu::PopupMenu,
                            owner: &gpui_kit::WeakEntity<GitPanel>,
                            label: &'static str,
                            text: String|
                 -> gpui_kit::component::menu::PopupMenu {
                    let owner = owner.clone();
                    menu.item(PopupMenuItem::new(label).on_click(move |_, window, cx| {
                        let _ = owner.update(cx, |this, cx| {
                            this.copy_text(&text.clone(), window, cx);
                        });
                    }))
                };
                let menu = copy(menu, &owner, tr("Copy Commit Hash"), commit.hash.clone());
                let menu = copy(menu, &owner, tr("Copy Short Hash"), short_hash);

                let menu = menu.separator();
                // GPUI 额外入口：完整差异 / 与 HEAD 比较（macOS 由双击与详情区承担）。
                let menu = item(menu, &owner, "openDiff", tr("Open Commit Diff"), false);
                let menu = item(
                    menu,
                    &owner,
                    "compareWithHead",
                    tr("Compare with HEAD"),
                    false,
                );

                let menu = menu.separator();
                let menu = item(
                    menu,
                    &owner,
                    "cherryPick",
                    tr("Cherry-pick Commit"),
                    busy || is_head,
                );
                let menu = item(menu, &owner, "revert", tr("Revert Commit"), busy);
                let menu = item(
                    menu,
                    &owner,
                    "reset",
                    tr("Reset to Commit"),
                    busy,
                );

                // 历史改写（undo / edit / delete）需要预览确认；undo 仅限 HEAD。
                let menu = menu.separator();
                let menu = item(menu, &owner, "undo", tr("Undo Commit"), busy || !is_head);
                let menu = item(menu, &owner, "edit", tr("Edit Commit Message"), busy);
                item(menu, &owner, "delete", tr("Delete Commit"), busy)
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
    pub(crate) fn run_commit_action(
        &mut self,
        action: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(commit) = self.selected_commit() else {
            return;
        };
        let hash = commit.hash.clone();
        let subject = commit.subject.clone();
        match action {
            // 打开该提交相对父提交的完整差异（Tauri `openCommitDiff`，path 为空
            // = 全部文件）。差异页在中央编辑区，不在 Log 右栏。
            "openDiff" => {
                if let Some(handler) = self.on_open_commit_diff.clone() {
                    handler(hash, String::new(), window, cx);
                } else {
                    self.notice = Some(SharedString::from(tr("Commit diff is not available")));
                    cx.notify();
                }
            }
            // 与 HEAD 比较：对齐 Tauri `viewBranchDiff(commit)`，区间为
            // `<commit>..HEAD`（左侧是提交，右侧是当前分支）。
            "compareWithHead" => {
                if let Some(handler) = self.on_open_diff_source.clone() {
                    handler(
                        GitDiffSource::Comparison {
                            base: hash,
                            target: "HEAD".to_string(),
                        },
                        String::new(),
                        window,
                        cx,
                    );
                } else {
                    self.notice = Some(SharedString::from(tr("Commit diff is not available")));
                    cx.notify();
                }
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

    /// 当前过滤条件下的可见提交，供键盘导航复用。
    ///
    /// 过滤规则与 `commit_filter_scope` 的匹配一致；这里不参与渲染，避免与
    /// 渲染期的可变状态（过滤输入框惰性创建）产生借用冲突。
    pub(crate) fn filtered_history(&self) -> Vec<&CoreCommit> {
        let filter = self.commit_filter.trim().to_lowercase();
        let scope = self.commit_filter_scope;
        self.history
            .iter()
            .filter(|commit| scope.matches(commit, &filter))
            .collect()
    }

    /// 键盘上下移动提交选中（对齐 macOS `moveGitLogCommitSelection`）。
    ///
    /// 选中后把目标行登记到 `log_reveal_index`，下一次 prepaint 会滚动到它。
    pub(crate) fn move_commit_selection(&mut self, delta: i32, cx: &mut Context<Self>) {
        let target = {
            let visible = self.filtered_history();
            if visible.is_empty() {
                None
            } else {
                let current = self.selected_commit_hash.as_deref();
                let position = visible
                    .iter()
                    .position(|commit| Some(commit.hash.as_str()) == current)
                    .unwrap_or(0);
                let next = (position as i32 + delta).clamp(0, visible.len() as i32 - 1) as usize;
                Some((visible[next].hash.clone(), next))
            }
        };
        let Some((hash, index)) = target else {
            return;
        };
        self.log_reveal_index = Some(index);
        self.select_commit(hash, cx);
        cx.notify();
    }

    /// 回车打开选中提交的完整差异（无选中时取列表第一行，与详情栏一致）。
    pub(crate) fn open_selected_commit_diff(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let hash = self
            .selected_commit_hash
            .clone()
            .or_else(|| self.history.first().map(|commit| commit.hash.clone()));
        let Some(hash) = hash else {
            return;
        };
        let Some(handler) = self.on_open_commit_diff.clone() else {
            self.notice = Some(SharedString::from(tr("Commit diff is not available")));
            cx.notify();
            return;
        };
        handler(hash, String::new(), window, cx);
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

// 提交文件树的构建与渲染见 `commit_files_view.rs`。

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
