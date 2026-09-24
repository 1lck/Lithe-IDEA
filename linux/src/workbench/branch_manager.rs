//! 分支管理器弹窗：对齐 Tauri `GitBranchManager`（`GitCommandSurface` 弹窗）。
//!
//! - 顶部三个 tab（仓库 / 分支 / 工作树），按 tab 切换搜索框占位与计数。
//! - 分支行点击经 core 直连 `git.write` 检出，当前分支打勾；
//!   搜索串无精确匹配时首行可建分支（`createBranch` 后再 `checkout` 切过去）。
//! - 工作树行点击把路径交给父级（`OpenWorktree`），由父级打开对应项目。
//! - 成功统一发射 [`BranchManagerEvent::CheckoutDone`]（父级刷新+关弹窗）；
//!   失败只在弹窗内显示错误行，不发射。
//! - 遮罩 + 卡片布局与键盘输入仿 `quick_open.rs`；core 调用模式照抄
//!   `sidebar.rs`（`CoreClient` + `cx.spawn`）与 `view.rs` 的分支解析。

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon, Selectable as _, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, rgba, Context, EventEmitter, FocusHandle, FontWeight, InteractiveElement as _,
    IntoElement, KeyDownEvent, ParentElement as _, Render, StatefulInteractiveElement as _,
    Styled as _, Window,
};

use crate::core::CoreClient;
use crate::theme::ThemeColors;

/// 管理器顶部的三个分区（对齐 Tauri `CommandTabs`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BranchTab {
    Repositories,
    Branches,
    Worktrees,
}

impl BranchTab {
    /// 分区标题文案键（与 Tauri `git.repositories/branches/worktrees` 对齐）。
    fn title_key(self) -> &'static str {
        match self {
            BranchTab::Repositories => "git.repositories",
            BranchTab::Branches => "git.branches",
            BranchTab::Worktrees => "git.worktrees",
        }
    }

    /// 搜索框占位文案键（按 tab 切换）。
    fn placeholder_key(self) -> &'static str {
        match self {
            BranchTab::Repositories => "git.filterRepositories",
            BranchTab::Branches => "git.searchBranches",
            BranchTab::Worktrees => "git.searchWorktrees",
        }
    }
}

/// 分支管理器对外事件。
#[derive(Debug, Clone)]
pub enum BranchManagerEvent {
    /// 检出或建分支成功：父级负责刷新 git 状态并关闭弹窗。
    CheckoutDone,
    /// 请求打开指定工作树路径的项目（父级关弹窗后打开）。
    OpenWorktree(String),
    /// 请求关闭弹窗（遮罩点击 / Esc）。
    Close,
}

/// 工作树列表项（字段形状对齐 core `GitWorktreeResponse` 的 camelCase 返回）。
#[derive(Debug, Clone)]
pub struct WorktreeInfo {
    pub path: String,
    pub branch: Option<String>,
    pub is_current: bool,
}

/// 居中的分支管理器弹窗（宽 560、高 420，仿 `project_dialog` 卡片）。
pub struct BranchManagerView {
    repo_path: String,
    current_branch: Option<String>,
    active_tab: BranchTab,
    query: String,
    branches: Vec<String>,
    worktrees: Vec<WorktreeInfo>,
    error: Option<String>,
    busy: bool,
    focus_handle: FocusHandle,
    client: CoreClient,
}

impl EventEmitter<BranchManagerEvent> for BranchManagerView {}

impl BranchManagerView {
    pub fn new(repo_path: String, cx: &mut Context<Self>) -> Self {
        let mut view = Self {
            repo_path,
            current_branch: None,
            active_tab: BranchTab::Branches,
            query: String::new(),
            branches: Vec::new(),
            worktrees: Vec::new(),
            error: None,
            busy: false,
            focus_handle: cx.focus_handle(),
            client: CoreClient::new(),
        };
        view.reload(cx);
        view
    }

    /// 更新仓库并重载分支与工作树（打开弹窗时由父级调用）。
    pub fn set_repo(&mut self, path: String, current: Option<String>, cx: &mut Context<Self>) {
        self.repo_path = path;
        self.current_branch = current;
        self.query.clear();
        self.error = None;
        self.busy = false;
        self.reload(cx);
    }

    /// 并发拉取 `git.references` 与 `worktrees`，分支排序去重。
    pub fn reload(&mut self, cx: &mut Context<Self>) {
        let client = self.client.clone();
        let root = self.repo_path.clone();
        let root_wt = self.repo_path.clone();
        cx.spawn(async move |this, cx| {
            let refs_task = client.execute::<serde_json::Value, serde_json::Value>(
                &cx,
                "git.references",
                serde_json::json!({ "root": root }),
            );
            let wt_task = client.execute::<serde_json::Value, serde_json::Value>(
                &cx,
                "worktrees",
                serde_json::json!({ "root": root_wt }),
            );
            let refs_val = refs_task.await.unwrap_or(serde_json::Value::Null);
            let wt_val = wt_task.await.unwrap_or(serde_json::Value::Null);
            // 分支解析照抄 view.rs observer：kind == local 的 shortName。
            let mut branches: Vec<String> = refs_val
                .get("references")
                .and_then(|r| r.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter(|item| item.get("kind").and_then(|k| k.as_str()) == Some("local"))
                        .filter_map(|item| {
                            item.get("shortName")
                                .and_then(|n| n.as_str())
                                .map(|s| s.to_string())
                        })
                        .collect()
                })
                .unwrap_or_default();
            branches.sort();
            branches.dedup();
            let worktrees: Vec<WorktreeInfo> = wt_val
                .get("worktrees")
                .and_then(|w| w.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|item| {
                            let path = item
                                .get("path")
                                .and_then(|p| p.as_str())
                                .unwrap_or("")
                                .to_string();
                            if path.is_empty() {
                                return None;
                            }
                            Some(WorktreeInfo {
                                path,
                                branch: item
                                    .get("branch")
                                    .and_then(|b| b.as_str())
                                    .map(|s| s.to_string()),
                                is_current: item
                                    .get("isCurrent")
                                    .and_then(|b| b.as_bool())
                                    .unwrap_or(false),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            let _ = this.update(cx, |view, cx| {
                view.branches = branches;
                view.worktrees = worktrees;
                view.error = None;
                cx.notify();
            });
        })
        .detach();
    }

    /// 检出指定本地分支：`git.write` 成功即 `CheckoutDone`，失败只显示错误行。
    fn checkout(&mut self, branch: String, cx: &mut Context<Self>) {
        if self.busy || Some(branch.as_str()) == self.current_branch.as_deref() {
            return;
        }
        self.busy = true;
        self.error = None;
        cx.notify();
        let client = self.client.clone();
        let payload = git_write_payload(
            &self.repo_path,
            "checkout",
            serde_json::json!({
                "reference": format!("refs/heads/{branch}"),
                "referenceKind": "local",
            }),
        );
        cx.spawn(async move |this, cx| {
            let task =
                client.execute::<serde_json::Value, serde_json::Value>(&cx, "git.write", payload);
            match task.await {
                Ok(_) => {
                    let _ = this.update(cx, |view, cx| {
                        view.busy = false;
                        cx.emit(BranchManagerEvent::CheckoutDone);
                    });
                }
                Err(err) => {
                    let _ = this.update(cx, |view, cx| {
                        view.busy = false;
                        view.error = Some(err);
                        cx.notify();
                    });
                }
            }
        })
        .detach();
    }

    /// 建分支后切过去：`createBranch`（`reference: "HEAD"`）成功再调一次 checkout。
    fn create_and_checkout(&mut self, name: String, cx: &mut Context<Self>) {
        let name = name.trim().to_string();
        if self.busy || name.is_empty() {
            return;
        }
        self.busy = true;
        self.error = None;
        cx.notify();
        let client = self.client.clone();
        let root = self.repo_path.clone();
        let checkout_ref = format!("refs/heads/{name}");
        let create_payload = git_write_payload(
            &root,
            "createBranch",
            serde_json::json!({ "name": name, "reference": "HEAD" }),
        );
        let checkout_payload = git_write_payload(
            &root,
            "checkout",
            serde_json::json!({ "reference": checkout_ref, "referenceKind": "local" }),
        );
        cx.spawn(async move |this, cx| {
            let create_task = client.execute::<serde_json::Value, serde_json::Value>(
                &cx,
                "git.write",
                create_payload,
            );
            let create_result = create_task.await;
            let final_result = match create_result {
                Ok(_) => {
                    let checkout_task = client.execute::<serde_json::Value, serde_json::Value>(
                        &cx,
                        "git.write",
                        checkout_payload,
                    );
                    checkout_task.await.map(|_| ())
                }
                Err(err) => Err(err),
            };
            match final_result {
                Ok(()) => {
                    let _ = this.update(cx, |view, cx| {
                        view.busy = false;
                        cx.emit(BranchManagerEvent::CheckoutDone);
                    });
                }
                Err(err) => {
                    let _ = this.update(cx, |view, cx| {
                        view.busy = false;
                        view.error = Some(err);
                        cx.notify();
                    });
                }
            }
        })
        .detach();
    }

    /// 当前 tab 下按 query 过滤后的分支（大小写不敏感包含）。
    fn filtered_branches(&self) -> Vec<String> {
        let q = self.query.trim().to_lowercase();
        self.branches
            .iter()
            .filter(|b| q.is_empty() || b.to_lowercase().contains(&q))
            .cloned()
            .collect()
    }

    /// 当前 tab 下按 query 过滤后的工作树（按分支名或路径匹配）。
    fn filtered_worktrees(&self) -> Vec<WorktreeInfo> {
        let q = self.query.trim().to_lowercase();
        self.worktrees
            .iter()
            .filter(|w| {
                q.is_empty()
                    || w.path.to_lowercase().contains(&q)
                    || w.branch
                        .as_deref()
                        .unwrap_or("")
                        .to_lowercase()
                        .contains(&q)
            })
            .cloned()
            .collect()
    }

    /// 当前仓库在 repositories tab 下是否匹配 query。
    fn repo_matches(&self) -> bool {
        let q = self.query.trim().to_lowercase();
        q.is_empty()
            || self.repo_path.to_lowercase().contains(&q)
            || repo_name(&self.repo_path).to_lowercase().contains(&q)
    }

    /// 计数行文案（`{count}` 占位在渲染时替换，单复数按英文区分键）。
    fn count_text(&self, cx: &gpui_kit::App) -> String {
        let (key, count) = match self.active_tab {
            BranchTab::Repositories => {
                let n = usize::from(self.repo_matches());
                (
                    if n == 1 {
                        "git.repositoryCount"
                    } else {
                        "git.repositoriesCount"
                    },
                    n,
                )
            }
            BranchTab::Branches => {
                let n = self.filtered_branches().len();
                (
                    if n == 1 {
                        "git.branchCount"
                    } else {
                        "git.branchesCount"
                    },
                    n,
                )
            }
            BranchTab::Worktrees => {
                let n = self.filtered_worktrees().len();
                (
                    if n == 1 {
                        "git.worktreeCount"
                    } else {
                        "git.worktreesCount"
                    },
                    n,
                )
            }
        };
        crate::i18n::menu_text(cx, key).replace("{count}", &count.to_string())
    }
}

/// 构造 `git.write` 全字段 camelCase payload（String 无值传 null，bool 传 false）。
fn git_write_payload(root: &str, operation: &str, extra: serde_json::Value) -> serde_json::Value {
    let mut payload = serde_json::json!({
        "root": root,
        "operation": operation,
        "paths": [],
        "reference": null,
        "gitReference": null,
        "referenceKind": null,
        "revision": null,
        "name": null,
        "message": null,
        "remote": null,
        "destination": null,
        "mode": null,
        "includeUntracked": false,
        "checkout": false,
        "amend": false,
        "force": false,
        "autoStash": false,
    });
    if let (Some(obj), Some(patch)) = (payload.as_object_mut(), extra.as_object()) {
        for (key, value) in patch {
            obj.insert(key.clone(), value.clone());
        }
    }
    payload
}

/// 仓库显示名：路径最后一段。
fn repo_name(path: &str) -> String {
    path.rsplit('/').next().unwrap_or(path).to_string()
}

impl Render for BranchManagerView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        window.focus(&self.focus_handle, cx);

        let active_tab = self.active_tab;
        let placeholder: String =
            crate::i18n::menu_text(cx, active_tab.placeholder_key()).to_string();
        let count_text = self.count_text(cx);
        let busy = self.busy;

        // 分支 tab：精确匹配存在时不展示建分支行。
        let trimmed_query = self.query.trim().to_string();
        let has_exact_match =
            !trimmed_query.is_empty() && self.branches.iter().any(|b| *b == trimmed_query);
        let show_create_row =
            active_tab == BranchTab::Branches && !trimmed_query.is_empty() && !has_exact_match;
        let create_label = if show_create_row {
            crate::i18n::menu_text(cx, "git.createNewBranch").replace("{name}", &trimmed_query)
        } else {
            String::new()
        };

        div()
            .id("branch-manager-backdrop")
            .track_focus(&self.focus_handle)
            .absolute()
            .inset_0()
            .bg(rgba(0x00000088))
            .flex()
            .items_center()
            .justify_center()
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                let key = event.keystroke.key.as_str();
                match key {
                    "escape" => {
                        cx.emit(BranchManagerEvent::Close);
                    }
                    "backspace" => {
                        this.query.pop();
                        this.error = None;
                        cx.notify();
                    }
                    "space" => {
                        this.query.push(' ');
                        this.error = None;
                        cx.notify();
                    }
                    _ => {
                        if !event.keystroke.modifiers.control
                            && !event.keystroke.modifiers.alt
                            && !event.keystroke.modifiers.platform
                        {
                            let mut changed = false;
                            if let Some(ch) = &event.keystroke.key_char {
                                this.query.push_str(ch);
                                changed = true;
                            } else if key.chars().count() == 1 {
                                this.query.push_str(key);
                                changed = true;
                            }
                            if changed {
                                this.error = None;
                                cx.notify();
                            }
                        }
                    }
                }
            }))
            .on_mouse_down(
                gpui_kit::MouseButton::Left,
                cx.listener(|_this, _event, _window, cx| {
                    cx.emit(BranchManagerEvent::Close);
                }),
            )
            .child(
                v_flex()
                    .id("branch-manager-card")
                    .w(px(560.0))
                    .h(px(420.0))
                    .bg(ThemeColors::surface())
                    .border_1()
                    .border_color(ThemeColors::border())
                    .rounded_lg()
                    .shadow_lg()
                    .overflow_hidden()
                    .on_mouse_down(
                        gpui_kit::MouseButton::Left,
                        cx.listener(|_this, _event, _window, cx| {
                            cx.stop_propagation();
                        }),
                    )
                    .child(self.render_tabs(cx))
                    .child(self.render_search_row(placeholder))
                    .child(
                        div()
                            .w_full()
                            .px_4()
                            .py_1()
                            .text_xs()
                            .text_color(ThemeColors::subtle_foreground())
                            .child(count_text),
                    )
                    .child(self.render_list(show_create_row, create_label, busy, cx))
                    .when(self.error.is_some(), |card| {
                        card.child(
                            div()
                                .w_full()
                                .px_4()
                                .py_2()
                                .border_t_1()
                                .border_color(ThemeColors::border())
                                .text_xs()
                                .text_color(ThemeColors::destructive())
                                .child(self.error.clone().unwrap_or_default()),
                        )
                    }),
            )
    }
}

impl BranchManagerView {
    /// 顶部三 tab 行（当前高亮）。
    fn render_tabs(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let tabs = [
            BranchTab::Repositories,
            BranchTab::Branches,
            BranchTab::Worktrees,
        ];
        h_flex()
            .w_full()
            .items_center()
            .gap_1()
            .px_3()
            .py_2()
            .border_b_1()
            .border_color(ThemeColors::border())
            .children(tabs.into_iter().enumerate().map(|(ix, tab)| {
                let label: String = crate::i18n::menu_text(cx, tab.title_key()).to_string();
                let selected = tab == self.active_tab;
                Button::new(format!("branch-manager-tab-{ix}"))
                    .small()
                    .ghost()
                    .label(label)
                    .selected(selected)
                    .on_click(cx.listener(move |this, _event, _window, cx| {
                        this.active_tab = tab;
                        cx.notify();
                    }))
            }))
    }

    /// 搜索行：图标 + 查询串/占位 + 静态光标（仿 quick_open 输入行）。
    fn render_search_row(&self, placeholder: String) -> impl IntoElement {
        h_flex()
            .h(px(48.0))
            .w_full()
            .items_center()
            .gap_2p5()
            .px_4()
            .border_b_1()
            .border_color(ThemeColors::border())
            .child(
                Icon::new(IconName::Search)
                    .size(px(16.0))
                    .text_color(ThemeColors::primary()),
            )
            .child(
                h_flex()
                    .flex_1()
                    .items_center()
                    .gap_1()
                    .child(
                        div()
                            .text_sm()
                            .text_color(if self.query.is_empty() {
                                ThemeColors::subtle_foreground()
                            } else {
                                ThemeColors::foreground()
                            })
                            .child(if self.query.is_empty() {
                                placeholder
                            } else {
                                self.query.clone()
                            }),
                    )
                    .child(div().w(px(2.0)).h(px(16.0)).bg(ThemeColors::primary())),
            )
    }

    /// 按当前 tab 渲染滚动列表。
    fn render_list(
        &self,
        show_create_row: bool,
        create_label: String,
        busy: bool,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let tab = self.active_tab;
        let query_empty = self.query.trim().is_empty();
        div()
            .flex_1()
            .w_full()
            .overflow_y_scrollbar()
            .py_1()
            .when(tab == BranchTab::Branches, |list| {
                let filtered = self.filtered_branches();
                let empty_key = if query_empty {
                    "git.noBranchesFound"
                } else {
                    "git.noMatchingBranches"
                };
                let empty_text: String = crate::i18n::menu_text(cx, empty_key).to_string();
                let current = self.current_branch.clone();
                list.when(show_create_row, |list| {
                    list.child(create_branch_row(create_label, busy, cx))
                })
                .when(filtered.is_empty(), |list| {
                    list.child(empty_row(empty_text))
                })
                .children(
                    filtered
                        .into_iter()
                        .enumerate()
                        .map(|(ix, name)| branch_row(ix, name, current.clone(), busy, cx)),
                )
            })
            .when(tab == BranchTab::Worktrees, |list| {
                let filtered = self.filtered_worktrees();
                let empty_text: String =
                    crate::i18n::menu_text(cx, "git.noMatchingBranches").to_string();
                list.when(filtered.is_empty(), |list| {
                    list.child(empty_row(empty_text))
                })
                .children(
                    filtered
                        .into_iter()
                        .enumerate()
                        .map(|(ix, info)| worktree_row(ix, info, busy, cx)),
                )
            })
            .when(tab == BranchTab::Repositories, |list| {
                if self.repo_matches() {
                    list.child(repository_row(
                        repo_name(&self.repo_path),
                        self.repo_path.clone(),
                    ))
                } else {
                    let empty_text: String =
                        crate::i18n::menu_text(cx, "git.noMatchingBranches").to_string();
                    list.child(empty_row(empty_text))
                }
            })
    }
}

/// 建分支首行（点击从搜索串建分支并切过去）。
fn create_branch_row(
    label: String,
    busy: bool,
    cx: &mut Context<BranchManagerView>,
) -> impl IntoElement {
    h_flex()
        .id("branch-manager-create")
        .h(px(32.0))
        .w_full()
        .mx_2()
        .px_2p5()
        .items_center()
        .gap_2()
        .rounded_md()
        .cursor_pointer()
        .hover(|h| h.bg(ThemeColors::accent()))
        .child(
            Icon::new(IconName::Plus)
                .size(px(14.0))
                .text_color(if busy {
                    ThemeColors::muted_foreground()
                } else {
                    ThemeColors::primary()
                }),
        )
        .child(
            div()
                .flex_1()
                .text_sm()
                .font_weight(FontWeight::MEDIUM)
                .text_color(ThemeColors::foreground())
                .child(label),
        )
        .on_click(cx.listener(|this, _event, _window, cx| {
            if this.busy {
                return;
            }
            let name = this.query.trim().to_string();
            this.create_and_checkout(name, cx);
        }))
        .into_any_element()
}

/// 分支行：名 + 当前分支打勾，点击检出。
fn branch_row(
    ix: usize,
    name: String,
    current: Option<String>,
    busy: bool,
    cx: &mut Context<BranchManagerView>,
) -> gpui_kit::AnyElement {
    let is_current = Some(name.as_str()) == current.as_deref();
    let target = name.clone();
    h_flex()
        .id(("branch-manager-branch", ix))
        .h(px(32.0))
        .w_full()
        .mx_2()
        .px_2p5()
        .items_center()
        .gap_2()
        .rounded_md()
        .cursor_pointer()
        .hover(|h| h.bg(ThemeColors::accent()))
        .child(
            Icon::new(IconName::GitBranch)
                .size(px(14.0))
                .text_color(if is_current {
                    ThemeColors::primary()
                } else {
                    ThemeColors::muted_foreground()
                }),
        )
        .child(
            div()
                .flex_1()
                .truncate()
                .text_sm()
                .font_weight(FontWeight::MEDIUM)
                .text_color(ThemeColors::foreground())
                .child(name),
        )
        .when(is_current, |row| {
            row.child(
                Icon::new(IconName::Check)
                    .size(px(14.0))
                    .text_color(ThemeColors::primary()),
            )
        })
        .on_click(cx.listener(move |this, _event, _window, cx| {
            if busy {
                return;
            }
            this.checkout(target.clone(), cx);
        }))
        .into_any_element()
}

/// 工作树行：分支名（无分支显示路径）+ 路径副行 + 当前打勾，点击打开对应项目。
fn worktree_row(
    ix: usize,
    info: WorktreeInfo,
    busy: bool,
    cx: &mut Context<BranchManagerView>,
) -> gpui_kit::AnyElement {
    let path = info.path.clone();
    let title = info.branch.clone().unwrap_or_else(|| info.path.clone());
    let is_current = info.is_current;
    h_flex()
        .id(("branch-manager-worktree", ix))
        .h(px(40.0))
        .w_full()
        .mx_2()
        .px_2p5()
        .items_center()
        .gap_2()
        .rounded_md()
        .cursor_pointer()
        .hover(|h| h.bg(ThemeColors::accent()))
        .child(
            Icon::new(IconName::Folder)
                .size(px(14.0))
                .text_color(ThemeColors::muted_foreground()),
        )
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .child(
                    div()
                        .w_full()
                        .truncate()
                        .text_sm()
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(ThemeColors::foreground())
                        .child(title),
                )
                .child(
                    div()
                        .w_full()
                        .truncate()
                        .text_xs()
                        .text_color(ThemeColors::subtle_foreground())
                        .child(info.path.clone()),
                ),
        )
        .when(is_current, |row| {
            row.child(
                Icon::new(IconName::Check)
                    .size(px(14.0))
                    .text_color(ThemeColors::primary()),
            )
        })
        .on_click(cx.listener(move |_this, _event, _window, cx| {
            if busy {
                return;
            }
            cx.emit(BranchManagerEvent::OpenWorktree(path.clone()));
        }))
        .into_any_element()
}

/// 仓库行：当前仓库名 + 路径 + 打勾，点击无动作。
fn repository_row(name: String, path: String) -> gpui_kit::AnyElement {
    h_flex()
        .id("branch-manager-repo")
        .h(px(40.0))
        .w_full()
        .mx_2()
        .px_2p5()
        .items_center()
        .gap_2()
        .rounded_md()
        .child(
            Icon::new(IconName::Folder)
                .size(px(14.0))
                .text_color(ThemeColors::primary()),
        )
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .child(
                    div()
                        .w_full()
                        .truncate()
                        .text_sm()
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(ThemeColors::foreground())
                        .child(name),
                )
                .child(
                    div()
                        .w_full()
                        .truncate()
                        .text_xs()
                        .text_color(ThemeColors::subtle_foreground())
                        .child(path),
                ),
        )
        .child(
            Icon::new(IconName::Check)
                .size(px(14.0))
                .text_color(ThemeColors::primary()),
        )
        .into_any_element()
}

/// 空态行。
fn empty_row(text: String) -> gpui_kit::AnyElement {
    div()
        .w_full()
        .py_8()
        .text_center()
        .text_sm()
        .text_color(ThemeColors::subtle_foreground())
        .child(text)
        .into_any_element()
}
