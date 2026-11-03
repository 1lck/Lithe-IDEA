//! Process Termination 页（gpui 独有）：退出时的进程策略与优雅停止秒数。

use gpui_kit::{AnyElement, Context, IntoElement, ParentElement as _, SharedString, Styled, Window, div, px};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens};

use crate::settings::controls::{choice_row, note_card, section_card, stepper_row};
use crate::settings::state::{
    AGENT_TASK_OPTIONS, BACKGROUND_SERVICE_OPTIONS, ChoiceAction, DEFAULT_GRACEFUL_STOP_SECONDS,
    MAX_GRACEFUL_STOP_SECONDS, MIN_GRACEFUL_STOP_SECONDS, RUN_SERVICE_OPTIONS,
    SETTINGS_SECTION_GAP, StepperAction, TERMINAL_QUIT_OPTIONS,
};
use crate::settings::SettingsView;

impl SettingsView {
    pub(in crate::settings) fn render_process_termination(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let policies = div()
            .w_full()
            .flex()
            .flex_col()
            .child(choice_row(
                "Run services",
                "lithe-settings:run-services",
                &RUN_SERVICE_OPTIONS,
                &self.settings.run_services_on_exit,
                ChoiceAction::RunServices,
                cx,
                tokens,
            ))
            .child(choice_row(
                "Terminals",
                "lithe-settings:terminal-on-quit",
                &TERMINAL_QUIT_OPTIONS,
                &self.settings.terminal_on_quit,
                ChoiceAction::TerminalOnQuit,
                cx,
                tokens,
            ))
            .child(choice_row(
                "Agent tasks",
                "lithe-settings:agent-tasks",
                &AGENT_TASK_OPTIONS,
                &self.settings.agent_tasks,
                ChoiceAction::AgentTasks,
                cx,
                tokens,
            ))
            .child(choice_row(
                "Background services",
                "lithe-settings:background-services",
                &BACKGROUND_SERVICE_OPTIONS,
                &self.settings.background_services,
                ChoiceAction::BackgroundServices,
                cx,
                tokens,
            ))
            .child(stepper_row(
                "Graceful stop seconds",
                "lithe-settings:graceful-stop",
                self.settings.graceful_stop_seconds as f32,
                MIN_GRACEFUL_STOP_SECONDS as f32,
                MAX_GRACEFUL_STOP_SECONDS as f32,
                DEFAULT_GRACEFUL_STOP_SECONDS as f32,
                StepperAction::GracefulStop,
                SharedString::from(format!("{} s", self.settings.graceful_stop_seconds)),
                cx,
                tokens,
            ));

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                "When quitting Lithe",
                None,
                policies.into_any_element(),
                tokens,
            ))
            .child(note_card(
                SharedString::from(tr(
                    "These choices are stored now; they are enforced once long-lived run services, terminals, agent tasks, and background services land in the GPUI build.",
                )),
                tokens,
            ))
            .into_any_element()
    }

    pub(in crate::settings) fn set_run_services_on_exit(
        &mut self,
        policy: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self
            .settings
            .run_services_on_exit
            .eq_ignore_ascii_case(policy)
        {
            return;
        }
        self.settings.run_services_on_exit = policy.to_string();
        self.commit(window, cx);
    }

    pub(in crate::settings) fn set_terminal_on_quit(
        &mut self,
        policy: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.terminal_on_quit.eq_ignore_ascii_case(policy) {
            return;
        }
        self.settings.terminal_on_quit = policy.to_string();
        self.commit(window, cx);
    }

    pub(in crate::settings) fn set_agent_tasks(
        &mut self,
        policy: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.settings.agent_tasks.eq_ignore_ascii_case(policy) {
            return;
        }
        self.settings.agent_tasks = policy.to_string();
        self.commit(window, cx);
    }

    pub(in crate::settings) fn set_background_services(
        &mut self,
        policy: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self
            .settings
            .background_services
            .eq_ignore_ascii_case(policy)
        {
            return;
        }
        self.settings.background_services = policy.to_string();
        self.commit(window, cx);
    }

    pub(in crate::settings) fn adjust_graceful_stop(
        &mut self,
        delta: i32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let current = self.settings.graceful_stop_seconds as i32;
        let next = (current + delta).clamp(
            MIN_GRACEFUL_STOP_SECONDS as i32,
            MAX_GRACEFUL_STOP_SECONDS as i32,
        ) as u32;
        if next == self.settings.graceful_stop_seconds {
            return;
        }
        self.settings.graceful_stop_seconds = next;
        self.commit(window, cx);
    }
}
