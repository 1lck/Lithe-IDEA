//! AI & Commit 页主体：Profile 管理、密钥、Codex/Claude 检测导入与规则区。
//!
//! 数据模型对齐 Tauri `features/git/types/ai-commit.ts`；检测解析直接复用共享
//! Core 的 `lithe_core::ai::parse_codex / parse_claude`（与 Tauri 宿主同源），
//! gpui 侧只做带 1MB 上限的文件读取。
//!
//! 密钥只保存在设置存储通道（`AppSettings`），界面是掩码输入 + “已存储”占位，
//! 绝不回显。popup 菜单回调拿不到 `Window`，因此需要写盘的选择与文本先挂
//! pending，由 [`SettingsView::apply_ai_commit_pending`] 在渲染帧统一提交——
//! 与 Maven/Git 身份输入框回填的 pending 模式同源。

use std::collections::BTreeMap;

use lithe_core::ai;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::checkbox::Checkbox;
use gpui_kit::component::input::Input;
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenu, PopupMenuItem};
use gpui_kit::component::{Disableable as _, Sizable as _, h_flex, v_flex};
use gpui_kit::{
    AnyElement, ClickEvent, Context, IntoElement, ParentElement as _, SharedString, Styled,
    Window, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens};

use crate::settings::controls::{choice_row, readonly_row, section_card, toggle_row};
use crate::settings::state::{
    AI_COMMIT_AUTHENTICATION, AI_COMMIT_EFFORTS, AI_COMMIT_LANGUAGES, AI_COMMIT_PROTOCOLS,
    AI_COMMIT_TOKEN_LIMIT_FIELDS, ChoiceAction, COMMIT_FORMATS, MAX_AI_COMMIT_PROFILES,
    SETTINGS_BUTTON_HEIGHT, SETTINGS_BUTTON_RADIUS, SETTINGS_CONTROL_GAP, SETTINGS_SECTION_GAP,
    ToggleAction,
};
use crate::settings::SettingsView;

/// Profile 文本的四个输入字段。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::settings) enum AiCommitTextField {
    Name,
    Endpoint,
    Model,
}

/// 数字输入字段。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::settings) enum AiCommitNumberField {
    Subject,
    Diff,
}

/// 检测到的外部配置摘要（不含凭据；Tauri `aiCommit.detected` 卡片语义）。
#[derive(Clone, Debug)]
pub(in crate::settings) struct DetectedCommitSource {
    pub(in crate::settings) source: String,
    pub(in crate::settings) name: String,
    pub(in crate::settings) endpoint: String,
    pub(in crate::settings) model: String,
    pub(in crate::settings) api_protocol: String,
    pub(in crate::settings) authentication: String,
    pub(in crate::settings) requires_api_key: bool,
    pub(in crate::settings) has_credential: bool,
}

/// 输入框回填值；密钥永远为空（不回显）。
#[derive(Clone, Debug, Default)]
pub(in crate::settings) struct AiCommitInputs {
    pub(in crate::settings) name: String,
    pub(in crate::settings) endpoint: String,
    pub(in crate::settings) model: String,
    pub(in crate::settings) subject: String,
    pub(in crate::settings) diff: String,
}

/// AI & Commit 页全部本地状态。
#[derive(Clone, Debug, Default)]
pub(in crate::settings) struct AiCommitState {
    pub(in crate::settings) generation: u64,
    pub(in crate::settings) detection_loading: bool,
    pub(in crate::settings) detected: Option<Vec<DetectedCommitSource>>,
    pub(in crate::settings) warnings: Vec<(String, String)>,
    pub(in crate::settings) notice: Option<String>,
    pub(in crate::settings) error: Option<String>,
    /// 首次进入页面时排队一次输入框回填。
    pub(in crate::settings) seeded: bool,
    // ---- pending：订阅 / 菜单回调没有 Window，写入在渲染帧 flush ----
    pub(in crate::settings) text_pending: Option<(AiCommitTextField, String)>,
    pub(in crate::settings) number_pending: Option<(AiCommitNumberField, String)>,
    pub(in crate::settings) pending_active_profile: Option<String>,
    pub(in crate::settings) pending_protocol: Option<&'static str>,
    pub(in crate::settings) pending_token_field: Option<&'static str>,
    pub(in crate::settings) pending_authentication: Option<&'static str>,
    pub(in crate::settings) pending_effort: Option<&'static str>,
    pub(in crate::settings) pending_custom: bool,
}

/// popup 选择回调里只拿 `Context<SettingsView>`，没有 `Window`；选择先按
/// 目标挂到对应 pending，渲染帧统一写盘。
impl AiCommitState {
    pub(in crate::settings) fn stage_choice(&mut self, target: AiCommitChoiceTarget, value: &'static str) {
        match target {
            AiCommitChoiceTarget::Protocol => self.pending_protocol = Some(value),
            AiCommitChoiceTarget::TokenField => self.pending_token_field = Some(value),
            AiCommitChoiceTarget::Authentication => self.pending_authentication = Some(value),
            AiCommitChoiceTarget::Effort => self.pending_effort = Some(value),
        }
    }
}


impl SettingsView {
    // -----------------------------------------------------------------
    // 渲染
    // -----------------------------------------------------------------

    pub(in crate::settings) fn render_ai_commit(
        &mut self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // 首次进入页面排队输入框回填 + 发现外部配置。
        if !self.ai_commit.seeded {
            self.ai_commit.seeded = true;
            self.queue_ai_commit_inputs();
        }
        if self.ai_commit.detected.is_none() && !self.ai_commit.detection_loading {
            self.detect_ai_commit_sources(cx);
        }

        let mut column = v_flex().w_full().gap(px(SETTINGS_SECTION_GAP));
        if let Some(notice) = self.ai_commit.notice.clone() {
            column = column.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(SharedString::from(notice)),
            );
        }
        if let Some(error) = self.ai_commit.error.clone() {
            column = column.child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.error)
                    .child(SharedString::from(error)),
            );
        }
        column
            .child(self.render_ai_commit_profiles(tokens, cx))
            .child(self.render_ai_commit_rules(tokens, cx))
            .child(readonly_row(
                "Storage",
                SharedString::from(tr(
                    "Profiles and API keys are stored in the application settings file. Keys are never shown again after saving.",
                )),
                tokens,
            ))
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(tr(
                        "Generation itself runs from the Git panel AI button; this page only manages providers, keys and message rules.",
                    )),
            )
            .into_any_element()
    }

    fn render_ai_commit_profiles(
        &mut self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mut body = v_flex().w_full().gap(px(SETTINGS_CONTROL_GAP));

        // Profile 选择（下拉） + 新增 / 移除。
        let profiles = self.settings.ai_commit_profiles.clone();
        let active_id = self.settings.ai_commit_active_profile.clone();
        let owner = cx.weak_entity();
        let active_label = profiles
            .iter()
            .find(|p| Some(&p.id) == active_id.as_ref())
            .map(display_profile_name)
            .unwrap_or_else(|| {
                if profiles.is_empty() {
                    tr("No profile yet")
                } else {
                    tr("Select a profile")
                }
                .to_string()
            });
        body = body.child(
            h_flex()
                .w_full()
                .flex_wrap()
                .gap(px(SETTINGS_CONTROL_GAP))
                .child(
                    Button::new("lithe-settings:ai-commit-profile")
                        .small()
                        .h(px(SETTINGS_BUTTON_HEIGHT))
                        .rounded(px(SETTINGS_BUTTON_RADIUS))
                        .secondary()
                        .label(SharedString::from(active_label))
                        .dropdown_menu(move |menu: PopupMenu, _, _| {
                            let mut menu = menu;
                            for profile in &profiles {
                                let owner = owner.clone();
                                let id = profile.id.clone();
                                let label = profile_meta_label(profile);
                                let is_active = Some(&profile.id) == active_id.as_ref();
                                menu = menu.item(
                                    PopupMenuItem::new(SharedString::from(label))
                                        .checked(is_active)
                                        .on_click(move |_, _, cx| {
                                            let _ = owner.update(cx, |this, cx| {
                                                this.ai_commit.pending_active_profile =
                                                    Some(id.clone());
                                                cx.notify();
                                            });
                                        }),
                                );
                            }
                            menu
                        }),
                )
                .child(
                    Button::new("lithe-settings:ai-commit-add")
                        .small()
                        .h(px(SETTINGS_BUTTON_HEIGHT))
                        .rounded(px(SETTINGS_BUTTON_RADIUS))
                        .secondary()
                        .label(tr("Add"))
                        .disabled(
                            self.settings.ai_commit_profiles.len() >= MAX_AI_COMMIT_PROFILES,
                        )
                        .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                            this.add_ai_commit_profile(window, cx);
                        })),
                )
                .child(
                    Button::new("lithe-settings:ai-commit-remove")
                        .small()
                        .h(px(SETTINGS_BUTTON_HEIGHT))
                        .rounded(px(SETTINGS_BUTTON_RADIUS))
                        .secondary()
                        .label(tr("Remove"))
                        .disabled(self.settings.ai_commit_profiles.is_empty())
                        .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                            this.remove_ai_commit_profile(window, cx);
                        })),
                ),
        );

        let Some(profile) = self.active_ai_commit_profile() else {
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr(
                        "Add a profile to configure an endpoint, model and API key, or import a Codex / Claude configuration below.",
                    )),
            );
            return section_card("Profiles", None, body.into_any_element(), tokens);
        };

        let managed = profile.managed();
        if managed {
            let caption = match profile.source.as_str() {
                "codex" => tr("Imported from Codex; fields are managed by that configuration."),
                _ => tr("Imported from Claude; fields are managed by that configuration."),
            };
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(SharedString::from(caption.to_string())),
            );
        }

        let uses_chat = profile.api_protocol == "chatCompletions";
        let protocol_value = profile.api_protocol.clone();
        let token_value = profile.chat_token_limit_field.clone();
        let auth_value = profile.authentication.clone();
        let requires_key = profile.requires_api_key;
        let insecure = profile.allows_insecure_http;
        let stored_key = !profile.api_key.is_empty();
        let endpoint_is_http = profile.endpoint.trim().starts_with("http:");

        // 文本字段（受管来源只读）。
        body = body
            .child(
                Input::new(&self.ai_commit_name_input)
                    .small()
                    .w_full()
                    .disabled(managed),
            )
            .child(
                Input::new(&self.ai_commit_endpoint_input)
                    .small()
                    .w_full()
                    .disabled(managed),
            )
            .child(
                Input::new(&self.ai_commit_model_input)
                    .small()
                    .w_full()
                    .disabled(managed),
            );

        // 协议下拉（切协议联动认证，Tauri ai-commit-settings-panel.tsx:234-254）。
        body = body.child(popup_select(
            "lithe-settings:ai-commit-protocol",
            AiCommitChoiceTarget::Protocol,
            &AI_COMMIT_PROTOCOLS,
            &protocol_value,
            !managed,
            cx,
        ));
        if uses_chat {
            body = body.child(popup_select(
                "lithe-settings:ai-commit-token-field",
                AiCommitChoiceTarget::TokenField,
                &AI_COMMIT_TOKEN_LIMIT_FIELDS,
                &token_value,
                !managed,
                cx,
            ));
        }
        // 认证方式下拉。
        body = body.child(popup_select(
            "lithe-settings:ai-commit-auth",
            AiCommitChoiceTarget::Authentication,
            &AI_COMMIT_AUTHENTICATION,
            &auth_value,
            !managed,
            cx,
        ));

        // 密钥行。
        let mut key_row = h_flex()
            .w_full()
            .gap(px(SETTINGS_CONTROL_GAP))
            .child(
                // 掩码与占位符在 InputState 创建时设置；输入框本身只显示状态，
                // “已存储”另行显示在密钥行末尾。
                Input::new(&self.ai_commit_key_input)
                    .small()
                    .w_full()
                    .disabled(managed),
            )
            .child(
                Button::new("lithe-settings:ai-commit-key-save")
                    .small()
                    .h(px(SETTINGS_BUTTON_HEIGHT))
                    .rounded(px(SETTINGS_BUTTON_RADIUS))
                    .primary()
                    .label(tr("Save key"))
                    .disabled(managed)
                    .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                        this.save_ai_commit_key(window, cx);
                    })),
            )
            .child(
                Button::new("lithe-settings:ai-commit-key-clear")
                    .small()
                    .h(px(SETTINGS_BUTTON_HEIGHT))
                    .rounded(px(SETTINGS_BUTTON_RADIUS))
                    .secondary()
                    .label(tr("Clear key"))
                    .disabled(managed || !stored_key)
                    .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                        this.clear_ai_commit_key(window, cx);
                    })),
            );
        if stored_key {
            key_row = key_row.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(tr("API key stored")),
            );
        }
        body = body.child(key_row);

        // requiresApiKey + http: 端点时的不安全 HTTP 复选框。
        body = body.child(
            h_flex()
                .w_full()
                .items_center()
                .gap(px(SETTINGS_CONTROL_GAP))
                .child(
                    Checkbox::new("lithe-settings:ai-commit-requires-key")
                        .checked(requires_key)
                        .disabled(managed)
                        .on_change(cx.listener(|this, checked: &bool, window, cx| {
                            let checked = *checked;
                            this.edit_ai_commit_active(
                                |p| p.requires_api_key = checked,
                                window,
                                cx,
                            );
                            cx.notify();
                        })),
                )
                .child(tr("Requires API key")),
        );
        if endpoint_is_http {
            body = body.child(
                h_flex()
                    .w_full()
                    .items_center()
                    .gap(px(SETTINGS_CONTROL_GAP))
                    .child(
                        Checkbox::new("lithe-settings:ai-commit-insecure-http")
                            .checked(insecure)
                            .disabled(managed)
                            .on_change(cx.listener(|this, checked: &bool, window, cx| {
                                let checked = *checked;
                                this.edit_ai_commit_active(
                                    |p| p.allows_insecure_http = checked,
                                    window,
                                    cx,
                                );
                                cx.notify();
                            })),
                    )
                    .child(tr("Allow insecure HTTP")),
            );
        }

        // 检测卡片 + 警告 + 「检测」按钮（Tauri :357-401）。
        if self.ai_commit.detection_loading {
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr("Detecting Codex / Claude configurations…")),
            );
        }
        if let Some(detected) = self.ai_commit.detected.clone() {
            for item in detected {
                let label = if item.source == "codex" { "Codex" } else { "Claude" }.to_string();
                let key_line = if item.has_credential {
                    tr("API key found in that configuration").to_string()
                } else {
                    tr("No key found in that configuration").to_string()
                };
                let source = item.source.clone();
                body = body.child(
                    v_flex()
                        .w_full()
                        .p(px(8.0))
                        .rounded(px(LitheMetrics::CONTROL_RADIUS))
                        .border_1()
                        .border_color(tokens.divider)
                        .gap(px(SETTINGS_CONTROL_GAP))
                        .child(
                            div()
                                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                                .text_color(tokens.primary_text)
                                .child(SharedString::from(format!(
                                    "{} {}",
                                    tr("Detected"),
                                    label
                                ))),
                        )
                        .child(
                            div()
                                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                                .font_family(lithe_ui::MONO_FONT_FAMILY)
                                .text_color(tokens.tertiary_text)
                                .child(SharedString::from(format!(
                                    "{} · {}",
                                    item.model, item.endpoint
                                ))),
                        )
                        .child(
                            div()
                                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                                .text_color(tokens.secondary_text)
                                .child(SharedString::from(key_line)),
                        )
                        .child(
                            Button::new(SharedString::from(format!(
                                "lithe-settings:ai-commit-import:{source}"
                            )))
                            .small()
                            .h(px(SETTINGS_BUTTON_HEIGHT))
                            .rounded(px(SETTINGS_BUTTON_RADIUS))
                            .secondary()
                            .label(SharedString::from(format!("{} {}", tr("Import"), label)))
                            .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                                this.import_ai_commit_source(source.clone(), window, cx);
                            })),
                        ),
                );
            }
        } else if !self.ai_commit.detection_loading {
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr("No Codex or Claude configuration detected.")),
            );
        }
        for (source, code) in self.ai_commit.warnings.clone() {
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.warning)
                    .child(SharedString::from(format!(
                        "{source}: {}",
                        ai_commit_warning(&code)
                    ))),
            );
        }
        body = body.child(
            Button::new("lithe-settings:ai-commit-detect")
                .small()
                .h(px(SETTINGS_BUTTON_HEIGHT))
                .rounded(px(SETTINGS_BUTTON_RADIUS))
                .secondary()
                .label(tr("Detect again"))
                .disabled(self.ai_commit.detection_loading)
                .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                    this.detect_ai_commit_sources(cx);
                })),
        );

        section_card("Profiles", None, body.into_any_element(), tokens)
    }

    fn render_ai_commit_rules(&mut self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let protocol_is_anthropic = self
            .active_ai_commit_profile()
            .map(|profile| profile.api_protocol == "anthropicMessages")
            .unwrap_or(false);
        let effort_value = self.settings.ai_commit_reasoning_effort.clone();

        let mut rules = v_flex()
            .w_full()
            .gap(px(SETTINGS_CONTROL_GAP))
            .child(toggle_row(
                "AI commit messages",
                "lithe-settings:ai-commit-enabled",
                self.settings.ai_commit_enabled,
                ToggleAction::AiCommitEnabled,
                cx,
                tokens,
            ))
            // 推理力度：anthropicMessages 协议不支持 reasoning（Tauri :415）。
            .child(popup_select(
                "lithe-settings:ai-commit-effort",
                AiCommitChoiceTarget::Effort,
                &AI_COMMIT_EFFORTS,
                &effort_value,
                !protocol_is_anthropic,
                cx,
            ))
            .child(choice_row(
                "Language",
                "lithe-settings:ai-commit-language",
                &AI_COMMIT_LANGUAGES,
                &self.settings.ai_commit_language,
                ChoiceAction::AiCommitLanguage,
                cx,
                tokens,
            ))
            .child(choice_row(
                "Format",
                "lithe-settings:ai-commit-format",
                &COMMIT_FORMATS,
                &self.settings.ai_commit_format,
                ChoiceAction::CommitFormat,
                cx,
                tokens,
            ));

        // Custom 描述（4000 字上限 + 计数）或内置格式的示例预览。
        if self.settings.ai_commit_format == "custom" {
            let char_count = self
                .ai_commit_custom_input
                .read(cx)
                .value()
                .chars()
                .count();
            rules = rules.child(
                v_flex()
                    .w_full()
                    .gap(px(SETTINGS_CONTROL_GAP))
                    .child(tr("Custom instructions"))
                    .child(
                        gpui_kit::component::input::Textarea::new(&self.ai_commit_custom_input)
                            .w_full()
                            .font_family(lithe_ui::MONO_FONT_FAMILY),
                    )
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.tertiary_text)
                            .child(SharedString::from(format!("{}/4000", char_count))),
                    ),
            );
        } else {
            let example_prefix = if self.settings.ai_commit_format == "conventional" {
                "feat(editor): <subject>"
            } else {
                "<subject>"
            };
            rules = rules.child(
                div()
                    .w_full()
                    .p(px(8.0))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .bg(tokens.raised)
                    .font_family(lithe_ui::MONO_FONT_FAMILY)
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(SharedString::from(format!(
                        "{}: {}",
                        tr("Example"),
                        example_prefix
                    ))),
            );
        }

        rules = rules
            .child(
                h_flex()
                    .w_full()
                    .items_center()
                    .gap(px(SETTINGS_CONTROL_GAP))
                    .child(
                        Checkbox::new("lithe-settings:ai-commit-include-body")
                            .checked(self.settings.ai_commit_include_body)
                            .on_change(cx.listener(|this, checked: &bool, window, cx| {
                                this.set_ai_commit_include_body(*checked, window, cx);
                            })),
                    )
                    .child(tr("Include commit body")),
            )
            .child(
                h_flex()
                    .w_full()
                    .items_center()
                    .gap(px(12.0))
                    .child(
                        div()
                            .w(px(120.0))
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(tr("Subject limit")),
                    )
                    .child(
                        Input::new(&self.ai_commit_subject_input)
                            .small()
                            .w(px(120.0)),
                    ),
            )
            .child(
                h_flex()
                    .w_full()
                    .items_center()
                    .gap(px(12.0))
                    .child(
                        div()
                            .w(px(120.0))
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(tr("Diff limit")),
                    )
                    .child(Input::new(&self.ai_commit_diff_input).small().w(px(120.0))),
            )
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(tr(
                        "Subject length 20–200, diff characters 8000–120000. Changes are committed when the value is valid.",
                    )),
            );

        section_card(
            "Commit rules",
            Some(
                "Rules define how generated messages look; generation runs from the Git panel AI button.",
            ),
            rules.into_any_element(),
            tokens,
        )
    }
}

// ---------------------------------------------------------------------------
// 交互方法
// ---------------------------------------------------------------------------

impl SettingsView {
    /// 发现 Codex / Claude 配置（后台线程读取文件，回调丢弃过期结果）。
    pub(in crate::settings) fn detect_ai_commit_sources(&mut self, cx: &mut Context<Self>) {
        if self.ai_commit.detection_loading {
            return;
        }
        self.ai_commit.generation = self.ai_commit.generation.wrapping_add(1);
        let generation = self.ai_commit.generation;
        self.ai_commit.detection_loading = true;
        self.ai_commit.error = None;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let outcome = cx
                .background_executor()
                .spawn(async move { detect_commit_sources() })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.ai_commit.generation != generation {
                    return;
                }
                this.ai_commit.detection_loading = false;
                match outcome {
                    Ok((list, warnings)) => {
                        this.ai_commit.detected = Some(list);
                        this.ai_commit.warnings = warnings;
                    }
                    Err(error) => {
                        this.ai_commit.error = Some(error);
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 把当前激活 Provider 的值排队到渲染帧的输入框回填（密钥不回填）。
    pub(in crate::settings) fn queue_ai_commit_inputs(&mut self) {
        let profile = self.active_ai_commit_profile();
        let (name, endpoint, model) = profile
            .as_ref()
            .map(|p| {
                (
                    p.name.clone(),
                    p.endpoint.clone(),
                    p.model.clone(),
                )
            })
            .unwrap_or_default();
        self.ai_commit_inputs_pending = Some(AiCommitInputs {
            name,
            endpoint,
            model,
            subject: self.settings.ai_commit_subject_max_length.to_string(),
            diff: self.settings.ai_commit_max_diff_characters.to_string(),
        });
    }

    /// 当前激活 Profile 的副本。
    pub(in crate::settings) fn active_ai_commit_profile(&self) -> Option<crate::settings::state::AiCommitProfile> {
        let active = self.settings.ai_commit_active_profile.clone()?;
        self.settings
            .ai_commit_profiles
            .iter()
            .find(|profile| profile.id == active)
            .cloned()
    }

    /// 编辑激活 Profile 的一个字段；受管 Profile 忽略。
    pub(in crate::settings) fn edit_ai_commit_active(
        &mut self,
        patch: impl FnOnce(&mut crate::settings::state::AiCommitProfile),
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(active) = self.settings.ai_commit_active_profile.clone() else {
            return;
        };
        let Some(index) = self
            .settings
            .ai_commit_profiles
            .iter()
            .position(|profile| profile.id == active)
        else {
            return;
        };
        if self.settings.ai_commit_profiles[index].managed() {
            return;
        }
        patch(&mut self.settings.ai_commit_profiles[index]);
        self.commit(window, cx);
    }

    pub(in crate::settings) fn add_ai_commit_profile(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.settings.ai_commit_profiles.len() >= MAX_AI_COMMIT_PROFILES {
            return;
        }
        let id = ai_commit_profile_uuid();
        let profile = crate::settings::state::AiCommitProfile::new_local(id.clone());
        self.settings.ai_commit_profiles.push(profile);
        self.settings.ai_commit_active_profile = Some(id);
        self.commit(window, cx);
        self.queue_ai_commit_inputs();
        cx.notify();
    }

    pub(in crate::settings) fn remove_ai_commit_profile(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(active) = self.settings.ai_commit_active_profile.clone() else {
            return;
        };
        self.settings
            .ai_commit_profiles
            .retain(|profile| profile.id != active);
        self.settings.ai_commit_active_profile = self
            .settings
            .ai_commit_profiles
            .first()
            .map(|profile| profile.id.clone());
        self.commit(window, cx);
        self.queue_ai_commit_inputs();
        cx.notify();
    }

    /// 导入检测到的配置（对齐 Tauri import 卡片：整字段替换受管 Profile、
    /// 保留本地 id 与 allowsInsecureHttp，并设为激活）。
    pub(in crate::settings) fn import_ai_commit_source(
        &mut self,
        source: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(detected) = self
            .ai_commit
            .detected
            .as_ref()
            .and_then(|list| list.iter().find(|item| item.source == source))
            .cloned()
        else {
            return;
        };
        let id = self
            .settings
            .ai_commit_profiles
            .iter()
            .find(|profile| profile.source == source)
            .map(|profile| profile.id.clone())
            .unwrap_or_else(|| format!("imported-{}", detected.source));
        let allows = self
            .settings
            .ai_commit_profiles
            .iter()
            .find(|existing| existing.source == source)
            .map(|existing| existing.allows_insecure_http)
            .unwrap_or(false);

        let mut profile = crate::settings::state::AiCommitProfile::new_local(id.clone());
        profile.source = detected.source.clone();
        profile.name = detected.name.clone();
        profile.endpoint = detected.endpoint.clone();
        profile.model = detected.model.clone();
        profile.api_protocol = detected.api_protocol.clone();
        profile.authentication = detected.authentication.clone();
        profile.requires_api_key = detected.requires_api_key;
        profile.allows_insecure_http = allows;

        self.settings.ai_commit_profiles.retain(|p| p.source != source);
        self.settings.ai_commit_profiles.push(profile);
        self.settings.ai_commit_active_profile = Some(id);
        self.commit(window, cx);
        self.queue_ai_commit_inputs();
        cx.notify();
    }

    /// 保存密钥：写入通道 + 清空输入 + “已存储”占位；受管 Profile 禁止。
    pub(in crate::settings) fn save_ai_commit_key(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(profile) = self.active_ai_commit_profile() else {
            return;
        };
        if profile.managed() {
            return;
        }
        let key = self.ai_commit_key_input.read(cx).value().trim().to_string();
        if key.is_empty() {
            self.ai_commit.error = Some(tr("API key is empty.").to_string());
            cx.notify();
            return;
        }
        if let Some(index) = self
            .settings
            .ai_commit_profiles
            .iter()
            .position(|p| p.id == profile.id)
        {
            self.settings.ai_commit_profiles[index].api_key = key;
        }
        self.ai_commit_key_input.update(cx, |state, cx| {
            state.set_value(String::new(), window, cx);
        });
        self.ai_commit.notice = Some(tr("API key stored.").to_string());
        self.ai_commit.error = None;
        self.commit(window, cx);
    }

    pub(in crate::settings) fn clear_ai_commit_key(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(profile) = self.active_ai_commit_profile() else {
            return;
        };
        if profile.managed() {
            return;
        }
        if let Some(index) = self
            .settings
            .ai_commit_profiles
            .iter()
            .position(|p| p.id == profile.id)
        {
            self.settings.ai_commit_profiles[index].api_key = String::new();
        }
        self.ai_commit_key_input.update(cx, |state, cx| {
            state.set_value(String::new(), window, cx);
        });
        self.ai_commit.notice = Some(tr("API key removed.").to_string());
        self.commit(window, cx);
    }

    // 规则区写入（窗口回调路径）。

    /// 提交信息格式（ChoiceAction::CommitFormat 的统一入口）。
    pub(in crate::settings) fn set_ai_commit_format(
        &mut self,
        format: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.ai_commit_format.eq_ignore_ascii_case(format) {
            return;
        }
        self.settings.ai_commit_format = format.to_string();
        self.commit(window, cx);
    }

    pub(in crate::settings) fn set_ai_commit_language(
        &mut self,
        value: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.ai_commit_language == value {
            return;
        }
        self.settings.ai_commit_language = value.to_string();
        self.commit(window, cx);
    }

    pub(in crate::settings) fn set_ai_commit_include_body(
        &mut self,
        checked: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.ai_commit_include_body == checked {
            return;
        }
        self.settings.ai_commit_include_body = checked;
        self.commit(window, cx);
    }

    // -----------------------------------------------------------------
    // 渲染帧 flush：处理订阅 / 弹窗积累的全部 pending 写入
    // -----------------------------------------------------------------

    pub(in crate::settings) fn apply_ai_commit_pending(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // 1) 输入框回填（先回填再消费写入，避免把刚回填的值当成新编辑）。
        if let Some(inputs) = self.ai_commit_inputs_pending.take() {
            for (input, value) in [
                (&self.ai_commit_name_input, inputs.name),
                (&self.ai_commit_endpoint_input, inputs.endpoint),
                (&self.ai_commit_model_input, inputs.model),
                (&self.ai_commit_subject_input, inputs.subject),
                (&self.ai_commit_diff_input, inputs.diff),
            ] {
                input.update(cx, |state, cx| state.set_value(value, window, cx));
            }
        }

        // 2) 激活 Profile。
        if let Some(id) = self.ai_commit.pending_active_profile.take() {
            if self
                .settings
                .ai_commit_profiles
                .iter()
                .any(|profile| profile.id == id)
                && self.settings.ai_commit_active_profile.as_deref() != Some(id.as_str())
            {
                self.settings.ai_commit_active_profile = Some(id);
                self.queue_ai_commit_inputs();
                self.commit(window, cx);
            }
        }

        // 3) 协议 / token 字段 / 认证 / effort。
        if let Some(value) = self.ai_commit.pending_protocol.take() {
            // Tauri：切到 anthropicMessages 时认证联动为 x-api-key。
            self.edit_ai_commit_active(
                |p| {
                    p.api_protocol = value.to_string();
                    if value == "anthropicMessages" {
                        p.authentication = "apiKey".to_string();
                    }
                },
                window,
                cx,
            );
            self.queue_ai_commit_inputs();
        }
        if let Some(value) = self.ai_commit.pending_token_field.take() {
            self.edit_ai_commit_active(
                |p| p.chat_token_limit_field = value.to_string(),
                window,
                cx,
            );
        }
        if let Some(value) = self.ai_commit.pending_authentication.take() {
            self.edit_ai_commit_active(
                |p| p.authentication = value.to_string(),
                window,
                cx,
            );
        }
        if let Some(value) = self.ai_commit.pending_effort.take() {
            if self.settings.ai_commit_reasoning_effort != value {
                self.settings.ai_commit_reasoning_effort = value.to_string();
                self.commit(window, cx);
            }
        }

        // 4) 文本字段 → 激活 Profile。
        if let Some((field, value)) = self.ai_commit.text_pending.take() {
            let unchanged = self.active_ai_commit_profile().map_or(true, |profile| {
                match field {
                    AiCommitTextField::Name => profile.name == value,
                    AiCommitTextField::Endpoint => profile.endpoint == value,
                    AiCommitTextField::Model => profile.model == value,
                }
            });
            if !unchanged {
                let apply = |p: &mut crate::settings::state::AiCommitProfile| {
                    let cloned = value.clone();
                    match field {
                        AiCommitTextField::Name => p.name = cloned,
                        AiCommitTextField::Endpoint => p.endpoint = cloned,
                        AiCommitTextField::Model => p.model = cloned,
                    }
                };
                self.edit_ai_commit_active(apply, window, cx);
            }
        }

        // 5) 数字字段。
        if let Some((field, text)) = self.ai_commit.number_pending.take() {
            let parsed: Option<u32> = text.trim().parse().ok();
            match field {
                AiCommitNumberField::Subject => {
                    let value = parsed.unwrap_or(self.settings.ai_commit_subject_max_length)
                        .clamp(20, 200);
                    if self.settings.ai_commit_subject_max_length != value {
                        self.settings.ai_commit_subject_max_length = value;
                        self.commit(window, cx);
                    }
                }
                AiCommitNumberField::Diff => {
                    let value = parsed
                        .unwrap_or(self.settings.ai_commit_max_diff_characters)
                        .clamp(8_000, 120_000);
                    if self.settings.ai_commit_max_diff_characters != value {
                        self.settings.ai_commit_max_diff_characters = value;
                        self.commit(window, cx);
                    }
                }
            }
        }

        // 6) 自定义说明（4000 字上限）。
        if self.ai_commit.pending_custom {
            self.ai_commit.pending_custom = false;
            let value = self
                .ai_commit_custom_input
                .read(cx)
                .value()
                .chars()
                .take(4_000)
                .collect::<String>();
            if self.settings.ai_commit_custom_instructions != value {
                self.settings.ai_commit_custom_instructions = value;
                self.commit(window, cx);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 检测（后台线程）
// ---------------------------------------------------------------------------

/// 组装环境变量映射；与 Tauri 宿主传给 parse_* 的 env 语义一致。
/// 生成本地 Profile id：毫秒时间戳 + 进程内自增序号，字符集符合设置归一化
/// 的 `[A-Za-z0-9-]{1,128}` 约束，不引入额外 uuid 依赖。
fn ai_commit_profile_uuid() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or_default();
    let sequence = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("local-{millis:x}-{sequence:x}")
}

fn environment() -> BTreeMap<String, String> {
    std::env::vars().collect()
}

fn user_home() -> Option<std::path::PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(std::path::PathBuf::from)
        .filter(|home| !home.as_os_str().is_empty())
}

/// 读取一个可选文件，大小不得超过 1MiB（对齐 Tauri `read_optional`）。
fn read_optional(path: &std::path::Path) -> Result<String, String> {
    use std::io::Read;
    const LIMIT: usize = 1_048_576;
    match std::fs::File::open(path) {
        Ok(mut file) => {
            let mut text = String::new();
            match file.read_to_string(&mut text) {
                Ok(_) => {
                    if text.len() > LIMIT {
                        Err(tr("Configuration file is too large.").to_string())
                    } else {
                        Ok(text)
                    }
                }
                Err(_) => Err(tr("Could not read the configuration file.").to_string()),
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(_) => Err(tr("Could not read the configuration file.").to_string()),
    }
}

/// 读取 Codex / Claude 两个来源，产出摘要 + 警告；任何解析错误都不阻塞页面。
fn detect_commit_sources() -> Result<(Vec<DetectedCommitSource>, Vec<(String, String)>), String> {
    let mut configurations = Vec::new();
    let mut warnings = Vec::new();
    let environment = environment();
    let Some(home) = user_home() else {
        return Ok((configurations, warnings));
    };

    // Codex：~/.codex（或 CODEX_HOME）下读 config.toml + auth.json。
    {
        let directory = std::env::var("CODEX_HOME")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| home.join(".codex"));
        match read_optional(&directory.join("config.toml")) {
            Ok(config) if !config.is_empty() => {
                let auth = read_optional(&directory.join("auth.json")).unwrap_or_default();
                match ai::parse_codex(&config, &auth, &environment) {
                    Ok(detected) => configurations.push(detected.into()),
                    Err(code) => warnings.push(("codex".to_string(), code.to_string())),
                }
            }
            Ok(_) => {}
            Err(error) => warnings.push(("codex".to_string(), error)),
        }
    }

    // Claude：~/.claude（或 CLAUDE_CONFIG_DIR）+ ~/.claude.json。
    {
        let directory = std::env::var("CLAUDE_CONFIG_DIR")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| home.join(".claude"));
        let settings = read_optional(&directory.join("settings.json")).unwrap_or_default();
        let credentials =
            read_optional(&directory.join(".credentials.json")).unwrap_or_default();
        let root = read_optional(&home.join(".claude.json")).unwrap_or_default();
        let anthropic_env = environment
            .keys()
            .any(|key| key.starts_with("ANTHROPIC_"));
        if !settings.is_empty() || !credentials.is_empty() || !root.is_empty() || anthropic_env {
            match ai::parse_claude(&settings, &credentials, &root, &environment) {
                Ok(detected) => configurations.push(detected.into()),
                Err(code) => warnings.push(("claude".to_string(), code.to_string())),
            }
        }
    }

    Ok((configurations, warnings))
}

// ---------------------------------------------------------------------------
// 展示辅助
// ---------------------------------------------------------------------------

/// Profile 在下拉里的显示名（名称 > 模型 > 未命名）。
fn display_profile_name(profile: &crate::settings::state::AiCommitProfile) -> String {
    if !profile.name.is_empty() {
        profile.name.clone()
    } else if !profile.model.is_empty() {
        profile.model.clone()
    } else {
        tr("Unnamed profile").to_string()
    }
}

/// Profile 在下拉里的摘要行。
fn profile_meta_label(profile: &crate::settings::state::AiCommitProfile) -> String {
    format!("{} · {}", display_profile_name(profile), profile.model)
}

/// popup 选择按钮的落点；同一形态被协议 / token 字段 / 认证 / effort 复用。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::settings) enum AiCommitChoiceTarget {
    Protocol,
    TokenField,
    Authentication,
    Effort,
}

impl From<lithe_core::ai::DetectedConfiguration> for DetectedCommitSource {
    fn from(value: lithe_core::ai::DetectedConfiguration) -> Self {
        let provider = value.provider;
        DetectedCommitSource {
            source: provider.source,
            name: provider.name,
            endpoint: provider.endpoint,
            model: provider.model,
            api_protocol: provider.api_protocol,
            authentication: provider.authentication,
            requires_api_key: provider.requires_api_key,
            has_credential: value.has_credential,
        }
    }
}

/// Core 错误码 → 页面可见文案（未知码原样展示）。
fn ai_commit_warning(code: &str) -> String {
    match code {
        "AI_COMMIT_INVALID_CONFIG" => tr("That configuration could not be parsed.").to_string(),
        "AI_COMMIT_CONFIG_READ_FAILED" => {
            tr("Could not read the configuration file.").to_string()
        }
        "AI_COMMIT_CONFIG_TOO_LARGE" => {
            tr("Configuration file is too large.").to_string()
        }
        other => other.to_string(),
    }
}

/// popup 选择按钮：gpui-kit `Button.dropdown_menu`，勾当前选择。
fn popup_select(
    id: &'static str,
    target: AiCommitChoiceTarget,
    options: &'static [(&'static str, &'static str)],
    selected: &str,
    enabled: bool,
    cx: &mut Context<SettingsView>,
) -> AnyElement {
    let label = options
        .iter()
        .find(|(value, _)| *value == selected)
        .map(|(_, title)| tr(title))
        .unwrap_or_else(|| tr("Select"))
        .to_string();
    let selected = selected.to_string();
    let owner = cx.weak_entity();
    Button::new(id)
        .small()
        .h(px(SETTINGS_BUTTON_HEIGHT))
        .rounded(px(SETTINGS_BUTTON_RADIUS))
        .secondary()
        .label(SharedString::from(label))
        .disabled(!enabled)
        .dropdown_menu(move |menu: PopupMenu, _, _| {
            let mut menu = menu;
            for (value, title) in options {
                let owner = owner.clone();
                let target = target;
                let value = *value;
                let is_selected = value == selected;
                menu = menu.item(
                    PopupMenuItem::new(tr(title))
                        .checked(is_selected)
                        .on_click(move |_, _, cx| {
                            let _ = owner.update(cx, |this, cx| {
                                this.ai_commit.stage_choice(target, value);
                                cx.notify();
                            });
                        }),
                );
            }
            menu
        })
        .into_any_element()
}
