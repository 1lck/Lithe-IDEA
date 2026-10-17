//! Exit policy resolution for processes and resources started by one Lithe instance.
//!
//! Hosts own discovery, signalling and dialogs. This module only decides, for
//! every record the host collected, whether it is ended silently, confirmed one
//! by one, offered in the background-resource dialog, kept, or ignored. Both
//! products feed it the same records and settings, so the behavior described in
//! `.agents/notes/proposed/architecture/2026-10-16-unified-child-process-lifecycle.md`
//! is decided once. `settle` turns the user's answers into what is ended and
//! kept, so the remembered-choice rules are not repeated by the hosts either.
//! Fixtures live in `shared/fixtures/process-lifecycle/`.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Lower and upper bound of the configurable graceful-stop wait, in seconds.
const GRACEFUL_STOP_SECONDS: (u32, u32) = (1, 60);

/// Situation in which the host asks for decisions.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum LifecycleContext {
    /// The user quit Lithe normally and can still answer dialogs.
    Quit,
    /// The user closes one terminal tab.
    CloseTerminalTab,
    /// An Agent connection is closed while Lithe keeps running.
    AgentDisconnect,
    /// The supervisor cleans up after Lithe ended without its normal shutdown.
    /// Nobody can answer a dialog, so nothing may be confirmed.
    CrashRecovery,
    /// Lithe starts and finds processes of an earlier instance.
    StartupSweep,
    /// The UI has finished shutdown. Newly observed Agent processes and
    /// background services must wait for startup confirmation unless their
    /// exact identities, or a setting, already approved ending them.
    FinalSweep,
}

/// Category of a ledger record; it selects the default policy.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum RecordKind {
    /// A run configuration or test session.
    Run,
    /// One terminal tab and every process of its shell session.
    Terminal,
    /// A command an Agent started while working on a request.
    AgentTask,
    /// A language server.
    LanguageServer,
    /// A debug adapter.
    DebugAdapter,
    /// A process a plugin started for one of its features.
    PluginTool,
    /// A helper owned by a built-in module, such as a database driver.
    Sidecar,
    /// A long-lived background process, such as a build daemon.
    Daemon,
    /// A container created on behalf of this instance.
    Container,
    /// A short command, such as Git or a formatter.
    OneShot,
}

/// Policy of a record before user settings are applied.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ExitPolicy {
    /// Ends with Lithe without asking.
    Terminate,
    /// Must be confirmed individually; never offered in a batch.
    ConfirmEach,
    /// Offered in the background-resource dialog, where the user may keep it.
    AskOnExit,
    /// Not provably started by this instance; never touched or shown.
    External,
}

/// How the host proved that this instance started the record.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Ownership {
    /// Started through the host's process port.
    Launched,
    /// Carries this instance's `LITHE_PROCESS_SCOPE` environment token.
    ScopeToken,
    /// Carries this instance's `lithe.instance` label.
    InstanceLabel,
    /// No proof; such records are ignored.
    Unproven,
}

/// What the host must do with one record.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum LifecycleAction {
    /// End it without asking.
    Terminate,
    /// Ask about this record alone, in input order.
    Confirm,
    /// List it in the background-resource dialog.
    Ask,
    /// Leave it running and record it as retained.
    Retain,
    /// Leave it alone for now; a later step of the same exit owns it.
    Defer,
    /// Not owned by this instance; do not show or touch it.
    Ignore,
}

/// Choice remembered for every record matched by one recognizer.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum RememberedChoice {
    /// End matching records without asking.
    Terminate,
    /// Keep matching records without asking.
    Keep,
}

/// Exit behavior of terminals that still run programs.
#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum TerminalQuitPolicy {
    /// Ask about each busy terminal.
    #[default]
    ConfirmEach,
    /// End busy terminals without asking.
    Terminate,
}

/// Exit behavior of Agent tasks.
#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum AgentTaskPolicy {
    /// Ask about each task.
    #[default]
    ConfirmEach,
    /// Keep every task running.
    Keep,
    /// End tasks without asking. Never applies to crash recovery or startup.
    Terminate,
}

/// Exit behavior of daemons and containers.
#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum BackgroundResourcePolicy {
    /// Offer them in the background-resource dialog.
    #[default]
    Ask,
    /// End them without asking.
    Terminate,
    /// Keep them without asking.
    Keep,
}

/// Handling of an earlier instance's leftovers found at startup.
#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum StartupSweepPolicy {
    /// List them for the user.
    #[default]
    Ask,
    /// End them without asking. Agent tasks are still confirmed.
    Terminate,
}

/// The user's process termination settings.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", default)]
pub struct TerminationSettings {
    /// Busy terminals when quitting.
    pub terminal_on_quit: TerminalQuitPolicy,
    /// Whether closing a busy terminal tab asks first.
    pub confirm_terminal_tab_close: bool,
    /// Agent tasks when quitting or disconnecting an Agent.
    pub agent_tasks: AgentTaskPolicy,
    /// Daemons and containers when quitting.
    pub background_resources: BackgroundResourcePolicy,
    /// Choices remembered from the background-resource dialog, by recognizer ID.
    pub remembered_choices: BTreeMap<String, RememberedChoice>,
    /// Leftovers of an earlier instance.
    pub startup_sweep: StartupSweepPolicy,
    /// How long ordinary processes may take to stop before they are killed.
    pub graceful_stop_seconds: u32,
}

impl Default for TerminationSettings {
    fn default() -> Self {
        Self {
            terminal_on_quit: TerminalQuitPolicy::default(),
            confirm_terminal_tab_close: true,
            agent_tasks: AgentTaskPolicy::default(),
            background_resources: BackgroundResourcePolicy::default(),
            remembered_choices: BTreeMap::new(),
            startup_sweep: StartupSweepPolicy::default(),
            graceful_stop_seconds: 5,
        }
    }
}

/// One process or resource collected by the host.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LifecycleRecord {
    /// Host-chosen identifier echoed in the decision.
    pub id: String,
    /// Category of the record.
    pub kind: RecordKind,
    /// How ownership by this instance was proven.
    pub ownership: Ownership,
    /// Policy passed by whoever launched it, if any.
    #[serde(default)]
    pub declared_policy: Option<ExitPolicy>,
    /// Recognizer that claimed it after launch, if any.
    #[serde(default)]
    pub recognizer_id: Option<String>,
    /// Policy of that recognizer.
    #[serde(default)]
    pub recognized_policy: Option<ExitPolicy>,
    /// It left its process group or session, or was re-parented to the system.
    #[serde(default)]
    pub detached: bool,
    /// A terminal whose shell runs no other program.
    #[serde(default)]
    pub idle: bool,
    /// The user already chose to keep it.
    #[serde(default)]
    pub retained: bool,
    /// Every process identity was approved for termination before UI shutdown.
    /// Used only by the final unattended sweep; never overrides retention.
    #[serde(default)]
    pub termination_approved: bool,
}

/// Request of `processLifecycle.resolve`.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LifecycleRequest {
    /// Situation in which decisions are needed.
    pub context: LifecycleContext,
    /// The user's settings; omitted fields take their defaults.
    #[serde(default)]
    pub settings: TerminationSettings,
    /// Records in the order the host will present them.
    #[serde(default)]
    pub records: Vec<LifecycleRecord>,
}

/// Decision for one record.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct LifecycleDecision {
    /// Identifier of the record.
    pub id: String,
    /// Category of the record, echoed for presentation.
    pub kind: RecordKind,
    /// Policy before user settings were applied.
    pub policy: ExitPolicy,
    /// What the host must do.
    pub action: LifecycleAction,
    /// Rule that produced the action, for logs and tests.
    pub reason: &'static str,
}

/// Response of `processLifecycle.resolve`.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct LifecyclePlan {
    /// Wait between the graceful stop request and the forced kill.
    pub graceful_stop_milliseconds: u64,
    /// One decision per record, in request order.
    pub decisions: Vec<LifecycleDecision>,
}

/// Decides every record of `request`. The result depends only on the request.
pub fn resolve(request: &LifecycleRequest) -> LifecyclePlan {
    let (minimum, maximum) = GRACEFUL_STOP_SECONDS;
    let seconds = request
        .settings
        .graceful_stop_seconds
        .clamp(minimum, maximum);
    LifecyclePlan {
        graceful_stop_milliseconds: u64::from(seconds) * 1_000,
        decisions: request
            .records
            .iter()
            .map(|record| decide(request.context, &request.settings, record))
            .collect(),
    }
}

fn decide(
    context: LifecycleContext,
    settings: &TerminationSettings,
    record: &LifecycleRecord,
) -> LifecycleDecision {
    let (policy, source) = base_policy(record);
    let (action, reason) = if policy == ExitPolicy::External {
        (LifecycleAction::Ignore, source)
    } else if record.retained {
        (LifecycleAction::Retain, "retainedByUser")
    } else if context == LifecycleContext::FinalSweep {
        final_sweep(settings, record, policy)
    } else {
        apply_settings(context, settings, record, policy, source)
    };
    LifecycleDecision {
        id: record.id.clone(),
        kind: record.kind,
        policy,
        action,
        reason,
    }
}

/// The unattended sweep after UI shutdown. Only exact identities approved
/// before shutdown, and categories the user pre-approved in settings, may end
/// here; anything that would have needed an answer waits for the next startup.
/// This covers a successor a kept service spawned after the quit dialog's
/// snapshot: its identity was never shown, so it was neither kept nor approved.
fn final_sweep(
    settings: &TerminationSettings,
    record: &LifecycleRecord,
    policy: ExitPolicy,
) -> (LifecycleAction, &'static str) {
    use LifecycleAction::{Defer, Retain, Terminate};
    if record.termination_approved {
        return (Terminate, "finalSweepApproved");
    }
    if record.kind == RecordKind::AgentTask {
        return (Defer, "agentTaskRequiresStartupConfirmation");
    }
    if policy != ExitPolicy::AskOnExit {
        return (Terminate, "finalSweepApproved");
    }
    let remembered = record
        .recognizer_id
        .as_ref()
        .and_then(|id| settings.remembered_choices.get(id));
    match (remembered, settings.background_resources) {
        (Some(RememberedChoice::Keep), _) => (Retain, "rememberedChoice"),
        (Some(RememberedChoice::Terminate), _) => (Terminate, "rememberedChoice"),
        (None, BackgroundResourcePolicy::Keep) => (Retain, "backgroundSetting"),
        (None, BackgroundResourcePolicy::Terminate) => (Terminate, "backgroundSetting"),
        (None, BackgroundResourcePolicy::Ask) => {
            (Defer, "backgroundResourceRequiresStartupConfirmation")
        }
    }
}

/// Policy from the launcher, recognizers, detachment and the kind, in that
/// priority. User settings are applied afterwards by `apply_settings`.
fn base_policy(record: &LifecycleRecord) -> (ExitPolicy, &'static str) {
    if record.ownership == Ownership::Unproven {
        return (ExitPolicy::External, "ownershipUnproven");
    }
    // Agent tasks and terminals are classified by their owner, never relaxed
    // by a recognizer: a daemon an Agent started is still that Agent's task.
    match record.kind {
        RecordKind::AgentTask => return (ExitPolicy::ConfirmEach, "agentTask"),
        RecordKind::Terminal if record.idle => return (ExitPolicy::Terminate, "idleTerminal"),
        RecordKind::Terminal => return (ExitPolicy::ConfirmEach, "busyTerminal"),
        _ => {}
    }
    if let Some(policy) = record.declared_policy {
        return (policy, "declaredByLauncher");
    }
    if let Some(policy) = record.recognized_policy {
        return (policy, "recognizer");
    }
    if record.detached {
        return (ExitPolicy::AskOnExit, "detachedProcess");
    }
    match record.kind {
        RecordKind::Daemon | RecordKind::Container => (ExitPolicy::AskOnExit, "backgroundKind"),
        // Unclassified records end with Lithe: a wrong guess then costs one
        // extra stopped process rather than one more leaked process.
        _ => (ExitPolicy::Terminate, "defaultTerminate"),
    }
}

fn apply_settings(
    context: LifecycleContext,
    settings: &TerminationSettings,
    record: &LifecycleRecord,
    policy: ExitPolicy,
    source: &'static str,
) -> (LifecycleAction, &'static str) {
    use LifecycleAction::{Ask, Confirm, Defer, Retain, Terminate};
    match policy {
        ExitPolicy::External => (LifecycleAction::Ignore, source),
        ExitPolicy::Terminate => (Terminate, source),
        ExitPolicy::ConfirmEach if record.kind == RecordKind::AgentTask => match context {
            // Nobody can confirm after a crash, and an interrupted migration is
            // worse than a leftover process.
            LifecycleContext::CrashRecovery => (Retain, "agentTaskNeverEndedUnattended"),
            LifecycleContext::StartupSweep => (Confirm, "agentTaskAlwaysConfirmedAtStartup"),
            _ => match settings.agent_tasks {
                AgentTaskPolicy::ConfirmEach => (Confirm, source),
                AgentTaskPolicy::Keep => (Retain, "agentTasksSetting"),
                AgentTaskPolicy::Terminate => (Terminate, "agentTasksSetting"),
            },
        },
        ExitPolicy::ConfirmEach => match context {
            LifecycleContext::Quit => match settings.terminal_on_quit {
                TerminalQuitPolicy::ConfirmEach => (Confirm, source),
                TerminalQuitPolicy::Terminate => (Terminate, "terminalOnQuitSetting"),
            },
            LifecycleContext::CloseTerminalTab if settings.confirm_terminal_tab_close => {
                (Confirm, source)
            }
            LifecycleContext::CloseTerminalTab => (Terminate, "terminalTabCloseSetting"),
            // A terminal cannot outlive its PTY, so there is nothing to keep.
            LifecycleContext::CrashRecovery
            | LifecycleContext::AgentDisconnect
            | LifecycleContext::FinalSweep => (Terminate, source),
            LifecycleContext::StartupSweep => startup_sweep(settings),
        },
        ExitPolicy::AskOnExit => {
            let remembered = record
                .recognizer_id
                .as_ref()
                .and_then(|id| settings.remembered_choices.get(id));
            match (context, remembered) {
                // Closing one tab or one Agent never opens the batch dialog; the
                // resource is decided when Lithe quits.
                (LifecycleContext::CloseTerminalTab | LifecycleContext::AgentDisconnect, _) => {
                    (Defer, "decidedOnQuit")
                }
                (_, Some(RememberedChoice::Keep)) => (Retain, "rememberedChoice"),
                (_, Some(RememberedChoice::Terminate)) => (Terminate, "rememberedChoice"),
                (LifecycleContext::StartupSweep, None) => startup_sweep(settings),
                (
                    LifecycleContext::Quit
                    | LifecycleContext::CrashRecovery
                    | LifecycleContext::FinalSweep,
                    None,
                ) => {
                    match (context, settings.background_resources) {
                        (_, BackgroundResourcePolicy::Keep) => (Retain, "backgroundSetting"),
                        (_, BackgroundResourcePolicy::Terminate) => {
                            (Terminate, "backgroundSetting")
                        }
                        (LifecycleContext::Quit, BackgroundResourcePolicy::Ask) => (Ask, source),
                        // Nobody answered; the next launch lists it again, and
                        // keeping a process is the reversible choice.
                        (_, BackgroundResourcePolicy::Ask) => (Retain, "leftForStartupSweep"),
                    }
                }
            }
        }
    }
}

/// The user's answer about one confirmed or listed record.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Answer {
    /// End it.
    Terminate,
    /// Keep it running.
    Keep,
}

/// A decision of an earlier plan, as the host presented it.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SettleDecision {
    /// Identifier of the record.
    pub id: String,
    /// Action of the plan.
    pub action: LifecycleAction,
    /// Recognizer of the record, used to remember the answer.
    #[serde(default)]
    pub recognizer_id: Option<String>,
}

/// Request of `processLifecycle.settle`.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SettleRequest {
    /// Settings the plan was made with.
    #[serde(default)]
    pub settings: TerminationSettings,
    /// The plan's decisions.
    #[serde(default)]
    pub decisions: Vec<SettleDecision>,
    /// Answers by record ID for records the plan asked about.
    #[serde(default)]
    pub answers: BTreeMap<String, Answer>,
    /// Remember the batch dialog's answers for records with a recognizer.
    #[serde(default)]
    pub remember: bool,
}

/// Response of `processLifecycle.settle`.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Settlement {
    /// Records to end, in plan order.
    pub terminate: Vec<String>,
    /// Records to keep running and record as retained, in plan order.
    pub keep: Vec<String>,
    /// Settings with newly remembered choices.
    pub settings: TerminationSettings,
}

/// Turns a plan and the user's answers into what the host ends and keeps.
///
/// A question without an answer keeps its record: the host only calls this
/// once the user went through every question, so a missing answer means the
/// prompt could not be shown, and keeping a process is the reversible choice.
/// Deferred and ignored records are in neither list.
pub fn settle(request: &SettleRequest) -> Settlement {
    let mut settlement = Settlement {
        terminate: Vec::new(),
        keep: Vec::new(),
        settings: request.settings.clone(),
    };
    for decision in &request.decisions {
        let terminate = match decision.action {
            LifecycleAction::Terminate => true,
            LifecycleAction::Retain => false,
            LifecycleAction::Confirm | LifecycleAction::Ask => {
                let answer = request
                    .answers
                    .get(&decision.id)
                    .copied()
                    .unwrap_or(Answer::Keep);
                if request.remember && decision.action == LifecycleAction::Ask {
                    if let Some(recognizer) = &decision.recognizer_id {
                        let choice = match answer {
                            Answer::Terminate => RememberedChoice::Terminate,
                            Answer::Keep => RememberedChoice::Keep,
                        };
                        settlement
                            .settings
                            .remembered_choices
                            .insert(recognizer.clone(), choice);
                    }
                }
                answer == Answer::Terminate
            }
            LifecycleAction::Defer | LifecycleAction::Ignore => continue,
        };
        if terminate {
            settlement.terminate.push(decision.id.clone());
        } else {
            settlement.keep.push(decision.id.clone());
        }
    }
    settlement
}

fn startup_sweep(settings: &TerminationSettings) -> (LifecycleAction, &'static str) {
    match settings.startup_sweep {
        StartupSweepPolicy::Ask => (LifecycleAction::Ask, "startupSweepSetting"),
        StartupSweepPolicy::Terminate => (LifecycleAction::Terminate, "startupSweepSetting"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Fixture {
        schema_version: u32,
        cases: Vec<FixtureCase>,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct FixtureCase {
        name: String,
        request: serde_json::Value,
        expected: serde_json::Value,
    }

    // Both hosts replay this file, so a rule change must update it.
    #[test]
    fn shared_fixture_decisions_match() {
        let fixture: Fixture = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/process-lifecycle/exit-plan-v1.json"
        ))
        .expect("fixture should parse");
        assert_eq!(fixture.schema_version, 1);
        for case in fixture.cases {
            let request: LifecycleRequest =
                serde_json::from_value(case.request).expect("fixture request should decode");
            let plan = serde_json::to_value(resolve(&request)).expect("plan should encode");
            assert_eq!(plan, case.expected, "fixture case {}", case.name);
        }
    }

    #[test]
    fn shared_fixture_settlements_match() {
        let fixture: Fixture = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/process-lifecycle/settle-v1.json"
        ))
        .expect("fixture should parse");
        assert_eq!(fixture.schema_version, 1);
        for case in fixture.cases {
            let request: SettleRequest =
                serde_json::from_value(case.request).expect("fixture request should decode");
            let settlement =
                serde_json::to_value(settle(&request)).expect("settlement should encode");
            assert_eq!(settlement, case.expected, "fixture case {}", case.name);
        }
    }

    #[test]
    fn graceful_stop_is_bounded() {
        let mut settings = TerminationSettings {
            graceful_stop_seconds: 0,
            ..TerminationSettings::default()
        };
        let request = |settings: TerminationSettings| LifecycleRequest {
            context: LifecycleContext::Quit,
            settings,
            records: Vec::new(),
        };
        assert_eq!(
            resolve(&request(settings.clone())).graceful_stop_milliseconds,
            1_000
        );
        settings.graceful_stop_seconds = 600;
        assert_eq!(
            resolve(&request(settings)).graceful_stop_milliseconds,
            60_000
        );
    }
}
