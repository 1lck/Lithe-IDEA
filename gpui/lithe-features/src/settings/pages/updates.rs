//! Updates 页：版本、更新渠道（stable/autobuild + 切换确认）与检查更新状态机。
//!
//! 检查行为对齐 Tauri 的 updater 流程：稳定通道查询 GitHub Releases API 并
//! 比较版本，给出「有新版 / 已是最新 / 检查失败（具体原因）」三种真实结果；
//! Auto Build 通道没有单调递增的版本号，与 Tauri 一样走发布页手动下载。
//! 网络请求在 `background_spawn` 中执行，视图线程只合并结果。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Disableable as _, Sizable as _, WindowExt as _, h_flex, v_flex};
use gpui_kit::{
    AnyElement, ClickEvent, Context, IntoElement, ParentElement as _, SharedString, Styled,
    Window, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens};

use crate::settings::controls::{
    choice_row, readonly_row, section_card, setting_row, switch_control,
};
use crate::settings::state::{
    SETTINGS_BUTTON_HEIGHT, SETTINGS_BUTTON_RADIUS, SETTINGS_CONTROL_GAP, ChoiceAction,
    SETTINGS_SECTION_GAP, UPDATE_CHANNELS,
};
use crate::settings::update_check::{self, UpdateCheckOutcome};
use crate::settings::SettingsView;

/// 检查更新状态机（对齐 Tauri useUpdater 的可见状态）。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(in crate::settings) enum UpdateCheckStatus {
    /// 尚未检查；不预先宣称“已是最新”。
    #[default]
    Idle,
    Checking,
    /// 发布源没有比当前构建更新的版本。
    UpToDate,
    /// 发布源存在新版本。
    Available(update_check::UpdateRelease),
    /// 该通道只能从发布页手动下载。
    ManualDownload { release_url: String },
    /// 检查失败，`message()` 给出具体原因。
    Failed(update_check::UpdateCheckFailure),
}

impl From<UpdateCheckOutcome> for UpdateCheckStatus {
    fn from(outcome: UpdateCheckOutcome) -> Self {
        match outcome {
            UpdateCheckOutcome::Available(release) => Self::Available(release),
            UpdateCheckOutcome::UpToDate => Self::UpToDate,
            UpdateCheckOutcome::ManualDownload { release_url } => {
                Self::ManualDownload { release_url }
            }
            UpdateCheckOutcome::Failed(failure) => Self::Failed(failure),
        }
    }
}

/// Updates 页本地状态。
#[derive(Clone, Debug, Default)]
pub(in crate::settings) struct UpdatesState {
    pub(in crate::settings) check: UpdateCheckStatus,
}

impl SettingsView {
    pub(in crate::settings) fn render_updates(
        &mut self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let version = SharedString::from(format!("{} (GPUI build)", env!("CARGO_PKG_VERSION")));

        let version_card = div().w_full().flex().flex_col().child(readonly_row(
            "Current version",
            version,
            tokens,
        ));

        let channel_card = div()
            .w_full()
            .flex()
            .flex_col()
            .child(choice_row(
                "Update channel",
                "lithe-settings:update-channel",
                &UPDATE_CHANNELS,
                &self.settings.update_channel,
                ChoiceAction::UpdateChannel,
                cx,
                tokens,
            ))
            .child(setting_row(
                "Auto check",
                switch_control(
                    "lithe-settings:auto-check-updates",
                    self.settings.auto_check_updates,
                    "Auto check for updates",
                    cx.listener(|this, checked: &bool, window, cx| {
                        this.set_auto_check_updates(*checked, window, cx);
                    }),
                ),
                SharedString::default(),
                tokens,
            ));

        let check_card = self.render_update_check(tokens, cx);

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                "Application version",
                None,
                version_card.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Update channel",
                None,
                channel_card.into_any_element(),
                tokens,
            ))
            .child(check_card)
            .into_any_element()
    }

    /// 检查更新行：真实状态文案 + 两个动作按钮。
    fn render_update_check(
        &mut self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mut body = v_flex().w_full().gap(px(SETTINGS_CONTROL_GAP));

        let status_line = match &self.updates.check {
            UpdateCheckStatus::Idle => tr("Not checked yet").to_string(),
            UpdateCheckStatus::Checking => tr("Checking for updates…").to_string(),
            UpdateCheckStatus::UpToDate => tr("Up to date").to_string(),
            UpdateCheckStatus::Available(release) => {
                tr("Update available: {version}").replace("{version}", &release.target_version)
            }
            UpdateCheckStatus::ManualDownload { .. } => tr(
                "Use the selected channel’s release page to download and install. Build freshness has not been checked.",
            )
            .to_string(),
            UpdateCheckStatus::Failed(failure) => {
                tr("Failed to check for updates: {detail}")
                    .replace("{detail}", &failure.message())
            }
        };
        body = body
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(SharedString::from(status_line)),
            )
            .child(
                h_flex().gap(px(SETTINGS_CONTROL_GAP)).child(
                    Button::new("lithe-settings:check-updates")
                        .small()
                        .h(px(SETTINGS_BUTTON_HEIGHT))
                        .rounded(px(SETTINGS_BUTTON_RADIUS))
                        .secondary()
                        .label(tr("Check for updates"))
                        .disabled(self.updates.check == UpdateCheckStatus::Checking)
                        .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                            this.check_for_updates(cx);
                        })),
                ),
            );

        // 「打开下载页」是真实可用的动作：platform adapter 的 open_url。
        let download_url = match &self.updates.check {
            UpdateCheckStatus::Available(release) => release.release_url.clone(),
            UpdateCheckStatus::ManualDownload { release_url } => release_url.clone(),
            _ => update_check::release_page_url(&self.settings.update_channel).to_string(),
        };
        body = body.child(
            Button::new("lithe-settings:open-download-page")
                .small()
                .h(px(SETTINGS_BUTTON_HEIGHT))
                .rounded(px(SETTINGS_BUTTON_RADIUS))
                .secondary()
                .label(tr("Open download page"))
                .on_click(move |_, _window, _cx| {
                    lithe_platform::current().open_url(&download_url);
                }),
        );

        body.into_any_element()
    }

    // -----------------------------------------------------------------
    // Updates 写入方法
    // -----------------------------------------------------------------

    /// 渠道写入：切到 Auto Build 时弹确认（对齐 Tauri update-channel-selector）。
    pub(in crate::settings) fn set_update_channel(
        &mut self,
        channel: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.update_channel.eq_ignore_ascii_case(channel) {
            return;
        }
        // Tauri：Auto Build 需要确认弹窗；Stable 直接保存。
        if channel == "autobuild" {
            let owner = cx.weak_entity();
            window.open_alert_dialog(cx, move |alert, _window, _cx| {
                let owner = owner.clone();
                alert
                    .title(tr("Switch to Auto Build channel?"))
                    .description(tr(
                        "Auto Build receives unstable builds as soon as they are produced. Updates may contain unfinished features.",
                    ))
                    .confirm()
                    .ok_text(tr("Switch to Auto Build"))
                    .on_ok(move |_event, window, cx| {
                        let _ = owner.update(cx, |this, cx| {
                            this.settings.update_channel = "autobuild".to_string();
                            this.commit(window, cx);
                        });
                        true
                    })
            });
            return;
        }
        self.settings.update_channel = channel.to_string();
        self.commit(window, cx);
    }

    pub(in crate::settings) fn set_auto_check_updates(
        &mut self,
        enabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.auto_check_updates == enabled {
            return;
        }
        self.settings.auto_check_updates = enabled;
        self.commit(window, cx);
    }

    /// 检查更新：状态机推进到 Checking，后台查询发布源后落到真实结果。
    /// 异步任务走 `background_spawn`，与全库模式一致。`pub(in crate::settings)`
    /// 让 `settings/mod.rs` 的公开入口（Help > Check for Updates）能触发同一
    /// 状态机；不改变实现。
    pub(in crate::settings) fn check_for_updates(&mut self, cx: &mut Context<Self>) {
        if self.updates.check == UpdateCheckStatus::Checking {
            return;
        }
        self.updates.check = UpdateCheckStatus::Checking;
        cx.notify();
        let channel = self.settings.update_channel.clone();
        cx.spawn(async move |this, cx| {
            let outcome = cx
                .background_executor()
                .spawn(async move { update_check::check_for_updates(&channel) })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.updates.check = UpdateCheckStatus::from(outcome);
                cx.notify();
            });
        })
        .detach();
    }
}
