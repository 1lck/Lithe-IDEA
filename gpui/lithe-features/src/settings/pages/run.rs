//! Run Configurations 页：配置列表、编辑器与工具链覆盖。

use std::time::Duration;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, Textarea};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenu, PopupMenuItem};
use gpui_kit::component::{Disableable as _, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, ClickEvent, Context, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled, Window, div, px,
};
use lithe_core_client::CoreClient;
use lithe_platform as platform;
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, MONO_FONT_FAMILY, icon};

use crate::run::config;
use crate::run::model::{requirement_messages, RunSaveScope};
use crate::run::toolchain::{
    self, describe_effective, EffectiveKind, EffectiveMode, EffectiveToolchainState,
    ToolchainResolution,
};
use crate::settings::controls::{note_card, run_detail_line, run_text_field};
use crate::settings::state::{
    RunEditorInputs, RunPathField, RunToolchainField, SETTINGS_BUTTON_HEIGHT,
    SETTINGS_BUTTON_RADIUS, SETTINGS_SECTION_GAP,
};
use crate::settings::SettingsView;

impl SettingsView {
    pub(in crate::settings) fn render_run_configurations(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if self.context.project_root.is_none() {
            return note_card(
                SharedString::from(tr("Open a project to configure its JDK and Maven.")),
                tokens,
            );
        }
        if self.run.loading {
            return note_card(SharedString::from(tr("Working…")), tokens);
        }
        if self.run.ready && self.run.editing_id.is_some() {
            return self.render_run_editor(tokens, cx);
        }
        self.render_run_list(tokens, cx)
    }

    /// 配置列表：说明、识别按钮和每条配置的编辑入口。
    fn render_run_list(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let mut body = v_flex()
            .w_full()
            .gap(px(8.0))
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr(
                        "Select a service or task to configure its arguments, environment and project-environment overrides. Changes apply after Save.",
                    )),
            );
        if let Some(error) = self.run.error.clone() {
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.error)
                    .child(error),
            );
        }
        if let Some(error) = self.run.save_error.clone() {
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.error)
                    .child(error),
            );
        }
        if let Some(notice) = self.run.generation_notice.clone() {
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(notice),
            );
        }
        if self.run.ready && self.run.requires_generation {
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.warning)
                    .child(tr("Run configurations may be out of date")),
            );
        }
        body = body.child(
            Button::new("lithe-settings:run-generate")
                .small()
                .h(px(SETTINGS_BUTTON_HEIGHT))
                .rounded(px(SETTINGS_BUTTON_RADIUS))
                .label(if self.run.generating {
                    tr("Working…")
                } else {
                    tr("Identify Again")
                })
                .disabled(self.run.generating)
                .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                    this.generate_run_configurations(cx);
                })),
        );

        for configuration in &self.run.configurations {
            let id = configuration.id.clone();
            body = body.child(
                h_flex()
                    .id(SharedString::from(format!(
                        "lithe-settings:run-configuration:{}",
                        configuration.id
                    )))
                    .w_full()
                    .h(px(28.0))
                    .flex_shrink_0()
                    .items_center()
                    .gap(px(8.0))
                    .px(px(8.0))
                    .rounded(px(SETTINGS_BUTTON_RADIUS))
                    .cursor_pointer()
                    .hover(|style| style.bg(tokens.hover))
                    .when(self.run.generating, |this| this.opacity(0.5))
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.0))
                            .truncate()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.primary_text)
                            .child(configuration.name.clone()),
                    )
                    .child(
                        div()
                            .flex_shrink_0()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(tr("Edit")),
                    )
                    .on_click(cx.listener(move |this, _: &ClickEvent, _window, cx| {
                        if this.run.generating {
                            return;
                        }
                        this.open_run_editor(id.clone(), cx);
                    })),
            );
        }

        body.into_any_element()
    }

    /// 单条配置的编辑器，布局对齐 Tauri `RunConfigurationEditor`。
    fn render_run_editor(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let Some(configuration) = self
            .run
            .configurations
            .iter()
            .find(|configuration| Some(&configuration.id) == self.run.editing_id.as_ref())
            .cloned()
        else {
            return self.render_run_list(tokens, cx);
        };
        let uses_java = configuration.uses_java();
        let uses_maven = configuration.uses_maven();
        let uses_node = configuration.uses_node();
        let configuration_id = configuration.id.clone();
        let java_candidates: Vec<(String, String)> = self
            .run
            .discovered
            .java
            .iter()
            .map(|runtime| {
                (
                    runtime.home_path.clone(),
                    if runtime.version.is_empty() {
                        runtime.home_path.clone()
                    } else {
                        format!("{} ({})", runtime.home_path, runtime.version)
                    },
                )
            })
            .collect();
        let maven_candidates: Vec<(String, String)> = self
            .run
            .discovered
            .maven
            .iter()
            .map(|runtime| {
                (
                    runtime.executable_path.clone(),
                    if runtime.version.is_empty() {
                        runtime.executable_path.clone()
                    } else {
                        format!("{} ({})", runtime.executable_path, runtime.version)
                    },
                )
            })
            .collect();
        let node_candidates: Vec<(String, String)> = self
            .run
            .discovered
            .runtimes
            .iter()
            .filter(|runtime| runtime.id == "project-node")
            .map(|runtime| {
                (
                    runtime.executable_path.clone(),
                    if runtime.version.is_empty() {
                        runtime.executable_path.clone()
                    } else {
                        format!("{} ({})", runtime.executable_path, runtime.version)
                    },
                )
            })
            .collect();

        let mut body = v_flex()
            .w_full()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(
                div()
                    .text_size(px(14.0))
                    .font_weight(FontWeight::BOLD)
                    .text_color(tokens.primary_text)
                    .child(configuration.name.clone()),
            );

        // 项目默认值：这里只编辑 Node；Java/Maven 默认值由 Project 设置页维护。
        let mut defaults = v_flex()
            .w_full()
            .gap(px(6.0))
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(tokens.secondary_text)
                    .child(format!(
                        "{} · {}",
                        tr("Project defaults"),
                        tr("This computer")
                    )),
            )
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr(
                        "Saved only for this project on this computer in .lithe/run/local.json and excluded from Git.",
                    )),
            );
        if uses_java || uses_maven {
            defaults = defaults.child(
                Button::new("lithe-settings:run-open-project")
                    .small()
                    .h(px(SETTINGS_BUTTON_HEIGHT))
                    .rounded(px(SETTINGS_BUTTON_RADIUS))
                    .ghost()
                    .label(tr("Configure project JDK and Maven…"))
                    .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                        this.open_project_page(cx);
                    })),
            );
        }
        if uses_node {
            let value = self
                .run
                .toolchain_draft
                .runtime_executable_paths
                .get("project-node")
                .cloned()
                .unwrap_or_default();
            defaults = defaults.child(self.render_run_toolchain_field(
                RunToolchainField::Node,
                "lithe-settings:run-node",
                tr("Node.js executable"),
                tr("Choose node.exe, or leave empty to use the detected Node.js runtime."),
                tr("Auto-detect (leave empty)"),
                value,
                node_candidates,
                None,
                tokens,
                cx,
            ));
        }
        body = body.child(defaults);

        // 配置信息与保存范围。
        let mut section = v_flex()
            .w_full()
            .gap(px(6.0))
            .border_t_1()
            .border_color(tokens.divider)
            .pt(px(SETTINGS_SECTION_GAP))
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(tokens.secondary_text)
                    .child(tr("Configuration")),
            )
            .child(run_detail_line(
                tr("Type"),
                configuration.kind_title(),
                false,
                tokens,
            ))
            .child(run_detail_line(
                tr("Effective source"),
                configuration.source_title().to_string(),
                false,
                tokens,
            ));
        if let Some(main_class) = configuration.main_class() {
            section = section.child(run_detail_line(
                tr("Main class"),
                main_class.to_string(),
                true,
                tokens,
            ));
        }

        let mut scope = h_flex()
            .gap(px(4.0))
            .p(px(2.0))
            .rounded(px(SETTINGS_BUTTON_RADIUS))
            .bg(tokens.raised);
        for value in [RunSaveScope::Local, RunSaveScope::Project] {
            scope = scope.child(
                Button::new(SharedString::from(format!(
                    "lithe-settings:run-scope:{}",
                    value.wire()
                )))
                .small()
                .h(px(SETTINGS_BUTTON_HEIGHT))
                .rounded(px(SETTINGS_BUTTON_RADIUS))
                .label(value.title())
                .when(self.run.scope == value, |this| this.primary())
                .on_click(cx.listener(move |this, _: &ClickEvent, _window, cx| {
                    this.set_run_scope(value, cx);
                })),
            );
        }
        section = section
            .child(
                div()
                    .pt(px(6.0))
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr("Save scope")),
            )
            .child(scope)
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(self.run.scope.hint()),
            )
            .child(
                div()
                    .pt(px(6.0))
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(tokens.secondary_text)
                    .child(tr("Configuration overrides")),
            )
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr(
                        "These overrides affect only this run configuration. Clear a path to inherit the project environment.",
                    )),
            );

        let mut overrides = v_flex().w_full().gap(px(12.0));
        if uses_java {
            let mode = if self.run.draft.java_home_path.is_empty() {
                EffectiveMode::Inherit
            } else {
                EffectiveMode::Configured
            };
            let requirements = requirement_messages(
                &self.run.diagnostics,
                "project-jdk",
                Some(&configuration_id),
            );
            let effective = self.render_run_effective(
                &self.run.effective.java,
                EffectiveKind::Java,
                mode,
                requirements,
                tokens,
            );
            overrides = overrides.child(self.render_run_toolchain_field(
                RunToolchainField::JavaHome,
                "lithe-settings:run-jdk",
                tr("JDK Home"),
                tr("Leave empty to use the project default."),
                tr("Use project default"),
                self.run.draft.java_home_path.clone(),
                java_candidates.clone(),
                Some(effective),
                tokens,
                cx,
            ));
        }
        if uses_maven {
            let maven_mode = if self.run.draft.maven_executable_path.is_empty() {
                EffectiveMode::Inherit
            } else {
                EffectiveMode::Configured
            };
            let requirements = requirement_messages(
                &self.run.diagnostics,
                "project-maven",
                Some(&configuration_id),
            );
            let effective = self.render_run_effective(
                &self.run.effective.maven,
                EffectiveKind::Maven,
                maven_mode,
                requirements,
                tokens,
            );
            overrides = overrides.child(self.render_run_toolchain_field(
                RunToolchainField::MavenExecutable,
                "lithe-settings:run-maven",
                tr("Maven executable"),
                tr("Leave empty to use the project default."),
                tr("Use project default"),
                self.run.draft.maven_executable_path.clone(),
                maven_candidates,
                Some(effective),
                tokens,
                cx,
            ));

            let maven_java_mode = if self.run.draft.maven_java_home_path.is_empty() {
                EffectiveMode::Inherit
            } else {
                EffectiveMode::Configured
            };
            let effective = self.render_run_effective(
                &self.run.effective.maven_java,
                EffectiveKind::Java,
                maven_java_mode,
                Vec::new(),
                tokens,
            );
            overrides = overrides.child(self.render_run_toolchain_field(
                RunToolchainField::MavenJavaHome,
                "lithe-settings:run-maven-jdk",
                tr("JDK Home"),
                tr("Leave empty to use the project default."),
                tr("Use project default"),
                self.run.draft.maven_java_home_path.clone(),
                java_candidates,
                Some(effective),
                tokens,
                cx,
            ));

            let tests_label = match self.run.draft.maven_skip_tests {
                None => tr("Use project default"),
                Some(true) => tr("Skip tests"),
                Some(false) => tr("Run tests"),
            };
            let maven_skip_tests = self.run.draft.maven_skip_tests;
            let owner = cx.weak_entity();
            overrides = overrides.child(
                v_flex()
                    .w_full()
                    .gap(px(4.0))
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.primary_text)
                            .child(tr("Maven tests")),
                    )
                    .child(
                        Button::new("lithe-settings:run-maven-tests")
                            .small()
                            .h(px(SETTINGS_BUTTON_HEIGHT))
                            .rounded(px(SETTINGS_BUTTON_RADIUS))
                            .label(tests_label)
                            .dropdown_menu(move |menu, _, _| {
                                let inherit_owner = owner.clone();
                                let run_owner = owner.clone();
                                let skip_owner = owner.clone();
                                menu.item(
                                    PopupMenuItem::new(tr("Use project default"))
                                        .checked(maven_skip_tests.is_none())
                                        .on_click(move |_, _, cx| {
                                            let _ = inherit_owner.update(cx, |this, cx| {
                                                this.set_run_maven_tests(None, cx);
                                            });
                                        }),
                                )
                                .item(
                                    PopupMenuItem::new(tr("Run tests"))
                                        .checked(maven_skip_tests == Some(false))
                                        .on_click(move |_, _, cx| {
                                            let _ = run_owner.update(cx, |this, cx| {
                                                this.set_run_maven_tests(Some(false), cx);
                                            });
                                        }),
                                )
                                .item(
                                    PopupMenuItem::new(tr("Skip tests"))
                                        .checked(maven_skip_tests == Some(true))
                                        .on_click(move |_, _, cx| {
                                            let _ = skip_owner.update(cx, |this, cx| {
                                                this.set_run_maven_tests(Some(true), cx);
                                            });
                                        }),
                                )
                            }),
                    )
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(tr(
                                "Override the Maven tool window's Skip Tests setting for this run configuration.",
                            )),
                    ),
            );
        }

        overrides = overrides
            .child(run_text_field(
                tr("Program arguments"),
                Input::new(&self.run_argument_input)
                    .small()
                    .w_full()
                    .font_family(MONO_FONT_FAMILY)
                    .into_any_element(),
                None,
                tokens,
            ))
            .child(run_text_field(
                tr("JVM arguments"),
                Input::new(&self.run_vm_input)
                    .small()
                    .w_full()
                    .font_family(MONO_FONT_FAMILY)
                    .into_any_element(),
                None,
                tokens,
            ))
            .child(run_text_field(
                tr("Working directory"),
                h_flex()
                    .w_full()
                    .gap(px(6.0))
                    .child(
                        div().flex_1().min_w(px(0.0)).child(
                            Input::new(&self.run_working_input)
                                .small()
                                .w_full()
                                .font_family(MONO_FONT_FAMILY),
                        ),
                    )
                    .child(
                        Button::new("lithe-settings:run-working-browse")
                            .ghost()
                            .small()
                            .icon(icon(LitheIcon::Folder))
                            .tooltip(tr("Browse"))
                            .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                                this.browse_run_path(RunPathField::WorkingDirectory, cx);
                            })),
                    )
                    .into_any_element(),
                Some(tr("Leave empty to use the project root.")),
                tokens,
            ))
            .child(run_text_field(
                tr("Environment"),
                Textarea::new(&self.run_environment_input)
                    .w_full()
                    .font_family(MONO_FONT_FAMILY)
                    .into_any_element(),
                None,
                tokens,
            ));
        section = section.child(overrides);
        body = body.child(section);

        let mut footer = h_flex()
            .w_full()
            .justify_end()
            .items_center()
            .gap(px(8.0))
            .border_t_1()
            .border_color(tokens.divider)
            .pt(px(12.0));
        if let Some(error) = self.run.save_error.clone() {
            footer = footer.child(
                div()
                    .flex_1()
                    .min_w(px(0.0))
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.error)
                    .child(error),
            );
        }
        footer = footer
            .child(
                Button::new("lithe-settings:run-cancel")
                    .small()
                    .h(px(SETTINGS_BUTTON_HEIGHT))
                    .rounded(px(SETTINGS_BUTTON_RADIUS))
                    .ghost()
                    .label(tr("Cancel"))
                    .disabled(self.run.saving)
                    .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                        this.close_run_editor(cx);
                    })),
            )
            .child(
                Button::new("lithe-settings:run-save")
                    .small()
                    .h(px(SETTINGS_BUTTON_HEIGHT))
                    .rounded(px(SETTINGS_BUTTON_RADIUS))
                    .primary()
                    .label(tr("Save"))
                    .disabled(self.run.saving)
                    .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                        this.save_run_configuration(cx);
                    })),
            );
        body.child(footer).into_any_element()
    }

    /// 工具链下拉字段：自动项、发现到的候选、以及当前的自定义路径。
    #[allow(clippy::too_many_arguments)]
    fn render_run_toolchain_field(
        &self,
        field: RunToolchainField,
        id: &'static str,
        label: &'static str,
        hint: &'static str,
        auto_label: &'static str,
        value: String,
        candidates: Vec<(String, String)>,
        effective: Option<AnyElement>,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let display = if value.is_empty() {
            tr(auto_label).to_string()
        } else if let Some((_, candidate_label)) = candidates
            .iter()
            .find(|(path, _)| config::same_windows_path(path, &value))
        {
            candidate_label.clone()
        } else {
            format!("{}: {value}", tr("Current path"))
        };
        let has_candidate = candidates
            .iter()
            .any(|(path, _)| config::same_windows_path(path, &value));
        let owner = cx.weak_entity();
        let menu_value = value.clone();
        let menu_candidates = candidates.clone();
        let menu = move |menu: PopupMenu, _window: &mut Window, _cx: &mut Context<PopupMenu>| {
            let auto_owner = owner.clone();
            let mut menu = menu.item(
                PopupMenuItem::new(tr(auto_label))
                    .checked(menu_value.is_empty())
                    .on_click(move |_, _, cx| {
                        let _ = auto_owner.update(cx, |this, cx| {
                            this.set_run_toolchain(field, String::new(), cx);
                        });
                    }),
            );
            for (path, candidate_label) in &menu_candidates {
                let choice_owner = owner.clone();
                let selected = config::same_windows_path(&menu_value, path);
                let path = path.clone();
                let candidate_label = candidate_label.clone();
                menu = menu.item(
                    PopupMenuItem::new(SharedString::from(candidate_label))
                        .checked(selected)
                        .on_click(move |_, _, cx| {
                            let _ = choice_owner.update(cx, |this, cx| {
                                this.set_run_toolchain(field, path.clone(), cx);
                            });
                        }),
                );
            }
            if !menu_value.is_empty() && !has_candidate {
                let custom_owner = owner.clone();
                let custom_value = menu_value.clone();
                menu = menu.item(
                    PopupMenuItem::new(SharedString::from(format!(
                        "{}: {}",
                        tr("Current path"),
                        menu_value
                    )))
                    .checked(true)
                    .on_click(move |_, _, cx| {
                        let _ = custom_owner.update(cx, |this, cx| {
                            this.set_run_toolchain(field, custom_value.clone(), cx);
                        });
                    }),
                );
            }
            menu
        };

        let path_field = match field {
            RunToolchainField::JavaHome => RunPathField::JavaHome,
            RunToolchainField::MavenExecutable => RunPathField::MavenExecutable,
            RunToolchainField::MavenJavaHome => RunPathField::MavenJavaHome,
            RunToolchainField::Node => RunPathField::Node,
        };
        let mut content = v_flex()
            .w_full()
            .gap(px(4.0))
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.primary_text)
                    .child(tr(label)),
            )
            .child(
                h_flex()
                    .w_full()
                    .gap(px(6.0))
                    .child(
                        div().flex_1().min_w(px(0.0)).child(
                            Button::new(id)
                                .small()
                                .h(px(SETTINGS_BUTTON_HEIGHT))
                                .rounded(px(SETTINGS_BUTTON_RADIUS))
                                .w_full()
                                .label(SharedString::from(display))
                                .dropdown_menu(menu),
                        ),
                    )
                    .child(
                        Button::new(SharedString::from(format!("{id}:browse")))
                            .ghost()
                            .small()
                            .icon(icon(LitheIcon::Folder))
                            .tooltip(tr("Browse"))
                            .on_click(cx.listener(move |this, _: &ClickEvent, _window, cx| {
                                this.browse_run_path(path_field, cx);
                            })),
                    ),
            )
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr(hint)),
            );
        if let Some(effective) = effective {
            content = content.child(effective);
        }
        content.into_any_element()
    }

    /// 生效工具链说明，以及该配置未满足的工具链要求。
    fn render_run_effective(
        &self,
        state: &EffectiveToolchainState,
        kind: EffectiveKind,
        mode: EffectiveMode,
        requirements: Vec<String>,
        tokens: LitheTokens,
    ) -> AnyElement {
        let line = describe_effective(state, kind, mode);
        let mut block = v_flex().w_full().gap(px(2.0)).child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(if line.error {
                    tokens.error
                } else {
                    tokens.primary_text
                })
                .child(line.text),
        );
        if let EffectiveToolchainState::Resolution(ToolchainResolution::Resolved {
            warning: Some(warning),
            ..
        }) = state
        {
            block = block.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.error)
                    .child(warning.clone()),
            );
        }
        for message in requirements {
            block = block.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.error)
                    .child(message),
            );
        }
        block.into_any_element()
    }

    // -----------------------------------------------------------------
    // Run Configurations 数据方法
    // -----------------------------------------------------------------

    /// 清空页面状态，同时把 generation 推进一格，让旧任务的结果失效。
    pub(in crate::settings) fn reset_run_state(&mut self) {
        let generation = self.run.generation.wrapping_add(1);
        self.run = crate::settings::state::RunConfigurationsState::new();
        self.run.generation = generation;
        self.run_editor_pending = None;
    }

    /// 首次进入页面或项目变化后读取配置；已经加载过就复用。
    pub(in crate::settings) fn ensure_run_loaded(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.context.project_root.clone() else {
            self.reset_run_state();
            return;
        };
        if self.run.root.as_ref() == Some(&root) {
            return;
        }
        self.reload_run_configurations(cx);
    }

    /// 后台读取设置页快照：inspect、工具链发现和 resolve。
    pub(in crate::settings) fn reload_run_configurations(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.context.project_root.clone() else {
            self.reset_run_state();
            cx.notify();
            return;
        };
        self.run.root = Some(root.clone());
        self.run.generation = self.run.generation.wrapping_add(1);
        let generation = self.run.generation;
        self.run.loading = true;
        self.run.error = None;
        self.run.save_error = None;
        cx.notify();

        let client = CoreClient::new();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor().spawn(
                    async move { config::load_settings_snapshot(&client, &root) },
                )
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.run.generation != generation {
                    return;
                }
                this.run.loading = false;
                match result {
                    Ok(snapshot) => this.apply_run_snapshot(snapshot, cx),
                    Err(error) => {
                        this.run.ready = false;
                        this.run.error = Some(error);
                        cx.notify();
                    }
                }
            });
        })
        .detach();
    }

    pub(in crate::settings) fn apply_run_snapshot(
        &mut self,
        snapshot: config::RunSettingsSnapshot,
        cx: &mut Context<Self>,
    ) {
        self.run.ready = snapshot.ready;
        self.run.requires_generation = snapshot.requires_generation;
        self.run.configurations = snapshot.configurations;
        self.run.diagnostics = snapshot.diagnostics;
        self.run.discovered = snapshot.discovered;
        self.run.global_toolchain = snapshot.toolchain;
        self.run.maven_executable_path = snapshot.maven_executable_path;
        self.run.maven_java_home_path = snapshot.maven_java_home_path;
        self.run.error = None;

        if self.run.editing_id.as_ref().is_some_and(|id| {
            !self
                .run
                .configurations
                .iter()
                .any(|configuration| &configuration.id == id)
        }) {
            self.run.editing_id = None;
        }
        if let Some(id) = self.run.pending_edit.take() {
            if self
                .run
                .configurations
                .iter()
                .any(|configuration| configuration.id == id)
            {
                self.open_run_editor(id, cx);
            }
        }
        cx.notify();
    }

    /// 重新识别项目并写回生成层。
    pub(in crate::settings) fn generate_run_configurations(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.run.root.clone().or_else(|| self.context.project_root.clone()) else {
            return;
        };
        if self.run.generating {
            return;
        }
        let generation = self.run.generation;
        self.run.generating = true;
        self.run.error = None;
        self.run.generation_notice = None;
        cx.notify();

        let client = CoreClient::new();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor().spawn(
                    async move { config::generate_configurations(&client, &root) },
                )
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.run.generation != generation {
                    return;
                }
                this.run.generating = false;
                match result {
                    Ok(count) => {
                        this.run.generation_notice = Some(
                            tr("Generated {count} runnable project entries.")
                                .replace("{count}", &count.to_string()),
                        );
                        this.notify_run_configurations_changed(cx);
                        this.reload_run_configurations(cx);
                    }
                    Err(error) => {
                        this.run.error = Some(error);
                        cx.notify();
                    }
                }
            });
        })
        .detach();
    }

    /// 打开一条配置的编辑器；已与项目默认值相同的路径清空为「继承」。
    pub(in crate::settings) fn open_run_editor(&mut self, id: String, cx: &mut Context<Self>) {
        let Some(configuration) = self
            .run
            .configurations
            .iter()
            .find(|configuration| configuration.id == id)
            .cloned()
        else {
            return;
        };
        self.run.pending_edit = None;
        self.run.editing_id = Some(configuration.id.clone());
        self.run.scope = RunSaveScope::Local;
        self.run.save_error = None;
        self.run.toolchain_draft = self.run.global_toolchain.clone();

        let mut draft = configuration.editor_options();
        if config::same_windows_path(
            &draft.java_home_path,
            &self.run.global_toolchain.java_home_path,
        ) {
            draft.java_home_path.clear();
        }
        if config::same_windows_path(
            &draft.maven_executable_path,
            &self.run.global_toolchain.maven_executable_path,
        ) {
            draft.maven_executable_path.clear();
        }
        if config::same_windows_path(
            &draft.maven_java_home_path,
            &self.run.global_toolchain.maven_java_home_path,
        ) {
            draft.maven_java_home_path.clear();
        }
        self.run_editor_pending = Some(RunEditorInputs {
            arguments: draft.program_arguments.clone(),
            vm_arguments: draft.vm_arguments.clone(),
            working_directory: draft.working_directory_path.clone(),
            environment: config::environment_text(&draft.environment),
        });
        self.run.draft = draft;
        self.schedule_run_resolve(cx);
        cx.notify();
    }

    pub(in crate::settings) fn close_run_editor(&mut self, cx: &mut Context<Self>) {
        self.run.editing_id = None;
        self.run.save_error = None;
        self.run.resolve_generation = self.run.resolve_generation.wrapping_add(1);
        cx.notify();
    }

    /// 三百毫秒防抖后解析生效工具链；被新选择替换的结果直接丢弃。
    pub(in crate::settings) fn schedule_run_resolve(&mut self, cx: &mut Context<Self>) {
        let Some(configuration) = self
            .run
            .editing_id
            .as_ref()
            .and_then(|id| {
                self.run
                    .configurations
                    .iter()
                    .find(|configuration| &configuration.id == id)
            })
            .cloned()
        else {
            return;
        };
        if !configuration.uses_java() && !configuration.uses_maven() {
            self.run.effective = toolchain::EffectiveToolchains::detecting();
            cx.notify();
            return;
        }
        let Some(root) = self.run.root.clone() else {
            return;
        };
        let selection = self.run.draft.toolchain_paths().launch_selection(
            &self.run.global_toolchain,
            &self.run.maven_executable_path,
            &self.run.maven_java_home_path,
        );
        self.run.resolve_generation = self.run.resolve_generation.wrapping_add(1);
        let generation = self.run.resolve_generation;
        self.run.effective = toolchain::EffectiveToolchains::detecting();
        cx.notify();

        cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(300))
                .await;
            // 计时器到期前又有新选择时不再探测，避免连续点击拉起多轮进程。
            let still_current = this
                .update(cx, |this, _cx| this.run.resolve_generation == generation)
                .unwrap_or(false);
            if !still_current {
                return;
            }
            let resolved = cx
                .background_executor().spawn(async move {
                    toolchain::resolve_for_display(
                        &root,
                        &selection.java_home_path,
                        &selection.maven_executable_path,
                        &selection.maven_java_home_path,
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.run.resolve_generation == generation {
                    this.run.effective = toolchain::EffectiveToolchains::resolved(resolved);
                    cx.notify();
                }
            });
        })
        .detach();
    }

    /// 下拉选择工具链；Node 只影响保存，不触发 JDK/Maven 解析。
    pub(in crate::settings) fn set_run_toolchain(
        &mut self,
        field: RunToolchainField,
        value: String,
        cx: &mut Context<Self>,
    ) {
        match field {
            RunToolchainField::JavaHome => self.run.draft.java_home_path = value,
            RunToolchainField::MavenExecutable => self.run.draft.maven_executable_path = value,
            RunToolchainField::MavenJavaHome => self.run.draft.maven_java_home_path = value,
            RunToolchainField::Node => {
                let paths = &mut self.run.toolchain_draft.runtime_executable_paths;
                if value.trim().is_empty() {
                    paths.remove("project-node");
                } else {
                    paths.insert("project-node".to_string(), value);
                }
                cx.notify();
                return;
            }
        }
        self.schedule_run_resolve(cx);
        cx.notify();
    }

    pub(in crate::settings) fn set_run_scope(&mut self, scope: RunSaveScope, cx: &mut Context<Self>) {
        if self.run.scope == scope {
            return;
        }
        self.run.scope = scope;
        cx.notify();
    }

    pub(in crate::settings) fn set_run_maven_tests(&mut self, value: Option<bool>, cx: &mut Context<Self>) {
        if self.run.draft.maven_skip_tests == value {
            return;
        }
        self.run.draft.maven_skip_tests = value;
        cx.notify();
    }

    pub(in crate::settings) fn run_editor_input_values(&self, cx: &Context<Self>) -> RunEditorInputs {
        RunEditorInputs {
            arguments: self.run_argument_input.read(cx).value().to_string(),
            vm_arguments: self.run_vm_input.read(cx).value().to_string(),
            working_directory: self.run_working_input.read(cx).value().to_string(),
            environment: self.run_environment_input.read(cx).value().to_string(),
        }
    }

    /// 保存前把输入框内容写回草稿。
    pub(in crate::settings) fn sync_run_draft_inputs(&mut self, cx: &Context<Self>) {
        if self.run.editing_id.is_none() {
            return;
        }
        let inputs = self.run_editor_input_values(cx);
        self.run.draft.program_arguments = inputs.arguments;
        self.run.draft.vm_arguments = inputs.vm_arguments;
        self.run.draft.working_directory_path = inputs.working_directory;
        self.run.draft.environment = config::environment_from_text(&inputs.environment);
    }

    /// 打开目录/文件选择器；工作目录回填输入框，其余回填草稿。
    pub(in crate::settings) fn browse_run_path(&mut self, field: RunPathField, cx: &mut Context<Self>) {
        let title = match field {
            RunPathField::JavaHome => tr("JDK Home"),
            RunPathField::MavenExecutable => tr("Maven executable"),
            RunPathField::MavenJavaHome => tr("JDK Home"),
            RunPathField::Node => tr("Node.js executable"),
            RunPathField::WorkingDirectory => tr("Working directory"),
        }
        .to_string();
        let platform = platform::current();
        cx.spawn(async move |this, cx| {
            let picked = if field == RunPathField::Node {
                platform.pick_file(title, Vec::new()).await
            } else {
                platform.pick_folder(title).await
            };
            let Some(path) = picked else {
                return;
            };
            let _ = this.update(cx, |this, cx| {
                let text = path.to_string_lossy().into_owned();
                match field {
                    RunPathField::JavaHome => {
                        this.set_run_toolchain(RunToolchainField::JavaHome, text, cx);
                    }
                    RunPathField::MavenExecutable => {
                        this.set_run_toolchain(RunToolchainField::MavenExecutable, text, cx);
                    }
                    RunPathField::MavenJavaHome => {
                        this.set_run_toolchain(RunToolchainField::MavenJavaHome, text, cx);
                    }
                    RunPathField::Node => {
                        this.set_run_toolchain(RunToolchainField::Node, text, cx);
                    }
                    RunPathField::WorkingDirectory => {
                        let mut pending = this
                            .run_editor_pending
                            .take()
                            .unwrap_or_else(|| this.run_editor_input_values(cx));
                        pending.working_directory = text;
                        this.run.draft.working_directory_path = pending.working_directory.clone();
                        this.run_editor_pending = Some(pending);
                        cx.notify();
                    }
                }
            });
        })
        .detach();
    }

    /// 保存编辑器：重新读取项目工具链、写回三份文档并刷新快照。
    pub(in crate::settings) fn save_run_configuration(&mut self, cx: &mut Context<Self>) {
        let (Some(root), Some(id)) = (self.run.root.clone(), self.run.editing_id.clone()) else {
            return;
        };
        if self.run.saving {
            return;
        }
        self.sync_run_draft_inputs(cx);
        let options = self.run.draft.clone();
        let toolchain_draft = self.run.toolchain_draft.clone();
        let scope = self.run.scope;
        let generation = self.run.generation;
        self.run.saving = true;
        self.run.save_error = None;
        cx.notify();

        let client = CoreClient::new();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor().spawn(async move {
                    let documents = config::save_editor_changes(
                        &client,
                        &root,
                        &id,
                        scope,
                        &options,
                        &toolchain_draft,
                    )?;
                    config::write_editor_documents(&root, &documents)?;
                    config::load_settings_snapshot(&client, &root)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.run.generation != generation {
                    return;
                }
                this.run.saving = false;
                match result {
                    Ok(snapshot) => {
                        this.run.editing_id = None;
                        this.apply_run_snapshot(snapshot, cx);
                        this.notify_run_configurations_changed(cx);
                    }
                    Err(error) => {
                        this.run.save_error = Some(error);
                        cx.notify();
                    }
                }
            });
        })
        .detach();
    }

    pub(in crate::settings) fn notify_run_configurations_changed(&self, cx: &mut Context<Self>) {
        if let Some(handler) = self.on_run_configurations_changed.as_ref() {
            handler(cx);
        }
    }
}
