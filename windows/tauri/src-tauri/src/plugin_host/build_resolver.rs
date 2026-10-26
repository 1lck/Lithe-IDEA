//! Resolves Core-ordered build executable candidates on Windows.
//!
//! Rust Core owns candidate ordering, setting validation, version parsing, and
//! build-system semantics. This adapter only turns an `invocationPlan` into
//! real Windows paths and candidate-local environments. It never starts a
//! process: callers execute each returned probe through the shared bounded
//! process runner, pass its output to `build.checkToolVersion`, and resume the
//! session with that deterministic answer.

use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::fmt;
use std::path::{Component, Path, PathBuf};

#[cfg(windows)]
use std::os::windows::fs::MetadataExt;

#[cfg(windows)]
const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0400;

/// A host-managed runtime selected by the existing Windows runtime settings.
///
/// `environment` carries runtime-owned values such as `JAVA_HOME`. The
/// executable directory is added to PATH by this resolver. Explicit inputs
/// are terminal: a stale user selection must not silently switch runtimes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RuntimeExecutableInput {
    pub(crate) executable: PathBuf,
    pub(crate) environment: BTreeMap<String, String>,
    pub(crate) explicit: bool,
}

impl RuntimeExecutableInput {
    pub(crate) fn discovered(executable: PathBuf) -> Self {
        Self {
            executable,
            environment: BTreeMap::new(),
            explicit: false,
        }
    }
}

/// Stateless production adapter plus one frozen environment/runtime snapshot.
///
/// Construct one per operation. That prevents a settings or environment change
/// halfway through resolution from changing the meaning of later candidates.
#[derive(Debug, Clone)]
pub(crate) struct WindowsBuildToolResolver {
    environment: BTreeMap<String, String>,
    runtimes: BTreeMap<String, RuntimeExecutableInput>,
    discovery_root: Option<PathBuf>,
}

impl WindowsBuildToolResolver {
    /// Passive cwd validation shared by the model planner; this performs no
    /// executable discovery or version probe.
    pub(crate) fn instance_directory(
        invocation: &Value,
        workspace: &Path,
    ) -> Result<PathBuf, BuildResolutionError> {
        Self {
            environment: BTreeMap::new(),
            runtimes: BTreeMap::new(),
            discovery_root: None,
        }
        .start(invocation, workspace)
        .map(|session| session.instance_root)
    }

    /// Passive native path proof shared with Provider bindings. Core keeps
    /// the workspace-relative root in its plans; hosts also retain the real
    /// directory identity without rewriting Provider request parameters.
    pub(crate) fn instance_root_directory(
        root: &str,
        workspace: &Path,
    ) -> Result<PathBuf, BuildResolutionError> {
        let workspace = absolute_existing_directory(workspace, "workspace root")?;
        let relative = plan_relative_path(root, "instance root")?;
        let path = workspace.join(relative);
        reject_reparse_components(&workspace, &path)?;
        let directory = absolute_existing_directory(&path, "build instance root")?;
        if !path_is_within(&directory, &workspace) {
            return Err(BuildResolutionError::project_escape(
                "Provider instance escaped its workspace",
            ));
        }
        Ok(directory)
    }
    /// Option-owned environment is frozen before both probes and execution.
    pub(crate) fn with_overrides(mut self, values: BTreeMap<String, String>) -> Self {
        for (key, value) in values {
            environment_set(&mut self.environment, key, value);
        }
        self
    }

    /// Freeze relative discovery before an operation can wait for consent.
    pub(crate) fn freeze_discovery(mut self) -> Result<Self, BuildResolutionError> {
        self.discovery_root = Some(std::env::current_dir().map_err(|error| {
            BuildResolutionError::invalid_plan(format!(
                "host tool discovery directory could not be resolved: {error}"
            ))
        })?);
        Ok(self)
    }

    /// Uses the process environment and caller-supplied runtime preferences.
    /// Runtime settings stay owned by the existing Windows runtime manager;
    /// this module deliberately has no persistence of its own.
    pub(crate) fn from_current_process(runtimes: BTreeMap<String, RuntimeExecutableInput>) -> Self {
        Self {
            environment: std::env::vars().collect(),
            runtimes,
            discovery_root: None,
        }
    }

    #[cfg(test)]
    pub(crate) fn with_environment(
        environment: BTreeMap<String, String>,
        runtimes: BTreeMap<String, RuntimeExecutableInput>,
    ) -> Self {
        Self {
            environment,
            runtimes,
            discovery_root: None,
        }
    }

    /// Validates the Core plan and freezes workspace/instance real paths.
    pub(crate) fn start(
        &self,
        invocation: &Value,
        workspace_root: &Path,
    ) -> Result<BuildResolutionSession, BuildResolutionError> {
        let plan: InvocationPlan = serde_json::from_value(invocation.clone()).map_err(|error| {
            BuildResolutionError::invalid_plan(format!("build invocation plan is invalid: {error}"))
        })?;
        let workspace_root = absolute_existing_directory(workspace_root, "workspace root")?;
        let instance_root = Self::instance_root_directory(&plan.root, &workspace_root)?;
        let configured_setting = plan
            .executables
            .iter()
            .chain(
                plan.runtime_dependencies
                    .iter()
                    .flat_map(|runtime| runtime.executables.iter()),
            )
            .any(ExecutableCandidate::has_configured_setting);
        // Relative discovery inputs belong to the host's current directory,
        // never the workspace that a later probe or build runs in.
        let discovery_root = self
            .discovery_root
            .clone()
            .map(Ok)
            .unwrap_or_else(std::env::current_dir)
            .map_err(|error| {
                BuildResolutionError::invalid_plan(format!(
                    "host tool discovery directory could not be resolved: {error}"
                ))
            })?;
        Ok(BuildResolutionSession {
            plan,
            workspace_root,
            instance_root,
            discovery_root,
            environment: self.environment.clone(),
            runtime_executables: BTreeMap::new(),
            runtime_index: 0,
            runtime_candidate_index: 0,
            tool_candidate_index: 0,
            pending: None,
            problems: Vec::new(),
            configured_setting,
        })
    }

    /// Advances resolution until a probe is needed or a tool is selected.
    ///
    /// The first call passes `None`. A `Probe` result must be followed by one
    /// call carrying the matching outcome; extra or missing outcomes are a
    /// protocol error. No filesystem state other than executable existence is
    /// retained between calls.
    pub(crate) fn advance(
        &self,
        session: &mut BuildResolutionSession,
        outcome: Option<VersionProbeOutcome>,
    ) -> Result<BuildResolutionStep, BuildResolutionError> {
        self.consume_probe(session, outcome)?;
        loop {
            if session.runtime_index < session.plan.runtime_dependencies.len() {
                if let Some(step) = self.advance_runtime(session)? {
                    return Ok(step);
                }
                continue;
            }
            return self.advance_tool(session);
        }
    }

    fn consume_probe(
        &self,
        session: &mut BuildResolutionSession,
        outcome: Option<VersionProbeOutcome>,
    ) -> Result<(), BuildResolutionError> {
        let Some(pending) = session.pending.take() else {
            if outcome.is_some() {
                return Err(BuildResolutionError::invalid_plan(
                    "a version outcome was supplied without a pending probe",
                ));
            }
            return Ok(());
        };
        let outcome = outcome.ok_or_else(|| {
            BuildResolutionError::invalid_plan("the pending version probe has no outcome")
        })?;
        match outcome {
            VersionProbeOutcome::Accepted { version } => match pending.target {
                PendingTarget::Runtime { id } => {
                    session.environment = pending.selection.environment;
                    session
                        .runtime_executables
                        .insert(id, pending.selection.executable);
                    session.runtime_index += 1;
                    session.runtime_candidate_index = 0;
                }
                PendingTarget::Tool => {
                    session.pending = Some(PendingProbe {
                        target: PendingTarget::ResolvedTool { version },
                        selection: pending.selection,
                        minimum_version: pending.minimum_version,
                    });
                }
                PendingTarget::ResolvedTool { .. } => {
                    return Err(BuildResolutionError::invalid_plan(
                        "a completed build-tool probe was resumed twice",
                    ));
                }
            },
            VersionProbeOutcome::Rejected { version } => {
                let problem = match version {
                    Some(version) => format!(
                        "{} reported version {version}; {} or newer is required",
                        pending.selection.executable.display(),
                        pending.minimum_version
                    ),
                    None => format!(
                        "{} did not report a usable version; {} or newer is required",
                        pending.selection.executable.display(),
                        pending.minimum_version
                    ),
                };
                if pending.selection.terminal {
                    return Err(BuildResolutionError::configured(problem));
                }
                session.problems.push(problem);
            }
            VersionProbeOutcome::Failed { message } => {
                let problem = format!(
                    "version probe for {} failed: {message}",
                    pending.selection.executable.display()
                );
                if pending.selection.terminal {
                    return Err(BuildResolutionError::configured(problem));
                }
                session.problems.push(problem);
            }
        }
        Ok(())
    }

    fn advance_runtime(
        &self,
        session: &mut BuildResolutionSession,
    ) -> Result<Option<BuildResolutionStep>, BuildResolutionError> {
        let dependency = session.plan.runtime_dependencies[session.runtime_index].clone();
        let sources = self.runtime_sources(&dependency, &session.environment);
        while session.runtime_candidate_index < sources.len() {
            let source = sources[session.runtime_candidate_index].clone();
            session.runtime_candidate_index += 1;
            let Some(mut selection) = self.resolve_source(session, source)? else {
                continue;
            };
            prepend_path(&mut selection.environment, &selection.executable)?;
            if selection.executes_project_code {
                session.environment = selection.environment;
                session
                    .runtime_executables
                    .insert(dependency.id.clone(), selection.executable);
                session.runtime_index += 1;
                session.runtime_candidate_index = 0;
                return Ok(None);
            }
            if let Some((arguments, minimum_version)) = dependency.probe() {
                let probe = VersionProbePlan::new(
                    selection.clone(),
                    arguments,
                    Some(dependency.id.clone()),
                    minimum_version.clone(),
                );
                session.pending = Some(PendingProbe {
                    target: PendingTarget::Runtime {
                        id: dependency.id.clone(),
                    },
                    selection,
                    minimum_version,
                });
                return Ok(Some(BuildResolutionStep::Probe(probe)));
            }
            session.environment = selection.environment;
            session
                .runtime_executables
                .insert(dependency.id.clone(), selection.executable);
            session.runtime_index += 1;
            session.runtime_candidate_index = 0;
            return Ok(None);
        }
        let name = dependency.display_name.as_deref().unwrap_or(&dependency.id);
        Err(BuildResolutionError::unavailable(
            format!("build runtime {name} is not available"),
            session.configured_setting,
            &session.problems,
        ))
    }

    fn advance_tool(
        &self,
        session: &mut BuildResolutionSession,
    ) -> Result<BuildResolutionStep, BuildResolutionError> {
        if let Some(PendingProbe {
            target: PendingTarget::ResolvedTool { version },
            selection,
            ..
        }) = session.pending.take()
        {
            return Ok(BuildResolutionStep::Resolved(ResolvedBuildTool {
                executable: selection.executable,
                environment: selection.environment,
                executes_project_code: selection.executes_project_code,
                version,
                runtime_executables: session.runtime_executables.clone(),
            }));
        }
        while session.tool_candidate_index < session.plan.executables.len() {
            let candidate = session.plan.executables[session.tool_candidate_index].clone();
            session.tool_candidate_index += 1;
            let Some(mut selection) = self.resolve_candidate(session, candidate)? else {
                continue;
            };
            if selection.terminal {
                prepend_path(&mut selection.environment, &selection.executable)?;
            }
            if selection.executes_project_code {
                return Ok(BuildResolutionStep::Resolved(ResolvedBuildTool {
                    executable: selection.executable,
                    environment: selection.environment,
                    executes_project_code: true,
                    version: None,
                    runtime_executables: session.runtime_executables.clone(),
                }));
            }
            if let Some((arguments, minimum_version)) = session.plan.probe() {
                let probe = VersionProbePlan::new(
                    selection.clone(),
                    arguments,
                    None,
                    minimum_version.clone(),
                );
                session.pending = Some(PendingProbe {
                    target: PendingTarget::Tool,
                    selection,
                    minimum_version,
                });
                return Ok(BuildResolutionStep::Probe(probe));
            }
            return Ok(BuildResolutionStep::Resolved(ResolvedBuildTool {
                executable: selection.executable,
                environment: selection.environment,
                executes_project_code: false,
                version: None,
                runtime_executables: session.runtime_executables.clone(),
            }));
        }
        Err(BuildResolutionError::unavailable(
            format!(
                "build tool {} is not available",
                session.plan.build_system_id
            ),
            session.configured_setting,
            &session.problems,
        ))
    }

    fn runtime_sources(
        &self,
        dependency: &RuntimeDependencyPlan,
        environment: &BTreeMap<String, String>,
    ) -> Vec<ResolutionSource> {
        if !dependency.host_managed {
            return dependency
                .executables
                .iter()
                .cloned()
                .map(ResolutionSource::Candidate)
                .collect();
        }
        let mut sources = Vec::new();
        if let Some(input) = self.runtimes.get(&dependency.id) {
            sources.push(ResolutionSource::Direct {
                executable: input.executable.clone(),
                environment: input.environment.clone(),
                terminal: input.explicit,
            });
            if input.explicit {
                return sources;
            }
        }
        if dependency.id.eq_ignore_ascii_case("java") {
            if let Some(home) = environment_value(environment, "JAVA_HOME") {
                sources.push(ResolutionSource::Direct {
                    executable: PathBuf::from(home).join("bin").join("java.exe"),
                    environment: BTreeMap::from([("JAVA_HOME".into(), home.to_string())]),
                    terminal: false,
                });
            }
        }
        sources.push(ResolutionSource::Candidate(ExecutableCandidate::Command {
            command: dependency.id.clone(),
        }));
        sources
    }

    fn resolve_source(
        &self,
        session: &BuildResolutionSession,
        source: ResolutionSource,
    ) -> Result<Option<SelectedCandidate>, BuildResolutionError> {
        match source {
            ResolutionSource::Candidate(candidate) => self.resolve_candidate(session, candidate),
            ResolutionSource::Direct {
                executable,
                environment,
                terminal,
            } => {
                let mut selected_environment = session.environment.clone();
                for (key, value) in environment {
                    environment_set(&mut selected_environment, key, value);
                }
                let discovered = discovery_path(&session.discovery_root, &executable);
                if discovered
                    .as_ref()
                    .is_none_or(|executable| !is_spawnable_windows_file(executable))
                {
                    if terminal {
                        return Err(BuildResolutionError::configured(format!(
                            "configured runtime {} is not a Windows executable file",
                            executable.display()
                        )));
                    }
                    return Ok(None);
                }
                Ok(Some(SelectedCandidate {
                    executable: discovered.expect("spawnable discovered executable"),
                    environment: selected_environment,
                    executes_project_code: false,
                    terminal,
                }))
            }
        }
    }

    fn resolve_candidate(
        &self,
        session: &BuildResolutionSession,
        candidate: ExecutableCandidate,
    ) -> Result<Option<SelectedCandidate>, BuildResolutionError> {
        let environment = session.environment.clone();
        let found = match candidate {
            ExecutableCandidate::ProjectFile { path, requires, .. } => {
                for required in requires {
                    if project_entry(session, &required, false)?.is_none() {
                        return Ok(None);
                    }
                }
                project_entry(session, &path, true)?.map(|executable| SelectedCandidate {
                    executable,
                    environment,
                    executes_project_code: true,
                    terminal: false,
                })
            }
            ExecutableCandidate::Environment { variable, path } => {
                if !session
                    .plan
                    .environment_inputs
                    .iter()
                    .any(|input| input.eq_ignore_ascii_case(&variable))
                {
                    return Ok(None);
                }
                let Some(base) = environment_value(&environment, &variable) else {
                    return Ok(None);
                };
                let base = PathBuf::from(base);
                let relative = plan_relative_path(&path, "environment executable")?;
                let Some(executable) =
                    discovery_path(&session.discovery_root, &base.join(relative))
                else {
                    return Ok(None);
                };
                is_spawnable_windows_file(&executable).then_some(SelectedCandidate {
                    executable,
                    environment,
                    executes_project_code: false,
                    terminal: false,
                })
            }
            ExecutableCandidate::Command { command } => {
                let path = environment_value(&environment, "PATH")
                    .and_then(|path| {
                        let directories: Vec<_> = std::env::split_paths(path)
                            .filter_map(|directory| {
                                discovery_path(&session.discovery_root, &directory)
                            })
                            .collect();
                        // An empty join would become an implicit cwd entry in
                        // find_system_tool instead of an empty search list.
                        (!directories.is_empty()).then(|| std::env::join_paths(directories))
                    })
                    .transpose()
                    .map_err(|error| {
                        BuildResolutionError::invalid_plan(format!(
                            "build tool search path is invalid: {error}"
                        ))
                    })?;
                super::super::language_tools::find_system_tool(path.as_deref(), &command).map(
                    |executable| SelectedCandidate {
                        executable,
                        environment,
                        executes_project_code: false,
                        terminal: false,
                    },
                )
            }
            ExecutableCandidate::Runtime { runtime } => session
                .runtime_executables
                .get(&runtime)
                .cloned()
                .map(|executable| SelectedCandidate {
                    executable,
                    environment,
                    executes_project_code: false,
                    terminal: false,
                }),
            ExecutableCandidate::Setting { setting_id, path } => {
                let Some(path) = path else { return Ok(None) };
                let executable = PathBuf::from(&path);
                if !executable.is_absolute() || !is_spawnable_windows_file(&executable) {
                    return Err(BuildResolutionError::configured(format!(
                        "configured build tool {setting_id} is not an executable file: {path}"
                    )));
                }
                Some(SelectedCandidate {
                    executable,
                    environment,
                    executes_project_code: false,
                    terminal: true,
                })
            }
        };
        Ok(found)
    }
}

/// Mutable continuation owned by one upper-layer build operation.
#[derive(Debug)]
pub(crate) struct BuildResolutionSession {
    plan: InvocationPlan,
    workspace_root: PathBuf,
    instance_root: PathBuf,
    /// Frozen host cwd for environment/PATH/runtime discovery inputs.
    discovery_root: PathBuf,
    environment: BTreeMap<String, String>,
    runtime_executables: BTreeMap<String, PathBuf>,
    runtime_index: usize,
    runtime_candidate_index: usize,
    tool_candidate_index: usize,
    pending: Option<PendingProbe>,
    problems: Vec<String>,
    configured_setting: bool,
}

/// The caller either executes one bounded version probe or receives the tool.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum BuildResolutionStep {
    Probe(VersionProbePlan),
    Resolved(ResolvedBuildTool),
}

/// A process plan only; creating this value grants no execution permission.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct VersionProbePlan {
    pub(crate) executable: PathBuf,
    pub(crate) arguments: Vec<String>,
    pub(crate) environment: BTreeMap<String, String>,
    pub(crate) runtime: Option<String>,
    pub(crate) minimum_version: String,
    pub(crate) terminal: bool,
}

impl VersionProbePlan {
    fn new(
        selection: SelectedCandidate,
        arguments: Vec<String>,
        runtime: Option<String>,
        minimum_version: String,
    ) -> Self {
        Self {
            executable: selection.executable,
            arguments,
            environment: selection.environment,
            runtime,
            minimum_version,
            terminal: selection.terminal,
        }
    }

    /// Request body for Core's `build.checkToolVersion` after the caller has
    /// captured combined stdout and stderr from this probe.
    pub(crate) fn core_request(&self, output: impl Into<String>) -> Value {
        let mut request = json!({ "output": output.into() });
        if let Some(runtime) = &self.runtime {
            request["runtime"] = json!(runtime);
        }
        request
    }
}

/// Core's version judgment, or a platform probe failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum VersionProbeOutcome {
    Accepted { version: Option<String> },
    Rejected { version: Option<String> },
    Failed { message: String },
}

impl VersionProbeOutcome {
    /// Parses the `version` value returned by `build.checkToolVersion`.
    pub(crate) fn from_core(value: &Value) -> Result<Self, BuildResolutionError> {
        let value = value.get("version").unwrap_or(value);
        let satisfied = value
            .get("satisfied")
            .and_then(Value::as_bool)
            .ok_or_else(|| {
                BuildResolutionError::invalid_plan(
                    "build.checkToolVersion returned no satisfied boolean",
                )
            })?;
        let version = value
            .get("version")
            .and_then(Value::as_str)
            .map(str::to_string);
        Ok(if satisfied {
            Self::Accepted { version }
        } else {
            Self::Rejected { version }
        })
    }
}

/// Selected executable and the exact environment its probe must also use.
///
/// `executes_project_code` remains an authorization input. Resolution alone
/// never grants workspace trust or permission to start the process.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedBuildTool {
    pub(crate) executable: PathBuf,
    pub(crate) environment: BTreeMap<String, String>,
    pub(crate) executes_project_code: bool,
    pub(crate) version: Option<String>,
    pub(crate) runtime_executables: BTreeMap<String, PathBuf>,
}

/// Stable host-side category plus a diagnostic message for the upper layer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct BuildResolutionError {
    code: &'static str,
    message: String,
    terminal: bool,
}

impl BuildResolutionError {
    pub(crate) fn code(&self) -> &'static str {
        self.code
    }

    pub(crate) fn is_terminal(&self) -> bool {
        self.terminal
    }

    fn invalid_plan(message: impl Into<String>) -> Self {
        Self {
            code: "plugin.build.invalidPlan",
            message: message.into(),
            terminal: true,
        }
    }

    fn project_escape(message: impl Into<String>) -> Self {
        Self {
            code: "plugin.build.projectPathEscape",
            message: message.into(),
            terminal: true,
        }
    }

    fn configured(message: impl Into<String>) -> Self {
        Self {
            code: "plugin.build.configuredToolUnavailable",
            message: message.into(),
            terminal: true,
        }
    }

    fn unavailable(message: String, terminal: bool, problems: &[String]) -> Self {
        let message = if problems.is_empty() {
            message
        } else {
            format!("{message}. {}", problems.join(". "))
        };
        Self {
            code: if terminal {
                "plugin.build.configuredToolUnavailable"
            } else {
                "plugin.build.toolUnavailable"
            },
            message,
            terminal,
        }
    }
}

impl fmt::Display for BuildResolutionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for BuildResolutionError {}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct InvocationPlan {
    #[serde(rename = "buildSystemID")]
    build_system_id: String,
    root: String,
    executables: Vec<ExecutableCandidate>,
    #[serde(default)]
    environment_inputs: Vec<String>,
    #[serde(default)]
    runtime_dependencies: Vec<RuntimeDependencyPlan>,
    version: Option<VersionProbe>,
    minimum_version: Option<String>,
}

impl InvocationPlan {
    fn probe(&self) -> Option<(Vec<String>, String)> {
        Some((
            self.version.as_ref()?.arguments.clone(),
            self.minimum_version.clone()?,
        ))
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RuntimeDependencyPlan {
    id: String,
    display_name: Option<String>,
    host_managed: bool,
    minimum_version: Option<String>,
    #[serde(default)]
    executables: Vec<ExecutableCandidate>,
    version: Option<VersionProbe>,
}

impl RuntimeDependencyPlan {
    fn probe(&self) -> Option<(Vec<String>, String)> {
        Some((
            self.version.as_ref()?.arguments.clone(),
            self.minimum_version.clone()?,
        ))
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct VersionProbe {
    arguments: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
enum ExecutableCandidate {
    ProjectFile {
        path: String,
        #[serde(default)]
        requires: Vec<String>,
        #[serde(default, rename = "executesProjectCode")]
        _executes_project_code: bool,
    },
    Environment {
        variable: String,
        path: String,
    },
    Command {
        command: String,
    },
    Runtime {
        runtime: String,
    },
    Setting {
        #[serde(rename = "settingID")]
        setting_id: String,
        path: Option<String>,
    },
}

impl ExecutableCandidate {
    fn has_configured_setting(&self) -> bool {
        matches!(self, Self::Setting { path: Some(_), .. })
    }
}

#[derive(Debug, Clone)]
enum ResolutionSource {
    Candidate(ExecutableCandidate),
    Direct {
        executable: PathBuf,
        environment: BTreeMap<String, String>,
        terminal: bool,
    },
}

#[derive(Debug, Clone)]
struct SelectedCandidate {
    executable: PathBuf,
    environment: BTreeMap<String, String>,
    executes_project_code: bool,
    terminal: bool,
}

#[derive(Debug)]
struct PendingProbe {
    target: PendingTarget,
    selection: SelectedCandidate,
    minimum_version: String,
}

#[derive(Debug)]
enum PendingTarget {
    Runtime { id: String },
    Tool,
    ResolvedTool { version: Option<String> },
}

fn absolute_existing_directory(path: &Path, label: &str) -> Result<PathBuf, BuildResolutionError> {
    if !path.is_absolute() {
        return Err(BuildResolutionError::invalid_plan(format!(
            "{label} must be absolute: {}",
            path.display()
        )));
    }
    let metadata = std::fs::symlink_metadata(path).map_err(|error| {
        BuildResolutionError::invalid_plan(format!(
            "{label} {} is unreadable: {error}",
            path.display()
        ))
    })?;
    if is_reparse_or_link(&metadata) || !metadata.is_dir() {
        return Err(BuildResolutionError::project_escape(format!(
            "{label} {} must be a real directory",
            path.display()
        )));
    }
    path.canonicalize().map_err(|error| {
        BuildResolutionError::invalid_plan(format!(
            "{label} {} could not be resolved: {error}",
            path.display()
        ))
    })
}

/// Freezes discovered paths before testing or returning them. Drive-relative
/// Windows paths are ambiguous even with a host cwd, so they are not candidates.
fn discovery_path(host_directory: &Path, path: &Path) -> Option<PathBuf> {
    if path.is_absolute() {
        return Some(path.to_path_buf());
    }
    if path
        .components()
        .any(|component| matches!(component, Component::Prefix(_) | Component::RootDir))
    {
        return None;
    }
    Some(host_directory.join(path))
}

fn plan_relative_path(value: &str, label: &str) -> Result<PathBuf, BuildResolutionError> {
    let path = Path::new(value);
    if path.is_absolute()
        || path.components().any(|component| {
            matches!(
                component,
                Component::ParentDir | Component::Prefix(_) | Component::RootDir
            )
        })
    {
        return Err(BuildResolutionError::invalid_plan(format!(
            "{label} must be workspace-relative: {value}"
        )));
    }
    Ok(value
        .split(['/', '\\'])
        .filter(|part| !part.is_empty() && *part != ".")
        .fold(PathBuf::new(), |path, part| path.join(part)))
}

fn project_entry(
    session: &BuildResolutionSession,
    relative: &str,
    executable: bool,
) -> Result<Option<PathBuf>, BuildResolutionError> {
    let relative = plan_relative_path(relative, "project executable")?;
    let path = session.workspace_root.join(relative);
    if !path.starts_with(&session.instance_root) {
        return Err(BuildResolutionError::project_escape(format!(
            "project executable {} is outside instance root {}",
            path.display(),
            session.instance_root.display()
        )));
    }
    if !reject_reparse_components(&session.workspace_root, &path)? {
        return Ok(None);
    }
    let metadata = match std::fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(BuildResolutionError::invalid_plan(format!(
                "project entry {} is unreadable: {error}",
                path.display()
            )))
        }
    };
    if is_reparse_or_link(&metadata) || !metadata.is_file() {
        return Ok(None);
    }
    let canonical = path.canonicalize().map_err(|error| {
        BuildResolutionError::invalid_plan(format!(
            "project entry {} could not be resolved: {error}",
            path.display()
        ))
    })?;
    if !path_is_within(&canonical, &session.instance_root) {
        return Err(BuildResolutionError::project_escape(format!(
            "project entry {} resolves outside instance root {}",
            path.display(),
            session.instance_root.display()
        )));
    }
    if executable && !has_windows_executable_type(&path) {
        return Ok(None);
    }
    Ok(Some(path))
}

/// Returns `false` only when a path component does not exist. Other metadata
/// failures stay visible instead of being mistaken for a missing candidate.
fn reject_reparse_components(root: &Path, target: &Path) -> Result<bool, BuildResolutionError> {
    let relative = target.strip_prefix(root).map_err(|_| {
        BuildResolutionError::project_escape(format!(
            "{} is outside workspace {}",
            target.display(),
            root.display()
        ))
    })?;
    let mut current = root.to_path_buf();
    for component in relative.components() {
        current.push(component.as_os_str());
        let metadata = match std::fs::symlink_metadata(&current) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
            Err(error) => {
                return Err(BuildResolutionError::invalid_plan(format!(
                    "project path {} is unreadable: {error}",
                    current.display()
                )))
            }
        };
        if is_reparse_or_link(&metadata) {
            return Err(BuildResolutionError::project_escape(format!(
                "project path {} crosses a reparse point",
                current.display()
            )));
        }
    }
    Ok(true)
}

fn is_reparse_or_link(metadata: &std::fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
    }
    #[cfg(not(windows))]
    {
        metadata.file_type().is_symlink()
    }
}

fn path_is_within(path: &Path, root: &Path) -> bool {
    #[cfg(windows)]
    {
        let path = path.components().collect::<Vec<_>>();
        let root = root.components().collect::<Vec<_>>();
        path.len() >= root.len()
            && path.iter().zip(root.iter()).all(|(left, right)| {
                left.as_os_str()
                    .to_string_lossy()
                    .eq_ignore_ascii_case(&right.as_os_str().to_string_lossy())
            })
    }
    #[cfg(not(windows))]
    {
        path.starts_with(root)
    }
}

fn is_spawnable_windows_file(path: &Path) -> bool {
    let Ok(metadata) = std::fs::symlink_metadata(path) else {
        return false;
    };
    !is_reparse_or_link(&metadata) && metadata.is_file() && has_windows_executable_type(path)
}

fn has_windows_executable_type(path: &Path) -> bool {
    path.extension()
        .and_then(OsStr::to_str)
        .is_some_and(|extension| {
            extension.eq_ignore_ascii_case("exe")
                || extension.eq_ignore_ascii_case("cmd")
                || extension.eq_ignore_ascii_case("bat")
        })
}

fn environment_value<'a>(environment: &'a BTreeMap<String, String>, key: &str) -> Option<&'a str> {
    environment
        .iter()
        .find(|(candidate, _)| candidate.eq_ignore_ascii_case(key))
        .map(|(_, value)| value.as_str())
}

fn environment_set(environment: &mut BTreeMap<String, String>, key: String, value: String) {
    let aliases = environment
        .keys()
        .filter(|candidate| candidate.eq_ignore_ascii_case(&key))
        .cloned()
        .collect::<Vec<_>>();
    for alias in aliases {
        environment.remove(&alias);
    }
    environment.insert(key, value);
}

fn prepend_path(
    environment: &mut BTreeMap<String, String>,
    executable: &Path,
) -> Result<(), BuildResolutionError> {
    let directory = executable.parent().ok_or_else(|| {
        BuildResolutionError::invalid_plan(format!(
            "executable {} has no parent directory",
            executable.display()
        ))
    })?;
    let existing = environment_value(environment, "PATH").unwrap_or_default();
    let mut paths = vec![directory.to_path_buf()];
    paths.extend(std::env::split_paths(OsStr::new(existing)));
    let joined = std::env::join_paths(paths).map_err(|error| {
        BuildResolutionError::invalid_plan(format!("could not construct PATH: {error}"))
    })?;
    environment_set(
        environment,
        "PATH".into(),
        joined.to_string_lossy().into_owned(),
    );
    Ok(())
}
