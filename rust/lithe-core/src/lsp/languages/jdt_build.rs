//! Coordination of JDT LS project builds requested by Run and Debug preparation.
//!
//! Java Debug Server's `vscode.java.buildWorkspace` builds every Java project in
//! the JDT workspace. Three upstream behaviors shape this coordinator:
//!
//! - Applying Maven profiles or changing build files schedules asynchronous JDT
//!   project-update jobs, and the command that scheduled them returns before the
//!   jobs finish. A build started meanwhile races JDT's own reconfiguration of
//!   classpaths, annotation processing, and output folders, so builds wait until
//!   those jobs report completion through work-done progress.
//! - Concurrent workspace builds in one JDT session contend for the same Eclipse
//!   workspace rule and share builder state. Core therefore runs at most one build
//!   per session and lets identical waiting requests share the next build.
//! - `$/cancelRequest` is advisory: JDT may keep building until an Eclipse job
//!   observes cancellation. A build stays tracked until JDT answers, even after
//!   every caller left, and the next build is not dispatched before that answer.
//!
//! The coordinator is a deterministic state machine. The engine supplies the
//! clock, allocates JSON-RPC IDs, and publishes the resulting events.

use serde::Serialize;
use serde_json::Value;
use std::collections::{BTreeMap, VecDeque};
use std::time::{Duration, Instant};

/// Java Debug Server command that builds the Java projects before a launch.
pub(crate) const JAVA_BUILD_WORKSPACE_COMMAND: &str = "vscode.java.buildWorkspace";

/// Default bound for one caller, covering the wait for project configuration,
/// the wait for an earlier build, and the build itself. Cold builds of large
/// multi-module projects with annotation processors take minutes, so the
/// ordinary 30-second semantic-request deadline does not apply.
pub(crate) const DEFAULT_JAVA_BUILD_TIMEOUT_MS: u64 = 10 * 60_000;

/// A project-configuration job that reports no progress for this long no longer
/// blocks builds. JDT reports long update jobs every few seconds, but one
/// Maven step can stay silent for over a minute, so the bound stays generous
/// while still releasing builds if JDT never sends the matching `end`.
const PROJECT_CONFIGURATION_IDLE_TIMEOUT: Duration = Duration::from_secs(120);

/// Job names JDT LS 1.38 reports while it rewrites project models. They come
/// from `ProjectsManager`: `updateProject`, `UpdateProjectsWorkspaceJob`,
/// `ImportProjectsFromSelectionJob`, and the workspace-folder update job.
const PROJECT_CONFIGURATION_JOB_PREFIXES: &[&str] = &[
    "Update project ",
    "Updating project configurations",
    "Applying the selected build files",
    "Updating workspace folders",
];

const WORK_DONE_PROGRESS_METHOD: &str = "$/progress";

/// Why a queued build has not been sent to JDT LS yet.
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub(crate) enum JavaBuildBlock {
    /// An earlier build has not received its terminal response.
    PreviousBuild,
    /// Core is still applying the selected Maven profiles.
    MavenProfiles,
    /// JDT reported a project-configuration job without its `end`.
    ProjectConfiguration,
}

impl JavaBuildBlock {
    /// Stable identifier used in log details and timeout diagnostics.
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::PreviousBuild => "waitingForPreviousBuild",
            Self::MavenProfiles => "waitingForMavenProfiles",
            Self::ProjectConfiguration => "waitingForProjectConfiguration",
        }
    }
}

/// One work-done progress notification that may affect build gating.
#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) enum ProjectJobProgress {
    /// A job began; `label` is its task name or title.
    Begin { token: String, label: String },
    /// A job reported progress, proving that it is still alive.
    Report { token: String },
    /// A job finished.
    End { token: String },
}

/// Parses a JDT work-done progress notification for build gating.
pub(crate) fn project_job_progress(
    provider_id: &str,
    method: Option<&str>,
    params: Option<&Value>,
) -> Option<ProjectJobProgress> {
    if provider_id != "java" || method != Some(WORK_DONE_PROGRESS_METHOD) {
        return None;
    }
    let params = params?;
    let token = match params.get("token")? {
        Value::String(token) => token.clone(),
        Value::Number(token) => token.to_string(),
        _ => return None,
    };
    let value = params.get("value")?;
    match value.get("kind").and_then(Value::as_str)? {
        "begin" => {
            // JDT puts the job name in `message` and may replace `title` with
            // a subtask, so both are candidates for the job label.
            let label = [value.get("message"), value.get("title")]
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .find(|label| is_project_configuration_job(label))
                .or_else(|| value.get("message").and_then(Value::as_str))
                .or_else(|| value.get("title").and_then(Value::as_str))
                .unwrap_or("")
                .trim()
                .to_string();
            Some(ProjectJobProgress::Begin { token, label })
        }
        "report" => Some(ProjectJobProgress::Report { token }),
        "end" => Some(ProjectJobProgress::End { token }),
        _ => None,
    }
}

fn is_project_configuration_job(label: &str) -> bool {
    let label = label.trim();
    PROJECT_CONFIGURATION_JOB_PREFIXES
        .iter()
        .any(|prefix| label.starts_with(prefix))
}

/// Returns whether an `executeCommand` payload asks Java Debug Server to build.
pub(crate) fn is_java_build_command(provider_id: &str, command: &Value) -> bool {
    provider_id == "java"
        && command.get("command").and_then(Value::as_str) == Some(JAVA_BUILD_WORKSPACE_COMMAND)
}

/// Terminal result of one `vscode.java.buildWorkspace` call.
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub(crate) enum JavaBuildOutcome {
    /// The build finished without error markers in the launched project.
    Succeeded,
    /// The build finished, but the launched project or a dependency has errors.
    CompilationErrors,
    /// JDT could not complete the build, for example after a builder exception.
    Failed,
    /// JDT observed cancellation before the build finished.
    Cancelled,
    /// The response did not contain a known build status.
    Unrecognized,
}

/// Which projects' error markers were requested for an unsuccessful build.
///
/// Java Debug Server judges a build from the markers on the project owning the
/// main class plus the projects on its classpath. When it cannot identify that
/// owner it falls back to every project in the workspace, and an unrelated
/// module can then decide the verdict. Core cannot observe the project Java
/// Debug Server ultimately resolves, so this is evidence inferred from the
/// request rather than an authoritative account of the upstream marker query.
#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum JavaBuildMarkerScope {
    /// The request named the owning project and asked upstream to scope to it.
    LaunchTarget,
    /// No owning project was named, so every project could decide the verdict.
    Workspace,
}

/// Recovery action a host should offer for an unsuccessful build.
#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum JavaBuildRecovery {
    /// Nothing beyond fixing the reported code is indicated.
    None,
    /// The language service's own builder failed, which leaves error markers
    /// that later builds neither refresh nor clear. Resetting the Java index is
    /// the only way back to a trustworthy verdict.
    RebuildJavaIndex,
}

/// Evidence behind one unsuccessful Java launch build.
///
/// A host must be able to explain a blocked launch and offer a way forward, so
/// this carries facts rather than a verdict: nothing here gates the launch by
/// itself, and the host decides what to show and which actions to enable.
#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JavaBuildReport {
    /// Marker scope inferred from the command arguments sent upstream.
    pub marker_scope: JavaBuildMarkerScope,
    /// An earlier build in this session ended with a builder failure, so the
    /// markers behind this verdict may predate the current sources.
    pub builder_failed_earlier: bool,
    /// Wall-clock duration of this build, measured from dispatch to response.
    /// A near-zero value can accompany an empty incremental build, but fast
    /// successful builds and real stored errors are possible too; this value
    /// is evidence only and never decides whether the verdict is trustworthy.
    pub elapsed_milliseconds: u64,
    /// Recovery action the host should offer alongside the reported errors.
    pub recovery: JavaBuildRecovery,
}

/// Derives the marker scope from the arguments sent to Java Debug Server.
///
/// The command carries one JSON-encoded string argument. A missing, blank, or
/// unparsable `projectName` all reach Java Debug Server as blank, because it
/// applies `isNotBlank` before falling back to resolving the main class.
pub(crate) fn java_build_marker_scope(command: &Value) -> JavaBuildMarkerScope {
    let named_project = command
        .get("arguments")
        .and_then(Value::as_array)
        .and_then(|arguments| arguments.first())
        .and_then(Value::as_str)
        .and_then(|encoded| serde_json::from_str::<Value>(encoded).ok())
        .as_ref()
        .and_then(|payload| payload.get("projectName"))
        .and_then(Value::as_str)
        .is_some_and(|name| !name.trim().is_empty());
    if named_project {
        JavaBuildMarkerScope::LaunchTarget
    } else {
        JavaBuildMarkerScope::Workspace
    }
}

/// Builds the report that accompanies an unsuccessful build.
pub(crate) fn java_build_report(
    outcome: JavaBuildOutcome,
    command: &Value,
    builder_failed_earlier: bool,
    elapsed: Duration,
) -> JavaBuildReport {
    let recovery = if outcome == JavaBuildOutcome::Failed || builder_failed_earlier {
        JavaBuildRecovery::RebuildJavaIndex
    } else {
        JavaBuildRecovery::None
    };
    JavaBuildReport {
        marker_scope: java_build_marker_scope(command),
        builder_failed_earlier,
        elapsed_milliseconds: elapsed.as_millis() as u64,
        recovery,
    }
}

/// Status returned by a Gradle build server when compilation fails.
const GRADLE_BUILD_SERVER_COMPILATION_ERROR: i64 = 100;

/// Interprets the raw command result using JDT LS `BuildWorkspaceStatus`
/// (`FAILED`, `SUCCEED`, `WITH_ERROR`, `CANCELLED`, serialized by ordinal).
pub(crate) fn java_build_outcome(result: Option<&Value>) -> JavaBuildOutcome {
    let numeric = match result {
        Some(Value::Number(number)) => number.as_i64(),
        Some(Value::String(text)) => match text.trim() {
            "FAILED" => Some(0),
            "SUCCEED" => Some(1),
            "WITH_ERROR" => Some(2),
            "CANCELLED" => Some(3),
            other => other.parse().ok(),
        },
        _ => None,
    };
    match numeric {
        Some(0) => JavaBuildOutcome::Failed,
        Some(1) => JavaBuildOutcome::Succeeded,
        Some(2) | Some(GRADLE_BUILD_SERVER_COMPILATION_ERROR) => {
            JavaBuildOutcome::CompilationErrors
        }
        Some(3) => JavaBuildOutcome::Cancelled,
        _ => JavaBuildOutcome::Unrecognized,
    }
}

/// Stable error code and user-facing message for an unsuccessful build.
pub(crate) fn java_build_failure(
    outcome: JavaBuildOutcome,
) -> Option<(&'static str, &'static str)> {
    match outcome {
        JavaBuildOutcome::Succeeded => None,
        JavaBuildOutcome::CompilationErrors => Some((
            "javaBuildCompilationErrors",
            "The Java project has compilation errors. Fix the reported errors and try again.",
        )),
        JavaBuildOutcome::Failed => Some((
            "javaBuildFailed",
            "The Java language service could not complete the project build. \
             Check the Java language server log for the build error.",
        )),
        JavaBuildOutcome::Cancelled => Some((
            "javaBuildCancelled",
            "The Java project build was cancelled before it finished.",
        )),
        JavaBuildOutcome::Unrecognized => Some((
            "invalidServerResult",
            "The Java language service returned an unknown project build status.",
        )),
    }
}

#[derive(Debug, Clone)]
struct BuildWaiter {
    operation_id: String,
    created_at: Instant,
    deadline: Instant,
}

/// Callers that share one dispatch because they asked for the same build.
#[derive(Debug)]
struct BuildBatch {
    /// Complete `workspace/executeCommand` params sent to JDT LS.
    command: Value,
    waiters: Vec<BuildWaiter>,
    queued_at: Instant,
}

impl BuildBatch {
    fn same_build(&self, command: &Value) -> bool {
        self.command.get("command") == command.get("command")
            && self.command.get("arguments") == command.get("arguments")
    }

    fn remove_waiter(&mut self, operation_id: &str) -> bool {
        let before = self.waiters.len();
        self.waiters
            .retain(|waiter| waiter.operation_id != operation_id);
        self.waiters.len() != before
    }
}

#[derive(Debug)]
struct InFlightBuild {
    /// JSON-RPC ID of the request, retained until JDT answers.
    request_id: String,
    batch: BuildBatch,
    started_at: Instant,
    cancel_sent: bool,
}

#[derive(Debug)]
struct ConfigurationJob {
    last_activity: Instant,
}

/// Result of trying to start the next queued build.
#[derive(Debug, Eq, PartialEq)]
pub(crate) enum JavaBuildDispatch {
    /// No caller is waiting for a build.
    Idle,
    /// A caller is waiting; `newly` is true when the reason changed.
    Blocked { block: JavaBuildBlock, newly: bool },
    /// The build was sent to JDT LS.
    Started {
        request_id: String,
        waiter_count: usize,
        waited: Duration,
    },
}

/// Callers whose shared build received a terminal response.
#[derive(Debug, Eq, PartialEq)]
pub(crate) struct CompletedJavaBuild {
    pub operation_ids: Vec<String>,
    pub elapsed: Duration,
    /// The `executeCommand` params this build was dispatched with, so the
    /// completion can report the marker scope requested upstream.
    pub command: Value,
}

/// Caller whose deadline elapsed before its build answered.
#[derive(Debug, Eq, PartialEq)]
pub(crate) struct ExpiredJavaBuildWaiter {
    pub operation_id: String,
    pub elapsed: Duration,
    /// Stable phase reached before the deadline, for diagnostics.
    pub phase: &'static str,
}

/// Waiters that left because of cancellation, timeout, or session teardown.
#[derive(Debug, Default, Eq, PartialEq)]
pub(crate) struct JavaBuildDeparture {
    pub expired: Vec<ExpiredJavaBuildWaiter>,
    /// Advisory cancellation to send when no caller still needs the running build.
    pub cancel_request_id: Option<String>,
}

/// Per-session state that serializes and gates Java project builds.
#[derive(Debug, Default)]
pub(crate) struct JavaBuildCoordinator {
    in_flight: Option<InFlightBuild>,
    queued: VecDeque<BuildBatch>,
    configuration_jobs: BTreeMap<String, ConfigurationJob>,
    /// Last block reason reported, so the monitor logs a reason once per change.
    reported_block: Option<JavaBuildBlock>,
    /// A build in this session ended with a builder failure. JDT keeps the
    /// error markers that failure left behind, and later incremental builds
    /// neither refresh nor clear them, so every subsequent verdict is suspect
    /// until the Java index is rebuilt.
    builder_failed: bool,
}

impl JavaBuildCoordinator {
    /// Whether a builder failure was already observed in this session.
    pub(crate) fn builder_failed_earlier(&self) -> bool {
        self.builder_failed
    }

    /// Records a terminal outcome so later builds can report that their markers
    /// may predate the current sources.
    pub(crate) fn observe_outcome(&mut self, outcome: JavaBuildOutcome) {
        if outcome == JavaBuildOutcome::Failed {
            self.builder_failed = true;
        }
    }

    /// Adds a caller. An identical queued build is shared; a running build
    /// never is, because it may have started before the caller saved files.
    pub(crate) fn enqueue(
        &mut self,
        operation_id: String,
        command: Value,
        now: Instant,
        timeout: Duration,
    ) {
        let waiter = BuildWaiter {
            operation_id,
            created_at: now,
            deadline: now + timeout,
        };
        if let Some(batch) = self
            .queued
            .iter_mut()
            .find(|batch| batch.same_build(&command))
        {
            batch.waiters.push(waiter);
            return;
        }
        self.queued.push_back(BuildBatch {
            command,
            waiters: vec![waiter],
            queued_at: now,
        });
    }

    /// Returns whether a caller is waiting for a build that has not started.
    pub(crate) fn has_queued(&self) -> bool {
        self.queued.iter().any(|batch| !batch.waiters.is_empty())
    }

    /// Returns whether `operation_id` is waiting for a build.
    pub(crate) fn contains(&self, operation_id: &str) -> bool {
        self.batches()
            .flat_map(|batch| batch.waiters.iter())
            .any(|waiter| waiter.operation_id == operation_id)
    }

    /// Operation IDs of every waiting caller, sorted for deterministic output.
    #[cfg(test)]
    pub(crate) fn operation_ids(&self) -> Vec<String> {
        let mut ids: Vec<String> = self
            .batches()
            .flat_map(|batch| batch.waiters.iter())
            .map(|waiter| waiter.operation_id.clone())
            .collect();
        ids.sort();
        ids
    }

    /// JSON-RPC ID of the build JDT is still running, if any.
    pub(crate) fn in_flight_request_id(&self) -> Option<&str> {
        self.in_flight
            .as_ref()
            .map(|build| build.request_id.as_str())
    }

    /// Reports the same bounded project-update gate used by build dispatch.
    pub(crate) fn project_configuration_running(&mut self, now: Instant) -> bool {
        self.configuration_jobs.retain(|_, job| {
            now.saturating_duration_since(job.last_activity) < PROJECT_CONFIGURATION_IDLE_TIMEOUT
        });
        !self.configuration_jobs.is_empty()
    }

    /// Records a project-configuration job's lifecycle from work-done progress.
    pub(crate) fn observe_progress(&mut self, progress: ProjectJobProgress, now: Instant) {
        match progress {
            ProjectJobProgress::Begin { token, label } => {
                if is_project_configuration_job(&label) {
                    self.configuration_jobs
                        .insert(token, ConfigurationJob { last_activity: now });
                }
            }
            ProjectJobProgress::Report { token } => {
                if let Some(job) = self.configuration_jobs.get_mut(&token) {
                    job.last_activity = now;
                }
            }
            ProjectJobProgress::End { token } => {
                self.configuration_jobs.remove(&token);
            }
        }
    }

    /// Sends the next build when nothing blocks it. `allocate` writes the
    /// JSON-RPC request for the command and returns its ID. If allocation
    /// fails, the batch is discarded and its callers are returned with the
    /// error so they fail once instead of being retried on every tick.
    pub(crate) fn dispatch<E>(
        &mut self,
        maven_profiles_running: bool,
        now: Instant,
        allocate: impl FnOnce(&Value) -> Result<String, E>,
    ) -> Result<JavaBuildDispatch, (E, Vec<String>)> {
        self.queued.retain(|batch| !batch.waiters.is_empty());
        if self.queued.is_empty() {
            self.reported_block = None;
            return Ok(JavaBuildDispatch::Idle);
        }
        if let Some(block) = self.block(maven_profiles_running, now) {
            let newly = self.reported_block != Some(block);
            self.reported_block = Some(block);
            return Ok(JavaBuildDispatch::Blocked { block, newly });
        }
        let Some(batch) = self.queued.pop_front() else {
            return Ok(JavaBuildDispatch::Idle);
        };
        let request_id = match allocate(&batch.command) {
            Ok(request_id) => request_id,
            Err(error) => {
                self.reported_block = None;
                let operation_ids = batch
                    .waiters
                    .into_iter()
                    .map(|waiter| waiter.operation_id)
                    .collect();
                return Err((error, operation_ids));
            }
        };
        self.reported_block = None;
        let waiter_count = batch.waiters.len();
        let waited = now.saturating_duration_since(batch.queued_at);
        self.in_flight = Some(InFlightBuild {
            request_id: request_id.clone(),
            batch,
            started_at: now,
            cancel_sent: false,
        });
        Ok(JavaBuildDispatch::Started {
            request_id,
            waiter_count,
            waited,
        })
    }

    /// Releases the running build after JDT answered `request_id`.
    pub(crate) fn complete(
        &mut self,
        request_id: &str,
        now: Instant,
    ) -> Option<CompletedJavaBuild> {
        if self.in_flight_request_id() != Some(request_id) {
            return None;
        }
        let build = self.in_flight.take()?;
        Some(CompletedJavaBuild {
            operation_ids: build
                .batch
                .waiters
                .into_iter()
                .map(|waiter| waiter.operation_id)
                .collect(),
            elapsed: now.saturating_duration_since(build.started_at),
            command: build.batch.command,
        })
    }

    /// Removes one caller. Returns `None` when the operation is not a build.
    pub(crate) fn cancel(&mut self, operation_id: &str) -> Option<JavaBuildDeparture> {
        let removed = self
            .in_flight
            .as_mut()
            .is_some_and(|build| build.batch.remove_waiter(operation_id))
            || self
                .queued
                .iter_mut()
                .any(|batch| batch.remove_waiter(operation_id));
        if !removed {
            return None;
        }
        self.queued.retain(|batch| !batch.waiters.is_empty());
        Some(JavaBuildDeparture {
            expired: Vec::new(),
            cancel_request_id: self.cancel_unneeded_build(),
        })
    }

    /// Removes every caller whose deadline elapsed.
    pub(crate) fn expire(
        &mut self,
        maven_profiles_running: bool,
        now: Instant,
    ) -> JavaBuildDeparture {
        let queued_phase = self
            .block(maven_profiles_running, now)
            .map(JavaBuildBlock::as_str)
            .unwrap_or("queued");
        let mut expired = Vec::new();
        let mut take_expired = |waiters: &mut Vec<BuildWaiter>, phase: &'static str| {
            waiters.retain(|waiter| {
                if now < waiter.deadline {
                    return true;
                }
                expired.push(ExpiredJavaBuildWaiter {
                    operation_id: waiter.operation_id.clone(),
                    elapsed: now.saturating_duration_since(waiter.created_at),
                    phase,
                });
                false
            });
        };
        if let Some(build) = self.in_flight.as_mut() {
            take_expired(&mut build.batch.waiters, "building");
        }
        for batch in &mut self.queued {
            take_expired(&mut batch.waiters, queued_phase);
        }
        if expired.is_empty() {
            return JavaBuildDeparture::default();
        }
        self.queued.retain(|batch| !batch.waiters.is_empty());
        JavaBuildDeparture {
            expired,
            cancel_request_id: self.cancel_unneeded_build(),
        }
    }

    /// Clears all state when the session stops or fails, returning the callers
    /// to fail and the request ID of a build JDT had not answered.
    pub(crate) fn drain(&mut self) -> (Vec<String>, Option<String>) {
        let in_flight = self.in_flight.take();
        let request_id = in_flight.as_ref().map(|build| build.request_id.clone());
        let mut operation_ids: Vec<String> = in_flight
            .into_iter()
            .map(|build| build.batch)
            .chain(self.queued.drain(..))
            .flat_map(|batch| batch.waiters)
            .map(|waiter| waiter.operation_id)
            .collect();
        operation_ids.sort();
        self.configuration_jobs.clear();
        self.reported_block = None;
        (operation_ids, request_id)
    }

    fn batches(&self) -> impl Iterator<Item = &BuildBatch> {
        self.in_flight
            .iter()
            .map(|build| &build.batch)
            .chain(self.queued.iter())
    }

    fn block(&mut self, maven_profiles_running: bool, now: Instant) -> Option<JavaBuildBlock> {
        self.configuration_jobs.retain(|_, job| {
            now.saturating_duration_since(job.last_activity) < PROJECT_CONFIGURATION_IDLE_TIMEOUT
        });
        if self.in_flight.is_some() {
            Some(JavaBuildBlock::PreviousBuild)
        } else if maven_profiles_running {
            Some(JavaBuildBlock::MavenProfiles)
        } else if !self.configuration_jobs.is_empty() {
            Some(JavaBuildBlock::ProjectConfiguration)
        } else {
            None
        }
    }

    /// Requests cancellation only when no running or queued caller still needs
    /// a build: a queued caller benefits from the running build's output, and
    /// interrupting JDT while it acquires workspace rules is itself risky.
    fn cancel_unneeded_build(&mut self) -> Option<String> {
        let build = self.in_flight.as_mut()?;
        if build.cancel_sent || !build.batch.waiters.is_empty() || !self.queued.is_empty() {
            return None;
        }
        build.cancel_sent = true;
        Some(build.request_id.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const TIMEOUT: Duration = Duration::from_secs(600);

    fn build_command(main_class: &str) -> Value {
        json!({
            "title": "Build Java Workspace",
            "command": JAVA_BUILD_WORKSPACE_COMMAND,
            "arguments": [format!("{{\"mainClass\":\"{main_class}\",\"isFullBuild\":false}}")]
        })
    }

    fn start_next(
        coordinator: &mut JavaBuildCoordinator,
        now: Instant,
        request_id: &str,
    ) -> JavaBuildDispatch {
        coordinator
            .dispatch(false, now, |_| Ok::<_, ()>(request_id.to_string()))
            .unwrap_or_else(|_| panic!("allocation succeeds"))
    }

    fn begin(token: &str, label: &str) -> ProjectJobProgress {
        ProjectJobProgress::Begin {
            token: token.to_string(),
            label: label.to_string(),
        }
    }

    #[test]
    fn marker_scope_follows_the_project_name_java_debug_would_use() {
        let command = |arguments: Value| {
            json!({
                "command": JAVA_BUILD_WORKSPACE_COMMAND,
                "arguments": arguments,
            })
        };
        let encoded = |payload: Value| json!([payload.to_string()]);

        assert_eq!(
            java_build_marker_scope(&command(encoded(
                json!({ "mainClass": "a.Main", "projectName": "service" })
            ))),
            JavaBuildMarkerScope::LaunchTarget
        );
        // Java Debug Server applies `isNotBlank`, so a missing field, an empty
        // string, and whitespace all take the workspace-wide fallback.
        assert_eq!(
            java_build_marker_scope(&command(encoded(json!({ "mainClass": "a.Main" })))),
            JavaBuildMarkerScope::Workspace
        );
        assert_eq!(
            java_build_marker_scope(&command(encoded(
                json!({ "mainClass": "a.Main", "projectName": "" })
            ))),
            JavaBuildMarkerScope::Workspace
        );
        assert_eq!(
            java_build_marker_scope(&command(encoded(
                json!({ "mainClass": "a.Main", "projectName": "   " })
            ))),
            JavaBuildMarkerScope::Workspace
        );
        // A payload Core cannot parse must not be reported as scoped.
        assert_eq!(
            java_build_marker_scope(&command(json!(["not json"]))),
            JavaBuildMarkerScope::Workspace
        );
        assert_eq!(
            java_build_marker_scope(&command(json!([]))),
            JavaBuildMarkerScope::Workspace
        );
    }

    #[test]
    fn a_builder_failure_marks_every_later_verdict_as_suspect() {
        let mut coordinator = JavaBuildCoordinator::default();
        let command = json!({
            "command": JAVA_BUILD_WORKSPACE_COMMAND,
            "arguments": [json!({ "projectName": "service" }).to_string()],
        });

        // The failure itself is the origin, not a casualty of an earlier one.
        assert!(!coordinator.builder_failed_earlier());
        let failure = java_build_report(
            JavaBuildOutcome::Failed,
            &command,
            coordinator.builder_failed_earlier(),
            Duration::from_millis(5012),
        );
        coordinator.observe_outcome(JavaBuildOutcome::Failed);
        assert!(!failure.builder_failed_earlier);
        assert_eq!(failure.recovery, JavaBuildRecovery::RebuildJavaIndex);

        // A later verdict stays suspect because the earlier builder failure may
        // have left markers behind. Its short duration remains evidence only.
        let leftover = java_build_report(
            JavaBuildOutcome::CompilationErrors,
            &command,
            coordinator.builder_failed_earlier(),
            Duration::from_millis(7),
        );
        assert!(leftover.builder_failed_earlier);
        assert_eq!(leftover.elapsed_milliseconds, 7);
        assert_eq!(leftover.recovery, JavaBuildRecovery::RebuildJavaIndex);
        assert_eq!(leftover.marker_scope, JavaBuildMarkerScope::LaunchTarget);
    }

    #[test]
    fn compilation_errors_without_a_builder_failure_need_no_workspace_reset() {
        let mut coordinator = JavaBuildCoordinator::default();
        coordinator.observe_outcome(JavaBuildOutcome::Succeeded);
        coordinator.observe_outcome(JavaBuildOutcome::Cancelled);
        assert!(!coordinator.builder_failed_earlier());

        let report = java_build_report(
            JavaBuildOutcome::CompilationErrors,
            &json!({ "command": JAVA_BUILD_WORKSPACE_COMMAND, "arguments": [] }),
            coordinator.builder_failed_earlier(),
            Duration::from_millis(12511),
        );
        assert!(!report.builder_failed_earlier);
        assert_eq!(report.recovery, JavaBuildRecovery::None);
        assert_eq!(report.marker_scope, JavaBuildMarkerScope::Workspace);
    }

    #[test]
    fn build_results_follow_jdt_build_workspace_status() {
        assert_eq!(
            java_build_outcome(Some(&json!(1))),
            JavaBuildOutcome::Succeeded
        );
        assert_eq!(
            java_build_outcome(Some(&json!(0))),
            JavaBuildOutcome::Failed
        );
        assert_eq!(
            java_build_outcome(Some(&json!(2))),
            JavaBuildOutcome::CompilationErrors
        );
        assert_eq!(
            java_build_outcome(Some(&json!(3))),
            JavaBuildOutcome::Cancelled
        );
        assert_eq!(
            java_build_outcome(Some(&json!(100))),
            JavaBuildOutcome::CompilationErrors
        );
        assert_eq!(
            java_build_outcome(Some(&json!("WITH_ERROR"))),
            JavaBuildOutcome::CompilationErrors
        );
        assert_eq!(
            java_build_outcome(Some(&json!("1"))),
            JavaBuildOutcome::Succeeded
        );
        assert_eq!(java_build_outcome(None), JavaBuildOutcome::Unrecognized);
        assert_eq!(java_build_failure(JavaBuildOutcome::Succeeded), None);
        let codes: Vec<_> = [
            JavaBuildOutcome::CompilationErrors,
            JavaBuildOutcome::Failed,
            JavaBuildOutcome::Cancelled,
            JavaBuildOutcome::Unrecognized,
        ]
        .into_iter()
        .filter_map(java_build_failure)
        .map(|(code, _)| code)
        .collect();
        // Each unsuccessful outcome keeps a distinct code so hosts never
        // present an internal failure or cancellation as a source error.
        assert_eq!(
            codes,
            [
                "javaBuildCompilationErrors",
                "javaBuildFailed",
                "javaBuildCancelled",
                "invalidServerResult"
            ]
        );
    }

    #[test]
    fn only_java_debug_build_commands_are_coordinated() {
        assert!(is_java_build_command("java", &build_command("demo.App")));
        assert!(!is_java_build_command("gopls", &build_command("demo.App")));
        assert!(!is_java_build_command(
            "java",
            &json!({ "command": "vscode.java.resolveClasspath", "arguments": [] })
        ));
    }

    #[test]
    fn progress_parser_uses_job_names_and_numeric_tokens() {
        let parsed = project_job_progress(
            "java",
            Some("$/progress"),
            Some(&json!({
                "token": 7,
                "value": {
                    "kind": "begin",
                    "message": "Update project ruoyi-vue-plus",
                    "title": "Refreshing '/ruoyi-vue-plus'."
                }
            })),
        );
        assert_eq!(parsed, Some(begin("7", "Update project ruoyi-vue-plus")));
        assert_eq!(
            project_job_progress(
                "java",
                Some("$/progress"),
                Some(&json!({ "token": "a", "value": { "kind": "end" } })),
            ),
            Some(ProjectJobProgress::End {
                token: "a".to_string()
            })
        );
        assert_eq!(
            project_job_progress(
                "gopls",
                Some("$/progress"),
                Some(&json!({ "token": "a", "value": { "kind": "end" } })),
            ),
            None
        );
    }

    #[test]
    fn builds_wait_for_maven_profiles_and_project_updates() {
        let now = Instant::now();
        let mut coordinator = JavaBuildCoordinator::default();
        coordinator.observe_progress(begin("update", "Update project ruoyi-vue-plus"), now);
        coordinator.observe_progress(begin("build", "Building"), now);
        coordinator.enqueue("run-1".into(), build_command("demo.App"), now, TIMEOUT);

        let blocked = coordinator
            .dispatch(true, now, |_| Ok::<_, ()>("never".to_string()))
            .unwrap();
        assert_eq!(
            blocked,
            JavaBuildDispatch::Blocked {
                block: JavaBuildBlock::MavenProfiles,
                newly: true
            }
        );
        // Profiles finished, but the update job they scheduled is still running.
        let blocked = coordinator
            .dispatch(false, now, |_| Ok::<_, ()>("never".to_string()))
            .unwrap();
        assert_eq!(
            blocked,
            JavaBuildDispatch::Blocked {
                block: JavaBuildBlock::ProjectConfiguration,
                newly: true
            }
        );
        let unchanged = coordinator
            .dispatch(false, now, |_| Ok::<_, ()>("never".to_string()))
            .unwrap();
        assert_eq!(
            unchanged,
            JavaBuildDispatch::Blocked {
                block: JavaBuildBlock::ProjectConfiguration,
                newly: false
            }
        );

        coordinator.observe_progress(
            ProjectJobProgress::End {
                token: "update".into(),
            },
            now,
        );
        let later = now + Duration::from_secs(3);
        assert_eq!(
            start_next(&mut coordinator, later, "41"),
            JavaBuildDispatch::Started {
                request_id: "41".to_string(),
                waiter_count: 1,
                waited: Duration::from_secs(3),
            }
        );
    }

    #[test]
    fn silent_configuration_jobs_stop_blocking_after_the_idle_bound() {
        let now = Instant::now();
        let mut coordinator = JavaBuildCoordinator::default();
        coordinator.observe_progress(begin("update", "Updating project configurations"), now);
        coordinator.enqueue("run-1".into(), build_command("demo.App"), now, TIMEOUT);

        let reported = now + PROJECT_CONFIGURATION_IDLE_TIMEOUT - Duration::from_secs(1);
        coordinator.observe_progress(
            ProjectJobProgress::Report {
                token: "update".into(),
            },
            reported,
        );
        assert!(matches!(
            start_next(
                &mut coordinator,
                now + PROJECT_CONFIGURATION_IDLE_TIMEOUT,
                "1"
            ),
            JavaBuildDispatch::Blocked { .. }
        ));
        assert!(matches!(
            start_next(
                &mut coordinator,
                reported + PROJECT_CONFIGURATION_IDLE_TIMEOUT,
                "1"
            ),
            JavaBuildDispatch::Started { .. }
        ));
    }

    #[test]
    fn one_build_runs_at_a_time_and_identical_queued_requests_share_the_next() {
        let now = Instant::now();
        let mut coordinator = JavaBuildCoordinator::default();
        coordinator.enqueue("run-1".into(), build_command("demo.App"), now, TIMEOUT);
        assert!(matches!(
            start_next(&mut coordinator, now, "10"),
            JavaBuildDispatch::Started {
                waiter_count: 1,
                ..
            }
        ));
        // Repeated Run clicks while the first build is running: the running
        // build is not shared because it may predate the latest save.
        coordinator.enqueue("run-2".into(), build_command("demo.App"), now, TIMEOUT);
        coordinator.enqueue("run-3".into(), build_command("demo.App"), now, TIMEOUT);
        coordinator.enqueue("other".into(), build_command("demo.Other"), now, TIMEOUT);
        assert_eq!(
            start_next(&mut coordinator, now, "11"),
            JavaBuildDispatch::Blocked {
                block: JavaBuildBlock::PreviousBuild,
                newly: true
            }
        );

        let first = coordinator
            .complete("10", now + Duration::from_secs(32))
            .unwrap();
        assert_eq!(first.operation_ids, ["run-1"]);
        assert_eq!(first.elapsed, Duration::from_secs(32));
        assert!(matches!(
            start_next(&mut coordinator, now, "11"),
            JavaBuildDispatch::Started {
                waiter_count: 2,
                ..
            }
        ));
        assert_eq!(coordinator.complete("unknown", now), None);
        let second = coordinator.complete("11", now).unwrap();
        assert_eq!(second.operation_ids, ["run-2", "run-3"]);
        assert!(matches!(
            start_next(&mut coordinator, now, "12"),
            JavaBuildDispatch::Started {
                waiter_count: 1,
                ..
            }
        ));
        assert_eq!(
            coordinator.complete("12", now).unwrap().operation_ids,
            ["other"]
        );
        assert_eq!(
            start_next(&mut coordinator, now, "13"),
            JavaBuildDispatch::Idle
        );
    }

    #[test]
    fn cancelling_the_only_caller_cancels_but_keeps_tracking_the_running_build() {
        let now = Instant::now();
        let mut coordinator = JavaBuildCoordinator::default();
        coordinator.enqueue("run-1".into(), build_command("demo.App"), now, TIMEOUT);
        start_next(&mut coordinator, now, "10");

        let departure = coordinator.cancel("run-1").unwrap();
        assert_eq!(departure.cancel_request_id.as_deref(), Some("10"));
        assert_eq!(coordinator.cancel("run-1"), None);
        // JDT may keep building after advisory cancellation, so a new caller
        // waits for that build's response instead of overlapping it.
        coordinator.enqueue("run-2".into(), build_command("demo.App"), now, TIMEOUT);
        assert!(matches!(
            start_next(&mut coordinator, now, "11"),
            JavaBuildDispatch::Blocked {
                block: JavaBuildBlock::PreviousBuild,
                ..
            }
        ));
        let abandoned = coordinator.complete("10", now).unwrap();
        assert!(abandoned.operation_ids.is_empty());
        assert!(matches!(
            start_next(&mut coordinator, now, "11"),
            JavaBuildDispatch::Started { .. }
        ));
    }

    #[test]
    fn a_running_build_is_not_cancelled_while_another_caller_needs_a_build() {
        let now = Instant::now();
        let mut coordinator = JavaBuildCoordinator::default();
        coordinator.enqueue("run-1".into(), build_command("demo.App"), now, TIMEOUT);
        coordinator.enqueue("run-1b".into(), build_command("demo.App"), now, TIMEOUT);
        start_next(&mut coordinator, now, "10");
        coordinator.enqueue("run-2".into(), build_command("demo.App"), now, TIMEOUT);

        assert_eq!(coordinator.cancel("run-1").unwrap().cancel_request_id, None);
        assert_eq!(
            coordinator.cancel("run-1b").unwrap().cancel_request_id,
            None
        );
        // The last caller leaving the queue makes the running build unneeded.
        assert_eq!(
            coordinator
                .cancel("run-2")
                .unwrap()
                .cancel_request_id
                .as_deref(),
            Some("10")
        );
        assert!(coordinator.operation_ids().is_empty());
        assert_eq!(coordinator.in_flight_request_id(), Some("10"));
    }

    #[test]
    fn deadlines_report_the_phase_each_caller_reached() {
        let now = Instant::now();
        let mut coordinator = JavaBuildCoordinator::default();
        let short = Duration::from_secs(30);
        coordinator.enqueue("building".into(), build_command("demo.App"), now, short);
        start_next(&mut coordinator, now, "10");
        coordinator.enqueue("queued".into(), build_command("demo.App"), now, short);
        coordinator.enqueue("patient".into(), build_command("demo.App"), now, TIMEOUT);

        assert_eq!(
            coordinator.expire(false, now + Duration::from_secs(29)),
            JavaBuildDeparture::default()
        );
        let departure = coordinator.expire(false, now + short);
        assert_eq!(
            departure.expired,
            [
                ExpiredJavaBuildWaiter {
                    operation_id: "building".to_string(),
                    elapsed: short,
                    phase: "building",
                },
                ExpiredJavaBuildWaiter {
                    operation_id: "queued".to_string(),
                    elapsed: short,
                    phase: "waitingForPreviousBuild",
                },
            ]
        );
        // `patient` still needs a build, so the running one is not cancelled.
        assert_eq!(departure.cancel_request_id, None);
        assert_eq!(coordinator.operation_ids(), ["patient"]);
    }

    #[test]
    fn draining_returns_every_caller_and_the_unanswered_build() {
        let now = Instant::now();
        let mut coordinator = JavaBuildCoordinator::default();
        coordinator.observe_progress(begin("update", "Update project app"), now);
        coordinator.enqueue("b".into(), build_command("demo.App"), now, TIMEOUT);
        coordinator.observe_progress(
            ProjectJobProgress::End {
                token: "update".into(),
            },
            now,
        );
        start_next(&mut coordinator, now, "10");
        coordinator.enqueue("a".into(), build_command("demo.Other"), now, TIMEOUT);

        let (operation_ids, request_id) = coordinator.drain();
        assert_eq!(operation_ids, ["a", "b"]);
        assert_eq!(request_id.as_deref(), Some("10"));
        assert!(!coordinator.contains("a"));
        assert_eq!(
            start_next(&mut coordinator, now, "11"),
            JavaBuildDispatch::Idle
        );
    }

    #[test]
    fn allocation_failure_fails_the_batch_once_and_keeps_later_builds() {
        let now = Instant::now();
        let mut coordinator = JavaBuildCoordinator::default();
        coordinator.enqueue("run-1".into(), build_command("demo.App"), now, TIMEOUT);
        coordinator.enqueue("run-1b".into(), build_command("demo.App"), now, TIMEOUT);
        coordinator.enqueue("other".into(), build_command("demo.Other"), now, TIMEOUT);
        let failed = coordinator.dispatch(false, now, |_| Err::<String, _>("encode failed"));
        assert_eq!(
            failed,
            Err((
                "encode failed",
                vec!["run-1".to_string(), "run-1b".to_string()]
            ))
        );
        assert!(!coordinator.contains("run-1"));
        assert_eq!(coordinator.in_flight_request_id(), None);
        assert!(matches!(
            start_next(&mut coordinator, now, "10"),
            JavaBuildDispatch::Started {
                waiter_count: 1,
                ..
            }
        ));
    }
}
