//! Logs and Diagnostics 页：时间线筛选、诊断开关、日志位置与诊断包。

use std::path::PathBuf;

use gpui_kit::component::input::Input;
use gpui_kit::component::{Sizable as _, h_flex, v_flex};
use gpui_kit::{
    AnyElement, ClickEvent, Context, InteractiveElement as _, IntoElement, ParentElement as _,
    SharedString, StatefulInteractiveElement as _, Styled, div, px,
};
use lithe_platform as platform;
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens, MONO_FONT_FAMILY};

use crate::logging;
use crate::settings::controls::{
    caption_line, code_text, confirm_strip, described_row, log_button, log_category_title,
    log_choice_row, log_fallback_description, note_card, section_card, switch_control,
};
use crate::settings::state::{
    LOG_CATEGORY_OPTIONS, LOG_LEVEL_OPTIONS, LOG_SESSION_OPTIONS, SETTINGS_CONTROL_GAP,
    SETTINGS_SECTION_GAP,
};
use crate::settings::SettingsView;

impl SettingsView {
    // -----------------------------------------------------------------
    // Logs and Diagnostics 数据方法
    // -----------------------------------------------------------------

    pub(in crate::settings) fn set_log_category(&mut self, value: &'static str, cx: &mut Context<Self>) {
        if self.logs.category == value {
            return;
        }
        self.logs.category = value.to_string();
        self.logs.timeline = None;
        cx.notify();
    }

    pub(in crate::settings) fn set_log_session(&mut self, value: &'static str, cx: &mut Context<Self>) {
        if self.logs.session == value {
            return;
        }
        self.logs.session = value.to_string();
        self.logs.timeline = None;
        cx.notify();
    }

    pub(in crate::settings) fn set_log_level(&mut self, value: &'static str, cx: &mut Context<Self>) {
        if self.logs.level == value {
            return;
        }
        self.logs.level = value.to_string();
        self.logs.timeline = None;
        cx.notify();
    }

    pub(in crate::settings) fn refresh_log_timeline(&mut self, cx: &mut Context<Self>) {
        self.logs.reload_timeline();
        self.logs.notice = None;
        self.logs.error = None;
        cx.notify();
    }

    pub(in crate::settings) fn set_diagnostic_logging(&mut self, enabled: bool, cx: &mut Context<Self>) {
        let category = self.logs.selection().category;
        logging::set_diagnostic_logging(enabled, category.as_deref());
        self.logs.reload_timeline();
        cx.notify();
    }

    /// 选择自定义日志父目录；返回后立即切换并提示清理旧目录。
    pub(in crate::settings) fn choose_log_directory(&mut self, cx: &mut Context<Self>) {
        if self.logs.busy {
            return;
        }
        self.logs.busy = true;
        let title = tr("Choose the parent directory for Lithe logs").to_string();
        let platform = platform::current();
        cx.spawn(async move |this, cx| {
            let picked = platform.pick_folder(title).await;
            let _ = this.update(cx, |this, cx| {
                this.logs.busy = false;
                match picked {
                    Some(path) => this.apply_log_directory(Some(path), cx),
                    None => cx.notify(),
                }
            });
        })
        .detach();
    }

    pub(in crate::settings) fn restore_default_log_directory(&mut self, cx: &mut Context<Self>) {
        self.apply_log_directory(None, cx);
    }

    fn apply_log_directory(&mut self, parent: Option<PathBuf>, cx: &mut Context<Self>) {
        let previous = self.logs.snapshot.configured_directory.clone();
        logging::set_log_directory(parent.as_deref());
        self.logs.reload_timeline();
        self.logs.previous_cleanup = None;
        // 旧自定义位置仍有 Lithe 日志时，按 Tauri 的流程询问是否删除。
        if let Some(previous) = previous {
            let old_directory = previous.join("Lithe").join("logs");
            let bytes = logging::directory_log_bytes(&old_directory);
            if bytes > 0 && old_directory != self.logs.snapshot.effective_path {
                self.logs.previous_cleanup = Some((previous, bytes));
            }
        }
        self.logs.notice = Some(tr("The log directory changed immediately.").to_string());
        self.logs.error = None;
        cx.notify();
    }

    pub(in crate::settings) fn confirm_previous_log_cleanup(&mut self, delete: bool, cx: &mut Context<Self>) {
        let Some((previous, _)) = self.logs.previous_cleanup.take() else {
            return;
        };
        if !delete {
            cx.notify();
            return;
        }
        let old_directory = previous.join("Lithe").join("logs");
        match logging::clear_directory_logs(&old_directory) {
            (count, freed) if count > 0 => {
                self.logs.notice = Some(format!(
                    "{} {} {}.",
                    tr("Deleted log files:"),
                    count,
                    logging::format_bytes(freed)
                ));
            }
            _ => {
                self.logs.notice = Some(tr("The previous log directory is already empty.").to_string());
            }
        }
        self.logs.error = None;
        cx.notify();
    }

    pub(in crate::settings) fn open_current_log(&mut self, cx: &mut Context<Self>) {
        let opened = logging::current_log_file()
            .map(|path| logging::open_log_file(&path))
            .unwrap_or(false);
        if opened {
            self.logs.error = None;
        } else {
            self.logs.error = Some(tr("Unable to open the current log.").to_string());
        }
        cx.notify();
    }

    pub(in crate::settings) fn open_log_directory(&mut self, cx: &mut Context<Self>) {
        let opened = logging::reveal_in_file_manager(&self.logs.snapshot.effective_path);
        if opened {
            self.logs.error = None;
        } else {
            self.logs.error = Some(tr("Unable to open the log directory.").to_string());
        }
        cx.notify();
    }

    pub(in crate::settings) fn copy_log_path(&mut self, cx: &mut Context<Self>) {
        cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string(
            self.logs.snapshot.effective_path.display().to_string(),
        ));
        self.logs.notice = Some(tr("Log path copied.").to_string());
        self.logs.error = None;
        cx.notify();
    }

    pub(in crate::settings) fn confirm_clear_logs(&mut self, cx: &mut Context<Self>) {
        self.logs.pending_clear = false;
        let (count, freed) = logging::clear_logs();
        self.logs.timeline = None;
        self.logs.reload_timeline();
        self.logs.notice = Some(format!(
            "{} {} {} {}.",
            tr("Deleted"),
            count,
            tr("log files, freed"),
            logging::format_bytes(freed)
        ));
        self.logs.error = None;
        cx.notify();
    }

    pub(in crate::settings) fn preview_log_bundle(&mut self, cx: &mut Context<Self>) {
        let selection = self.logs.selection();
        self.logs.bundle_preview = Some(logging::preview_bundle(&selection));
        self.logs.error = None;
        cx.notify();
    }

    /// 确认预览后选择保存路径并写出 zip。
    pub(in crate::settings) fn export_log_bundle(&mut self, cx: &mut Context<Self>) {
        if self.logs.busy {
            return;
        }
        self.logs.bundle_preview = None;
        self.logs.busy = true;
        let selection = self.logs.selection();
        let title = tr("Choose Where to Save the Diagnostic Bundle").to_string();
        let default_name = format!("lithe-diagnostics-{}.zip", logging::today());
        let platform = platform::current();
        cx.spawn(async move |this, cx| {
            let picked = platform
                .pick_save_path(
                    title,
                    default_name,
                    vec![platform::FileFilter {
                        name: String::from("Zip Archives"),
                        extensions: vec![String::from("zip")],
                    }],
                )
                .await;
            let _ = this.update(cx, |this, cx| {
                this.logs.busy = false;
                let Some(destination) = picked else {
                    cx.notify();
                    return;
                };
                match logging::export_bundle(&destination, &selection) {
                    Ok(_) => {
                        this.logs.notice = Some(format!(
                            "{} {}.",
                            tr("Diagnostic bundle saved to"),
                            destination.display()
                        ));
                        this.logs.error = None;
                    }
                    Err(error) => {
                        this.logs.error = Some(format!(
                            "{} {error}",
                            tr("Unable to export the diagnostic bundle:")
                        ));
                        this.logs.notice = None;
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    // -----------------------------------------------------------------
    // 渲染
    // -----------------------------------------------------------------

    pub(in crate::settings) fn render_diagnostics(
        &mut self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if !self.logs.loaded {
            self.logs.refresh();
        }
        let snapshot = self.logs.snapshot.clone();
        let busy = self.logs.busy;
        let selecting_disabled = busy;

        // 时间线筛选：模块、会话、最低级别三组互斥按钮，再是搜索与时间范围。
        let mut timeline_body = v_flex()
            .w_full()
            .gap(px(SETTINGS_CONTROL_GAP))
            .child(log_choice_row(
                "Module",
                "lithe-settings:logs-module",
                &LOG_CATEGORY_OPTIONS,
                &self.logs.category,
                SettingsView::set_log_category,
                cx,
                tokens,
            ))
            .child(log_choice_row(
                "Session",
                "lithe-settings:logs-session",
                &LOG_SESSION_OPTIONS,
                &self.logs.session,
                SettingsView::set_log_session,
                cx,
                tokens,
            ))
            .child(log_choice_row(
                "Minimum level",
                "lithe-settings:logs-level",
                &LOG_LEVEL_OPTIONS,
                &self.logs.level,
                SettingsView::set_log_level,
                cx,
                tokens,
            ))
            .child(Input::new(&self.logs_search_input).small().w_full())
            .child(
                h_flex()
                    .w_full()
                    .gap(px(SETTINGS_CONTROL_GAP))
                    .child(Input::new(&self.logs_since_input).small().flex_1())
                    .child(Input::new(&self.logs_until_input).small().flex_1()),
            )
            .child(log_button(
                "lithe-settings:logs-refresh",
                tr("Refresh logs").to_string(),
                selecting_disabled,
                cx.listener(|this, _: &ClickEvent, _window, cx| this.refresh_log_timeline(cx)),
            ));

        if let Some(timeline) = self.logs.timeline.as_ref() {
            if timeline.truncated {
                timeline_body = timeline_body.child(note_card(
                    SharedString::from(tr("Earlier evidence was omitted by collection limits.")),
                    tokens,
                ));
            }
            let content = if timeline.content.trim().is_empty() {
                SharedString::from(tr("No matching logs"))
            } else {
                SharedString::from(timeline.content.clone())
            };
            timeline_body = timeline_body.child(
                div()
                    .id("lithe-settings:logs-timeline")
                    .w_full()
                    .max_h(px(288.0))
                    .overflow_y_scroll()
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .border_1()
                    .border_color(tokens.divider)
                    .bg(tokens.raised)
                    .p(px(8.0))
                    .font_family(MONO_FONT_FAMILY)
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.primary_text)
                    .child(content),
            );
        }

        timeline_body = timeline_body.child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.tertiary_text)
                .child(SharedString::from(format!(
                    "{} {}; {} {}",
                    tr("Dropped:"),
                    snapshot.dropped_events,
                    tr("write failures:"),
                    snapshot.write_failures
                ))),
        );

        // 诊断：开关 + 当前状态 + 过期说明。
        let diagnostic_module = snapshot
            .diagnostic_category
            .as_deref()
            .map(log_category_title)
            .unwrap_or_else(|| tr("All modules").to_string());
        let diagnostic_status = if snapshot.diagnostic_enabled {
            format!(
                "{} ({})",
                tr("Detailed diagnostics: On"),
                diagnostic_module
            )
        } else {
            tr("Detailed diagnostics: Off").to_string()
        };
        let diagnostic_body = v_flex()
            .w_full()
            .gap(px(SETTINGS_CONTROL_GAP))
            .child(described_row(
                "Detailed diagnostics",
                Some(SharedString::from(tr(
                    "Record detailed events for the selected module for 15 minutes.",
                ))),
                switch_control(
                    "lithe-settings:logs-diagnostic",
                    snapshot.diagnostic_enabled,
                    "Detailed diagnostics",
                    cx.listener(|this, checked: &bool, _window, cx| {
                        this.set_diagnostic_logging(*checked, cx)
                    }),
                ),
                tokens,
            ))
            .child(caption_line(SharedString::from(diagnostic_status), tokens))
            .child(caption_line(
                SharedString::from(tr(
                    "Detailed diagnostics cover the selected module and expire after 15 minutes. Refresh to see the current status.",
                )),
                tokens,
            ));

        let fallback = snapshot
            .fallback_reason
            .map(log_fallback_description)
            .unwrap_or_else(|| {
                SharedString::from(tr("The directory receiving logs in this session."))
            });
        let configured_path = snapshot
            .configured_directory
            .as_ref()
            .map(|path| SharedString::from(path.display().to_string()))
            .unwrap_or_else(|| SharedString::from(tr("Using the default location")));

        let locations_body = v_flex()
            .w_full()
            .gap(px(SETTINGS_CONTROL_GAP))
            .child(described_row(
                "Current log location",
                Some(fallback),
                v_flex()
                    .items_end()
                    .gap(px(4.0))
                    .child(code_text(
                        SharedString::from(snapshot.effective_path.display().to_string()),
                        tokens,
                    ))
                    .child(
                        h_flex()
                            .flex_wrap()
                            .justify_end()
                            .gap(px(SETTINGS_CONTROL_GAP))
                            .child(log_button(
                                "lithe-settings:logs-open-current",
                                tr("Open Current Log").to_string(),
                                busy,
                                cx.listener(|this, _: &ClickEvent, _window, cx| {
                                    this.open_current_log(cx)
                                }),
                            ))
                            .child(log_button(
                                "lithe-settings:logs-open-directory",
                                tr("Open Directory").to_string(),
                                busy,
                                cx.listener(|this, _: &ClickEvent, _window, cx| {
                                    this.open_log_directory(cx)
                                }),
                            ))
                            .child(log_button(
                                "lithe-settings:logs-copy-path",
                                tr("Copy Path").to_string(),
                                busy,
                                cx.listener(|this, _: &ClickEvent, _window, cx| {
                                    this.copy_log_path(cx)
                                }),
                            )),
                    )
                    .into_any_element(),
                tokens,
            ))
            .child(described_row(
                "Default log location",
                Some(SharedString::from(tr(
                    "Lithe always maintains and cleans this application-owned directory.",
                ))),
                code_text(
                    SharedString::from(snapshot.default_path.display().to_string()),
                    tokens,
                ),
                tokens,
            ))
            .child(described_row(
                "Custom log location",
                Some(SharedString::from(tr(
                    "After choosing a parent directory, Lithe writes into its Lithe/logs subdirectory.",
                ))),
                v_flex()
                    .items_end()
                    .gap(px(4.0))
                    .child(code_text(configured_path, tokens))
                    .child(
                        h_flex()
                            .justify_end()
                            .gap(px(SETTINGS_CONTROL_GAP))
                            .child(log_button(
                                "lithe-settings:logs-choose-directory",
                                tr("Choose…").to_string(),
                                busy,
                                cx.listener(|this, _: &ClickEvent, _window, cx| {
                                    this.choose_log_directory(cx)
                                }),
                            ))
                            .child(log_button(
                                "lithe-settings:logs-restore-default",
                                tr("Restore Default").to_string(),
                                busy || snapshot.configured_directory.is_none(),
                                cx.listener(|this, _: &ClickEvent, _window, cx| {
                                    this.restore_default_log_directory(cx)
                                }),
                            )),
                    )
                    .into_any_element(),
                tokens,
            ));

        let mut retention_body = v_flex()
            .w_full()
            .gap(px(SETTINGS_CONTROL_GAP))
            .child(note_card(
                SharedString::from(tr(
                    "Module logs rotate at 10 MiB and expire after 30 days. The combined budget is 100 MiB; performance logs have a separate 20 MiB budget.",
                )),
                tokens,
            ))
            .child(described_row(
                "Clear logs in the current directory",
                Some(SharedString::from(tr(
                    "Only delete Lithe-managed log files in the current directory.",
                ))),
                log_button(
                    "lithe-settings:logs-clear",
                    tr("Clear Logs").to_string(),
                    busy,
                    cx.listener(|this, _: &ClickEvent, _window, cx| {
                        this.logs.pending_clear = true;
                        cx.notify();
                    }),
                ),
                tokens,
            ));

        if self.logs.pending_clear {
            retention_body = retention_body.child(confirm_strip(
                "lithe-settings:logs-clear-confirm",
                SharedString::from(tr(
                    "Only Lithe-managed logs for all modules and sessions in the current directory are deleted. Filters do not limit cleanup; future events keep being recorded.",
                )),
                tr("Clear Logs").to_string(),
                tr("Cancel").to_string(),
                cx.listener(|this, _: &ClickEvent, _window, cx| this.confirm_clear_logs(cx)),
                cx.listener(|this, _: &ClickEvent, _window, cx| {
                    this.logs.pending_clear = false;
                    cx.notify();
                }),
                tokens,
            ));
        }

        let mut bundle_body = v_flex()
            .w_full()
            .gap(px(SETTINGS_CONTROL_GAP))
            .child(described_row(
                "Export Diagnostic Bundle…",
                Some(SharedString::from(tr(
                    "Preview and export the selected logs with environment information. Credentials and home-directory paths are redacted; source code, editor buffers and terminal history are excluded.",
                ))),
                log_button(
                    "lithe-settings:logs-preview-bundle",
                    tr("Preview and Export…").to_string(),
                    busy,
                    cx.listener(|this, _: &ClickEvent, _window, cx| this.preview_log_bundle(cx)),
                ),
                tokens,
            ));

        if let Some(entries) = self.logs.bundle_preview.as_ref() {
            let mut files = v_flex()
                .id("lithe-settings:logs-bundle-files")
                .w_full()
                .max_h(px(192.0))
                .overflow_y_scroll()
                .gap(px(2.0))
                .child(note_card(
                    SharedString::from(tr(
                        "Lithe will include the following files, with credentials, tokens, and home-directory paths already redacted:",
                    )),
                    tokens,
                ));
            for entry in entries {
                files = files.child(
                    h_flex()
                        .w_full()
                        .gap(px(8.0))
                        .child(
                            div()
                                .min_w(px(0.0))
                                .truncate()
                                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                                .text_color(tokens.secondary_text)
                                .child(SharedString::from(entry.relative_path.clone())),
                        )
                        .child(
                            div()
                                .flex_shrink_0()
                                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                                .text_color(tokens.tertiary_text)
                                .child(SharedString::from(logging::format_bytes(
                                    entry.size_bytes,
                                ))),
                        ),
                );
            }
            bundle_body = bundle_body.child(files).child(confirm_strip(
                "lithe-settings:logs-bundle-confirm",
                SharedString::from(tr("Export Diagnostic Bundle?")),
                tr("Export").to_string(),
                tr("Cancel").to_string(),
                cx.listener(|this, _: &ClickEvent, _window, cx| this.export_log_bundle(cx)),
                cx.listener(|this, _: &ClickEvent, _window, cx| {
                    this.logs.bundle_preview = None;
                    cx.notify();
                }),
                tokens,
            ));
        }

        let mut page = v_flex()
            .w_full()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(note_card(
                SharedString::from(tr(
                    "Choose a module, enable detailed diagnostics, reproduce the problem, then preview and export a diagnostic bundle.",
                )),
                tokens,
            ));

        if let Some(error) = self.logs.error.as_ref() {
            page = page.child(
                div()
                    .w_full()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.error)
                    .child(SharedString::from(error.clone())),
            );
        }
        if let Some(notice) = self.logs.notice.as_ref() {
            page = page.child(
                div()
                    .w_full()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(SharedString::from(notice.clone())),
            );
        }
        if let Some((previous, bytes)) = self.logs.previous_cleanup.as_ref() {
            page = page.child(confirm_strip(
                "lithe-settings:logs-previous-confirm",
                SharedString::from(format!(
                    "{} {} {} {}",
                    tr("The previous directory"),
                    previous.display(),
                    tr("still contains about"),
                    logging::format_bytes(*bytes)
                )),
                tr("Delete Logs").to_string(),
                tr("Keep Logs").to_string(),
                cx.listener(|this, _: &ClickEvent, _window, cx| {
                    this.confirm_previous_log_cleanup(true, cx)
                }),
                cx.listener(|this, _: &ClickEvent, _window, cx| {
                    this.confirm_previous_log_cleanup(false, cx)
                }),
                tokens,
            ));
        }

        page.child(section_card(
            "Log timeline",
            None,
            timeline_body.into_any_element(),
            tokens,
        ))
        .child(section_card(
            "Diagnostics",
            None,
            diagnostic_body.into_any_element(),
            tokens,
        ))
        .child(section_card(
            "Log locations",
            None,
            locations_body.into_any_element(),
            tokens,
        ))
        .child(section_card(
            "Retention and cleanup",
            None,
            retention_body.into_any_element(),
            tokens,
        ))
        .child(section_card(
            "Diagnostic bundle",
            None,
            bundle_body.into_any_element(),
            tokens,
        ))
        .into_any_element()
    }
}
