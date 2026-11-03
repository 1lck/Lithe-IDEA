//! Git 面板的写操作：暂存 / 取消暂存 / 丢弃、Fetch、提交与工作区提交流水线。
//!
//! 拆分自原 `git.rs` 的动作段。所有 Core 调用都在 `cx.background_spawn` 中
//! 执行，结果经 `this.update` 回到视图线程；`generation` 变化时丢弃过期结果。
//! 同一时刻只允许一个写操作：`pending_action` 既挡住重复点击，也是按钮的
//! 进行中标记。工作区提交走 Core `git.workspaceCommitPrepare/Step` 流水线
//! （对齐 Tauri `git-workspace-commit.store.ts`），流水线不可用时回退到旧的
//! 单命令 `git.command ["commit"]` 路径。

use serde_json::Value;
use gpui_kit::{AppContext as _, SharedString};
use lithe_ui::i18n::tr;

use super::model::{CoreChange, command_failure_detail, parse_command, root_text};
use super::{
    ChangeAction, ChangeGroup, CommitHint, GitPanel, PendingAction, Selection,
    execute_git_command,
};

/// 分组内每一行可用的动作。
///
/// 未跟踪项只给 Stage：Discard 对它们等于删除用户文件，不能放在一键操作里。
/// 已暂存行只给 Unstage；工作区组才提供 Stage / Discard（同一条目可能同时
/// 出现在两个组里，索引与工作区是两个独立维度）。
pub(crate) fn actions_for(change: &CoreChange, group: ChangeGroup) -> &'static [ChangeAction] {
    match group {
        ChangeGroup::Staged => &[ChangeAction::Unstage],
        ChangeGroup::Worktree if !change.untracked => &[ChangeAction::Stage, ChangeAction::Discard],
        ChangeGroup::Worktree | ChangeGroup::Untracked => &[ChangeAction::Stage],
    }
}

impl PendingAction {
    pub(crate) fn arguments(&self) -> Vec<String> {
        match self {
            PendingAction::Change { path, action, .. } => action.arguments(path),
            PendingAction::Paths { paths, action } => {
                let first = paths.first().map(String::as_str).unwrap_or("");
                // `action.arguments(first)` 产出「命令段 + `--` + 单路径」，
                // 其余路径追加到分隔符之后，保持一条命令一个 `--`。
                let mut arguments = action.arguments(first);
                arguments.extend(paths.iter().skip(1).cloned());
                arguments
            }
            PendingAction::StageAll => vec!["add".to_string(), "-A".to_string()],
            PendingAction::UnstageAll => vec!["reset".to_string(), "HEAD".to_string()],
            // `GitWrite` 变体走 `git.write`，不产生参数数组。
            PendingAction::GitWrite { .. } => Vec::new(),
        }
    }

    pub(crate) fn success_message(&self) -> &'static str {
        match self {
            PendingAction::Change { action, .. } => action.success_message(),
            PendingAction::Paths { paths, action } => {
                // 批量成功文案是一次动态字符串；execute_action 的提示通道
                // 用 `tr` 收集的是静态 key，这里先回落到单文件的成功提示，
                // 计数提示由调用侧在 notice 里覆盖（见 execute_action）。
                let _ = paths;
                action.success_message()
            }
            PendingAction::StageAll => tr("Staged all changes"),
            PendingAction::UnstageAll => tr("Unstaged all changes"),
            PendingAction::GitWrite { success, .. } => success,
        }
    }

    pub(crate) fn failure_message(&self) -> &'static str {
        match self {
            PendingAction::Change { action, .. } => action.failure_message(),
            PendingAction::Paths { action, .. } => action.failure_message(),
            PendingAction::StageAll => tr("Stage all failed"),
            PendingAction::UnstageAll => tr("Unstage all failed"),
            PendingAction::GitWrite { failure, .. } => failure,
        }
    }

    /// `git.write` 的 operation 字段；仅 `GitWrite` 变体携带。
    pub(crate) fn write_operation(&self) -> Option<&'static str> {
        match self {
            PendingAction::GitWrite { operation, .. } => Some(operation),
            _ => None,
        }
    }

    /// 随 `git.write` 发送的完整 payload；仅 `GitWrite` 变体携带。
    pub(crate) fn write_payload(&self) -> Option<Value> {
        match self {
            PendingAction::GitWrite { payload, .. } => Some(payload.clone()),
            _ => None,
        }
    }
}

impl GitPanel {
    /// 是否至少有一个可暂存（工作区或未跟踪）的条目。
    pub(crate) fn can_stage_all(&self) -> bool {
        self.status.as_ref().is_some_and(|status| {
            status
                .changes
                .iter()
                .any(|change| change.can_toggle_staging && (change.worktree || change.untracked))
        })
    }

    /// 是否至少有一个已暂存条目。
    pub(crate) fn can_unstage_all(&self) -> bool {
        self.status.as_ref().is_some_and(|status| {
            status
                .changes
                .iter()
                .any(|change| change.staged && change.can_toggle_staging)
        })
    }

    /// 暂存全部工作区与未跟踪改动。工具窗标题栏的操作菜单复用同一入口。
    pub fn stage_all_changes(&mut self, cx: &mut gpui_kit::Context<Self>) {
        self.execute_action(PendingAction::StageAll, cx);
    }

    /// 取消暂存全部条目。工具窗标题栏的操作菜单复用同一入口。
    pub fn unstage_all_changes(&mut self, cx: &mut gpui_kit::Context<Self>) {
        self.execute_action(PendingAction::UnstageAll, cx);
    }

    pub(crate) fn apply_change_action(
        &mut self,
        path: String,
        group: ChangeGroup,
        action: ChangeAction,
        cx: &mut gpui_kit::Context<Self>,
    ) {
        self.pending_discard = None;
        self.pending_discard_all = false;
        self.execute_action(
            PendingAction::Change {
                path,
                group,
                action,
            },
            cx,
        );
    }

    /// 统一的破坏性丢弃入口：所有 Rollback / Discard 路径（行内、工具栏、
    /// 菜单、右键）都经过这里，确认与否由设置 `confirmBeforeDiscard` 控制
    /// （对齐 Tauri git-actions-menu.tsx:142-154 与行级确认）。
    pub(crate) fn confirm_discard(
        &mut self,
        path: String,
        group: ChangeGroup,
        cx: &mut gpui_kit::Context<Self>,
    ) {
        if self.pending_action.is_some() || self.committing {
            return;
        }
        if !self.git_confirm_discard {
            self.apply_change_action(path, group, ChangeAction::Discard, cx);
            return;
        }
        self.pending_discard_all = false;
        self.pending_discard = Some((path, group));
        cx.notify();
    }

    /// 单文件丢弃入口（行内按钮与右键菜单共用）。
    pub(crate) fn request_discard(
        &mut self,
        path: String,
        group: ChangeGroup,
        cx: &mut gpui_kit::Context<Self>,
    ) {
        self.confirm_discard(path, group, cx);
    }

    /// 执行一次写操作：先占用 `pending_action`，再在后台调用 Core。
    ///
    /// 参数数组走 `git.command`；带 operation 的走 `git.write`。成功复用
    /// `reload_all`（status / diff / log 一起刷新），失败把 Git 的 stderr
    /// 留在状态行；generation 变化时直接丢弃结果。
    pub(crate) fn execute_action(&mut self, pending: PendingAction, cx: &mut gpui_kit::Context<Self>) {
        if self.pending_action.is_some() || self.committing {
            return;
        }
        let Some(root) = self.root.clone() else {
            self.error = Some(SharedString::from(tr("No project open")));
            self.notice = None;
            cx.notify();
            return;
        };
        let Some(root_text) = root_text(&root) else {
            self.error = Some(SharedString::from(tr("Project path is not valid UTF-8")));
            self.notice = None;
            cx.notify();
            return;
        };

        let failure = pending.failure_message();
        // 批量动作的成功提示带计数（动态字符串）；其余用静态词条。
        let success_notice: SharedString = match &pending {
            PendingAction::Paths { paths, action } if paths.len() > 1 => SharedString::from(
                PendingAction::batch_success_message(*action, paths.len()),
            ),
            _ => SharedString::from(pending.success_message()),
        };
        // 后台任务需要 owned 的请求描述；先把它们取出来再 move `pending`
        // 进 `self.pending_action`。
        let write_operation = pending.write_operation();
        let write_payload = pending.write_payload();
        let arguments = pending.arguments();
        let generation = self.generation;
        let client = self.client;
        self.pending_action = Some(pending);
        self.error = None;
        self.notice = None;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    // `git.command` 的边界是参数数组，不经过 shell；路径放在
                    // `--` 之后，避免以 `-` 开头的文件名被当成选项。
                    if let Some(operation) = write_operation {
                        let mut payload = write_payload.unwrap_or(Value::Null);
                        if payload.is_null() {
                            payload = serde_json::json!({});
                        }
                        payload["root"] = Value::String(root_text.clone());
                        payload["operation"] = Value::String(operation.to_string());
                        execute_git_command(&client, "git.write", payload)
                    } else {
                        execute_git_command(&client, 
                            "git.command",
                            serde_json::json!({
                                "root": root_text,
                                "arguments": arguments,
                            }),
                        )
                    }
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.pending_action = None;
                match raw {
                    Ok(value) => match parse_command(&value) {
                        Ok(command) if command.exit_code == 0 => {
                            // reload_all 会清空 error / notice，提示必须放在其后。
                            this.reload_all(cx);
                            this.notice = Some(success_notice);
                        }
                        Ok(command) => {
                            this.error = Some(SharedString::from(command_failure_detail(
                                &command, failure,
                            )));
                        }
                        Err(message) => {
                            this.error = Some(SharedString::from(message));
                        }
                    },
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 丢弃当前选中的变更（多选时批量）。工具栏入口复用同一入口。
    pub fn discard_selected_change(&mut self, cx: &mut gpui_kit::Context<Self>) {
        let mut targets: Vec<Selection> = self.multi_selected.iter().cloned().collect();
        if targets.is_empty() {
            if let Some(selection) = self.selected.clone() {
                targets.push(selection);
            }
        }
        if targets.is_empty() {
            return;
        }
        // 单选保持旧行为：一份确认覆盖层。多选也只弹一次确认，确认后逐条执行。
        let first = targets.remove(0);
        self.batch_discard = targets;
        self.confirm_discard(first.path, first.group, cx);
    }

    /// 丢弃全部变更（标题栏菜单）。Core `git.write {"operation":"discardAll"}`；
    /// 确认与否由设置 `confirmBeforeDiscard` 控制（对齐 Tauri discardAllChanges）。
    pub fn discard_all_changes(&mut self, cx: &mut gpui_kit::Context<Self>) {
        if self.pending_action.is_some() || self.committing {
            return;
        }
        if !self.git_confirm_discard {
            self.execute_discard_all(cx);
            return;
        }
        self.pending_discard_all = true;
        self.pending_discard = None;
        cx.notify();
    }

    pub(crate) fn execute_discard_all(&mut self, cx: &mut gpui_kit::Context<Self>) {
        self.pending_discard_all = false;
        self.execute_action(
            PendingAction::GitWrite {
                operation: "discardAll",
                payload: serde_json::json!({}),
                success: tr("Discarded all changes"),
                failure: tr("Discard failed"),
            },
            cx,
        );
    }

    /// Fetch 直执行（对齐 git-actions-menu.tsx:134-140：默认参数，toast + 刷新）。
    /// Core `git.write {"operation":"fetch"}` 缺省 fetch_options = 全部远端，
    /// prune / submodules / tags 由设置页的 Fetch 默认值经执行信封生效。
    pub fn fetch_changes(&mut self, cx: &mut gpui_kit::Context<Self>) {
        if self.pending_action.is_some() || self.committing || self.fetching {
            return;
        }
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root_text(&root) else {
            return;
        };
        let generation = self.generation;
        let client = self.client;
        self.fetching = true;
        self.error = None;
        self.notice = None;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(
                        &client,
                        "git.write",
                        serde_json::json!({ "root": root_text, "operation": "fetch" }),
                    )
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.fetching = false;
                match raw {
                    Ok(value) => match parse_command(&value) {
                        Ok(command) if command.exit_code == 0 => {
                            this.reload_all(cx);
                            this.notice = Some(SharedString::from(tr("Changes fetched")));
                        }
                        Ok(command) => {
                            this.error = Some(SharedString::from(command_failure_detail(
                                &command,
                                tr("Fetch failed"),
                            )));
                        }
                        Err(message) => {
                            this.error = Some(SharedString::from(message));
                        }
                    },
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 初始化仓库（无仓库态的标题栏菜单项）。Core `git.initialize { root }`。
    pub fn initialize_repository(&mut self, cx: &mut gpui_kit::Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root_text(&root) else {
            return;
        };
        let generation = self.generation;
        let client = self.client;
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, 
                        "git.initialize",
                        serde_json::json!({ "root": root_text }),
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                match raw {
                    Ok(_) => {
                        this.reload_all(cx);
                        this.notice =
                            Some(SharedString::from(tr("Repository initialized")));
                    }
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    // -----------------------------------------------------------------------
    // 提交：工作区提交流水线（Core `git.workspaceCommitPrepare/Step`）
    // -----------------------------------------------------------------------

    /// 本次提交会包含的已暂存文件数；对齐 Tauri 的「包含在提交里的文件数」。
    pub(crate) fn staged_count(&self) -> usize {
        self.status.as_ref().map_or(0, |status| {
            status
                .changes
                .iter()
                .filter(|change| change.staged && change.can_toggle_staging)
                .count()
        })
    }

    pub(crate) fn commit(&mut self, window: &mut gpui_kit::Window, cx: &mut gpui_kit::Context<Self>) {
        self.commit_inner(false, window, cx);
    }

    /// 「提交并推送」走工作区流水线的 `push: true`；推送目标追问自然覆盖
    /// 「上游未设置」的场景（对齐 Tauri use-git-workspace-commit）。
    pub(crate) fn commit_and_push(
        &mut self,
        window: &mut gpui_kit::Window,
        cx: &mut gpui_kit::Context<Self>,
    ) {
        self.commit_inner(true, window, cx);
    }

    fn commit_inner(
        &mut self,
        push: bool,
        _window: &mut gpui_kit::Window,
        cx: &mut gpui_kit::Context<Self>,
    ) {
        if self.committing || self.pending_action.is_some() || self.commit_session.is_some() {
            return;
        }
        let Some(input) = self.commit_input.clone() else {
            return;
        };
        let message = input.read(cx).value().trim().to_string();
        // 对齐 Tauri `handleCommit`：按钮在缺少文件或消息时禁用，但键盘提交
        // 仍要留下可执行的提示，而不是静默什么都不做。
        let no_changes = self.staged_count() == 0;
        let no_message = message.is_empty();
        if no_changes || no_message {
            self.commit_hint = Some(CommitHint {
                no_changes,
                no_message,
            });
            self.notice = None;
            cx.notify();
            return;
        }
        self.commit_hint = None;
        let Some(root) = self.root.clone() else {
            self.error = Some(SharedString::from(tr("No project open")));
            cx.notify();
            return;
        };
        let Some(root_text) = root_text(&root) else {
            self.error = Some(SharedString::from(tr("Project path is not valid UTF-8")));
            cx.notify();
            return;
        };

        self.committing = true;
        self.error = None;
        self.notice = None;
        cx.notify();

        let amend = self.amend;
        let include_parent_references = self.update_parent_refs;
        let generation = self.generation;
        let client = self.client;

        cx.spawn(async move |this, cx| {
            // 工作区提交流水线：Core 负责发现仓库、依赖排序、状态守卫与
            // 推送目标追问。单个仓库时等价于一次受守卫的普通提交。
            let payload = serde_json::json!({
                "repositories": [{ "id": ".", "root": root_text }],
                "message": message,
                "amend": amend,
                "push": push,
                "includeParentReferences": include_parent_references,
            });
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, "git.workspaceCommitPrepare", payload)
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.committing = false;
                match raw {
                    Ok(value) => {
                        this.begin_commit_session(value, push, cx);
                    }
                    Err(_) => {
                        // 旧 Core 没有 workspaceCommit 命令：回退到单命令提交
                        // 路径（push 用裸 `git push`），保持面板可用。
                        this.legacy_commit(amend, push, cx);
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 解析 prepare 响应并进入 Review / 追问 / 逐步执行。
    pub(crate) fn begin_commit_session(
        &mut self,
        value: Value,
        push: bool,
        cx: &mut gpui_kit::Context<Self>,
    ) {
        let Some(state) = super::commit_area::CommitSessionState::from_prepare(value, push) else {
            self.error = Some(SharedString::from(tr("Commit failed")));
            cx.notify();
            return;
        };
        let needs_review = state.requires_confirmation || !state.pending_questions.is_empty();
        let finished = state.finished;
        self.commit_session = Some(state);
        if needs_review {
            // Review 卡与推送目标追问都在提交区覆盖层呈现；确认后再逐步执行。
            cx.notify();
            return;
        }
        if finished {
            self.finish_commit_session(cx);
        } else {
            self.step_commit_session(cx);
        }
    }

    /// Review 卡确认：开始逐仓库执行。
    pub(crate) fn confirm_commit_review(&mut self, cx: &mut gpui_kit::Context<Self>) {
        let Some(session) = self.commit_session.as_mut() else {
            return;
        };
        session.review_visible = false;
        if session.finished {
            self.finish_commit_session(cx);
        } else {
            self.step_commit_session(cx);
        }
    }

    /// 关闭 Review 卡：放弃本次提交计划。
    pub(crate) fn dismiss_commit_review(&mut self, cx: &mut gpui_kit::Context<Self>) {
        if self.commit_session.take().is_some() {
            cx.notify();
        }
    }

    /// 会话进行中请求停止：下一个 step 完成前不再继续（对齐 Tauri Stop）。
    pub(crate) fn stop_commit_session(&mut self, cx: &mut gpui_kit::Context<Self>) {
        if let Some(session) = self.commit_session.as_mut() {
            session.cancel_requested = true;
            cx.notify();
        }
    }

    /// 关闭已结束的会话（Dismiss）。
    pub(crate) fn dismiss_commit_session(&mut self, cx: &mut gpui_kit::Context<Self>) {
        if self.commit_session.take().is_some() {
            cx.notify();
        }
    }

    /// 重试失败会话：把当前 Session 作为 `previous` 传给 prepare，继承结果。
    pub(crate) fn retry_commit_session(&mut self, cx: &mut gpui_kit::Context<Self>) {
        let Some(session) = self.commit_session.as_mut() else {
            return;
        };
        if session.busy || !session.can_retry {
            return;
        }
        session.busy = true;
        let previous = session.session.clone();
        let push = session.push;
        let message = session.plan_message();
        let amend = session.plan_amend();
        let include_parent_references = session.plan_include_parent_references();
        let generation = self.generation;
        let client = self.client;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let payload = serde_json::json!({
                "repositories": [{ "id": "." }],
                "message": message,
                "amend": amend,
                "push": push,
                "includeParentReferences": include_parent_references,
                "previous": previous,
            });
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, "git.workspaceCommitPrepare", payload)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                if let Some(session) = this.commit_session.as_mut() {
                    session.busy = false;
                }
                match raw {
                    Ok(value) => this.begin_commit_session(value, push, cx),
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 回答推送目标追问（对齐 git-push-target-prompt.tsx）：
    /// 用确认的目的地重新 prepare，Core 把答案写进计划的 push_targets。
    pub(crate) fn answer_push_target(
        &mut self,
        repository_id: String,
        choice: &'static str,
        cx: &mut gpui_kit::Context<Self>,
    ) {
        let Some(session) = self.commit_session.as_mut() else {
            return;
        };
        let Some(question) = session
            .pending_questions
            .iter()
            .find(|question| question.repository_id == repository_id)
            .cloned()
        else {
            return;
        };
        session.busy = true;
        let previous = session.session.clone();
        let push = session.push;
        let message = session.plan_message();
        let amend = session.plan_amend();
        let generation = self.generation;
        let client = self.client;
        let include_parent_references = session.plan_include_parent_references();
        // 键是仓库 id（Core 的 `pushTargets` 是 `{ repositoryId: … }` 映射）。
        // `json!` 的键只接受字面量，动态键必须显式构造 Map。
        let mut push_targets = serde_json::Map::new();
        push_targets.insert(
            repository_id.clone(),
            serde_json::json!({
                "choice": choice,
                "remote": question.remote,
                "remoteBranch": question.upstream_branch,
            }),
        );
        let push_targets = Value::Object(push_targets);
        cx.notify();

        cx.spawn(async move |this, cx| {
            let payload = serde_json::json!({
                "repositories": [{ "id": "." }],
                "message": message,
                "amend": amend,
                "push": push,
                "pushTargets": push_targets,
                "includeParentReferences": include_parent_references,
                "previous": previous,
            });
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, "git.workspaceCommitPrepare", payload)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                if let Some(session) = this.commit_session.as_mut() {
                    session.busy = false;
                }
                match raw {
                    Ok(value) => this.begin_commit_session(value, push, cx),
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 执行一个 step：每次至多提交 / 推送一个仓库，结果回传后继续下一个。
    pub(crate) fn step_commit_session(&mut self, cx: &mut gpui_kit::Context<Self>) {
        let Some(session) = self.commit_session.as_mut() else {
            return;
        };
        if session.busy {
            return;
        }
        session.busy = true;
        let payload = serde_json::json!({ "session": session.session.clone() });
        let generation = self.generation;
        let client = self.client;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, "git.workspaceCommitStep", payload)
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                let Some(session) = this.commit_session.as_mut() else {
                    return;
                };
                session.busy = false;
                match raw {
                    Ok(value) => {
                        session.apply_step(&value);
                        if session.cancel_requested && !session.finished {
                            // 用户点了 Stop：保留已完成的结果，不再继续。
                            session.stopped = true;
                            cx.notify();
                            return;
                        }
                        if session.finished {
                            this.finish_commit_session(cx);
                        } else {
                            // 继续下一个仓库；先 notify 让本步结果上屏。
                            cx.notify();
                            this.step_commit_session(cx);
                        }
                    }
                    Err(error) => {
                        session.command_failed = true;
                        this.error = Some(SharedString::from(error.to_string()));
                        cx.notify();
                    }
                }
            });
        })
        .detach();
    }

    /// 会话结束：复位 Amend、清空消息、刷新面板并提示。
    fn finish_commit_session(&mut self, cx: &mut gpui_kit::Context<Self>) {
        let (succeeded, push) = match self.commit_session.as_ref() {
            Some(session) => (session.succeeded, session.push),
            None => return,
        };
        if succeeded {
            self.pending_clear_message = true;
            self.amend = false;
            self.reload_all(cx);
            self.notice = Some(SharedString::from(if push {
                tr("Committed and pushed")
            } else {
                tr("Commit created")
            }));
        } else {
            self.error = Some(SharedString::from(tr("Commit changes failed")));
        }
        cx.notify();
    }

    // -----------------------------------------------------------------------
    // 旧 Core 的回退提交路径（保留 plan §4.E-3 要求的 fallback）
    // -----------------------------------------------------------------------

    /// 单命令提交（`git.command ["commit", ...]`）；流水线不可用时的回退。
    fn legacy_commit(&mut self, amend: bool, push: bool, cx: &mut gpui_kit::Context<Self>) {
        let Some(input) = self.commit_input.clone() else {
            return;
        };
        let message = input.read(cx).value().trim().to_string();
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root_text(&root) else {
            return;
        };
        if self.committing || self.pending_action.is_some() {
            return;
        }

        // Amend 只是同一个命令的参数变体；命令边界仍是参数数组，不经过 shell。
        let mut arguments = vec!["commit".to_string()];
        if amend {
            arguments.push("--amend".to_string());
        }
        arguments.extend(["-m".to_string(), message]);

        let generation = self.generation;
        let client = self.client;
        self.committing = true;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, 
                        "git.command",
                        serde_json::json!({
                            "root": root_text,
                            "arguments": arguments,
                        }),
                    )
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.committing = false;
                match raw {
                    Ok(value) => match parse_command(&value) {
                        Ok(command) if command.exit_code == 0 => {
                            this.pending_clear_message = true;
                            // 提交成功即复位 Amend，后续提交恢复普通命令。
                            this.amend = false;
                            this.reload_all(cx);
                            if push {
                                this.push_after_commit(cx);
                            } else {
                                this.notice = Some(SharedString::from(tr("Commit created")));
                            }
                        }
                        Ok(command) => {
                            this.error = Some(SharedString::from(command_failure_detail(
                                &command,
                                tr("Commit failed"),
                            )));
                        }
                        Err(message) => {
                            this.error = Some(SharedString::from(message));
                        }
                    },
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 提交成功之后的推送步骤（回退路径）。失败时保留「已提交」的事实。
    fn push_after_commit(&mut self, cx: &mut gpui_kit::Context<Self>) {
        let Some(root) = self.root.clone() else {
            self.notice = Some(SharedString::from(tr("Commit created")));
            return;
        };
        let Some(root_text) = root_text(&root) else {
            self.notice = Some(SharedString::from(tr("Commit created")));
            return;
        };

        let generation = self.generation;
        let client = self.client;
        self.committing = true;
        self.notice = Some(SharedString::from(tr("Committed; push pending")));

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, 
                        "git.command",
                        serde_json::json!({
                            "root": root_text,
                            "arguments": ["push"],
                        }),
                    )
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.committing = false;
                match raw {
                    Ok(value) => match parse_command(&value) {
                        Ok(command) if command.exit_code == 0 => {
                            this.notice = Some(SharedString::from(tr("Committed and pushed")));
                            this.error = None;
                        }
                        Ok(command) => {
                            this.error = Some(SharedString::from(command_failure_detail(
                                &command,
                                tr("Push failed"),
                            )));
                            this.notice = Some(SharedString::from(tr("Commit created")));
                        }
                        Err(message) => {
                            this.error = Some(SharedString::from(message));
                            this.notice = Some(SharedString::from(tr("Commit created")));
                        }
                    },
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                        this.notice = Some(SharedString::from(tr("Commit created")));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
}
