//! Git 分支 / 工作树 / 补丁 / Rebase 管理对话框。
//!
//! 与 `git_dialogs.rs` 共享 [`GitDialogView`](super::git_dialogs::GitDialogView)
//! 实体；这些 kind 是多行管理或会话语义，独立成文件保持两者都 ≤1500 行。
//! 语义对齐 Tauri `git-branch-manager.tsx`（branches / worktrees 两页——
//! gpui 的 repositories 页就是当前工作区仓库）、`git-patch-dialog.tsx`
//! （export / apply 两模式）与 `git-rebase-dialog.tsx`（预览 → 开始 → 会话
//! 状态与 abort）。写操作互斥复用 `busy`；成功后刷新面板并关闭。

use gpui_kit::component::button::Button;
use gpui_kit::component::button::ButtonVariants as _;
use gpui_kit::component::checkbox::Checkbox;
use gpui_kit::component::input::Input;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AppContext as _, Context, InteractiveElement as _, IntoElement, ParentElement as _,
    SharedString, StatefulInteractiveElement as _, Styled as _, Window, div, px,
};
use lithe_features::git::{GitDialogKind, execute_git_command};
use lithe_ui::i18n::tr;
use lithe_ui::MONO_FONT_FAMILY;
use serde_json::Value;

use super::git_dialogs::{
    CheckoutConfirm, GitDialogView, PushPreviewData, checkout_write_payload,
};

/// 分支管理器里的 tab。Tauri 的第三个 repositories tab 在 gpui 里等价于
/// 当前工作区仓库本身，因此只剩 branches / worktrees 两页。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ManageTab {
    Branches,
    Worktrees,
}

impl GitDialogView {
    pub(crate) fn manage_tab(&self) -> ManageTab {
        match self.kind {
            GitDialogKind::Worktrees => ManageTab::Worktrees,
            _ => ManageTab::Branches,
        }
    }

    /// 分支 / 工作树 / 补丁 / Rebase 的渲染分发。
    pub(crate) fn render_manage(
        &mut self,
        window: &mut Window,
        tokens: lithe_ui::LitheTokens,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        match self.kind {
            GitDialogKind::Branches | GitDialogKind::Worktrees => {
                self.render_branch_manager(window, tokens, cx)
            }
            GitDialogKind::CreatePatch => self.render_patch_export(tokens, cx),
            GitDialogKind::ApplyPatch => self.render_patch_apply(tokens, cx),
            GitDialogKind::Rebase => self.render_rebase(tokens, cx),
            _ => div().into_any_element(),
        }
    }

    // -----------------------------------------------------------------------
    // 分支管理器（branches + worktrees 两页）
    // -----------------------------------------------------------------------

    fn render_branch_manager(
        &mut self,
        window: &mut Window,
        tokens: lithe_ui::LitheTokens,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let tab = self.manage_tab();
        let tabs = h_flex()
            .gap(px(6.0))
            .child(
                Button::new("lithe-git-dialog:tab-branches")
                    .small()
                    .when(tab == ManageTab::Branches, |this| this.primary())
                    .when(tab != ManageTab::Branches, |this| this.secondary())
                    .label(tr("Branches"))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.kind = GitDialogKind::Branches;
                        cx.notify();
                    })),
            )
            .child(
                Button::new("lithe-git-dialog:tab-worktrees")
                    .small()
                    .when(tab == ManageTab::Worktrees, |this| this.primary())
                    .when(tab != ManageTab::Worktrees, |this| this.secondary())
                    .label(tr("Worktrees"))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.kind = GitDialogKind::Worktrees;
                        this.load_worktrees(cx);
                        cx.notify();
                    })),
            );

        let body = if tab == ManageTab::Branches {
            self.render_branches_list(tokens, cx)
        } else {
            self.render_worktrees_list(tokens, cx)
        };
        let _ = window;

        v_flex()
            .gap(px(10.0))
            .child(tabs)
            .child(body)
            .child(
                h_flex().justify_end().child(
                    Button::new("lithe-git-dialog:manage-close")
                        .ghost()
                        .small()
                        .label(tr("Close"))
                        .on_click(cx.listener(|this, _, _, _cx| this.request_close())),
                ),
            )
            .into_any_element()
    }

    /// 本地分支列表 + 新建输入 + checkout / rename / delete 动作。
    fn render_branches_list(
        &mut self,
        tokens: lithe_ui::LitheTokens,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let branches = self.entries_of("local");
        let selected = self.selected;
        let selected_exists = !branches.is_empty();
        if !branches.is_empty() && selected >= branches.len() {
            self.selected = branches.len() - 1;
        }
        let selected_branch = branches.get(self.selected).cloned().unwrap_or_default();

        let busy = self.busy;
        let mut list = v_flex().gap(px(2.0));
        for (index, branch) in branches.iter().enumerate() {
            let is_selected = index == self.selected;
            let name = branch.short_name.clone();
            let is_current = branch.is_current;
            list = list.child(
                h_flex()
                    .id(SharedString::from(format!(
                        "lithe-git-dialog:branch-{index}"
                    )))
                    .w_full()
                    .rounded(px(4.0))
                    .px(px(8.0))
                    .py(px(3.0))
                    .gap(px(8.0))
                    .cursor_pointer()
                    .when(is_selected, |this| this.bg(tokens.subtle_selection))
                    .when(!is_selected, |this| this.hover(|style| style.bg(tokens.hover)))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.selected = index;
                        cx.notify();
                    }))
                    .child(
                        Icon::new(gpui_kit::assets::IconName::GitBranch)
                            .with_size(px(13.0))
                            .text_color(if is_current {
                                tokens.success
                            } else {
                                tokens.secondary_text
                            }),
                    )
                    .child(
                        div()
                            .min_w(px(0.0))
                            .flex_1()
                            .truncate()
                            .text_size(px(12.0))
                            .font_family(MONO_FONT_FAMILY)
                            .text_color(tokens.primary_text)
                            .child(name.clone()),
                    )
                    .when(!is_current, |this| {
                        // 非 HEAD 行提供 checkout；先做 checkoutPreflight，
                        // 有阻断路径时先确认再切换（对齐 Tauri 的切换前检查）。
                        let checkout_full = branch.full_name.clone();
                        let checkout_short = branch.short_name.clone();
                        let checkout_kind = branch.kind.clone();
                        this.child(
                            Button::new(SharedString::from(format!(
                                "lithe-git-dialog:branch-checkout-{index}"
                            )))
                            .ghost()
                            .xsmall()
                            .label(tr("Checkout"))
                            .disabled(busy)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.begin_checkout(
                                    checkout_full.clone(),
                                    checkout_short.clone(),
                                    checkout_kind.clone(),
                                    cx,
                                );
                            })),
                        )
                    })
                    .child(
                        Button::new(SharedString::from(format!(
                            "lithe-git-dialog:branch-delete-{index}"
                        )))
                        .ghost()
                        .xsmall()
                        .label(tr("Delete"))
                        .disabled(busy || is_current)
                        .on_click(cx.listener({
                            let full_name = branch.full_name.clone();
                            let short_name = branch.short_name.clone();
                            move |this, _, _, cx| {
                                // Core `deleteBranch` 走类型化 `gitReference`
                                // （旧 `reference` 字段只是裸名字，会被
                                // `local_branch_name` 以“仅支持本地分支”拒绝）。
                                this.run_write(
                                    serde_json::json!({
                                        "operation": "deleteBranch",
                                        "gitReference": {
                                            "fullName": full_name,
                                            "shortName": short_name,
                                            "kind": "local",
                                        },
                                    }),
                                    cx,
                                );
                            }
                        })),
                    ),
            );
        }
        if branches.is_empty() {
            list = list.child(
                div()
                    .text_size(px(11.5))
                    .text_color(tokens.tertiary_text)
                    .child(tr("No local branches")),
            );
        }

        let branch_input = self.branch_input.clone();
        let new_branch_payload = h_flex()
            .gap(px(6.0))
            .child(Input::new(&branch_input).small().flex_1())
            .child(
                Button::new("lithe-git-dialog:branch-create")
                    .secondary()
                    .small()
                    .label(tr("New branch"))
                    .disabled(self.busy)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        let name = this.branch_input.read(cx).value().trim().to_string();
                        if name.is_empty() {
                            cx.notify();
                            return;
                        }
                        // `checkout -b` 在 Core 的边界是参数数组（不经过
                        // shell）；新建即切换与 Tauri 的 create & checkout 一致。
                        this.run_command(
                            vec!["checkout".into(), "-b".into(), name],
                            cx,
                        );
                    })),
            );

        let checkout_confirm = self.pending_checkout.clone();
        let confirm_card = checkout_confirm
            .as_ref()
            .map(|confirm| self.render_checkout_confirm(confirm, tokens, cx));

        v_flex()
            .gap(px(8.0))
            .children(confirm_card)
            .child(list)
            .when(selected_exists && !selected_branch.is_current, |this| {
                // 选中行提供 rename（`git branch -m`，参数数组边界）。
                this.child(
                    h_flex()
                        .gap(px(6.0))
                        .justify_end()
                        .child(
                            Button::new("lithe-git-dialog:branch-rename")
                                .secondary()
                                .xsmall()
                                .label(tr("Rename to…"))
                                .disabled(busy)
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    let new_name =
                                        this.branch_input.read(cx).value().trim().to_string();
                                    if new_name.is_empty() || new_name == selected_branch.short_name
                                    {
                                        cx.notify();
                                        return;
                                    }
                                    this.run_command(
                                        vec![
                                            "branch".into(),
                                            "-m".into(),
                                            selected_branch.short_name.clone(),
                                            new_name,
                                        ],
                                        cx,
                                    );
                                })),
                        ),
                )
            })
            .child(new_branch_payload)
            .into_any_element()
    }

    /// 开始一次 checkout：先跑 `git.checkoutPreflight`。没有阻断路径时直接
    /// 切换；有阻断路径时进入确认态，由用户决定是否覆盖本地改动。
    pub(crate) fn begin_checkout(
        &mut self,
        full_name: String,
        short_name: String,
        kind: String,
        cx: &mut Context<Self>,
    ) {
        if self.busy {
            return;
        }
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root.to_str().map(str::to_string) else {
            return;
        };
        let payload = serde_json::json!({
            "root": root_text,
            "gitReference": {
                "fullName": full_name,
                "shortName": short_name,
                "kind": kind,
            },
        });
        let client = self.client;
        // 预检结果决定下一步：无阻断直接切换；有阻断进入确认态。
        let full_for_cb = full_name.clone();
        let short_for_cb = short_name.clone();
        let kind_for_cb = kind.clone();
        self.busy = true;
        self.error = None;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, "git.checkoutPreflight", payload)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.busy = false;
                match raw {
                    Ok(value) => {
                        let blocking_paths: Vec<String> = value
                            .get("blockingPaths")
                            .and_then(Value::as_array)
                            .map(|items| {
                                items
                                    .iter()
                                    .filter_map(Value::as_str)
                                    .map(str::to_string)
                                    .collect()
                            })
                            .unwrap_or_default();
                        if blocking_paths.is_empty() {
                            this.run_write(
                                checkout_write_payload(
                                    &full_for_cb,
                                    &short_for_cb,
                                    &kind_for_cb,
                                ),
                                cx,
                            );
                        } else {
                            this.pending_checkout = Some(CheckoutConfirm {
                                full_name: full_for_cb.clone(),
                                short_name: short_for_cb.clone(),
                                kind: kind_for_cb.clone(),
                                blocking_paths,
                            });
                        }
                    }
                    Err(error) => {
                        this.error = Some(error.to_string());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 用户确认「仍然切换」：带遮蔽风险执行 checkout（Core 会校验引用与
    /// 工作区；失败仍回显 stderr）。
    pub(crate) fn confirm_checkout(&mut self, cx: &mut Context<Self>) {
        let Some(confirm) = self.pending_checkout.take() else {
            return;
        };
        self.run_write(
            checkout_write_payload(
                &confirm.full_name,
                &confirm.short_name,
                &confirm.kind,
            ),
            cx,
        );
    }

    pub(crate) fn cancel_checkout(&mut self, cx: &mut Context<Self>) {
        if self.pending_checkout.take().is_some() {
            cx.notify();
        }
    }

    /// checkout 阻断确认卡：列出会被覆盖的本地改动文件。
    fn render_checkout_confirm(
        &self,
        confirm: &CheckoutConfirm,
        tokens: lithe_ui::LitheTokens,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let mut card = v_flex()
            .w_full()
            .gap(px(6.0))
            .rounded(px(4.0))
            .border_1()
            .border_color(tokens.warning)
            .bg(tokens.raised)
            .p(px(8.0))
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(tokens.primary_text)
                    .child(
                        tr("Switching to {branch} would overwrite local changes.")
                            .replace("{branch}", &confirm.short_name),
                    ),
            );
        // 阻断路径可能很多；只列前 8 条，其余给计数（不伪造滚动状态）。
        for path in confirm.blocking_paths.iter().take(8) {
            card = card.child(
                div()
                    .text_size(px(11.0))
                    .font_family(MONO_FONT_FAMILY)
                    .text_color(tokens.secondary_text)
                    .child(path.clone()),
            );
        }
        if confirm.blocking_paths.len() > 8 {
            card = card.child(
                div()
                    .text_size(px(11.0))
                    .text_color(tokens.tertiary_text)
                    .child(
                        tr("and {count} more files")
                            .replace("{count}", &(confirm.blocking_paths.len() - 8).to_string()),
                    ),
            );
        }
        card.child(
            h_flex()
                .w_full()
                .justify_end()
                .gap(px(6.0))
                .child(
                    Button::new("lithe-git-dialog:checkout-cancel")
                        .ghost()
                        .xsmall()
                        .label(tr("Cancel"))
                        .on_click(cx.listener(|this, _, _, cx| this.cancel_checkout(cx))),
                )
                .child(
                    Button::new("lithe-git-dialog:checkout-confirm")
                        .danger()
                        .xsmall()
                        .label(tr("Checkout anyway"))
                        .disabled(self.busy)
                        .on_click(cx.listener(|this, _, _, cx| this.confirm_checkout(cx))),
                ),
        )
        .into_any_element()
    }

    /// worktree 列表 + 新建 / 删除 / lock / unlock / prune。
    fn render_worktrees_list(
        &mut self,
        tokens: lithe_ui::LitheTokens,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let worktrees = self.worktrees.clone();
        let mut list = v_flex().gap(px(2.0));
        for (index, entry) in worktrees.iter().enumerate() {
            let path = entry.path.clone();
            let branch = entry.branch.clone().unwrap_or_else(|| {
                if entry.detached {
                    tr("detached").to_string()
                } else if entry.bare {
                    tr("bare").to_string()
                } else {
                    String::new()
                }
            });
            let locked = entry.locked.clone();
            list = list.child(
                h_flex()
                    .id(SharedString::from(format!(
                        "lithe-git-dialog:worktree-{index}"
                    )))
                    .w_full()
                    .rounded(px(4.0))
                    .px(px(8.0))
                    .py(px(3.0))
                    .gap(px(8.0))
                    .child(
                        Icon::new(gpui_kit::assets::IconName::Folder)
                            .with_size(px(13.0))
                            .text_color(tokens.secondary_text),
                    )
                    .child(
                        v_flex()
                            .min_w(px(0.0))
                            .flex_1()
                            .gap(px(1.0))
                            .child(
                                div()
                                    .min_w(px(0.0))
                                    .truncate()
                                    .text_size(px(12.0))
                                    .font_family(MONO_FONT_FAMILY)
                                    .text_color(tokens.primary_text)
                                    .child(path.clone()),
                            )
                            .child(
                                div()
                                    .min_w(px(0.0))
                                    .truncate()
                                    .text_size(px(10.5))
                                    .text_color(tokens.tertiary_text)
                                    .child(branch),
                            ),
                    )
                    .when_some(locked, |this, reason| {
                        this.child(
                            div()
                                .text_size(px(10.5))
                                .text_color(tokens.warning)
                                .child(tr("Locked ({reason})").replace("{reason}", &reason)),
                        )
                    })
                    .child(
                        Button::new(SharedString::from(format!(
                            "lithe-git-dialog:worktree-remove-{index}"
                        )))
                        .ghost()
                        .xsmall()
                        .label(tr("Remove"))
                        // Core 拒绝当前 / 主 worktree 的移除；本地先禁用，
                        // 与 Git 的约束一致。
                        .disabled(
                            self.busy || entry.bare || entry.is_current || entry.is_primary,
                        )
                        // 三个按钮各自需要一份 destination：move 闭包会独占
                        // 捕获，先按按钮克隆再构造。
                        .on_click(cx.listener({
                            let destination = path.clone();
                            move |this, _, _, cx| {
                                this.run_write(
                                    serde_json::json!({
                                        "operation": "removeWorktree",
                                        "destination": destination,
                                    }),
                                    cx,
                                );
                            }
                        })),
                    )
                    // `locked` 已在上面 `when_some` 里按值消费；这里直接读
                    // 数据源，避免额外 clone。
                    .child(if entry.locked.is_some() {
                        Button::new(SharedString::from(format!(
                            "lithe-git-dialog:worktree-unlock-{index}"
                        )))
                        .ghost()
                        .xsmall()
                        .label(tr("Unlock"))
                        .disabled(self.busy)
                        .on_click(cx.listener({
                            let destination = path.clone();
                            move |this, _, _, cx| {
                                this.run_write(
                                    serde_json::json!({
                                        "operation": "unlockWorktree",
                                        "destination": destination,
                                    }),
                                    cx,
                                );
                            }
                        }))
                        .into_any_element()
                    } else {
                        Button::new(SharedString::from(format!(
                            "lithe-git-dialog:worktree-lock-{index}"
                        )))
                        .ghost()
                        .xsmall()
                        .label(tr("Lock"))
                        .disabled(self.busy)
                        .on_click(cx.listener({
                            let destination = path.clone();
                            move |this, _, _, cx| {
                                this.run_write(
                                    serde_json::json!({
                                        "operation": "lockWorktree",
                                        "destination": destination,
                                    }),
                                    cx,
                                );
                            }
                        }))
                        .into_any_element()
                    }),
            );
        }
        if worktrees.is_empty() {
            list = list.child(
                div()
                    .text_size(px(11.5))
                    .text_color(tokens.tertiary_text)
                    .child(tr("No worktrees")),
            );
        }

        // Core `createWorktree`（newBranch 模式）要求带类型化本地引用：
        // 新分支从当前分支起点创建；detached HEAD 没有可用的起点，按钮禁用。
        let current_branch = self
            .entries_of("local")
            .iter()
            .find(|entry| entry.is_current)
            .map(|entry| {
                (
                    entry.full_name.clone(),
                    entry.short_name.clone(),
                    entry.kind.clone(),
                )
            });

        v_flex()
            .gap(px(8.0))
            .child(list)
            .child(
                h_flex()
                    .gap(px(6.0))
                    .child(Input::new(&self.branch_input).small().flex_1())
                    .child(
                        Button::new("lithe-git-dialog:worktree-create")
                            .secondary()
                            .small()
                            .label(tr("Add worktree"))
                            .disabled(
                                self.busy || self.root.is_none() || current_branch.is_none(),
                            )
                            .on_click(cx.listener(move |this, _, _, cx| {
                                // destination 是工作区下的相对目录（对齐
                                // Tauri createWorktree 的 path + newBranch）。
                                let destination =
                                    this.branch_input.read(cx).value().trim().to_string();
                                let Some((full_name, short_name, kind)) =
                                    current_branch.clone()
                                else {
                                    return;
                                };
                                if destination.is_empty() {
                                    cx.notify();
                                    return;
                                }
                                this.run_write(
                                    serde_json::json!({
                                        "operation": "createWorktree",
                                        "destination": destination,
                                        "worktreeMode": "newBranch",
                                        "name": destination,
                                        "revision": "HEAD",
                                        "gitReference": {
                                            "fullName": full_name,
                                            "shortName": short_name,
                                            "kind": kind,
                                        },
                                    }),
                                    cx,
                                );
                            })),
                    ),
            )
            .child(
                h_flex().justify_end().child(
                    Button::new("lithe-git-dialog:worktree-prune")
                        .ghost()
                        .small()
                        .label(tr("Prune"))
                        .disabled(self.busy)
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.run_write(
                                serde_json::json!({ "operation": "pruneWorktrees" }),
                                cx,
                            );
                        })),
                ),
            )
            .into_any_element()
    }

    // -----------------------------------------------------------------------
    // Patch：export / apply
    // -----------------------------------------------------------------------

    /// Create Patch：来源（工作区 / 已暂存）+ 右键所选路径 + include-untracked
    /// + 导出（导出结果先复制到剪贴板，保存路径走 lithe-platform 的保存框）。
    fn render_patch_export(
        &mut self,
        tokens: lithe_ui::LitheTokens,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let paths = self.patch_paths.clone();
        let source = self.patch_source;
        let mut form = v_flex().gap(px(8.0));

        for candidate in [super::git_dialogs::PatchSource::WorkingTree, super::git_dialogs::PatchSource::Staged] {
            form = form.child(
                h_flex()
                    .id(SharedString::from(candidate.wire()))
                    .cursor_pointer()
                    .rounded(px(4.0))
                    .px(px(6.0))
                    .py(px(2.0))
                    .hover(|style| style.bg(tokens.hover))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.patch_source = candidate;
                        cx.notify();
                    }))
                    .child(Self::radio_row(
                        "lithe-git-dialog:patch-source-item",
                        self.patch_source == candidate,
                        candidate.label(),
                        tokens,
                    )),
            );
        }

        if !paths.is_empty() {
            form = form.child(
                div()
                    .text_size(px(11.5))
                    .text_color(tokens.secondary_text)
                    .child(tr("{count} files selected").replace("{count}", &paths.len().to_string())),
            );
        }

        form = form
            .child(
                Checkbox::new("lithe-git-dialog:patch-include-untracked")
                    .small()
                    .checked(self.patch_include_untracked)
                    .label(tr("Include untracked files"))
                    .on_change(cx.listener(|this, checked: &bool, _window, cx| {
                        this.patch_include_untracked = *checked;
                        cx.notify();
                    })),
            )
            .child(
                h_flex()
                    .justify_end()
                    .gap(px(8.0))
                    .child(Self::cancel_button(
                        "lithe-git-dialog:patch-export-cancel",
                        cx,
                    ))
                    .child(
                        Button::new("lithe-git-dialog:patch-export-run")
                            .primary()
                            .small()
                            .label(tr("Export"))
                            .disabled(self.action_disabled())
                            .on_click(cx.listener(move |this, _, _, cx| {
                                // Core `patch.export` 的请求字段是 camelCase。
                                let payload = serde_json::json!({
                                    "source": source.wire(),
                                    "paths": paths,
                                    "includeUntracked": this.patch_include_untracked,
                                });
                                this.run_patch_export(payload, cx);
                            })),
                    ),
            );

        if let Some(patch) = self.patch_text.clone() {
            form = form
                .child(
                    div()
                        .text_size(px(11.5))
                        .text_color(tokens.success)
                        .child(tr("Patch exported ({bytes} bytes)")
                            .replace("{bytes}", &patch.as_bytes().len().to_string())),
                )
                .child(
                    h_flex()
                        .justify_end()
                        .gap(px(6.0))
                        .child(
                            Button::new("lithe-git-dialog:patch-copy")
                                .secondary()
                                .small()
                                .label(tr("Copy patch"))
                                .on_click(cx.listener(move |_, _, _, cx| {
                                    // 导出结果复制到剪贴板（跨平台，gpui-kit
                                    // Clipboard 组件的能力；Tauri 的另存文件
                                    // 在 gpui 里走 pick_save_path，V2 迭代）。
                                    cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string(
                                        patch.clone(),
                                    ));
                                    cx.notify();
                                })),
                        ),
                );
        }

        form.into_any_element()
    }

    /// Apply Patch：粘贴或选择文件 → `git.patchPreview` 校验 →
    /// `git.patchApply`（expectedState 绑定预览令牌）。
    fn render_patch_apply(
        &mut self,
        tokens: lithe_ui::LitheTokens,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let has_preview = self.patch_expected_state.is_some();
        let is_applicable = has_preview;

        v_flex()
            .gap(px(10.0))
            .child(
                div()
                    .text_size(px(11.5))
                    .text_color(tokens.tertiary_text)
                    .child(tr(
                        "Paste a patch below (or load it from the file input), preview it, then apply.",
                    )),
            )
            .child(Input::new(&self.branch_input).small().w_full())
            .child(
                h_flex()
                    .gap(px(6.0))
                    .child(
                        Button::new("lithe-git-dialog:patch-load-clipboard")
                            .secondary()
                            .small()
                            .label(tr("Load from clipboard"))
                            .on_click(cx.listener(|this, _, window, cx| {
                                // set_value 需要 Window；listener 的第三个参数
                                // 正好是它。剪贴板读取取消 / 失败时静默。
                                if let Some(item) = cx.read_from_clipboard() {
                                    // `text()` 返回 Option<String>；剪贴板里没有
                                    // 文本时按空串处理（不崩、不写入占位内容）。
                                    let text = item.text().unwrap_or_default();
                                    this.branch_input.update(cx, |state, cx| {
                                        state.set_value(text, window, cx);
                                    });
                                }
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("lithe-git-dialog:patch-preview")
                            .secondary()
                            .small()
                            .label(tr("Check patch"))
                            .disabled(self.action_disabled())
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.run_patch_preview(cx);
                            })),
                    ),
            )
            .when_some(self.patch_expected_state.clone(), |this, _token| {
                this.child(
                    div()
                        .text_size(px(11.5))
                        .text_color(tokens.success)
                        .child(tr("Patch is applicable.")),
                )
            })
            .child(
                h_flex()
                    .justify_end()
                    .gap(px(8.0))
                    .child(Self::cancel_button(
                        "lithe-git-dialog:patch-apply-cancel",
                        cx,
                    ))
                    .child(
                        Button::new("lithe-git-dialog:patch-apply-run")
                            .primary()
                            .small()
                            .label(tr("Apply"))
                            .disabled(!is_applicable || self.busy)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.run_patch_apply(cx);
                            })),
                    ),
            )
            .into_any_element()
    }

    // -----------------------------------------------------------------------
    // Interactive Rebase：预览 → 开始 → 会话状态
    // -----------------------------------------------------------------------

    fn render_rebase(
        &mut self,
        tokens: lithe_ui::LitheTokens,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let plan = self.rebase_plan.clone().unwrap_or_default();
        let mut body = v_flex().gap(px(8.0));

        if !plan.allowed {
            body = body.child(
                div()
                    .text_size(px(11.5))
                    .text_color(tokens.error)
                    .child(if plan.blockers.is_empty() {
                        tr("Rebase is not available for the current history.").to_string()
                    } else {
                        plan.blockers.join("\n")
                    }),
            );
        } else {
            body = body.child(
                div()
                    .text_size(px(11.5))
                    .text_color(tokens.secondary_text)
                    .child(format!(
                        "{} {} · {} {}",
                        tr("Branch:"),
                        plan.branch.clone().unwrap_or_default(),
                        tr("Base:"),
                        plan.base.clone().unwrap_or_default()
                    )),
            );
            for (hash, subject) in plan.commits.clone() {
                body = body.child(
                    h_flex()
                        .gap(px(6.0))
                        .child(
                            div()
                                .text_size(px(11.0))
                                .font_family(MONO_FONT_FAMILY)
                                .text_color(tokens.link)
                                .child(hash),
                        )
                        .child(
                            div()
                                .min_w(px(0.0))
                                .truncate()
                                .text_size(px(11.5))
                                .text_color(tokens.primary_text)
                                .child(subject),
                        ),
                );
            }
        }

        body = body.child(
            h_flex()
                .justify_end()
                .gap(px(8.0))
                .child(Self::cancel_button(
                    "lithe-git-dialog:rebase-cancel",
                    cx,
                ))
                .when_some(self.rebase_session_id(), |this, session_id| {
                    this.child(
                        Button::new("lithe-git-dialog:rebase-abort")
                            .danger()
                            .small()
                            .label(tr("Abort session"))
                            .disabled(self.busy)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                // `run_rebase_control` 接受 owned session id；
                                // listener 是 Fn，闭包内克隆避免把捕获值 move 出去。
                                this.run_rebase_control(session_id.clone(), "abort", cx);
                            })),
                    )
                })
                .child(
                    Button::new("lithe-git-dialog:rebase-start")
                        .primary()
                        .small()
                        .label(tr("Start rebase"))
                        .disabled(!plan.allowed || self.busy)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.run_rebase_start(cx);
                        })),
                ),
        );

        body.into_any_element()
    }
}

// --- 数据与命令通道（patch / rebase） --------------------------------------

impl GitDialogView {
    /// `git.patchExport`（metadata_only: false）：结果暂存 `patch_text` 并
    /// 自动复制到剪贴板（对齐 Tauri 的 export 结果展示；另存文件 V2 走
    /// lithe-platform pick_save_path）。
    pub(crate) fn run_patch_export(&mut self, mut payload: Value, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some(root) = self.root.clone() else {
            return;
        };
        if let Some(root_text) = root.to_str() {
            payload["root"] = Value::String(root_text.to_string());
        }
        // Core `PatchExportRequest` 是 camelCase（`metadataOnly`）。
        payload["metadataOnly"] = Value::Bool(false);
        self.busy = true;
        self.error = None;
        let client = self.client;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move { execute_git_command(&client, "git.patchExport", payload) })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.busy = false;
                match raw {
                    Ok(value) => {
                        let patch = value
                            .get("patch")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string();
                        if patch.is_empty() {
                            this.error = Some(tr("No textual changes").to_string());
                        } else {
                            this.patch_text = Some(patch);
                            cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string(
                                this.patch_text.clone().unwrap_or_default(),
                            ));
                            cx.notify();
                        }
                    }
                    Err(error) => {
                        this.error = Some(error.to_string());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// `git.patchPreview`：前向可适用性检查；拿到 `expected_state` 令牌后才
    /// 允许 Apply（Core 的绑定规则）。
    pub(crate) fn run_patch_preview(&mut self, cx: &mut Context<Self>) {
        let patch = self.branch_input.read(cx).value().to_string();
        if patch.trim().is_empty() {
            self.error = Some(tr("Paste a patch to apply").to_string());
            cx.notify();
            return;
        }
        self.run_read(
            "git.patchPreview",
            serde_json::json!({
                "patch": patch,
                "target": "worktree",
                "metadataOnly": false,
            }),
            cx,
            Self::absorb_patch_preview,
        );
    }

    /// 消费 patchPreview 回包：拿到 expected_state 令牌或把诊断留在错误行。
    fn absorb_patch_preview(&mut self, value: &Value) {
        self.patch_expected_state = None;
        if value.get("applicable").and_then(Value::as_bool).unwrap_or(false) {
            self.patch_expected_state = value
                .get("expectedState")
                .and_then(Value::as_str)
                .map(str::to_string);
        } else {
            let diagnostic = value
                .get("diagnostic")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if diagnostic.is_empty() {
                self.error = Some(tr("Patch is not applicable").to_string());
            } else {
                self.error = Some(diagnostic.to_string());
            }
        }
    }

    /// `git.patchApply { patch, target, expectedState }`：成功后刷新并关闭
    /// （Core 的 apply 带预览令牌，逐字节等价）。
    pub(crate) fn run_patch_apply(&mut self, cx: &mut Context<Self>) {
        let Some(token) = self.patch_expected_state.clone() else {
            return;
        };
        let patch = self.branch_input.read(cx).value().to_string();
        if patch.trim().is_empty() {
            self.error = Some(tr("Paste a patch to apply").to_string());
            cx.notify();
            return;
        }
        self.run_command_generic(
            "git.patchApply",
            serde_json::json!({
                "patch": patch,
                "target": "worktree",
                "expectedState": Value::String(token),
            }),
            cx,
            |_this: &mut Self, _value: &Value| {},
            true,
        );
    }

    /// `git.rebasePreview { root, revision: HEAD }`：预览计划（可重放的提交）。
    pub(crate) fn run_rebase_preview(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root.to_str().map(str::to_string) else {
            return;
        };
        self.loading = true;
        let client = self.client;
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, 
                        "git.rebasePreview",
                        serde_json::json!({ "root": root_text, "revision": "HEAD" }),
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.loading = false;
                match raw {
                    Ok(value) => {
                        this.rebase_plan = Some(Self::plan_from_preview(&value));
                    }
                    Err(error) => {
                        this.error = Some(error.to_string());
                        this.rebase_plan = None;
                    }
                }
                // 有无计划都查一次进行中的会话（Abort 入口）。
                this.run_rebase_session(cx);
                cx.notify();
            });
        })
        .detach();
    }

    /// 从 rebasePreview 响应构建本地计划：相对路径提交 + 默认 pick 步骤。
    fn plan_from_preview(value: &Value) -> super::git_dialogs::RebasePlan {
        let commits = value
            .get("commits")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| {
                        let hash = item.get("hash").and_then(Value::as_str)?;
                        let message = item.get("message").and_then(Value::as_str)?;
                        Some((hash.to_string(), message.to_string()))
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let steps = serde_json::json!(commits
            .iter()
            .map(|(hash, _)| serde_json::json!({
                "hash": hash,
                "action": "pick",
            }))
            .collect::<Vec<_>>());
        super::git_dialogs::RebasePlan {
            allowed: value
                .get("allowed")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            blockers: value
                .get("blockers")
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|item| item.get("message").and_then(Value::as_str))
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default(),
            branch: value.get("branch").and_then(Value::as_str).map(str::to_string),
            base: value.get("base").and_then(Value::as_str).map(str::to_string),
            commits,
            // Core 的响应同样是 camelCase。
            expected_state: value.get("expectedState").cloned(),
            steps: Some(steps),
        }
    }

    /// `git.rebaseSession { root }`：查询进行中的会话；没有会话属于正常态。
    pub(crate) fn run_rebase_session(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root.to_str().map(str::to_string) else {
            return;
        };
        let client = self.client;
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, 
                        "git.rebaseSession",
                        serde_json::json!({ "root": root_text }),
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.rebase_session = match raw {
                    Ok(value) => {
                        let session_id = value
                            .get("sessionId")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string();
                        if session_id.is_empty() {
                            None
                        } else {
                            Some((
                                session_id,
                                value
                                    .get("status")
                                    .and_then(Value::as_str)
                                    .unwrap_or_default()
                                    .to_string(),
                            ))
                        }
                    }
                    Err(_) => None,
                };
                cx.notify();
            });
        })
        .detach();
    }

    /// `git.rebaseStart { root, expectedState, steps }`（全部 pick）。
    pub(crate) fn run_rebase_start(&mut self, cx: &mut Context<Self>) {
        let Some(plan) = self.rebase_plan.clone() else {
            return;
        };
        let (Some(expected_state), Some(steps)) = (plan.expected_state, plan.steps) else {
            return;
        };
        self.run_command_generic(
            "git.rebaseStart",
            serde_json::json!({
                "expectedState": expected_state,
                "steps": steps,
            }),
            cx,
            |this: &mut Self, _value: &Value| {
                // 会话开始后查询状态；会话不在本对话框渲染（面板会刷新）。
                this.rebase_session = None;
            },
            false,
        );
    }

    /// `git.rebaseControl { root, sessionId, action }`：continue / skip / abort。
    pub(crate) fn run_rebase_control(
        &mut self,
        session_id: String,
        action: &'static str,
        cx: &mut Context<Self>,
    ) {
        self.run_command_generic(
            "git.rebaseControl",
            serde_json::json!({
                "sessionId": session_id,
                "action": action,
            }),
            cx,
            |this: &mut Self, _value: &Value| {
                this.rebase_session = None;
            },
            true,
        );
    }

    /// 进行中会话查询的 id。
    pub(crate) fn rebase_session_id(&self) -> Option<String> {
        self.rebase_session.as_ref().map(|(id, _)| id.clone())
    }

    /// 会话命令执行：不自动关闭（会话可能处于 conflict，需要继续控制），
    /// 成功后查询会话状态并刷新面板。
    pub(crate) fn run_session_command(
        &mut self,
        command: &'static str,
        payload: Value,
        cx: &mut Context<Self>,
    ) {
        if self.busy {
            return;
        }
        self.busy = true;
        self.error = None;
        let client = self.client;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move { execute_git_command(&client, command, payload) })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.busy = false;
                match raw {
                    Ok(_) => {
                        this.run_rebase_session(cx);
                        this.notify_panel_refresh(cx);
                    }
                    Err(error) => {
                        this.error = Some(error.to_string());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
}

/// patch 输入为空时的内联校验（不动执行管线）。
fn thiserror_patch_empty(view: &mut GitDialogView) {
    view.error = Some(tr("Patch is empty").to_string());
}

/// 会话查询失败不算错误；进行中查询入口给 rebase 控制。
impl GitDialogView {
    /// 通用命令执行（patchApply / rebaseStart / rebaseControl 等），带可选
    /// `close_on_success` 与回包消费者；失败把错误留在状态行。
    pub(crate) fn run_command_generic<R>(
        &mut self,
        command: &'static str,
        mut payload: Value,
        cx: &mut Context<Self>,
        on_value: R,
        close_on_success: bool,
    ) where
        R: FnOnce(&mut GitDialogView, &Value) + 'static,
    {
        if self.busy {
            return;
        }
        if let Some(root) = self.root.clone().and_then(|root| root.to_str().map(str::to_string)) {
            payload["root"] = Value::String(root);
        }
        self.busy = true;
        self.error = None;
        let client = self.client;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move { execute_git_command(&client, command, payload) })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.busy = false;
                match raw {
                    Ok(value) => {
                        on_value(&mut *this, &value);
                        this.notify_panel_refresh(cx);
                        if close_on_success {
                            this.request_close();
                        }
                    }
                    Err(error) => {
                        this.error = Some(error.to_string());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// `run_read` 是 `run_command_generic` 的只读别名（不关对话框）。带一个
    /// Fn(&mut Self, &Value) 消费者（boot 时创建实体引用约定）。
    pub(crate) fn run_read<R>(
        &mut self,
        command: &'static str,
        payload: Value,
        cx: &mut Context<Self>,
        on_value: R,
    ) where
        R: Fn(&mut GitDialogView, &Value) + 'static,
    {
        self.run_command_generic(
            command,
            payload,
            cx,
            // `move` 让包装闭包拥有 `on_value`，满足 `run_command_generic`
            // 的 `'static` 约束。
            move |this, value| on_value(this, value),
            false,
        );
    }

    /// `GitPushPreviewResponse` 的最小本地解析（Push 对话框在
    /// `git_dialogs.rs` 打开时调用；放在本文件是为了让两个对话框文件都
    /// 保持在 1500 行以内）。
    pub(crate) fn parse_push_preview(value: &Value) -> PushPreviewData {
        let string = |key: &str| {
            value
                .get(key)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string()
        };
        let tags = value
            .get("tags")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .map(|item| {
                        (
                            item.get("fullName")
                                .and_then(Value::as_str)
                                .unwrap_or_default()
                                .to_string(),
                            item.get("objectId")
                                .and_then(Value::as_str)
                                .unwrap_or_default()
                                .to_string(),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default();
        PushPreviewData {
            local_branch: string("localBranch"),
            local_head: string("localHead"),
            remote: string("remote"),
            remote_branch: string("remoteBranch"),
            target_kind: string("targetKind"),
            creates_remote_branch: value
                .get("createsRemoteBranch")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            remote_tracking_oid: value
                .get("remoteTrackingOid")
                .and_then(Value::as_str)
                .map(str::to_string),
            tags,
            ahead: value
                .get("commits")
                .and_then(Value::as_array)
                .map(|items| items.len())
                .unwrap_or(0),
            has_more: value
                .get("hasMore")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        }
    }
}


