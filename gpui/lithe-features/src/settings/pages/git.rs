//! Git 页：集成开关、视图选项、fetch 默认值、Git 执行设置与 Git 身份。
//!
//! Git 执行设置与 Git 身份是 Source-backed：经 `CoreClient::execute_raw` 读
//! `git.executionInspect` / `git.command`，写入用 `git.executionConfigure` /
//! `git.command`，保存带 `expectedValues` 并发保护（Core
//! `git/configuration.rs` 的 allowlist 契约），全部阻塞调用走
//! `background_spawn` + generation 丢弃过期结果。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenu, PopupMenuItem};
use gpui_kit::component::{Disableable as _, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, ClickEvent, Context, Entity, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled, Window, div, px,
};
use lithe_core_client::CoreClient;
use lithe_ui::i18n::tr;
use lithe_ui::LitheMetrics;
use lithe_ui::LitheTokens;

use crate::settings::controls::{
    choice_row, note_card, project_root_label, readonly_row, section_card,
    string_or_placeholder, toggle_row,
};
use crate::settings::source_backed::CONFLICT_MESSAGE;
use crate::settings::state::{
    ChoiceAction, DIFF_VIEWS, FETCH_SUBMODULES, FETCH_TAGS, SETTINGS_BUTTON_HEIGHT,
    SETTINGS_BUTTON_RADIUS, SETTINGS_CONTROL_GAP, SETTINGS_SECTION_GAP, ToggleAction,
};
use crate::settings::SettingsView;

// ---------------------------------------------------------------------------
// Git 执行设置（Source-backed）
// ---------------------------------------------------------------------------

/// `git.executionInspect` 返回的一条配置条目。
#[derive(Clone, Debug, Default)]
struct GitConfigEntry {
    key: String,
    value: String,
    scope: String,
    origin: String,
    effective: bool,
}

/// Core 允许编辑的一个配置字段及其当前作用域内的已配置值。
#[derive(Clone, Debug, Default)]
struct GitConfigField {
    key: String,
    choices: Vec<String>,
    configured_values: Vec<String>,
}

/// fetch 生效选项与来源标注。
#[derive(Clone, Debug, Default)]
struct GitFetchPresentation {
    prune: Option<bool>,
    submodules: Option<String>,
    tags: Option<String>,
    prune_source: Option<String>,
    submodules_source: Option<String>,
    tags_source: Option<String>,
}

/// Git 执行设置页状态。
///
/// `pub(in crate::settings)`：`settings/mod.rs`（`pages` 的父模块）要在
/// `SettingsView` 字段里持有它；`pub(super)` 只覆盖 `pages` 一层。
pub(in crate::settings) struct GitExecutionState {
    generation: u64,
    loading: bool,
    loaded: bool,
    saving: bool,
    /// UI 选择的检查/写入作用域；`"local"` 或 `"global"`。
    scope: String,
    executable: Option<String>,
    version: Option<String>,
    entries: Vec<GitConfigEntry>,
    fields: Vec<GitConfigField>,
    temporary_config: Vec<(String, String)>,
    fetch: GitFetchPresentation,
    credential_helper: Option<bool>,
    error: Option<String>,
    save_error: Option<String>,
    /// 最近一次保存成功的提示；任何刷新/重载都会清空。
    notice: Option<String>,
    conflict: bool,
    advanced_open: bool,
}

impl GitExecutionState {
    pub(in crate::settings) fn new() -> Self {
        Self {
            generation: 0,
            loading: false,
            loaded: false,
            saving: false,
            scope: "local".to_string(),
            executable: None,
            version: None,
            entries: Vec::new(),
            fields: Vec::new(),
            temporary_config: Vec::new(),
            fetch: GitFetchPresentation::default(),
            credential_helper: None,
            error: None,
            save_error: None,
            notice: None,
            conflict: false,
            advanced_open: false,
        }
    }
}

// ---------------------------------------------------------------------------
// Git 身份（Source-backed）
// ---------------------------------------------------------------------------

/// 一个身份字段的发现值；草稿保存在输入框实体里，保存时读取。
type GitIdentityField = Option<String>;

/// Git 身份页状态。
pub(in crate::settings) struct GitIdentityState {
    generation: u64,
    loading: bool,
    loaded: bool,
    busy: bool,
    scope: String,
    name: GitIdentityField,
    email: GitIdentityField,
    error: Option<String>,
    notice: Option<String>,
    conflict: bool,
}

impl GitIdentityState {
    pub(in crate::settings) fn new() -> Self {
        Self {
            generation: 0,
            loading: false,
            loaded: false,
            busy: false,
            scope: "local".to_string(),
            name: GitIdentityField::default(),
            email: GitIdentityField::default(),
            error: None,
            notice: None,
            conflict: false,
        }
    }
}

impl SettingsView {
    pub(in crate::settings) fn render_git(&mut self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        // Source-backed 分区在首次渲染时发现；项目切换后 set_context 会重置。
        self.ensure_git_sources_loaded(cx);

        let context = div()
            .w_full()
            .flex()
            .flex_col()
            .child(readonly_row(
                "Project",
                project_root_label(self.context.project_root.as_ref()),
                tokens,
            ))
            .child(readonly_row(
                "Branch",
                string_or_placeholder(&self.context.branch, "Not available"),
                tokens,
            ));

        let integration = div()
            .w_full()
            .flex()
            .flex_col()
            .child(toggle_row(
                "Git Integration",
                "lithe-settings:git-integration",
                self.settings.git_integration,
                ToggleAction::GitIntegration,
                cx,
                tokens,
            ))
            .child(toggle_row(
                "Auto Refresh Git Status",
                "lithe-settings:git-auto-refresh",
                self.settings.git_auto_refresh,
                ToggleAction::GitAutoRefresh,
                cx,
                tokens,
            ))
            .child(toggle_row(
                "Confirm Before Discard",
                "lithe-settings:git-confirm-discard",
                self.settings.git_confirm_discard,
                ToggleAction::GitConfirmDiscard,
                cx,
                tokens,
            ));

        let view = div()
            .w_full()
            .flex()
            .flex_col()
            .child(toggle_row(
                "Folder-Based Changes",
                "lithe-settings:git-folder-view",
                self.settings.git_changes_folder_view,
                ToggleAction::GitFolderView,
                cx,
                tokens,
            ))
            .child(toggle_row(
                "Show Untracked Files",
                "lithe-settings:git-untracked",
                self.settings.git_show_untracked,
                ToggleAction::GitUntracked,
                cx,
                tokens,
            ))
            .child(toggle_row(
                "Show Staged First",
                "lithe-settings:git-staged-first",
                self.settings.git_show_staged_first,
                ToggleAction::GitStagedFirst,
                cx,
                tokens,
            ))
            // 对齐 Tauri `showGitChangelists`：本地 changelist 分组显示开关。
            .child(toggle_row(
                "Show Changelists",
                "lithe-settings:git-changelists",
                self.settings.show_git_changelists,
                ToggleAction::GitChangelists,
                cx,
                tokens,
            ))
            .child(toggle_row(
                "Open Diff On Click",
                "lithe-settings:git-open-diff",
                self.settings.git_open_diff_on_click,
                ToggleAction::GitOpenDiff,
                cx,
                tokens,
            ))
            .child(toggle_row(
                "Compact Git Status Badges",
                "lithe-settings:git-compact-badges",
                self.settings.git_compact_badges,
                ToggleAction::GitCompactBadges,
                cx,
                tokens,
            ))
            .child(toggle_row(
                "Collapse Empty Sections",
                "lithe-settings:git-collapse-empty",
                self.settings.git_collapse_empty,
                ToggleAction::GitCollapseEmpty,
                cx,
                tokens,
            ))
            .child(choice_row(
                "Default Diff View",
                "lithe-settings:git-diff-view",
                &DIFF_VIEWS,
                &self.settings.git_default_diff_view,
                ChoiceAction::GitDiffView,
                cx,
                tokens,
            ));

        let inline = div()
            .w_full()
            .flex()
            .flex_col()
            .child(toggle_row(
                "Enable Inline Blame",
                "lithe-settings:git-inline-blame",
                self.settings.git_inline_blame,
                ToggleAction::GitInlineBlame,
                cx,
                tokens,
            ))
            .child(toggle_row(
                "Enable Git Gutter",
                "lithe-settings:git-gutter",
                self.settings.git_gutter,
                ToggleAction::GitGutter,
                cx,
                tokens,
            ));

        let fetch = div()
            .w_full()
            .flex()
            .flex_col()
            .child(toggle_row(
                "Prune stale remote-tracking references",
                "lithe-settings:git-fetch-prune",
                self.settings.git_fetch_prune,
                ToggleAction::GitFetchPrune,
                cx,
                tokens,
            ))
            .child(choice_row(
                "Fetch submodules",
                "lithe-settings:git-fetch-submodules",
                &FETCH_SUBMODULES,
                &self.settings.git_fetch_submodules,
                ChoiceAction::GitFetchSubmodules,
                cx,
                tokens,
            ))
            .child(choice_row(
                "Fetch tags",
                "lithe-settings:git-fetch-tags",
                &FETCH_TAGS,
                &self.settings.git_fetch_tags,
                ChoiceAction::GitFetchTags,
                cx,
                tokens,
            ));

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                "Repository",
                None,
                context.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Git integration",
                None,
                integration.into_any_element(),
                tokens,
            ))
            .child(section_card("View", None, view.into_any_element(), tokens))
            .child(section_card(
                "Inline",
                None,
                inline.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Fetch defaults",
                None,
                fetch.into_any_element(),
                tokens,
            ))
            .child(self.render_git_execution(tokens, cx))
            .child(self.render_git_identity(tokens, cx))
            .into_any_element()
    }

    // -----------------------------------------------------------------
    // Git 开关写入（含 fetch prune↔tags 联动）
    // -----------------------------------------------------------------

    pub(in crate::settings) fn set_git_default_diff_view(
        &mut self,
        value: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.git_default_diff_view == value {
            return;
        }
        self.settings.git_default_diff_view = value.to_string();
        self.commit(window, cx);
    }

    pub(in crate::settings) fn set_git_fetch_submodules(
        &mut self,
        value: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.git_fetch_submodules == value {
            return;
        }
        self.settings.git_fetch_submodules = value.to_string();
        self.commit(window, cx);
    }

    /// Tauri `git-settings.tsx` 的联动：tags 选 prune 时强制 prune 开。
    pub(in crate::settings) fn set_git_fetch_tags(
        &mut self,
        value: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.git_fetch_tags == value {
            return;
        }
        self.settings.git_fetch_tags = value.to_string();
        if value == "prune" && !self.settings.git_fetch_prune {
            self.settings.git_fetch_prune = true;
        }
        self.commit(window, cx);
    }

    // -----------------------------------------------------------------
    // Git 执行设置：发现 → 回显 → 草稿/选择 → 确认写入（expectedValues）→ 回读
    // -----------------------------------------------------------------

    fn ensure_git_sources_loaded(&mut self, cx: &mut Context<Self>) {
        if !self.git_execution.loaded && !self.git_execution.loading {
            self.reload_git_execution(cx);
        }
        if !self.git_identity.loaded && !self.git_identity.loading {
            self.reload_git_identity(cx);
        }
    }

    /// 项目切换后重置 Git 执行/身份的发现缓存；下一次渲染重新发现。
    pub(in crate::settings) fn reset_git_sources(&mut self) {
        self.git_execution = GitExecutionState::new();
        self.git_identity = GitIdentityState::new();
        self.git_identity_pending_inputs = None;
    }

    /// 重新执行 `git.executionInspect`；scope 切换或用户点“重新加载”时调用。
    pub(in crate::settings) fn reload_git_execution(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.context.project_root.clone() else {
            self.git_execution = GitExecutionState::new();
            cx.notify();
            return;
        };
        let Some(root_text) = root.to_str().map(str::to_string) else {
            self.git_execution.error = Some(tr("Project path is not valid UTF-8").to_string());
            cx.notify();
            return;
        };
        self.git_execution.generation = self.git_execution.generation.wrapping_add(1);
        let generation = self.git_execution.generation;
        let scope = self.git_execution.scope.clone();
        self.git_execution.loading = true;
        self.git_execution.error = None;
        cx.notify();

        let client = CoreClient::new();
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_executor().spawn(async move {
                    client.execute_raw(
                        "git.executionInspect",
                        serde_json::json!({ "root": root_text, "scope": scope }),
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.git_execution.generation != generation {
                    return;
                }
                this.git_execution.loading = false;
                this.git_execution.loaded = true;
                match raw {
                    Ok(value) => {
                        apply_git_execution_inspect(&mut this.git_execution, &value);
                        cx.notify();
                    }
                    Err(error) => {
                        this.git_execution.error = Some(error.to_string());
                        cx.notify();
                    }
                }
            });
        })
        .detach();
    }

    /// 保存一个白名单字段；`value` 为 `None` 表示清除（unset-all）。
    fn configure_git_field(&mut self, key: String, value: Option<String>, cx: &mut Context<Self>) {
        let Some(root) = self.context.project_root.clone() else {
            return;
        };
        let Some(root_text) = root.to_str().map(str::to_string) else {
            return;
        };
        if self.git_execution.saving {
            return;
        }
        // expectedValues 取发现时的 configuredValues 快照；并发修改时 Core 拒绝。
        let Some(expected) = self
            .git_execution
            .fields
            .iter()
            .find(|field| field.key == key)
            .map(|field| field.configured_values.clone())
        else {
            return;
        };
        self.git_execution.generation = self.git_execution.generation.wrapping_add(1);
        let generation = self.git_execution.generation;
        let scope = self.git_execution.scope.clone();
        self.git_execution.saving = true;
        self.git_execution.save_error = None;
        self.git_execution.conflict = false;
        cx.notify();

        let mut payload = serde_json::json!({
            "root": root_text,
            "scope": scope,
            "key": key,
            "expectedValues": expected,
        });
        if let Some(value) = value {
            payload["value"] = serde_json::Value::String(value);
        }
        let client = CoreClient::new();
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_executor().spawn(async move {
                    client.execute_raw("git.executionConfigure", payload)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.git_execution.generation != generation {
                    return;
                }
                this.git_execution.saving = false;
                match raw {
                    Ok(value) => {
                        // 写入成功后 Core 直接回读同 scope 的 inspect。
                        apply_git_execution_inspect(&mut this.git_execution, &value);
                        this.git_execution.notice = Some(tr("Git configuration saved.").to_string());
                        cx.notify();
                    }
                    Err(error) => {
                        let text = error.to_string();
                        this.git_execution.conflict = text.contains("reload");
                        this.git_execution.save_error = Some(text);
                        cx.notify();
                    }
                }
            });
        })
        .detach();
    }

    pub(in crate::settings) fn set_git_execution_scope(&mut self, scope: &'static str, cx: &mut Context<Self>) {
        if self.git_execution.scope == scope {
            return;
        }
        self.git_execution.scope = scope.to_string();
        self.git_execution.advanced_open = true;
        self.reload_git_execution(cx);
    }

    pub(in crate::settings) fn toggle_git_execution_advanced(&mut self, cx: &mut Context<Self>) {
        self.git_execution.advanced_open = !self.git_execution.advanced_open;
        cx.notify();
    }

    fn render_git_execution(
        &mut self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // 先拷贝需要的快照，避免跨可变方法调用持有字段借用。
        let loading = self.git_execution.loading;
        let error = self.git_execution.error.clone();
        let advanced_open = self.git_execution.advanced_open;
        let conflict = self.git_execution.conflict;
        let save_error = self.git_execution.save_error.clone();
        let executable = self
            .git_execution
            .executable
            .clone()
            .unwrap_or_else(|| tr("Git executable not found").to_string());
        let version = self.git_execution.version.clone().unwrap_or_default();
        let credential_helper = match self.git_execution.credential_helper {
            Some(true) => tr("On").to_string(),
            Some(false) => tr("Off").to_string(),
            None => tr("Unknown").to_string(),
        };

        let mut body = v_flex().w_full().gap(px(SETTINGS_CONTROL_GAP));

        if self.context.project_root.is_none() {
            body = body.child(note_card(
                SharedString::from(tr("Open a project to inspect the Git executable and repository configuration.")),
                tokens,
            ));
            return section_card("Git execution", None, body.into_any_element(), tokens);
        }
        if loading {
            body = body.child(note_card(SharedString::from(tr("Working…")), tokens));
            return section_card("Git execution", None, body.into_any_element(), tokens);
        }
        if let Some(error) = error {
            body = body.child(error_line(&error, tokens));
        }

        // 可执行文件与版本快照（Core `git.executable` 解析结果，只读）。
        // Core 没有暴露修改可执行路径的命令，这里诚实只读。
        body = body
            .child(readonly_row("Git executable", SharedString::from(executable), tokens))
            .child(readonly_row(
                "Git version",
                string_or_placeholder(&version, "Unknown"),
                tokens,
            ))
            .child(readonly_row(
                "Credential helper",
                SharedString::from(credential_helper),
                tokens,
            ));

        // 高级折叠区：scope 切换、生效 fetch 选项与来源、白名单字段编辑、
        // 配置条目列表与重新加载。
        body = body.child(
            Button::new("lithe-settings:git-execution-advanced")
                .small()
                .h(px(SETTINGS_BUTTON_HEIGHT))
                .rounded(px(SETTINGS_BUTTON_RADIUS))
                .ghost()
                .label(if advanced_open {
                    tr("Hide advanced settings")
                } else {
                    tr("Show advanced settings")
                })
                .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                    this.toggle_git_execution_advanced(cx);
                })),
        );

        if advanced_open {
            let mut advanced = v_flex().w_full().gap(px(SETTINGS_CONTROL_GAP));
            advanced = advanced.child(self.render_git_execution_scope(tokens, cx));
            advanced = advanced.child(self.render_git_fetch_effective(tokens));
            advanced = advanced.child(self.render_git_fields(tokens, cx));
            advanced = advanced.child(self.render_git_entries(tokens));
            advanced = advanced.child(self.render_git_temporary_config(tokens));
            body = body.child(advanced);
        }

        if conflict {
            body = body.child(
                h_flex()
                    .w_full()
                    .items_center()
                    .justify_between()
                    .gap(px(SETTINGS_CONTROL_GAP))
                    .child(error_line(&CONFLICT_MESSAGE.to_string(), tokens))
                    .child(
                        Button::new("lithe-settings:git-execution-reload")
                            .small()
                            .h(px(SETTINGS_BUTTON_HEIGHT))
                            .rounded(px(SETTINGS_BUTTON_RADIUS))
                            .secondary()
                            .label(tr("Reload"))
                            .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                                this.reload_git_execution(cx);
                            })),
                    ),
            );
        }
        if let Some(error) = save_error {
            if !conflict {
                body = body.child(error_line(&error, tokens));
            }
        }
        if let Some(notice) = self.git_execution.notice.clone() {
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(SharedString::from(notice)),
            );
        }

        section_card("Git execution", None, body.into_any_element(), tokens)
    }

    /// 检查作用域切换：local 写仓库配置，global 写用户配置。
    fn render_git_execution_scope(
        &mut self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let scopes: [(&str, &str); 2] = [("local", "This repository"), ("global", "This computer")];
        let mut controls = h_flex().flex_wrap().gap(px(SETTINGS_CONTROL_GAP));
        for &(value, title) in &scopes {
            let is_selected = self.git_execution.scope == value;
            controls = controls.child(
                Button::new(format!("lithe-settings:git-execution-scope:{value}"))
                    .small()
                    .h(px(SETTINGS_BUTTON_HEIGHT))
                    .rounded(px(SETTINGS_BUTTON_RADIUS))
                    .min_w(px(SETTINGS_BUTTON_HEIGHT * 3.0))
                    .when(is_selected, |button| button.primary())
                    .when(!is_selected, |button| button.secondary())
                    .label(tr(title))
                    .on_click(cx.listener(move |this, _: &ClickEvent, _window, cx| {
                        this.set_git_execution_scope(value, cx);
                    })),
            );
        }
        div()
            .w_full()
            .flex()
            .flex_wrap()
            .items_center()
            .gap_x(px(8.0))
            .gap_y(px(4.0))
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.primary_text)
                    .child(tr("Configuration scope")),
            )
            .child(controls)
            .into_any_element()
    }

    /// 生效 fetch 选项 + 来源标注（Core `fetchOptions` / `fetchSources`）。
    fn render_git_fetch_effective(&self, tokens: LitheTokens) -> AnyElement {
        let fetch = &self.git_execution.fetch;
        let mut body = v_flex().w_full().gap(px(2.0)).child(section_subtitle(
            tr("Effective fetch options").to_string(),
            tokens,
        ));
        for (label, value, source) in [
            (
                tr("Prune stale remote-tracking references").to_string(),
                fetch
                    .prune
                    .map(|value| if value { tr("On").to_string() } else { tr("Off").to_string() })
                    .unwrap_or_else(|| tr("Unknown").to_string()),
                fetch.prune_source.clone(),
            ),
            (
                tr("Fetch submodules").to_string(),
                fetch.submodules.clone().unwrap_or_else(|| tr("Unknown").to_string()),
                fetch.submodules_source.clone(),
            ),
            (
                tr("Fetch tags").to_string(),
                fetch.tags.clone().unwrap_or_else(|| tr("Unknown").to_string()),
                fetch.tags_source.clone(),
            ),
        ] {
            let mut line = format!("{}: {}", label, value);
            if let Some(source) = source {
                if !source.is_empty() {
                    line.push_str(&format!(" · {}", source));
                }
            }
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(SharedString::from(line)),
            );
        }
        body.into_any_element()
    }

    /// 白名单字段的草稿选择与保存（expectedValues 冲突保护在写入层）。
    fn render_git_fields(&mut self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let mut body = v_flex().w_full().gap(px(SETTINGS_CONTROL_GAP)).child(
            section_subtitle(tr("Repository preferences").to_string(), tokens),
        );
        let fields = self.git_execution.fields.clone();
        for field in &fields {
            let configured = if field.configured_values.is_empty() {
                tr("Not configured").to_string()
            } else {
                field.configured_values.join(", ")
            };
            let owner = cx.weak_entity();
            let key = field.key.clone();
            let choices = field.choices.clone();
            body = body.child(
                v_flex()
                    .w_full()
                    .gap(px(2.0))
                    .child(
                        h_flex()
                            .w_full()
                            .items_center()
                            .gap(px(SETTINGS_CONTROL_GAP))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w(px(0.0))
                                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                                    .text_color(tokens.primary_text)
                                    .child(SharedString::from(field.key.clone())),
                            )
                            .child(
                                Button::new(SharedString::from(format!(
                                    "lithe-settings:git-field:{}",
                                    field.key
                                )))
                                .small()
                                .h(px(SETTINGS_BUTTON_HEIGHT))
                                .rounded(px(SETTINGS_BUTTON_RADIUS))
                                .secondary()
                                .label(SharedString::from(configured))
                                .dropdown_menu(move |menu: PopupMenu, _, _| {
                                    let mut menu = menu;
                                    for choice in &choices {
                                        let owner = owner.clone();
                                        let key = key.clone();
                                        let choice = choice.clone();
                                        menu = menu.item(
                                            PopupMenuItem::new(SharedString::from(choice.clone()))
                                                .on_click(move |_, _, cx| {
                                                    let _ = owner.update(cx, |this, cx| {
                                                        this.configure_git_field(
                                                            key.clone(),
                                                            Some(choice.clone()),
                                                            cx,
                                                        );
                                                    });
                                                }),
                                        );
                                    }
                                    // 清除（unset）：只在已配置时提供。
                                    let owner = owner.clone();
                                    let key = key.clone();
                                    menu.item(
                                        PopupMenuItem::new(tr("Clear"))
                                            .on_click(move |_, _, cx| {
                                                let _ = owner.update(cx, |this, cx| {
                                                    this.configure_git_field(
                                                        key.clone(),
                                                        None,
                                                        cx,
                                                    );
                                                });
                                            }),
                                    )
                                }),
                            ),
                    )
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.tertiary_text)
                            .child(SharedString::from(field.choices.join(" / "))),
                    ),
            );
        }
        body.into_any_element()
    }

    /// 配置条目列表：只读展示 Git 原始优先级顺序（来源脱敏由 Core 完成）。
    fn render_git_entries(&self, tokens: LitheTokens) -> AnyElement {
        let mut body = v_flex()
            .id("lithe-settings:git-entries")
            .w_full()
            .max_h(px(220.0))
            .overflow_y_scroll()
            .gap(px(2.0))
            .child(section_subtitle(tr("Configuration entries").to_string(), tokens));
        if self.git_execution.entries.is_empty() {
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(tr("No readable Git configuration entries.")),
            );
        }
        for entry in &self.git_execution.entries {
            let mut line = format!("{} = {}", entry.key, entry.value);
            if entry.effective {
                line.push_str(&format!(" · {} · {}", entry.scope, entry.origin));
            }
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(if entry.effective {
                        tokens.primary_text
                    } else {
                        tokens.tertiary_text
                    })
                    .child(SharedString::from(line)),
            );
        }
        body.into_any_element()
    }

    /// Core 在每次 git 调用上叠加的临时配置（只读说明）。
    fn render_git_temporary_config(&self, tokens: LitheTokens) -> AnyElement {
        let mut body = v_flex()
            .w_full()
            .gap(px(2.0))
            .child(section_subtitle(tr("Temporary Git configuration").to_string(), tokens));
        if self.git_execution.temporary_config.is_empty() {
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(tr("None")),
            );
        }
        for (key, value) in &self.git_execution.temporary_config {
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(SharedString::from(format!("{key} = {value}"))),
            );
        }
        body.into_any_element()
    }

    // -----------------------------------------------------------------
    // Git 身份：scope local/global，读 → 草稿 → 保存/清除 → 回读
    // -----------------------------------------------------------------

    pub(in crate::settings) fn reload_git_identity(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.context.project_root.clone() else {
            self.git_identity = GitIdentityState::new();
            cx.notify();
            return;
        };
        let Some(root_text) = root.to_str().map(str::to_string) else {
            self.git_identity.error = Some(tr("Project path is not valid UTF-8").to_string());
            cx.notify();
            return;
        };
        self.git_identity.generation = self.git_identity.generation.wrapping_add(1);
        let generation = self.git_identity.generation;
        let scope = self.git_identity.scope.clone();
        self.git_identity.loading = true;
        self.git_identity.error = None;
        cx.notify();

        let client = CoreClient::new();
        cx.spawn(async move |this, cx| {
            let flag = if scope == "global" { "--global" } else { "--local" };
            let raw = cx
                .background_executor().spawn(async move {
                    let name = client.execute_raw(
                        "git.command",
                        serde_json::json!({
                            "root": root_text,
                            "arguments": ["config", flag, "--get", "user.name"],
                        }),
                    );
                    let email = client.execute_raw(
                        "git.command",
                        serde_json::json!({
                            "root": root_text,
                            "arguments": ["config", flag, "--get", "user.email"],
                        }),
                    );
                    (name, email)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.git_identity.generation != generation {
                    return;
                }
                this.git_identity.loading = false;
                this.git_identity.loaded = true;
                match raw {
                    (Ok(name), Ok(email)) => {
                        this.git_identity.name = config_output_value(&name);
                        this.git_identity.email = config_output_value(&email);
                        // 输入框回填需要 Window，推迟到渲染帧应用（与 Maven
                        // 字段的 pending_inputs 同一模式）。
                        this.git_identity_pending_inputs = Some((
                            this.git_identity.name.clone().unwrap_or_default(),
                            this.git_identity.email.clone().unwrap_or_default(),
                        ));
                        this.git_identity.error = None;
                        this.git_identity.conflict = false;
                        cx.notify();
                    }
                    (Err(error), _) | (_, Err(error)) => {
                        this.git_identity.error = Some(error.to_string());
                        cx.notify();
                    }
                }
            });
        })
        .detach();
    }

    /// 保存或清除一个身份字段；成功后回读生效值（对齐 Tauri 分字段保存）。
    fn save_git_identity_field(&mut self, field: GitIdentityTarget, clear: bool, cx: &mut Context<Self>) {
        let Some(root) = self.context.project_root.clone() else {
            return;
        };
        let Some(root_text) = root.to_str().map(str::to_string) else {
            return;
        };
        if self.git_identity.busy {
            return;
        }
        // 草稿即输入框当前值；保存前从输入框读取（与 Maven 字段一致）。
        let value = match (field, clear) {
            (GitIdentityTarget::Name, false) => {
                self.git_identity_name_input.read(cx).value().trim().to_string()
            }
            (GitIdentityTarget::Email, false) => {
                self.git_identity_email_input.read(cx).value().trim().to_string()
            }
            (_, true) => String::new(),
        };
        if value.is_empty() && !clear {
            return;
        }
        let key = match field {
            GitIdentityTarget::Name => "user.name",
            GitIdentityTarget::Email => "user.email",
        };
        let flag = if self.git_identity.scope == "global" {
            "--global"
        } else {
            "--local"
        };
        let mut arguments = vec!["config".to_string(), flag.to_string()];
        if clear {
            arguments.push("--unset-all".to_string());
            arguments.push(key.to_string());
        } else {
            arguments.push(key.to_string());
            arguments.push(value);
        }

        self.git_identity.generation = self.git_identity.generation.wrapping_add(1);
        let generation = self.git_identity.generation;
        self.git_identity.busy = true;
        self.git_identity.error = None;
        self.git_identity.notice = None;
        self.git_identity.conflict = false;
        cx.notify();

        let client = CoreClient::new();
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_executor().spawn(async move {
                    client.execute_raw(
                        "git.command",
                        serde_json::json!({ "root": root_text, "arguments": arguments }),
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.git_identity.generation != generation {
                    return;
                }
                this.git_identity.busy = false;
                match raw {
                    Ok(value) => {
                        // exitCode 5 = 本来就没有该键；清除时同样视为成功。
                        let exit = value
                            .get("exitCode")
                            .and_then(serde_json::Value::as_i64)
                            .unwrap_or(-1);
                        if exit == 0 || (clear && exit == 5) {
                            this.git_identity.notice = Some(
                                if clear {
                                    tr("Git identity cleared.").to_string()
                                } else {
                                    tr("Git identity saved.").to_string()
                                },
                            );
                            this.reload_git_identity(cx);
                        } else {
                            let detail = value
                                .get("stderr")
                                .and_then(serde_json::Value::as_str)
                                .unwrap_or("git config failed");
                            this.git_identity.error = Some(detail.to_string());
                            cx.notify();
                        }
                    }
                    Err(error) => {
                        this.git_identity.error = Some(error.to_string());
                        cx.notify();
                    }
                }
            });
        })
        .detach();
    }

    pub(in crate::settings) fn set_git_identity_scope(&mut self, scope: &'static str, cx: &mut Context<Self>) {
        if self.git_identity.scope == scope {
            return;
        }
        self.git_identity.scope = scope.to_string();
        self.reload_git_identity(cx);
    }

    fn render_git_identity(&mut self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let mut body = v_flex().w_full().gap(px(SETTINGS_CONTROL_GAP)).child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(tr(
                    "The commit author for this repository or your user account.",
                )),
        );

        if self.context.project_root.is_none() {
            body = body.child(note_card(
                SharedString::from(tr("Open a project to edit the Git identity.")),
                tokens,
            ));
            return section_card("Git identity", None, body.into_any_element(), tokens);
        }

        // 作用域选择：local 写仓库配置，global 写用户配置。
        let scopes: [(&str, &str); 2] = [("local", "This repository"), ("global", "This computer")];
        let mut controls = h_flex().flex_wrap().gap(px(SETTINGS_CONTROL_GAP));
        for &(value, title) in &scopes {
            let is_selected = self.git_identity.scope == value;
            controls = controls.child(
                Button::new(format!("lithe-settings:git-identity-scope:{value}"))
                    .small()
                    .h(px(SETTINGS_BUTTON_HEIGHT))
                    .rounded(px(SETTINGS_BUTTON_RADIUS))
                    .min_w(px(SETTINGS_BUTTON_HEIGHT * 3.0))
                    .when(is_selected, |button| button.primary())
                    .when(!is_selected, |button| button.secondary())
                    .label(tr(title))
                    .on_click(cx.listener(move |this, _: &ClickEvent, _window, cx| {
                        this.set_git_identity_scope(value, cx);
                    })),
            );
        }
        body = body
            .child(controls)
            .child(self.render_git_identity_field(GitIdentityTarget::Name, "User name", tokens, cx))
            .child(self.render_git_identity_field(GitIdentityTarget::Email, "User email", tokens, cx));

        if self.git_identity.loading {
            body = body.child(note_card(SharedString::from(tr("Working…")), tokens));
        }
        if let Some(notice) = self.git_identity.notice.clone() {
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(SharedString::from(notice)),
            );
        }
        if let Some(error) = self.git_identity.error.clone() {
            body = body.child(error_line(&error, tokens));
        }

        section_card("Git identity", None, body.into_any_element(), tokens)
    }

    fn render_git_identity_field(
        &mut self,
        field: GitIdentityTarget,
        label: &'static str,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let (loaded, busy) = match field {
            GitIdentityTarget::Name => (self.git_identity.name.clone(), self.git_identity.busy),
            GitIdentityTarget::Email => (self.git_identity.email.clone(), self.git_identity.busy),
        };
        let input = self.git_identity_input(field).clone();
        let draft = input.read(cx).value().trim().to_string();
        let dirty = draft != loaded.as_deref().unwrap_or("").trim();
        let mut body = v_flex()
            .w_full()
            .gap(px(2.0))
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.primary_text)
                    .child(tr(label)),
            )
            .child(Input::new(&input).small().w_full())
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(match loaded.as_deref() {
                        Some(value) => SharedString::from(format!(
                            "{}: {}",
                            tr("In effect"),
                            value
                        )),
                        None => SharedString::from(tr("Not configured in this scope")),
                    }),
            )
            .child(
                h_flex()
                    .gap(px(SETTINGS_CONTROL_GAP))
                    .child(
                        Button::new(SharedString::from(format!(
                            "lithe-settings:git-identity-save:{}",
                            label
                        )))
                        .small()
                        .h(px(SETTINGS_BUTTON_HEIGHT))
                        .rounded(px(SETTINGS_BUTTON_RADIUS))
                        .primary()
                        .label(tr("Save"))
                        .disabled(busy || !dirty)
                        .on_click(cx.listener(move |this, _: &ClickEvent, _window, cx| {
                            this.save_git_identity_field(field, false, cx);
                        })),
                    )
                    .child(
                        Button::new(SharedString::from(format!(
                            "lithe-settings:git-identity-clear:{}",
                            label
                        )))
                        .small()
                        .h(px(SETTINGS_BUTTON_HEIGHT))
                        .rounded(px(SETTINGS_BUTTON_RADIUS))
                        .secondary()
                        .label(tr("Clear"))
                        .disabled(busy || loaded.is_none())
                        .on_click(cx.listener(move |this, _: &ClickEvent, _window, cx| {
                            this.save_git_identity_field(field, true, cx);
                        })),
                    ),
            );
        if dirty {
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.warning)
                    .child(tr("Unsaved changes")),
            );
        }
        body.into_any_element()
    }

    fn git_identity_input(&mut self, field: GitIdentityTarget) -> &Entity<InputState> {
        match field {
            GitIdentityTarget::Name => &self.git_identity_name_input,
            GitIdentityTarget::Email => &self.git_identity_email_input,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum GitIdentityTarget {
    Name,
    Email,
}

/// `git.command` 的成功输出 → 身份值；exitCode 1（未设置）返回 `None`。
fn config_output_value(raw: &serde_json::Value) -> Option<String> {
    let exit = raw.get("exitCode").and_then(serde_json::Value::as_i64)?;
    if exit != 0 {
        return None;
    }
    let output = raw.get("output").and_then(serde_json::Value::as_str)?;
    let trimmed = output.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

/// 解析 `git.executionInspect` 响应并回显到状态。
fn apply_git_execution_inspect(state: &mut GitExecutionState, value: &serde_json::Value) {
    state.executable = value
        .get("executable")
        .and_then(serde_json::Value::as_str)
        .map(str::to_string);
    state.version = value
        .get("version")
        .and_then(serde_json::Value::as_str)
        .map(str::to_string);
    state.entries = value
        .get("entries")
        .and_then(serde_json::Value::as_array)
        .map(|entries| {
            entries
                .iter()
                .map(|entry| GitConfigEntry {
                    key: string_at(entry, "key"),
                    value: string_at(entry, "value"),
                    scope: string_at(entry, "scope"),
                    origin: string_at(entry, "origin"),
                    effective: entry
                        .get("effective")
                        .and_then(serde_json::Value::as_bool)
                        .unwrap_or(false),
                })
                .collect()
        })
        .unwrap_or_default();
    state.fields = value
        .get("fields")
        .and_then(serde_json::Value::as_array)
        .map(|fields| {
            fields
                .iter()
                .map(|field| GitConfigField {
                    key: string_at(field, "key"),
                    choices: strings_at(field, "choices"),
                    configured_values: strings_at(field, "configuredValues"),
                })
                .collect()
        })
        .unwrap_or_default();
    state.temporary_config = value
        .get("temporaryConfig")
        .and_then(serde_json::Value::as_array)
        .map(|pairs| {
            pairs
                .iter()
                .filter_map(|pair| {
                    let array = pair.as_array()?;
                    Some((
                        array.first()?.as_str()?.to_string(),
                        array.get(1)?.as_str()?.to_string(),
                    ))
                })
                .collect()
        })
        .unwrap_or_default();
    state.credential_helper = value
        .get("credentialHelperEnabled")
        .and_then(serde_json::Value::as_bool);

    let options = value.get("fetchOptions");
    state.fetch.prune = options
        .and_then(|options| options.get("prune"))
        .and_then(serde_json::Value::as_bool);
    state.fetch.submodules = options
        .and_then(|options| options.get("submodules"))
        .and_then(serde_json::Value::as_str)
        .map(str::to_string);
    state.fetch.tags = options
        .and_then(|options| options.get("tags"))
        .and_then(serde_json::Value::as_str)
        .map(str::to_string);
    let sources = value.get("fetchSources");
    for (field, slot) in [
        ("prune", &mut state.fetch.prune_source),
        ("submodules", &mut state.fetch.submodules_source),
        ("tags", &mut state.fetch.tags_source),
    ] {
        *slot = sources
            .and_then(|sources| sources.get(field))
            .map(|source| {
                let scope = source
                    .get("scope")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("application");
                let origin = source
                    .get("origin")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("");
                if origin.is_empty() {
                    scope.to_string()
                } else {
                    format!("{scope} · {origin}")
                }
            });
    }
    state.error = None;
    state.save_error = None;
    state.notice = None;
}

fn string_at(value: &serde_json::Value, key: &str) -> String {
    value
        .get(key)
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn strings_at(value: &serde_json::Value, key: &str) -> Vec<String> {
    value
        .get(key)
        .and_then(serde_json::Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(serde_json::Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

/// 小节副标题。
fn section_subtitle(text: String, tokens: LitheTokens) -> AnyElement {
    div()
        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
        .font_weight(FontWeight::MEDIUM)
        .text_color(tokens.secondary_text)
        .child(SharedString::from(text))
        .into_any_element()
}

/// 错误行。
fn error_line(text: &str, tokens: LitheTokens) -> AnyElement {
    div()
        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
        .text_color(tokens.error)
        .child(SharedString::from(text.to_string()))
        .into_any_element()
}
