//! Project · JDK & Maven 页：Maven 项目级四字段的草稿编辑与生效展示，外加
//! 用户级 `~/.m2/settings.xml` 的 `<localRepository>` 编辑与项目工具链跳板。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::{Disableable as _, Sizable as _, h_flex, v_flex};
use gpui_kit::{
    AnyElement, ClickEvent, Context, IntoElement, ParentElement as _, SharedString,
    Styled, div, px,
};
use lithe_platform as platform;
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, MONO_FONT_FAMILY, icon};

use crate::maven::configuration::{self, MavenLocalSettings};
use crate::maven::user_settings::{
    self, CONFLICT_ERROR, MavenUserSettingsSnapshot, MavenUserSettingsStatus,
};
use crate::settings::controls::{note_card, project_root_label, readonly_row, section_card};
use crate::settings::state::SETTINGS_BUTTON_HEIGHT;
use crate::settings::state::SETTINGS_BUTTON_RADIUS;
use crate::settings::state::SETTINGS_CONTROL_GAP;
use crate::settings::state::SETTINGS_SECTION_GAP;
use crate::settings::SettingsView;

// ---------------------------------------------------------------------------
// 用户级 Maven settings.xml（Source-backed：~/.m2/settings.xml 的 localRepository）
// ---------------------------------------------------------------------------

/// 用户级 Maven 设置状态：发现 → 草稿 → 确认写入（revision 冲突保护）→ 回读。
///
/// 读写经 `maven::user_settings`（与 Tauri 宿主同一模块语义的 gpui 移植），
/// revision 是文件内容的 SHA-256；阻塞 I/O 全部走 `background_spawn`。
#[derive(Clone, Debug, Default)]
pub(in crate::settings) struct MavenUserState {
    pub(in crate::settings) loaded: bool,
    pub(in crate::settings) busy: bool,
    pub(in crate::settings) snapshot: Option<MavenUserSettingsSnapshot>,
    pub(in crate::settings) error: Option<String>,
    pub(in crate::settings) notice: Option<String>,
    pub(in crate::settings) conflict: bool,
}

impl SettingsView {
    pub(in crate::settings) fn render_project(
        &mut self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let project_root_row = readonly_row(
            "Project root",
            project_root_label(self.context.project_root.as_ref()),
            tokens,
        );

        // Maven 设置表单：无项目时展示说明；有项目时四个字段的草稿编辑 +
        // 检测值提示 + 应用按钮（对齐 Tauri `MavenSettingsForm`）。
        let Some(root) = self.context.project_root.clone() else {
            return div()
                .w_full()
                .flex()
                .flex_col()
                .gap(px(SETTINGS_SECTION_GAP))
                .child(section_card(
                    "Project",
                    None,
                    project_root_row.into_any_element(),
                    tokens,
                ))
                .child(note_card(
                    SharedString::from(tr(
                        "Open a Maven project to configure its settings.xml, local repository, Maven executable and JDK home.",
                    )),
                    tokens,
                ))
                .into_any_element();
        };
        let _ = root;

        let mut fields = v_flex().w_full().gap(px(SETTINGS_SECTION_GAP));
        let resolutions = [
            self.maven_effective.as_ref().map(|e| &e.settings_path),
            self.maven_effective
                .as_ref()
                .map(|e| &e.local_repository_path),
            self.maven_effective
                .as_ref()
                .map(|e| &e.maven_executable_path),
            self.maven_effective.as_ref().map(|e| &e.java_home_path),
        ];
        for (index, (label, _directory)) in Self::MAVEN_FIELDS.iter().enumerate() {
            let resolution = resolutions[index];
            let mut row = v_flex()
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
                            Input::new(&self.maven_inputs[index])
                                .small()
                                .w_full()
                                .font_family(MONO_FONT_FAMILY),
                        )
                        .child(
                            Button::new(SharedString::from(format!(
                                "lithe-settings:maven-clear:{index}"
                            )))
                            .ghost()
                            .small()
                            .icon(icon(LitheIcon::Close))
                            .tooltip(tr("Clear"))
                            .on_click(cx.listener(
                                move |this, _: &ClickEvent, _window, cx| {
                                    let mut pending = this
                                        .maven_pending_inputs
                                        .take()
                                        .unwrap_or_else(|| this.maven_draft_values(cx));
                                    pending[index] = String::new();
                                    this.maven_pending_inputs = Some(pending);
                                    cx.notify();
                                },
                            )),
                        )
                        .child(
                            Button::new(SharedString::from(format!(
                                "lithe-settings:maven-browse:{index}"
                            )))
                            .ghost()
                            .small()
                            .icon(icon(LitheIcon::Folder))
                            .tooltip(tr("Browse"))
                            .on_click(cx.listener(
                                move |this, _: &ClickEvent, _window, cx| {
                                    this.browse_maven_field(index, cx);
                                },
                            )),
                        ),
                );

            // 检测值 / 生效值提示（对齐 Tauri `MavenDetectedValue`）。
            if let Some(resolution) = resolution {
                let effective = resolution.effective.clone().unwrap_or_default();
                let detected = resolution.detected.clone().unwrap_or_default();
                let hint: SharedString = if effective.is_empty() {
                    tr("Not detected").into()
                } else if detected.is_empty() || detected == effective {
                    SharedString::from(format!("{} · {}", tr("In effect"), effective))
                } else {
                    SharedString::from(format!(
                        "{} · {}\n{}: {}",
                        tr("In effect"),
                        effective,
                        tr("Detected"),
                        detected
                    ))
                };
                row = row.child(
                    div()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.tertiary_text)
                        .child(hint),
                );
            }
            fields = fields.child(row);
        }

        let dirty = self.maven_dirty(cx);
        let maven_conflict = self.maven_conflict;
        let mut card = v_flex()
            .w_full()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(fields);
        if maven_conflict {
            // Tauri project 环境保存用 revision ref 防并发覆盖；gpui 在
            // apply 前重读发现结果，来源变了就拒绝草稿并要求重载。
            card = card.child(
                h_flex()
                    .w_full()
                    .items_center()
                    .justify_between()
                    .gap(px(SETTINGS_CONTROL_GAP))
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.warning)
                            .child(tr(crate::settings::source_backed::CONFLICT_MESSAGE)),
                    )
                    .child(
                        Button::new("lithe-settings:maven-reload")
                            .small()
                            .h(px(SETTINGS_BUTTON_HEIGHT))
                            .rounded(px(SETTINGS_BUTTON_RADIUS))
                            .secondary()
                            .label(tr("Reload"))
                            .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                                this.reload_maven_configuration(cx);
                            })),
                    ),
            );
        } else if let Some(error) = self.maven_error.clone() {
            card = card.child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.error)
                    .child(error),
            );
        }
        card = card.child(
            h_flex()
                .w_full()
                .justify_end()
                .gap(px(SETTINGS_CONTROL_GAP))
                // Tauri project-environment-settings 的「刷新发现」按钮。
                .child(
                    Button::new("lithe-settings:maven-refresh")
                        .small()
                        .h(px(SETTINGS_BUTTON_HEIGHT))
                        .rounded(px(SETTINGS_BUTTON_RADIUS))
                        .secondary()
                        .label(tr("Refresh"))
                        .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                            this.reload_maven_configuration(cx);
                        })),
                )
                .child(
                    Button::new("lithe-settings:maven-apply")
                        .small()
                        .h(px(SETTINGS_BUTTON_HEIGHT))
                        .rounded(px(SETTINGS_BUTTON_RADIUS))
                        .primary()
                        .label(tr("Apply"))
                        .disabled(!dirty)
                        .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                            this.apply_maven_configuration(cx);
                        })),
                ),
        );

        // 用户级 Maven settings.xml（Source-backed：~/.m2/settings.xml）。
        self.reload_maven_user(false, cx);
        let mut column = div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card("Maven", None, card.into_any_element(), tokens))
            .child(self.render_maven_user(tokens, cx));

        // 项目工具链默认值（Tauri project-environment 三字段的 gpui 归属）：
        // 显示生效快照并提供跳板；编辑保留在 Run Configurations 页——gpui 的
        // 项目级 JDK / Maven / Maven JDK 默认值由 run 文档链路统一写回。
        if let Some(resolutions) = self.maven_effective.as_ref() {
            let toolchain = v_flex()
                .w_full()
                .gap(px(SETTINGS_CONTROL_GAP))
                .child(readonly_row(
                    "JDK Home",
                    SharedString::from(
                        resolutions
                            .java_home_path
                            .effective
                            .clone()
                            .unwrap_or_else(|| tr("Automatic").to_string()),
                    ),
                    tokens,
                ))
                .child(readonly_row(
                    "Maven executable",
                    SharedString::from(
                        resolutions
                            .maven_executable_path
                            .effective
                            .clone()
                            .unwrap_or_else(|| tr("Automatic").to_string()),
                    ),
                    tokens,
                ))
                // Maven JDK Home 属于 Run 工具链覆盖；这里不复制数据，
                // 展示说明并跳转到统一的编辑入口。
                .child(
                    div()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.tertiary_text)
                        .child(tr(
                            "Maven JDK Home is an override stored with the run toolchain; edit it in Run Configurations.",
                        )),
                )
                .child(
                    div().w_full().child(
                        Button::new("lithe-settings:project-toolchain-edit")
                            .small()
                            .h(px(SETTINGS_BUTTON_HEIGHT))
                            .rounded(px(SETTINGS_BUTTON_RADIUS))
                            .secondary()
                            .label(tr("Edit in Run Configurations"))
                            .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                                this.open_run_configurations_page(cx);
                            })),
                    ),
                );
            column = column.child(section_card(
                "Toolchain defaults",
                None,
                toolchain.into_any_element(),
                tokens,
            ));
        }

        column.into_any_element()
    }

    // -----------------------------------------------------------------
    // Maven 项目配置（Source-backed：读真实来源 → 草稿 → 确认写回 → 回读）
    // -----------------------------------------------------------------

    /// 重新读取 Maven 项目配置并解析生效值。
    pub(in crate::settings) fn reload_maven_configuration(&mut self, cx: &mut Context<Self>) {
        self.maven_conflict = false;
        let Some(root) = self.context.project_root.clone() else {
            self.maven_saved = MavenLocalSettings::default();
            self.maven_effective = None;
            self.maven_pending_inputs = Some(Default::default());
            return;
        };
        let saved = configuration::load_local(&root, &self.maven_reactor);
        self.maven_pending_inputs = Some([
            saved.settings_path.clone().unwrap_or_default(),
            saved.local_repository_path.clone().unwrap_or_default(),
            saved.maven_executable_path.clone().unwrap_or_default(),
            saved.java_home_path.clone().unwrap_or_default(),
        ]);
        self.maven_saved = saved;
        self.maven_error = None;
        cx.notify();

        // 生效解析做文件探测，放后台；JAVA_HOME 检测值取本机环境变量
        // （与启动解析的默认来源一致；项目级覆盖解析由 resolve_effective 处理）。
        let java_home = std::env::var("JAVA_HOME")
            .ok()
            .filter(|value| !value.is_empty());
        let saved_for_resolve = self.maven_saved.clone();
        cx.spawn(async move |this, cx| {
            let effective = cx
                .background_executor().spawn(async move {
                    configuration::resolve_effective(&root, ".", &saved_for_resolve, java_home)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.maven_effective = Some(effective);
                cx.notify();
            });
        })
        .detach();
    }

    /// 四个字段的标签与选择模式（文件 / 目录）。
    pub(super) const MAVEN_FIELDS: [(&'static str, bool); 4] = [
        ("settings.xml", false),
        ("Maven local repository", true),
        ("Maven executable", true),
        ("JDK Home", true),
    ];

    /// 当前草稿与已保存值是否不同；不同才允许应用。
    pub(in crate::settings) fn maven_dirty(&self, cx: &Context<Self>) -> bool {
        let values = self.maven_draft_values(cx);
        values
            .iter()
            .zip([
                self.maven_saved.settings_path.as_deref(),
                self.maven_saved.local_repository_path.as_deref(),
                self.maven_saved.maven_executable_path.as_deref(),
                self.maven_saved.java_home_path.as_deref(),
            ])
            .any(|(draft, saved)| draft.trim() != saved.unwrap_or(""))
    }

    pub(in crate::settings) fn maven_draft_values(&self, cx: &Context<Self>) -> [String; 4] {
        [
            self.maven_inputs[0].read(cx).value().to_string(),
            self.maven_inputs[1].read(cx).value().to_string(),
            self.maven_inputs[2].read(cx).value().to_string(),
            self.maven_inputs[3].read(cx).value().to_string(),
        ]
    }

    /// 应用草稿：写回项目 Maven 配置（双写 Tauri/gpui 数据目录），成功后
    /// 重新解析生效值展示。
    ///
    /// 冲突保护：写前重读磁盘上的当前保存值；期间被其他窗口/产品改过即拒绝
    /// 草稿（对齐 Tauri project-environment 的 revision ref 语义），置
    /// `maven_conflict` 并要求用户 Reload。
    pub(in crate::settings) fn apply_maven_configuration(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.context.project_root.clone() else {
            return;
        };
        // 写前重读：与打开页面时的快照比对。
        let current = configuration::load_local(&root, &self.maven_reactor);
        if current != self.maven_saved {
            self.maven_conflict = true;
            cx.notify();
            return;
        }
        self.maven_conflict = false;
        let values = self.maven_draft_values(cx);
        let saved = MavenLocalSettings {
            settings_path: Some(values[0].clone()).filter(|value| !value.trim().is_empty()),
            local_repository_path: Some(values[1].clone()).filter(|value| !value.trim().is_empty()),
            maven_executable_path: Some(values[2].clone()).filter(|value| !value.trim().is_empty()),
            java_home_path: Some(values[3].clone()).filter(|value| !value.trim().is_empty()),
        };
        match configuration::save_local(&root, &self.maven_reactor, &saved) {
            Ok(()) => {
                self.maven_error = None;
                self.maven_saved = saved;
                // 保存后重新解析生效配置，让「当前生效」提示反映新值。
                let java_home = std::env::var("JAVA_HOME")
                    .ok()
                    .filter(|value| !value.is_empty());
                let saved_for_resolve = self.maven_saved.clone();
                cx.spawn(async move |this, cx| {
                    let effective = cx
                        .background_executor().spawn(async move {
                            configuration::resolve_effective(
                                &root,
                                ".",
                                &saved_for_resolve,
                                java_home,
                            )
                        })
                        .await;
                    let _ = this.update(cx, |this, cx| {
                        this.maven_effective = Some(effective);
                        cx.notify();
                    });
                })
                .detach();
                cx.notify();
            }
            Err(error) => {
                self.maven_error = Some(error);
                cx.notify();
            }
        }
    }

    /// 打开目录/文件选择器并回填对应草稿输入框。
    pub(in crate::settings) fn browse_maven_field(&mut self, index: usize, cx: &mut Context<Self>) {
        let (label, is_directory) = Self::MAVEN_FIELDS[index];
        let title = tr(label).to_string();
        let platform = platform::current();
        cx.spawn(async move |this, cx| {
            let picked = if is_directory {
                platform.pick_folder(title).await
            } else {
                platform
                    .pick_file(
                        title,
                        vec![platform::FileFilter {
                            name: String::from("XML"),
                            extensions: vec![String::from("xml")],
                        }],
                    )
                    .await
            };
            if let Some(path) = picked {
                let _ = this.update(cx, |this, cx| {
                    let text = path.to_string_lossy().into_owned();
                    let mut pending = this
                        .maven_pending_inputs
                        .take()
                        .unwrap_or_else(|| this.maven_draft_values(cx));
                    pending[index] = text;
                    this.maven_pending_inputs = Some(pending);
                    cx.notify();
                });
            }
        })
        .detach();
    }

    // -----------------------------------------------------------------
    // 用户级 Maven settings.xml：发现 → 草稿 → 确认写入（revision）→ 回读
    // -----------------------------------------------------------------

    /// 读取 `~/.m2/settings.xml` 快照。文件很小，但为了不阻塞界面借用，
    /// 读取仍然放到 `background_spawn`。
    ///
    /// `force=false` 只做一次发现（渲染时反复调用）；用户点 Reload / 保存后
    /// 才传 `force=true`。
    pub(in crate::settings) fn reload_maven_user(&mut self, force: bool, cx: &mut Context<Self>) {
        if self.maven_user.busy || (self.maven_user.loaded && !force) {
            return;
        }
        self.maven_user.loaded = true;
        self.maven_user.busy = true;
        self.maven_user.error = None;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let result = cx.background_executor().spawn(async move {
                user_settings::user_home().and_then(|home| user_settings::read(&home))
            });
            let snapshot = result.await;
            let _ = this.update(cx, |this, cx| {
                this.maven_user.busy = false;
                match snapshot {
                    Ok(snapshot) => {
                        let declared = snapshot.local_repository.clone().unwrap_or_default();
                        this.maven_user.snapshot = Some(snapshot);
                        this.maven_user.conflict = false;
                        this.maven_user.error = None;
                        // 输入框回填需要 Window，统一在渲染帧应用。
                        this.maven_user_pending = Some(declared);
                    }
                    Err(error) => {
                        this.maven_user.error = Some(error);
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 保存草稿到 `~/.m2/settings.xml`；`revision` 冲突时 UI 提示 Reload。
    pub(in crate::settings) fn apply_maven_user(&mut self, cx: &mut Context<Self>) {
        let Some(snapshot) = self.maven_user.snapshot.clone() else {
            return;
        };
        if self.maven_user.busy {
            return;
        }
        let draft = self.maven_user_input.read(cx).value().trim().to_string();
        if draft.is_empty() {
            self.maven_user.error =
                Some(tr("Enter a Maven local repository path.").to_string());
            cx.notify();
            return;
        }
        self.maven_user.busy = true;
        self.maven_user.error = None;
        self.maven_user.notice = None;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let result = cx.background_executor().spawn(async move {
                user_settings::user_home()
                    .and_then(|home| {
                        user_settings::write_local_repository(
                            &home,
                            &draft,
                            snapshot.revision.as_deref(),
                        )
                    })
            });
            let outcome = result.await;
            let _ = this.update(cx, |this, cx| {
                this.maven_user.busy = false;
                match outcome {
                    Ok(snapshot) => {
                        let declared = snapshot.local_repository.clone().unwrap_or_default();
                        this.maven_user.snapshot = Some(snapshot);
                        this.maven_user.conflict = false;
                        this.maven_user.error = None;
                        this.maven_user.notice = Some(
                            tr("Saved. Reload projects to pick up the new repository location.")
                                .to_string(),
                        );
                        this.maven_user_pending = Some(declared);
                    }
                    Err(error) => {
                        // 错误统一为 code + OS 文本；code 由界面翻译。
                        let code = user_settings_error_code(&error);
                        this.maven_user.conflict = code == CONFLICT_ERROR;
                        this.maven_user.error = Some(user_settings_message(code, &error));
                        this.reload_maven_user(true, cx);
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn render_maven_user(&self, tokens: LitheTokens, cx: &Context<Self>) -> AnyElement {
        // 用户输入框的回填在 mod.rs 的 Render 里应用（需要 Window）；这里
        // 出现的 pending 值已在渲染帧开头消耗完毕。
        let mut body = v_flex().w_full().gap(px(SETTINGS_CONTROL_GAP));
        let Some(snapshot) = self.maven_user.snapshot.as_ref() else {
            if self.maven_user.busy {
                body = body.child(note_card(SharedString::from(tr("Working…")), tokens));
            } else if let Some(error) = self.maven_user.error.as_ref() {
                body = body.child(note_card(SharedString::from(error.clone()), tokens));
            }
            return section_card(
                "User settings.xml",
                None,
                body.into_any_element(),
                tokens,
            );
        };

        // 路径 + 状态说明（对齐 Tauri `MavenUserSettingsGroup` 的三态标注）。
        body = body
            .child(readonly_row(
                "File",
                SharedString::from(snapshot.path.clone()),
                tokens,
            ))
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(SharedString::from(match snapshot.status {
                        MavenUserSettingsStatus::Missing => tr(
                            "The file does not exist yet; saving creates a minimal Maven settings.xml.",
                        )
                        .to_string(),
                        MavenUserSettingsStatus::Readable => {
                            // 未声明仓库时 Maven 用默认位置；说明一并展示。
                            match snapshot.local_repository.as_deref() {
                                Some(declared) => format!(
                                    "{} · {}",
                                    tr("Declared in this file"),
                                    declared
                                ),
                                None => tr("No local repository declared; Maven uses its default location.")
                                    .to_string(),
                            }
                        }
                        MavenUserSettingsStatus::Invalid => tr(
                            "The file is not a valid Maven settings.xml; fix it outside Lithe before editing here.",
                        )
                        .to_string(),
                    })),
            );
        if !snapshot.default_local_repository.is_empty() {
            body = body.child(readonly_row(
                "Default location",
                SharedString::from(snapshot.default_local_repository.clone()),
                tokens,
            ));
        }

        let dirty = {
            let draft = self.maven_user_input.read(cx).value().trim().to_string();
            let declared = snapshot.local_repository.clone().unwrap_or_default();
            snapshot.status != MavenUserSettingsStatus::Invalid && draft != declared
        };

        if self.maven_user.conflict {
            body = body.child(
                h_flex()
                    .w_full()
                    .items_center()
                    .justify_between()
                    .gap(px(SETTINGS_CONTROL_GAP))
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.warning)
                            .child(tr(crate::settings::source_backed::CONFLICT_MESSAGE)),
                    )
                    .child(
                        Button::new("lithe-settings:maven-user-reload")
                            .small()
                            .h(px(SETTINGS_BUTTON_HEIGHT))
                            .rounded(px(SETTINGS_BUTTON_RADIUS))
                            .secondary()
                            .label(tr("Reload"))
                            .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                                this.reload_maven_user(true, cx);
                            })),
                    ),
            );
        }
        if let Some(notice) = self.maven_user.notice.as_ref() {
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(SharedString::from(notice.clone())),
            );
        }

        body = body
            .child(
                h_flex()
                    .w_full()
                    .gap(px(6.0))
                    .child(
                        Input::new(&self.maven_user_input)
                            .small()
                            .w_full()
                            .font_family(MONO_FONT_FAMILY),
                    ),
            )
            .child(
                h_flex().w_full().justify_end().gap(px(SETTINGS_CONTROL_GAP)).child(
                    Button::new("lithe-settings:maven-user-save")
                        .small()
                        .h(px(SETTINGS_BUTTON_HEIGHT))
                        .rounded(px(SETTINGS_BUTTON_RADIUS))
                        .primary()
                        .label(tr("Save"))
                        .disabled(
                            self.maven_user.busy
                                || !dirty
                                || snapshot.status == MavenUserSettingsStatus::Invalid,
                        )
                        .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                            this.apply_maven_user(cx);
                        })),
                ),
            );

        if !self.maven_user.conflict {
            if let Some(error) = self.maven_user.error.as_ref() {
                body = body.child(
                    div()
                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                        .text_color(tokens.error)
                        .child(SharedString::from(error.clone())),
                );
            }
        }

        section_card("User settings.xml", None, body.into_any_element(), tokens)
    }
}

/// 把 user_settings 错误拆出 code 前缀（`code: detail`）。
fn user_settings_error_code(error: &str) -> &'static str {
    for code in [
        CONFLICT_ERROR,
        user_settings::INVALID_ERROR,
        user_settings::EMPTY_ERROR,
        user_settings::NO_HOME_ERROR,
    ] {
        if error == code || error.starts_with(&format!("{code}:")) {
            return match code {
                CONFLICT_ERROR => CONFLICT_ERROR,
                user_settings::INVALID_ERROR => user_settings::INVALID_ERROR,
                user_settings::EMPTY_ERROR => user_settings::EMPTY_ERROR,
                user_settings::NO_HOME_ERROR => user_settings::NO_HOME_ERROR,
                _ => "",
            };
        }
    }
    ""
}

/// 错误 code → 界面文案；未知 code 原样展示（OS/IO 细节不翻译）。
fn user_settings_message(code: &'static str, error: &str) -> String {
    let detail = error.split_once(':').map(|(_, detail)| detail.trim());
    match code {
        CONFLICT_ERROR => tr(crate::settings::source_backed::CONFLICT_MESSAGE)
            .to_string(),
        user_settings::INVALID_ERROR => tr("The file is not a valid Maven settings.xml.").to_string(),
        user_settings::EMPTY_ERROR => tr("Enter a Maven local repository path.").to_string(),
        user_settings::NO_HOME_ERROR => tr("Could not determine the user home directory.").to_string(),
        _ => detail.map(str::to_string).unwrap_or_else(|| error.to_string()),
    }
}
