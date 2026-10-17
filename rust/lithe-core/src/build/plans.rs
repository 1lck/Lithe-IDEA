//! Argv plans for tasks, tests, model and dependency commands, and the run
//! entries derived from a model.
//!
//! Every plan is the build system's global arguments followed by the
//! command's own, expanded for one selection and one set of option values.
//! Plans always run at the instance root: build tools address nested
//! projects with their own flags, which the templates spell out. Model and
//! dependency sources answered by a provider get a request for that process
//! instead of an argv plan.

use super::decode::{self, join_relative};
use super::integrations;
use super::manifest::{
    BuildExecution, BuildSystemDeclaration, DependenciesSource, ExecutableCandidate, ModelSource,
    OutputChannel, ProviderDeclaration, RunDeclaration, Scope, TestFilter, TestResultsSource,
    WorkingDirectory,
};
use super::model::{entry_id, BuildModel, ModelProject};
use super::options::{self, OptionContribution};
use super::template::{self, BuildArgument, Selected, Values, Variable};
use crate::plugins::declarative::{PluginRejection, Validation};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

const MAX_USER_ARGUMENTS: usize = 64;
const MAX_USER_ARGUMENT: usize = 4_096;
const MAX_SELECTION_TEXT: usize = 1_024;
/// Bounds the report globs a workspace test plan lists; the model's own
/// project limit.
const MAX_REPORT_PROJECTS: usize = super::model::MAX_PROJECTS;
/// Provider methods; their results are the canonical formats of the same
/// name that commands may print.
const PROVIDER_MODEL_METHOD: &str = "lithe/build/model";
const PROVIDER_DEPENDENCIES_METHOD: &str = "lithe/build/dependencies";

pub(crate) fn invalid_selection(message: impl Into<String>) -> PluginRejection {
    PluginRejection::new("plugin.build.invalidSelection", message)
}

pub(crate) fn unavailable(build_system: &BuildSystemDeclaration, what: &str) -> PluginRejection {
    PluginRejection::new(
        "plugin.build.unavailable",
        format!("{} does not declare {what}.", build_system.display_name),
    )
}

/// A project, target, or task the host selected from the model.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SelectedEntity {
    /// Workspace-relative directory; a target or task defaults to its
    /// project's, and a project is required to have one.
    #[serde(default)]
    pub(crate) path: Option<String>,
    pub(crate) name: String,
    #[serde(default)]
    pub(crate) tags: Vec<String>,
    /// For model tasks: the execution the model recorded.
    #[serde(default)]
    pub(crate) execution: Option<BuildExecution>,
    #[serde(default)]
    pub(crate) properties: BTreeMap<String, String>,
}

/// Fields every plan request shares.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PlanBase {
    /// Instance root, workspace-relative.
    pub(crate) root: String,
    /// Stored option values by option ID.
    #[serde(default)]
    pub(crate) options: BTreeMap<String, Value>,
    /// Absolute installed plugin directory, for `${pluginDir}`.
    #[serde(default)]
    pub(crate) plugin_directory: Option<String>,
    /// Absolute writable directory of this plugin for this workspace.
    #[serde(default)]
    pub(crate) workspace_state_directory: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TaskPlanRequest {
    #[serde(flatten)]
    pub(crate) base: PlanBase,
    /// A task declaration ID.
    pub(crate) task: String,
    #[serde(default)]
    pub(crate) project: Option<SelectedEntity>,
    #[serde(default)]
    pub(crate) target: Option<SelectedEntity>,
    /// The model task, when `task` is a `fromModel` template.
    #[serde(default)]
    pub(crate) model_task: Option<SelectedEntity>,
    #[serde(default)]
    pub(crate) user_arguments: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TestPlanRequest {
    #[serde(flatten)]
    pub(crate) base: PlanBase,
    #[serde(default)]
    pub(crate) project: Option<SelectedEntity>,
    #[serde(default)]
    pub(crate) target: Option<SelectedEntity>,
    #[serde(default)]
    pub(crate) suite: Option<String>,
    #[serde(default)]
    pub(crate) case: Option<String>,
    #[serde(default)]
    pub(crate) user_arguments: Vec<String>,
    /// Workspace-relative project directories from the current model; a
    /// workspace run collects reports from each of them.
    #[serde(default)]
    pub(crate) projects: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct OutputPlanRequest {
    #[serde(flatten)]
    pub(crate) base: PlanBase,
    #[serde(default)]
    pub(crate) project: Option<SelectedEntity>,
    /// Fresh absolute host-owned path, for `"output": "outputFile"`.
    #[serde(default)]
    pub(crate) output_file: Option<String>,
}

/// A selection resolved against the instance root.
pub(crate) struct Selection {
    pub(crate) name: String,
    /// Workspace-relative directory.
    pub(crate) path: String,
    /// Directory relative to the instance root.
    pub(crate) relative: String,
    pub(crate) tags: Vec<String>,
    pub(crate) execution: Option<BuildExecution>,
    pub(crate) properties: BTreeMap<String, String>,
}

impl Selection {
    fn selected(&self) -> Selected<'_> {
        Selected {
            name: &self.name,
            path: &self.relative,
            properties: &self.properties,
        }
    }
}

fn selection_text(value: &str, what: &str) -> Validation<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() || value.len() > MAX_SELECTION_TEXT || value.chars().any(char::is_control)
    {
        return Err(invalid_selection(format!(
            "The {what} is empty or not printable."
        )));
    }
    Ok(value.to_string())
}

pub(crate) fn selection(
    entity: &SelectedEntity,
    root: &str,
    default_path: Option<&str>,
    what: &str,
) -> Validation<Selection> {
    let path = match (&entity.path, default_path) {
        (Some(path), _) => decode::request_path(path, what)?,
        (None, Some(path)) => path.to_string(),
        (None, None) => return Err(invalid_selection(format!("The {what} needs a path."))),
    };
    let relative = decode::relative_to(root, &path).ok_or_else(|| {
        invalid_selection(format!("The {what} is outside the build-system root."))
    })?;
    for value in entity.properties.values() {
        if value.contains('\0') || value.len() > MAX_SELECTION_TEXT {
            return Err(invalid_selection(format!("A {what} property is invalid.")));
        }
    }
    Ok(Selection {
        name: selection_text(&entity.name, &format!("{what} name"))?,
        path,
        relative,
        tags: entity.tags.clone(),
        execution: entity.execution,
        properties: entity.properties.clone(),
    })
}

/// Options and directories of one plan request.
pub(crate) struct PlanContext<'a> {
    pub(crate) build_system: &'a BuildSystemDeclaration,
    pub(crate) root: String,
    pub(crate) contribution: OptionContribution,
    pub(crate) fingerprint: String,
    /// Effective option values by option ID.
    option_values: BTreeMap<String, Value>,
    plugin_directory: Option<String>,
    workspace_state_directory: Option<String>,
}

fn host_directory(value: &Option<String>, name: &str) -> Validation<Option<String>> {
    let Some(value) = value else {
        return Ok(None);
    };
    let trimmed = value.trim_end_matches(['/', '\\']);
    if trimmed.is_empty()
        || trimmed.chars().any(char::is_control)
        || !Path::new(trimmed).is_absolute()
    {
        return Err(invalid_selection(format!(
            "The {name} must be an absolute path."
        )));
    }
    Ok(Some(trimmed.to_string()))
}

impl<'a> PlanContext<'a> {
    pub(crate) fn new(
        build_system: &'a BuildSystemDeclaration,
        base: &PlanBase,
    ) -> Validation<Self> {
        Self::with_model_options(build_system, base, None)
    }

    fn with_model_options(
        build_system: &'a BuildSystemDeclaration,
        base: &PlanBase,
        model_values: Option<&BTreeMap<String, Vec<String>>>,
    ) -> Validation<Self> {
        let resolved = options::resolve(build_system, &base.options, model_values);
        let contribution = options::contribution(build_system, &resolved)?;
        let fingerprint = options::fingerprint(build_system, &resolved);
        Ok(Self {
            build_system,
            root: decode::request_path(&base.root, "root")?,
            contribution,
            fingerprint,
            option_values: resolved.values,
            plugin_directory: host_directory(&base.plugin_directory, "pluginDirectory")?,
            workspace_state_directory: host_directory(
                &base.workspace_state_directory,
                "workspaceStateDirectory",
            )?,
        })
    }

    fn values<'v>(&'v self, user_arguments: &'v [String]) -> Values<'v> {
        Values {
            root: &self.root,
            option_arguments: &self.contribution.arguments,
            user_arguments,
            plugin_dir: self.plugin_directory.as_deref(),
            workspace_state_dir: self.workspace_state_directory.as_deref(),
            ..Values::default()
        }
    }

    /// Global arguments followed by `arguments`, as one plan.
    pub(crate) fn plan(
        &self,
        arguments: &[BuildArgument],
        values: &Values<'_>,
        execution: BuildExecution,
        extra: Map<String, Value>,
    ) -> Validation<Value> {
        let mut argv = template::expand(&self.build_system.invocation.global_arguments, values)?;
        argv.extend(template::expand(arguments, values)?);
        self.plan_with_arguments(argv, execution, extra)
    }

    pub(crate) fn plan_with_arguments(
        &self,
        arguments: Vec<String>,
        execution: BuildExecution,
        extra: Map<String, Value>,
    ) -> Validation<Value> {
        let mut plan = json!({
            "buildSystemID": self.build_system.id,
            "root": self.root,
            "arguments": arguments,
            "environment": self.contribution.environment,
            "workingDirectory": self.root,
            "execution": execution,
            "optionFingerprint": self.fingerprint,
        });
        if let Value::Object(object) = &mut plan {
            object.extend(extra);
        }
        Ok(plan)
    }

    /// A request for the provider process. Paths in `params` are relative
    /// to the workspace folder the host sent in `initialize`; options come
    /// as their effective values and as the arguments and environment they
    /// would contribute to a command line, so the provider can hand either
    /// to the tool.
    fn provider_plan(
        &self,
        provider: &ProviderDeclaration,
        method: &str,
        decoder: &str,
        mut params: Map<String, Value>,
    ) -> Value {
        let option_arguments: Vec<&String> = self
            .contribution
            .arguments
            .iter()
            .flat_map(|(_, arguments)| arguments)
            .collect();
        params.insert("buildSystemID".to_string(), json!(self.build_system.id));
        params.insert("root".to_string(), json!(self.root));
        params.insert("options".to_string(), json!(self.option_values));
        params.insert("optionArguments".to_string(), json!(option_arguments));
        params.insert(
            "environment".to_string(),
            json!(self.contribution.environment),
        );
        json!({
            "buildSystemID": self.build_system.id,
            "root": self.root,
            "provider": { "method": method, "params": params },
            "decoder": decoder,
            "executesProjectCode": provider.executes_project_code(),
            "mayUseNetwork": provider.may_use_network(),
            "optionFingerprint": self.fingerprint,
        })
    }
}

/// The provider a validated declaration names for one of its sources.
fn declared_provider(build_system: &BuildSystemDeclaration) -> Validation<&ProviderDeclaration> {
    build_system
        .provider
        .as_ref()
        .ok_or_else(|| unavailable(build_system, "a provider"))
}

fn check_user_arguments(arguments: &[String], declared: &[BuildArgument]) -> Validation<()> {
    if arguments.is_empty() {
        return Ok(());
    }
    if !template::uses(declared, &template::Variable::UserArguments) {
        return Err(invalid_selection("This command takes no extra arguments."));
    }
    if arguments.len() > MAX_USER_ARGUMENTS
        || arguments
            .iter()
            .any(|argument| argument.contains('\0') || argument.len() > MAX_USER_ARGUMENT)
    {
        return Err(invalid_selection(
            "The extra arguments are too long or contain NUL.",
        ));
    }
    Ok(())
}

/// Validates a host-allocated output file path.
pub(crate) fn output_file(
    value: Option<&str>,
    channel: OutputChannel,
) -> Validation<Option<String>> {
    match (channel, value) {
        (OutputChannel::Stdout, _) => Ok(None),
        (OutputChannel::OutputFile, None) => Err(invalid_selection(
            "This command writes to a file; pass outputFile.",
        )),
        (OutputChannel::OutputFile, Some(path)) => {
            // The path becomes part of an argument; surrounding whitespace or
            // control characters would change which file the tool writes.
            let usable = !path.is_empty()
                && path.trim() == path
                && !path.chars().any(char::is_control)
                && Path::new(path).is_absolute();
            if !usable {
                return Err(invalid_selection("outputFile must be an absolute path."));
            }
            Ok(Some(path.to_string()))
        }
    }
}

/// Which scope a selection addresses.
fn selected_scope(project: bool, target: bool) -> Scope {
    match (project, target) {
        (_, true) => Scope::Target,
        (true, false) => Scope::Project,
        (false, false) => Scope::Workspace,
    }
}

fn scope_name(scope: Scope) -> &'static str {
    match scope {
        Scope::Workspace => "the workspace",
        Scope::Project => "a project",
        Scope::Target => "a target",
    }
}

/// `build.taskPlan`.
pub(crate) fn task_plan(
    build_system: &BuildSystemDeclaration,
    request: &TaskPlanRequest,
) -> Validation<Value> {
    let context = PlanContext::new(build_system, &request.base)?;
    let declaration = build_system.task(&request.task).ok_or_else(|| {
        invalid_selection(format!(
            "{} has no task {}.",
            build_system.display_name, request.task
        ))
    })?;
    check_user_arguments(&request.user_arguments, &declaration.arguments)?;
    let project = request
        .project
        .as_ref()
        .map(|project| selection(project, &context.root, None, "project"))
        .transpose()?;
    let mut values = context.values(&request.user_arguments);
    let execution;
    let target;
    let task;
    if declaration.from_model {
        let (Some(project), Some(model_task)) = (&project, &request.model_task) else {
            return Err(invalid_selection(
                "A model task needs its project and modelTask.",
            ));
        };
        if request.target.is_some() {
            return Err(invalid_selection("A model task does not take a target."));
        }
        let selected = selection(model_task, &context.root, Some(&project.path), "task")?;
        execution = selected.execution.unwrap_or(declaration.execution);
        task = Some(selected);
        target = None;
    } else {
        if request.model_task.is_some() {
            return Err(invalid_selection(format!(
                "{} is not a model task.",
                declaration.id
            )));
        }
        target = request
            .target
            .as_ref()
            .map(|entity| {
                let project = project
                    .as_ref()
                    .ok_or_else(|| invalid_selection("A target needs its project."))?;
                selection(entity, &context.root, Some(&project.path), "target")
            })
            .transpose()?;
        let scope = selected_scope(project.is_some(), target.is_some());
        if !declaration.scopes.contains(&scope) {
            return Err(invalid_selection(format!(
                "The task {} does not run on {}.",
                declaration.id,
                scope_name(scope)
            )));
        }
        if !target_matches(target.as_ref(), &declaration.target_tags) {
            return Err(invalid_selection(format!(
                "The task {} does not apply to this target.",
                declaration.id
            )));
        }
        execution = declaration.execution;
        task = None;
    }
    values.project = project.as_ref().map(Selection::selected);
    values.target = target.as_ref().map(Selection::selected);
    values.task = task.as_ref().map(Selection::selected);
    context.plan(&declaration.arguments, &values, execution, Map::new())
}

fn check_test_text(value: &Option<String>, what: &str) -> Validation<()> {
    if let Some(value) = value {
        selection_text(value, what)?;
    }
    Ok(())
}

/// `build.testPlan`: the command and where its results will be.
/// Whether a selected target carries one of the declared tags; no tags
/// accept every target.
fn target_matches(target: Option<&Selection>, tags: &[String]) -> bool {
    target.is_none_or(|target| tags.is_empty() || target.tags.iter().any(|tag| tags.contains(tag)))
}

pub(crate) fn test_plan(
    build_system: &BuildSystemDeclaration,
    request: &TestPlanRequest,
) -> Validation<Value> {
    let test = build_system
        .test
        .as_ref()
        .ok_or_else(|| unavailable(build_system, "tests"))?;
    let context = PlanContext::new(build_system, &request.base)?;
    check_user_arguments(&request.user_arguments, &test.arguments)?;
    check_test_text(&request.suite, "test suite")?;
    check_test_text(&request.case, "test case")?;
    for (requested, filter) in [
        (request.suite.is_some(), TestFilter::Suite),
        (request.case.is_some(), TestFilter::Case),
    ] {
        if requested && !test.filters.contains(&filter) {
            return Err(invalid_selection(format!(
                "{} cannot select a single test {filter:?}.",
                build_system.display_name
            )));
        }
    }
    let project = request
        .project
        .as_ref()
        .map(|project| selection(project, &context.root, None, "project"))
        .transpose()?;
    let target = request
        .target
        .as_ref()
        .map(|entity| {
            let project = project
                .as_ref()
                .ok_or_else(|| invalid_selection("A target needs its project."))?;
            selection(entity, &context.root, Some(&project.path), "target")
        })
        .transpose()?;
    let scope = selected_scope(project.is_some(), target.is_some());
    if !test.scopes.contains(&scope) {
        return Err(invalid_selection(format!(
            "{} does not run tests on {}.",
            build_system.display_name,
            scope_name(scope)
        )));
    }
    if !target_matches(target.as_ref(), &test.target_tags) {
        return Err(invalid_selection(format!(
            "{} does not run tests on this target.",
            build_system.display_name
        )));
    }
    let mut values = context.values(&request.user_arguments);
    values.project = project.as_ref().map(Selection::selected);
    values.target = target.as_ref().map(Selection::selected);
    values.suite = request.suite.as_deref();
    values.case = request.case.as_deref();
    // Declaring a filter does not make every combination expressible: a
    // case that only means something inside its suite (`-Dtest=Suite#case`,
    // `--tests Suite.case`) would otherwise silently widen to every test.
    for (requested, variables, what) in [
        (
            request.suite.is_some(),
            &[Variable::TestSuite][..],
            "a test suite",
        ),
        (
            request.case.is_some(),
            &[Variable::TestCase, Variable::TestCaseRegex][..],
            "this test case without its suite",
        ),
    ] {
        if requested && !template::applies_any(&test.arguments, &values, variables) {
            return Err(invalid_selection(format!(
                "{} cannot select {what}.",
                build_system.display_name
            )));
        }
    }
    let directories = match &project {
        Some(project) => vec![project.path.clone()],
        None => {
            let mut directories = BTreeSet::from([context.root.clone()]);
            for path in request.projects.iter().take(MAX_REPORT_PROJECTS) {
                let path = decode::request_path(path, "project")?;
                if decode::contains(&context.root, &path) {
                    directories.insert(path);
                }
            }
            directories.into_iter().collect()
        }
    };
    let reports = |globs: &[String]| -> Vec<String> {
        directories
            .iter()
            .flat_map(|directory| globs.iter().map(|glob| join_relative(directory, glob)))
            .collect()
    };
    let results = match &test.results {
        None => Value::Null,
        Some(TestResultsSource::JunitXml { reports: globs }) => json!({
            "decoder": "junitXml",
            "reports": reports(globs),
        }),
        Some(TestResultsSource::LitheTestResults { reports: globs }) => json!({
            "decoder": "litheTestResults",
            "reports": reports(globs),
        }),
        Some(TestResultsSource::HostIntegration) => json!({ "decoder": "hostIntegration" }),
    };
    let mut extra = Map::new();
    extra.insert("results".to_string(), results);
    context.plan(&test.arguments, &values, BuildExecution::Task, extra)
}

fn output_extra(
    output: OutputChannel,
    decoder: Value,
    executes_project_code: bool,
    may_use_network: bool,
) -> Map<String, Value> {
    let mut extra = Map::new();
    extra.insert("output".to_string(), json!(output));
    extra.insert("decoder".to_string(), decoder);
    extra.insert(
        "executesProjectCode".to_string(),
        json!(executes_project_code),
    );
    extra.insert("mayUseNetwork".to_string(), json!(may_use_network));
    extra
}

/// `build.modelPlan`: the command that prints the model, or the provider
/// request that returns it. Static and integration models need neither;
/// `build.decodeModel` reads them.
pub(crate) fn model_plan(
    build_system: &BuildSystemDeclaration,
    request: &OutputPlanRequest,
) -> Validation<Value> {
    if matches!(build_system.model, Some(ModelSource::Provider)) {
        if request.project.is_some() {
            return Err(invalid_selection(
                "The model request covers the whole instance.",
            ));
        }
        let context = PlanContext::new(build_system, &request.base)?;
        return Ok(context.provider_plan(
            declared_provider(build_system)?,
            PROVIDER_MODEL_METHOD,
            "litheBuildModel",
            Map::new(),
        ));
    }
    let Some(ModelSource::Command {
        arguments,
        output,
        decoder,
        executes_project_code,
        may_use_network,
        ..
    }) = &build_system.model
    else {
        return Err(PluginRejection::new(
            "plugin.build.unavailable",
            format!(
                "{} reads its model without a command; use build.decodeModel.",
                build_system.display_name
            ),
        ));
    };
    if request.project.is_some() {
        return Err(invalid_selection(
            "The model command covers the whole instance.",
        ));
    }
    let context = PlanContext::new(build_system, &request.base)?;
    let output_file = output_file(request.output_file.as_deref(), *output)?;
    let mut values = context.values(&[]);
    values.output_file = output_file.as_deref();
    context.plan(
        arguments,
        &values,
        BuildExecution::Task,
        output_extra(
            *output,
            json!(decoder),
            *executes_project_code,
            *may_use_network,
        ),
    )
}

/// `build.dependencyPlan`.
pub(crate) fn dependency_plan(
    build_system: &BuildSystemDeclaration,
    request: &OutputPlanRequest,
) -> Validation<Value> {
    let source = build_system
        .dependencies
        .as_ref()
        .ok_or_else(|| unavailable(build_system, "dependencies"))?;
    let context = PlanContext::new(build_system, &request.base)?;
    let project = request
        .project
        .as_ref()
        .map(|project| selection(project, &context.root, None, "project"))
        .transpose()?;
    let check_scope = |scopes: &[Scope]| {
        let scope = selected_scope(project.is_some(), false);
        if !scopes.contains(&scope) {
            return Err(invalid_selection(format!(
                "{} does not list dependencies of {}.",
                build_system.display_name,
                scope_name(scope)
            )));
        }
        Ok(())
    };
    match source {
        DependenciesSource::Command {
            scopes,
            arguments,
            output,
            decoder,
            executes_project_code,
            may_use_network,
            ..
        } => {
            check_scope(scopes)?;
            let output_file = output_file(request.output_file.as_deref(), *output)?;
            let mut values = context.values(&[]);
            values.project = project.as_ref().map(Selection::selected);
            values.output_file = output_file.as_deref();
            context.plan(
                arguments,
                &values,
                BuildExecution::Task,
                output_extra(
                    *output,
                    json!(decoder),
                    *executes_project_code,
                    *may_use_network,
                ),
            )
        }
        DependenciesSource::HostIntegration => integrations::dependency_plan(
            &context,
            project.as_ref(),
            request.output_file.as_deref(),
        ),
        DependenciesSource::Provider { scopes } => {
            check_scope(scopes)?;
            let mut params = Map::new();
            params.insert(
                "project".to_string(),
                project.as_ref().map_or(
                    Value::Null,
                    |project| json!({ "name": project.name, "path": project.path }),
                ),
            );
            Ok(context.provider_plan(
                declared_provider(build_system)?,
                PROVIDER_DEPENDENCIES_METHOD,
                "litheDependencies",
                params,
            ))
        }
    }
}

// MARK: Run entries

/// The bare command of a build system whose only candidate is one; run
/// entries then need no executable resolution of their own.
fn sole_command(build_system: &BuildSystemDeclaration) -> Option<&str> {
    match build_system.invocation.executables.as_slice() {
        [ExecutableCandidate::Command { command, platforms }] if platforms.is_empty() => {
            Some(command)
        }
        _ => None,
    }
}

fn project_selection(project: &ModelProject, root: &str) -> Option<Selection> {
    Some(Selection {
        name: project.name.clone(),
        path: project.path.clone(),
        relative: decode::relative_to(root, &project.path)?,
        tags: Vec::new(),
        execution: None,
        properties: project.properties.clone(),
    })
}

struct EntryParts<'a> {
    run: &'a RunDeclaration,
    project: &'a ModelProject,
    name: String,
    arguments: Vec<String>,
    execution: BuildExecution,
    extension: Map<String, Value>,
    binding: (&'static str, String),
}

/// Run entries at the given options, from every run declaration. Entries
/// whose templates need a value the model did not record are left out.
pub(crate) fn run_entries(
    build_system: &BuildSystemDeclaration,
    model: &BuildModel,
    root: &str,
    stored_options: &BTreeMap<String, Value>,
    source: Option<&str>,
) -> Validation<Vec<Value>> {
    if build_system.run.is_empty() {
        return Ok(Vec::new());
    }
    let base = PlanBase {
        root: root.to_string(),
        options: stored_options.clone(),
        plugin_directory: None,
        workspace_state_directory: None,
    };
    let context = PlanContext::with_model_options(build_system, &base, Some(&model.option_values))?;
    let projects: BTreeMap<&str, &ModelProject> = model
        .projects
        .iter()
        .map(|project| (project.id.as_str(), project))
        .collect();
    let mut parts = Vec::new();
    for run in &build_system.run {
        if let Some(from) = &run.from_targets {
            for target in model
                .targets
                .iter()
                .filter(|target| target.tags.iter().any(|tag| from.tags.contains(tag)))
            {
                let Some(project) = projects.get(target.project_id.as_str()) else {
                    continue;
                };
                let (Some(project_selection), Some(relative)) = (
                    project_selection(project, &context.root),
                    decode::relative_to(&context.root, &target.path),
                ) else {
                    continue;
                };
                let target_selection = Selection {
                    name: target.name.clone(),
                    path: target.path.clone(),
                    relative,
                    tags: target.tags.clone(),
                    execution: None,
                    properties: target.properties.clone(),
                };
                let mut values = context.values(&[]);
                values.project = Some(project_selection.selected());
                values.target = Some(target_selection.selected());
                if let Some(entry) = entry_parts(
                    &context,
                    run,
                    project,
                    &run.arguments,
                    &values,
                    &target.name,
                    run.execution.unwrap_or(BuildExecution::Application),
                    ("targetID", target.id.clone()),
                ) {
                    parts.push(entry);
                }
            }
        }
        if let Some(from) = &run.from_tasks {
            for task in model.tasks.iter().filter(|task| {
                (from.templates.is_empty() || from.templates.contains(&task.template))
                    && (from.executions.is_empty() || from.executions.contains(&task.execution))
            }) {
                let (Some(project), Some(declaration)) = (
                    projects.get(task.project_id.as_str()),
                    build_system.task(&task.template),
                ) else {
                    continue;
                };
                let (Some(project_selection), Some(relative)) = (
                    project_selection(project, &context.root),
                    decode::relative_to(&context.root, &task.path),
                ) else {
                    continue;
                };
                let task_selection = Selection {
                    name: task.name.clone(),
                    path: task.path.clone(),
                    relative,
                    tags: Vec::new(),
                    execution: Some(task.execution),
                    properties: task.properties.clone(),
                };
                let mut values = context.values(&[]);
                values.project = Some(project_selection.selected());
                values.task = Some(task_selection.selected());
                if let Some(entry) = entry_parts(
                    &context,
                    run,
                    project,
                    &declaration.arguments,
                    &values,
                    &task.name,
                    run.execution.unwrap_or(task.execution),
                    ("taskID", task.id.clone()),
                ) {
                    parts.push(entry);
                }
            }
        }
    }

    let command = sole_command(build_system);
    let mut seen = BTreeSet::new();
    let mut entries = Vec::new();
    for part in parts {
        let cwd = match part.run.working_directory {
            WorkingDirectory::Project => part.project.path.clone(),
            WorkingDirectory::Root => context.root.clone(),
        };
        let provider = format!("{}.{}", build_system.id, part.run.id);
        let id = entry_id(&provider, &cwd, &part.name);
        if !seen.insert(id.clone()) {
            continue;
        }
        let mut entry = json!({
            "id": id,
            "name": part.name,
            "provider": provider,
            "execution": part.execution,
            "command": command,
            "args": part.arguments,
            "cwd": cwd,
            "env": context.contribution.environment,
            "source": source,
            "buildSystem": {
                "id": build_system.id,
                "root": context.root,
                "projectID": part.project.id,
                part.binding.0: part.binding.1,
                "optionFingerprint": context.fingerprint,
            },
        });
        if !part.extension.is_empty() {
            entry["extensions"] = json!({ build_system.id.clone(): part.extension });
        }
        entries.push((cwd.matches('/').count(), cwd, part.name, entry));
    }
    entries.sort_by(|left, right| (left.0, &left.1, &left.2).cmp(&(right.0, &right.1, &right.2)));
    Ok(entries.into_iter().map(|(_, _, _, entry)| entry).collect())
}

#[allow(clippy::too_many_arguments)]
fn entry_parts<'a>(
    context: &PlanContext<'_>,
    run: &'a RunDeclaration,
    project: &'a ModelProject,
    arguments: &[BuildArgument],
    values: &Values<'_>,
    default_name: &str,
    execution: BuildExecution,
    binding: (&'static str, String),
) -> Option<EntryParts<'a>> {
    let mut argv =
        template::expand(&context.build_system.invocation.global_arguments, values).ok()?;
    argv.extend(template::expand(arguments, values).ok()?);
    let name = match &run.name {
        Some(name) => template::expand_text(name, values).ok()?,
        None => default_name.to_string(),
    };
    let mut extension = Map::new();
    for (key, value) in &run.extension {
        extension.insert(
            key.clone(),
            json!(template::expand_text(value, values).ok()?),
        );
    }
    Some(EntryParts {
        run,
        project,
        name,
        arguments: argv,
        execution,
        extension,
        binding,
    })
}
