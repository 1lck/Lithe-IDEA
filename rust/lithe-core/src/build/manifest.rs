//! `buildSystems` declarations of API level 3 plugins and their validation.
//!
//! A declaration is data only. Everything a community plugin needs is
//! expressible here: any command or packaged script as the executable, any
//! runtime it depends on (described by how to find and probe it), and any
//! output, either through a selector map over a public format or by printing
//! one of the canonical `lithe*` formats. What no command can print is
//! answered by a `provider`: a server process of the plugin, declared with
//! the language-server launch fields or shared with one of its language
//! servers. The only named host code is a `hostIntegration`, reserved to
//! official plugins while Maven migrates.

use super::select::{self, FieldSpec, Predicate};
use super::template::{self, Allowed, Availability, BuildArgument, Variable};
use crate::plugins::declarative::{
    invalid, is_bare_command, is_identifier, is_safe_relative_path, is_setting_identifier,
    sorted_unique, template as template_error, validate_minimum_version, PluginRejection,
    ServerProcess, ServerRole, UIIcon, Validation, KNOWN_RUNTIME_TOOLS_V2,
};
use regex::Regex;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

/// First plugin API level with `buildSystems`.
pub(crate) const BUILD_SYSTEMS_API_VERSION: u32 = 3;
/// Host integrations a build system may name; official plugins only.
pub(crate) const HOST_INTEGRATION_MAVEN: &str = "maven";
const HOST_INTEGRATIONS: &[&str] = &[HOST_INTEGRATION_MAVEN];

const MAX_BUILD_SYSTEMS: usize = 16;
const MAX_LIST: usize = 32;
const MAX_TASKS: usize = 128;
const MAX_CHOICES: usize = 64;
const MAX_ARGUMENTS: usize = 64;
const MAX_TEXT: usize = 120;
const MAX_OPTION_VALUE: usize = 256;
const MAX_REGEX: usize = 512;
const MAX_IDENTIFIER: usize = 64;
const MAX_PRIORITY: u8 = 100;
const DEFAULT_PRIORITY: u8 = 50;
const DEFAULT_SEPARATOR: &str = ",";
/// Deepest heading path a task can be filed under, e.g. `Plugins › compiler`.
pub(crate) const MAX_CATEGORY_DEPTH: usize = 4;

/// One project-level build tool a plugin describes.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct BuildSystemDeclaration {
    pub(crate) id: String,
    pub(crate) display_name: String,
    /// Icon of the build system's tool window; display only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) icon: Option<UIIcon>,
    pub(crate) detection: Detection,
    pub(crate) invocation: Invocation,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) host_integration: Option<String>,
    /// The process that answers the `provider` sources.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) provider: Option<ProviderDeclaration>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) options: Vec<OptionDeclaration>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) model: Option<ModelSource>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) tasks: Vec<TaskDeclaration>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) run: Vec<RunDeclaration>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) test: Option<TestDeclaration>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) diagnostics: Option<DiagnosticsDeclaration>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) dependencies: Option<DependenciesSource>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) sync: Option<SyncDeclaration>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) layout: Option<LayoutDeclaration>,
    /// How the Java language server imports this build system's projects.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) language_import: Option<LanguageImportDeclaration>,
}

/// A server process that answers `lithe/build/*` requests over the LSP base
/// protocol. It is a language-server process: either one of its own, with
/// the same launch fields as `languageServers[]`, or the plugin's language
/// server of one language, which then answers build requests besides its
/// language features. The form is decided by `languageServer`, so a mistake
/// is reported against that form's fields.
#[derive(Debug, Clone, Serialize)]
#[serde(untagged)]
#[allow(clippy::large_enum_variant)] // Decoded once per manifest validation.
pub(crate) enum ProviderDeclaration {
    LanguageServer(SharedProvider),
    Process(ProcessProvider),
}

/// Build requests go to the language server of `languageServer`.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct SharedProvider {
    #[serde(rename = "languageServer")]
    pub(crate) language_id: String,
    pub(crate) executes_project_code: bool,
    pub(crate) may_use_network: bool,
}

/// A provider process of its own.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ProcessProvider {
    #[serde(flatten)]
    pub(crate) process: ServerProcess,
    pub(crate) executes_project_code: bool,
    pub(crate) may_use_network: bool,
}

impl<'de> Deserialize<'de> for ProviderDeclaration {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = Value::deserialize(deserializer)?;
        if value.get("languageServer").is_some() {
            SharedProvider::deserialize(value).map(Self::LanguageServer)
        } else {
            ProcessProvider::deserialize(value).map(Self::Process)
        }
        .map_err(serde::de::Error::custom)
    }
}

/// Which process a provider's requests go to.
pub(crate) enum ProviderProcess<'a> {
    /// The language server of this language ID.
    LanguageServer(&'a str),
    Own(&'a ServerProcess),
}

impl ProviderDeclaration {
    pub(crate) fn process(&self) -> ProviderProcess<'_> {
        match self {
            Self::LanguageServer(shared) => ProviderProcess::LanguageServer(&shared.language_id),
            Self::Process(own) => ProviderProcess::Own(&own.process),
        }
    }

    /// Shown to the user; whether a provider may run is decided by trust.
    pub(crate) fn executes_project_code(&self) -> bool {
        match self {
            Self::LanguageServer(shared) => shared.executes_project_code,
            Self::Process(own) => own.executes_project_code,
        }
    }

    pub(crate) fn may_use_network(&self) -> bool {
        match self {
            Self::LanguageServer(shared) => shared.may_use_network,
            Self::Process(own) => own.may_use_network,
        }
    }
}

/// How instances of the build system are recognized during the shared walk.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Detection {
    /// Exact file names; a directory containing any of them is a candidate.
    pub(crate) markers: Vec<String>,
    #[serde(default)]
    pub(crate) nesting: Nesting,
    /// Decides between plugins declaring the same build-system ID.
    #[serde(default = "default_priority")]
    pub(crate) priority: u8,
}

fn default_priority() -> u8 {
    DEFAULT_PRIORITY
}

/// What a marker below another instance's root means.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Nesting {
    /// Every candidate directory is its own instance (Cargo packages).
    #[default]
    Separate,
    /// Only candidates with no candidate above them are instances; deeper
    /// markers belong to them (Gradle builds, Maven reactors).
    Outermost,
}

/// Which executable runs the tool and what it needs.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Invocation {
    /// Candidates in preference order; the host takes the first that exists.
    pub(crate) executables: Vec<ExecutableCandidate>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) global_arguments: Vec<BuildArgument>,
    /// Environment variables the plugin may read. The host passes only these.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) environment_inputs: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) runtime_dependencies: Vec<RuntimeDependency>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) version: Option<VersionProbe>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) minimum_version: Option<String>,
}

/// One place an executable may come from.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub(crate) enum ExecutableCandidate {
    /// A file inside the instance root, such as a wrapper script. Running it
    /// always counts as running project code.
    ProjectFile {
        path: String,
        /// Further files that must exist for the candidate to apply.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        requires: Vec<String>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        platforms: Vec<Platform>,
    },
    /// A path below a directory named by a declared environment input.
    Environment {
        variable: String,
        path: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        platforms: Vec<Platform>,
    },
    /// A bare command resolved through the host's tool discovery.
    Command {
        command: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        platforms: Vec<Platform>,
    },
    /// The executable of a declared runtime dependency itself.
    Runtime {
        runtime: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        platforms: Vec<Platform>,
    },
}

impl ExecutableCandidate {
    pub(crate) fn platforms(&self) -> &[Platform] {
        match self {
            Self::ProjectFile { platforms, .. }
            | Self::Environment { platforms, .. }
            | Self::Command { platforms, .. }
            | Self::Runtime { platforms, .. } => platforms,
        }
    }

    fn platforms_mut(&mut self) -> &mut Vec<Platform> {
        match self {
            Self::ProjectFile { platforms, .. }
            | Self::Environment { platforms, .. }
            | Self::Command { platforms, .. }
            | Self::Runtime { platforms, .. } => platforms,
        }
    }
}

/// Host operating systems a candidate applies to; empty means all.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Platform {
    Macos,
    Linux,
    Windows,
}

/// A runtime the tool needs. Runtimes the host already manages (`java`,
/// `node`, `go`) take only an ID and an optional minimum version and follow
/// the user's runtime settings; any other runtime describes how to find and
/// probe it, so a community plugin is never limited to a host list.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RuntimeDependency {
    pub(crate) id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) display_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) minimum_version: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) executables: Vec<ExecutableCandidate>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) version: Option<VersionProbe>,
}

impl RuntimeDependency {
    /// True when the host discovers this runtime with its own settings.
    pub(crate) fn is_host_managed(&self) -> bool {
        KNOWN_RUNTIME_TOOLS_V2.contains(&self.id.as_str())
    }
}

/// How to ask an executable for its version: literal arguments, and a
/// pattern whose first capture group is the dotted version.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct VersionProbe {
    pub(crate) arguments: Vec<String>,
    pub(crate) pattern: String,
}

/// A build dimension the user chooses, stored per workspace by the host.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct OptionDeclaration {
    pub(crate) id: String,
    pub(crate) display_name: String,
    pub(crate) kind: OptionKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) default: Option<Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) choices: Vec<OptionChoice>,
    /// Choices also come from the model's `optionValues` for this option.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub(crate) choices_from_model: bool,
    /// Values outside the known choices are accepted.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub(crate) allow_custom: bool,
    /// Joins multi-select values in `${value}`; `,` by default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) separator: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) arguments: Vec<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub(crate) environment: BTreeMap<String, String>,
    /// Where the host offers the option; display only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) presentation: Option<OptionPresentation>,
    /// Icon of a `toolbar` toggle; display only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) icon: Option<UIIcon>,
}

/// Where a host offers an option besides its option list. Neither placement
/// changes how the option is resolved or emitted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum OptionPresentation {
    /// A toggle button in the tool window's toolbar; boolean options with an
    /// icon only (offline mode, skipping tests).
    Toolbar,
    /// A checklist node at the top of the tool window's tree; multiSelect
    /// options only (Maven profiles).
    Tree,
}

impl OptionDeclaration {
    pub(crate) fn separator(&self) -> &str {
        self.separator.as_deref().unwrap_or(DEFAULT_SEPARATOR)
    }

    pub(crate) fn is_select(&self) -> bool {
        matches!(
            self.kind,
            OptionKind::SingleSelect | OptionKind::MultiSelect
        )
    }

    /// Whether a single value is acceptable, given the model's values for a
    /// `choicesFromModel` option (`None` while no model is loaded, in which
    /// case model choices cannot be checked and are accepted).
    pub(crate) fn accepts_value(&self, value: &str, model_values: Option<&[String]>) -> bool {
        if !is_option_value(value) {
            return false;
        }
        if self.kind == OptionKind::MultiSelect && value.contains(self.separator()) {
            return false;
        }
        if !self.is_select() || self.allow_custom {
            return true;
        }
        if self.choices.iter().any(|choice| choice.value == value) {
            return true;
        }
        self.choices_from_model
            && model_values.is_none_or(|values| values.iter().any(|known| known == value))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum OptionKind {
    Boolean,
    SingleSelect,
    MultiSelect,
    Text,
    File,
    Directory,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct OptionChoice {
    pub(crate) value: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) title: Option<String>,
}

/// Where the project model comes from.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(
    tag = "source",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub(crate) enum ModelSource {
    /// A file in the instance root, read during detection without starting a
    /// process.
    Static {
        file: String,
        decoder: DocumentDecoder,
        map: ModelMap,
    },
    /// A command the host runs on request; its output is decoded by Core.
    Command {
        arguments: Vec<BuildArgument>,
        #[serde(default)]
        output: OutputChannel,
        decoder: ModelDecoder,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        map: Option<ModelMap>,
        executes_project_code: bool,
        may_use_network: bool,
    },
    /// The named host integration reads the model.
    HostIntegration,
    /// The provider answers `lithe/build/model` with a `litheBuildModel`.
    Provider,
}

/// Structured formats a static model file may use. A tool whose manifest
/// uses another format gets a plugin command that prints `litheBuildModel`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum DocumentDecoder {
    Toml,
}

/// Formats a model command may print.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum ModelDecoder {
    /// Whitespace-separated JSON values: NDJSON, concatenated objects such
    /// as `go list -json` prints, or a single document.
    JsonStream,
    /// The canonical model format; needs no map.
    LitheBuildModel,
}

/// Formats a dependency command may print.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum DependencyDecoder {
    /// Whitespace-separated JSON values: NDJSON, concatenated objects such
    /// as `go list -json` prints, or a single document.
    JsonStream,
    /// The canonical dependency format; needs no map.
    LitheDependencies,
}

/// Where a command leaves its result.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum OutputChannel {
    #[default]
    Stdout,
    /// A host-allocated file passed as `${outputFile}`.
    OutputFile,
}

/// Mapping of a decoded document onto the model: projects with their
/// targets and content roots, and option values. The map only selects
/// values; anything that needs more, such as tasks or parent links read from
/// the tool, comes from a plugin command that prints `litheBuildModel`.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ModelMap {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) projects: Vec<ProjectRule>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub(crate) option_values: BTreeMap<String, OptionValueRule>,
}

/// Fields every rule shares: which elements it reads and when it applies.
/// Written out in each rule because `deny_unknown_fields` and `flatten`
/// cannot be combined.
pub(crate) trait RuleMatch {
    fn each(&self) -> Option<&str>;
    fn filter(&self) -> &[Predicate];
    fn fallback(&self) -> bool;
    fn when_file(&self) -> Option<&str>;
}

macro_rules! rule_match {
    ($rule:ty) => {
        impl RuleMatch for $rule {
            fn each(&self) -> Option<&str> {
                self.each.as_deref()
            }
            fn filter(&self) -> &[Predicate] {
                &self.filter
            }
            fn fallback(&self) -> bool {
                self.fallback
            }
            fn when_file(&self) -> Option<&str> {
                self.when_file.as_deref()
            }
        }
    };
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ProjectRule {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) each: Option<String>,
    #[serde(default, rename = "where", skip_serializing_if = "Vec::is_empty")]
    pub(crate) filter: Vec<Predicate>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub(crate) fallback: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) when_file: Option<String>,
    pub(crate) name: FieldSpec,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) display_name: Option<FieldSpec>,
    /// Project directory; the instance root when absent. The parent is the
    /// deepest project containing it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) path: Option<FieldSpec>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub(crate) properties: BTreeMap<String, FieldSpec>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) targets: Vec<TargetRule>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) content_roots: Vec<ContentRootRule>,
}
rule_match!(ProjectRule);

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct TargetRule {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) each: Option<String>,
    #[serde(default, rename = "where", skip_serializing_if = "Vec::is_empty")]
    pub(crate) filter: Vec<Predicate>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub(crate) fallback: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) when_file: Option<String>,
    pub(crate) name: FieldSpec,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) path: Option<FieldSpec>,
    pub(crate) tags: Vec<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub(crate) properties: BTreeMap<String, FieldSpec>,
}
rule_match!(TargetRule);

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ContentRootRule {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) each: Option<String>,
    #[serde(default, rename = "where", skip_serializing_if = "Vec::is_empty")]
    pub(crate) filter: Vec<Predicate>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub(crate) fallback: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) when_file: Option<String>,
    /// Directory relative to the project, or absolute inside the workspace.
    pub(crate) path: FieldSpec,
    pub(crate) kind: ContentRootKind,
}
rule_match!(ContentRootRule);

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct OptionValueRule {
    pub(crate) each: String,
    #[serde(default, rename = "where", skip_serializing_if = "Vec::is_empty")]
    pub(crate) filter: Vec<Predicate>,
    pub(crate) value: FieldSpec,
}

/// Role of a source directory in a project.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum ContentRootKind {
    Source,
    Resource,
    TestSource,
    TestResource,
    GeneratedSource,
    GeneratedTestSource,
    Excluded,
}

/// How a task's process behaves; the same values as run configurations.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum BuildExecution {
    Application,
    Service,
    Task,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum TaskGroup {
    Lifecycle,
    Build,
    Test,
    Run,
    Verification,
    Documentation,
    Other,
}

/// What a task, test, or dependency command acts on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Scope {
    Workspace,
    Project,
    Target,
}

/// A task in the build system's catalog. `fromModel` tasks are templates
/// for the tasks the model lists.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct TaskDeclaration {
    pub(crate) id: String,
    pub(crate) display_name: String,
    pub(crate) group: TaskGroup,
    #[serde(default = "task_execution")]
    pub(crate) execution: BuildExecution,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) scopes: Vec<Scope>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub(crate) from_model: bool,
    /// For target-scoped tasks: tags of the targets it applies to.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) target_tags: Vec<String>,
    /// The host must ask for arguments before running it.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub(crate) requires_user_arguments: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) description: Option<String>,
    /// Headings the host files the task under in its project, outermost
    /// first (`["Lifecycle"]`); also the default of the model tasks this
    /// template runs. Display only; empty files the task by `group`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) category: Vec<String>,
    pub(crate) arguments: Vec<BuildArgument>,
}

fn task_execution() -> BuildExecution {
    BuildExecution::Task
}

/// Run entries derived from model targets or tasks.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RunDeclaration {
    pub(crate) id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) from_targets: Option<FromTargets>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) from_tasks: Option<FromTasks>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) execution: Option<BuildExecution>,
    /// Entry name; the target or task name when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) name: Option<String>,
    /// Argument templates for target entries; task entries reuse the task's.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) arguments: Vec<BuildArgument>,
    #[serde(default)]
    pub(crate) working_directory: WorkingDirectory,
    /// Metadata stored under `extensions.<buildSystemID>` of the entry.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub(crate) extension: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct FromTargets {
    pub(crate) tags: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct FromTasks {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) templates: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) executions: Vec<BuildExecution>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum WorkingDirectory {
    #[default]
    Project,
    Root,
}

/// How tests run and how their results are read.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct TestDeclaration {
    pub(crate) scopes: Vec<Scope>,
    /// Tags a selected target must carry, as for tasks.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) target_tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) filters: Vec<TestFilter>,
    pub(crate) arguments: Vec<BuildArgument>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) results: Option<TestResultsSource>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum TestFilter {
    Suite,
    Case,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(
    tag = "decoder",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub(crate) enum TestResultsSource {
    /// JUnit XML report files, globbed relative to the project directory.
    JunitXml {
        reports: Vec<String>,
    },
    /// Canonical result files, globbed relative to the project directory.
    LitheTestResults {
        reports: Vec<String>,
    },
    HostIntegration,
}

/// How build output becomes file diagnostics.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(
    tag = "decoder",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub(crate) enum DiagnosticsDeclaration {
    LineMatcher {
        patterns: Vec<LinePattern>,
    },
    /// Output lines holding canonical diagnostic objects.
    LitheDiagnostics,
}

/// A regular expression and which capture group holds each field.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct LinePattern {
    pub(crate) regex: String,
    pub(crate) file: usize,
    pub(crate) line: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) column: Option<usize>,
    pub(crate) message: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) severity: Option<usize>,
    /// Raw severity text to severity; without it the text is lowercased.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub(crate) severities: BTreeMap<String, Severity>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) default_severity: Option<Severity>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Severity {
    Error,
    Warning,
    Information,
    Hint,
}

impl Severity {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Error => "error",
            Self::Warning => "warning",
            Self::Information => "information",
            Self::Hint => "hint",
        }
    }
}

/// Where dependency trees come from.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(
    tag = "source",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
#[allow(clippy::large_enum_variant)] // Decoded once per manifest validation.
pub(crate) enum DependenciesSource {
    Command {
        scopes: Vec<Scope>,
        arguments: Vec<BuildArgument>,
        #[serde(default)]
        output: OutputChannel,
        decoder: DependencyDecoder,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        map: Option<DependencyRule>,
        executes_project_code: bool,
        may_use_network: bool,
    },
    HostIntegration,
    /// The provider answers `lithe/build/dependencies` with
    /// `litheDependencies`.
    Provider {
        scopes: Vec<Scope>,
    },
}

/// Mapping of one dependency element onto a flat list. Dependency trees
/// come from `litheDependencies`.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DependencyRule {
    pub(crate) each: String,
    #[serde(default, rename = "where", skip_serializing_if = "Vec::is_empty")]
    pub(crate) filter: Vec<Predicate>,
    pub(crate) name: FieldSpec,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) group: Option<FieldSpec>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) version: Option<FieldSpec>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) scope: Option<FieldSpec>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub(crate) properties: BTreeMap<String, FieldSpec>,
}

/// Files whose change makes the model stale, relative to the instance root
/// and to each project directory.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct SyncDeclaration {
    pub(crate) watch: Vec<String>,
}

/// Output directories excluded from every project, relative to each
/// project directory.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct LayoutDeclaration {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) excluded: Vec<String>,
}

/// The project import a language server performs for this build system, and
/// which of the plugin's options carry the import settings.
///
/// The Java language server imports Maven and Gradle projects itself. Its
/// import has to use the profiles, settings, and caches the user chose for
/// the build tool, or the editor resolves other dependencies than the build.
/// A plugin names the import it matches and maps each import setting to one
/// of its own options; Core turns the user's values into the language
/// server's settings, so the host passes them on without knowing the plugin.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct LanguageImportDeclaration {
    pub(crate) kind: LanguageImportKind,
    /// Import setting -> option ID. Settings without an option keep the
    /// language server's default.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub(crate) options: BTreeMap<String, String>,
}

/// Project imports Lithe's Java language server knows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum LanguageImportKind {
    Maven,
    Gradle,
}

impl LanguageImportKind {
    /// The import settings of this kind and the option kind each needs.
    pub(crate) fn settings(self) -> &'static [(&'static str, OptionKind)] {
        match self {
            Self::Maven => &[
                ("profiles", OptionKind::MultiSelect),
                ("settingsFile", OptionKind::File),
                ("localRepository", OptionKind::Directory),
            ],
            Self::Gradle => &[
                ("offline", OptionKind::Boolean),
                ("gradleUserHome", OptionKind::Directory),
            ],
        }
    }
}

impl BuildSystemDeclaration {
    pub(crate) fn option(&self, id: &str) -> Option<&OptionDeclaration> {
        self.options.iter().find(|option| option.id == id)
    }

    pub(crate) fn task(&self, id: &str) -> Option<&TaskDeclaration> {
        self.tasks.iter().find(|task| task.id == id)
    }

    /// True when the named host integration owns this build system.
    pub(crate) fn integration(&self) -> Option<&str> {
        self.host_integration.as_deref()
    }
}

// MARK: Validation

/// Validates and normalizes every build system of a manifest.
/// Normalizes the tags a selected target must carry; they only make sense
/// when the command can run on a target.
fn check_target_tags(tags: &mut Vec<String>, scopes: &[Scope], field: &str) -> Validation<()> {
    if !tags.is_empty() && !scopes.contains(&Scope::Target) {
        return Err(invalid(
            format!("{field}.targetTags"),
            "targetTags need the target scope.",
        ));
    }
    if tags.iter().any(|tag| !is_tag(tag)) {
        return Err(invalid(
            format!("{field}.targetTags"),
            "Tags are identifiers.",
        ));
    }
    *tags = sorted_unique(std::mem::take(tags));
    Ok(())
}

/// Facts of the rest of the manifest a build-system declaration is checked
/// against.
pub(crate) struct DeclarationContext<'a> {
    pub(crate) plugin_api_version: u32,
    pub(crate) official: bool,
    /// Setting IDs a provider's launch templates may name.
    pub(crate) declared_settings: &'a BTreeSet<String>,
    /// Language IDs the plugin declares a language server for.
    pub(crate) language_servers: &'a BTreeSet<String>,
}

pub(crate) fn validate_declarations(
    build_systems: &mut [BuildSystemDeclaration],
    context: &DeclarationContext<'_>,
) -> Validation<()> {
    if build_systems.is_empty() {
        return Ok(());
    }
    if context.plugin_api_version < BUILD_SYSTEMS_API_VERSION {
        return Err(invalid(
            "buildSystems",
            "Build systems require pluginAPIVersion 3.",
        ));
    }
    if build_systems.len() > MAX_BUILD_SYSTEMS {
        return Err(invalid(
            "buildSystems",
            "The plugin declares too many build systems.",
        ));
    }
    let mut ids = BTreeSet::new();
    for (index, build_system) in build_systems.iter_mut().enumerate() {
        let field = format!("buildSystems[{index}]");
        build_system.validate(&field, context)?;
        if !ids.insert(build_system.id.clone()) {
            return Err(invalid(
                format!("{field}.id"),
                "A build system is declared more than once.",
            ));
        }
    }
    build_systems.sort_by(|left, right| left.id.cmp(&right.id));
    Ok(())
}

/// Activation event the host raises before using a build system.
pub(crate) fn activation_event(build_system: &BuildSystemDeclaration) -> String {
    format!("onBuildSystem:{}", build_system.id)
}

/// Install-review entries: everything that decides which process runs with
/// which arguments. Display text, detection, and output decoding are left
/// out; changing them does not run anything new. A provider process of its
/// own is reviewed like a language server, with the runtimes it needs.
pub(crate) fn programs(build_system: &BuildSystemDeclaration) -> Vec<Value> {
    let mut programs = vec![program(build_system)];
    if let Some(ProviderDeclaration::Process(own)) = &build_system.provider {
        let mut provider = own.process.program(ServerRole::BuildProvider);
        provider["buildSystemID"] = json!(build_system.id);
        provider["executesProjectCode"] = json!(own.executes_project_code);
        provider["mayUseNetwork"] = json!(own.may_use_network);
        programs.push(provider);
        programs.extend(own.process.runtime_programs());
    }
    programs
}

fn program(build_system: &BuildSystemDeclaration) -> Value {
    let options: Vec<Value> = build_system
        .options
        .iter()
        .map(|option| {
            json!({
                "id": option.id,
                "kind": option.kind,
                "default": option.default,
                "choices": option.choices.iter().map(|choice| &choice.value).collect::<Vec<_>>(),
                "choicesFromModel": option.choices_from_model,
                "allowCustom": option.allow_custom,
                "separator": option.separator(),
                "arguments": option.arguments,
                "environment": option.environment,
            })
        })
        .collect();
    let tasks: Vec<Value> = build_system
        .tasks
        .iter()
        .map(|task| json!({ "id": task.id, "arguments": task.arguments }))
        .collect();
    let model = match &build_system.model {
        Some(ModelSource::Command { arguments, .. }) => json!({ "arguments": arguments }),
        _ => Value::Null,
    };
    let dependencies = match &build_system.dependencies {
        Some(DependenciesSource::Command { arguments, .. }) => json!({ "arguments": arguments }),
        _ => Value::Null,
    };
    let mut program = json!({
        "kind": "buildSystem",
        "buildSystemID": build_system.id,
        "invocation": build_system.invocation,
        "options": options,
        "tasks": tasks,
        "run": build_system.run,
        "test": build_system.test.as_ref().map(|test| json!({ "arguments": test.arguments })),
        "model": model,
        "dependencies": dependencies,
    });
    if let Some(integration) = &build_system.host_integration {
        program["hostIntegration"] = json!(integration);
    }
    // Build requests reaching a language server change what that process
    // is asked to do, so the shared form is part of this entry.
    if let Some(ProviderDeclaration::LanguageServer(shared)) = &build_system.provider {
        program["provider"] = json!(shared);
    }
    program
}

/// A build-system or run ID: also a run-configuration provider segment, so
/// it starts with a letter.
fn is_entry_identifier(value: &str) -> bool {
    is_identifier(value)
        && value.len() <= MAX_IDENTIFIER
        && value
            .chars()
            .next()
            .is_some_and(|first| first.is_ascii_lowercase())
}

fn is_tag(value: &str) -> bool {
    is_identifier(value) && value.len() <= MAX_IDENTIFIER
}

pub(crate) fn is_environment_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_IDENTIFIER
        && value
            .chars()
            .next()
            .is_some_and(|first| first.is_ascii_uppercase() || first == '_')
        && value.chars().all(|character| {
            character.is_ascii_uppercase() || character.is_ascii_digit() || character == '_'
        })
}

/// A file name with no directory part.
fn is_file_name(value: &str) -> bool {
    is_safe_relative_path(value) && !value.contains('/') && value != "."
}

/// An option value: no control characters, bounded.
pub(crate) fn is_option_value(value: &str) -> bool {
    !value.is_empty() && value.len() <= MAX_OPTION_VALUE && !value.chars().any(char::is_control)
}

fn check_text(value: &str, field: &str, what: &str) -> Validation<()> {
    if value.trim().is_empty() || value.len() > MAX_TEXT || value.chars().any(char::is_control) {
        return Err(invalid(
            field,
            format!("The {what} must be 1-{MAX_TEXT} printable characters."),
        ));
    }
    Ok(())
}

/// Trimmed headings of a task category, or `None` when the path is too deep
/// or a heading is empty, too long, or not printable.
pub(crate) fn category_labels(labels: &[String]) -> Option<Vec<String>> {
    if labels.len() > MAX_CATEGORY_DEPTH {
        return None;
    }
    labels
        .iter()
        .map(|label| {
            let label = label.trim();
            (!label.is_empty() && label.len() <= MAX_TEXT && !label.chars().any(char::is_control))
                .then(|| label.to_string())
        })
        .collect()
}

fn check_paths(values: &mut Vec<String>, field: &str, glob: bool) -> Validation<()> {
    if values.len() > MAX_LIST {
        return Err(invalid(field, "The list is too long."));
    }
    for (index, value) in values.iter().enumerate() {
        let safe = is_safe_relative_path(value)
            && (glob || !value.contains('*'))
            && !value
                .split('/')
                .any(|segment| segment.is_empty() || segment == ".");
        if !safe {
            return Err(PluginRejection::at(
                "plugin.path.invalid",
                format!("{field}[{index}]"),
                "Paths must be relative, use /, and stay inside the project.",
            ));
        }
    }
    *values = sorted_unique(std::mem::take(values));
    Ok(())
}

fn check_regex(value: &str, field: &str, groups: usize) -> Validation<Regex> {
    let compiled = (value.len() <= MAX_REGEX)
        .then(|| Regex::new(value).ok())
        .flatten()
        .ok_or_else(|| invalid(field, "The regular expression is invalid or too long."))?;
    if compiled.captures_len() <= groups {
        return Err(invalid(
            field,
            format!("The regular expression needs at least {groups} capture group(s)."),
        ));
    }
    Ok(compiled)
}

fn check_argument_count(arguments: &[BuildArgument], field: &str) -> Validation<()> {
    if arguments.len() > MAX_ARGUMENTS {
        return Err(invalid(field, "The argument list is too long."));
    }
    Ok(())
}

fn availability(scopes: &[Scope], scope: Scope) -> Availability {
    let workspace = scopes.contains(&Scope::Workspace);
    match scope {
        Scope::Project if scopes.iter().all(|value| *value == Scope::Workspace) => {
            Availability::Never
        }
        Scope::Project if workspace => Availability::Maybe,
        Scope::Project => Availability::Always,
        Scope::Target if !scopes.contains(&Scope::Target) => Availability::Never,
        Scope::Target if scopes.len() == 1 => Availability::Always,
        Scope::Target => Availability::Maybe,
        Scope::Workspace => Availability::Always,
    }
}

fn check_scopes(scopes: &mut Vec<Scope>, field: &str, allowed: &[Scope]) -> Validation<()> {
    *scopes = std::mem::take(scopes)
        .into_iter()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    if scopes.is_empty() || scopes.iter().any(|scope| !allowed.contains(scope)) {
        return Err(invalid(
            field,
            format!("Scopes must be a non-empty subset of {allowed:?}."),
        ));
    }
    Ok(())
}

impl BuildSystemDeclaration {
    /// Whether the build system starts a provider process of its own.
    pub(crate) fn starts_own_provider(&self) -> bool {
        matches!(self.provider, Some(ProviderDeclaration::Process(_)))
    }

    fn validate(&mut self, field: &str, context: &DeclarationContext<'_>) -> Validation<()> {
        if !is_entry_identifier(&self.id) {
            return Err(invalid(
                format!("{field}.id"),
                "A build-system ID starts with a letter and uses lowercase letters, digits, and hyphens.",
            ));
        }
        check_text(
            &self.display_name,
            &format!("{field}.displayName"),
            "display name",
        )?;
        if let Some(icon) = &self.icon {
            icon.validate_at(&format!("{field}.icon"))?;
        }
        self.validate_integration(field, context.official)?;
        self.validate_provider(field, context)?;
        self.validate_detection(field)?;
        let option_ids = self.validate_options(field)?;
        self.validate_invocation(field, &option_ids)?;
        let model_templates = self.validate_tasks(field, &option_ids)?;
        self.validate_model(field, &option_ids)?;
        self.validate_run(field, &option_ids, &model_templates)?;
        self.validate_test(field, &option_ids)?;
        self.validate_diagnostics(field)?;
        self.validate_dependencies(field, &option_ids)?;
        if let Some(sync) = &mut self.sync {
            check_paths(&mut sync.watch, &format!("{field}.sync.watch"), false)?;
        }
        if let Some(layout) = &mut self.layout {
            check_paths(
                &mut layout.excluded,
                &format!("{field}.layout.excluded"),
                false,
            )?;
        }
        self.validate_language_import(field)?;
        self.validate_option_emission(field)
    }

    fn validate_language_import(&self, field: &str) -> Validation<()> {
        let Some(import) = &self.language_import else {
            return Ok(());
        };
        let settings = import.kind.settings();
        for (setting, option_id) in &import.options {
            let field = format!("{field}.languageImport.options.{setting}");
            let Some((_, kind)) = settings.iter().find(|(name, _)| name == setting) else {
                let known: Vec<&str> = settings.iter().map(|(name, _)| *name).collect();
                return Err(invalid(
                    field,
                    format!("This import has the settings {}.", known.join(", ")),
                ));
            };
            match self.option(option_id) {
                Some(option) if option.kind == *kind => {}
                Some(_) => {
                    return Err(invalid(
                        field,
                        format!("The option {option_id} has the wrong kind for this setting."),
                    ))
                }
                None => {
                    return Err(invalid(
                        field,
                        format!("The build system declares no option {option_id}."),
                    ))
                }
            }
        }
        Ok(())
    }

    fn validate_integration(&self, field: &str, official: bool) -> Validation<()> {
        let Some(integration) = &self.host_integration else {
            let named = matches!(self.model, Some(ModelSource::HostIntegration))
                || matches!(self.dependencies, Some(DependenciesSource::HostIntegration))
                || matches!(
                    self.test.as_ref().and_then(|test| test.results.as_ref()),
                    Some(TestResultsSource::HostIntegration)
                );
            if named {
                return Err(invalid(
                    format!("{field}.hostIntegration"),
                    "A host-integration source requires hostIntegration.",
                ));
            }
            return Ok(());
        };
        let field = format!("{field}.hostIntegration");
        if !HOST_INTEGRATIONS.contains(&integration.as_str()) {
            return Err(PluginRejection::at(
                "plugin.integration.unsupported",
                field,
                format!("The host has no build integration named {integration}."),
            ));
        }
        // An integration runs trusted host code against the plugin's files,
        // so a community package must not be able to request one.
        if !official {
            return Err(PluginRejection::at(
                "plugin.integration.unsupported",
                field,
                "Host integrations are reserved to official plugins.",
            ));
        }
        Ok(())
    }

    fn validate_provider(&self, field: &str, context: &DeclarationContext<'_>) -> Validation<()> {
        let uses = matches!(self.model, Some(ModelSource::Provider))
            || matches!(self.dependencies, Some(DependenciesSource::Provider { .. }));
        let field = format!("{field}.provider");
        let Some(provider) = &self.provider else {
            if uses {
                return Err(invalid(field, "A provider source requires provider."));
            }
            return Ok(());
        };
        if !uses {
            return Err(invalid(
                field,
                "No model or dependencies source uses the provider.",
            ));
        }
        match provider {
            ProviderDeclaration::LanguageServer(shared) => {
                if !context.language_servers.contains(&shared.language_id) {
                    return Err(invalid(
                        format!("{field}.languageServer"),
                        "The provider names a language the plugin declares no language server for.",
                    ));
                }
                Ok(())
            }
            ProviderDeclaration::Process(own) => own.process.validate(
                &field,
                context.plugin_api_version,
                context.declared_settings,
                ServerRole::BuildProvider,
            ),
        }
    }

    fn validate_detection(&mut self, field: &str) -> Validation<()> {
        let detection = &mut self.detection;
        let markers = format!("{field}.detection.markers");
        if detection.markers.is_empty() || detection.markers.len() > MAX_LIST {
            return Err(invalid(markers, "Detection needs 1-32 marker file names."));
        }
        if let Some(index) = detection
            .markers
            .iter()
            .position(|marker| !is_file_name(marker))
        {
            return Err(invalid(
                format!("{markers}[{index}]"),
                "A marker is a file name without a directory.",
            ));
        }
        detection.markers = sorted_unique(std::mem::take(&mut detection.markers));
        if detection.priority > MAX_PRIORITY {
            return Err(invalid(
                format!("{field}.detection.priority"),
                "The priority must be 0-100.",
            ));
        }
        Ok(())
    }

    fn validate_options(&mut self, field: &str) -> Validation<BTreeSet<String>> {
        if self.options.len() > MAX_LIST {
            return Err(invalid(format!("{field}.options"), "Too many options."));
        }
        let mut ids = BTreeSet::new();
        for (index, option) in self.options.iter_mut().enumerate() {
            let field = format!("{field}.options[{index}]");
            option.validate(&field)?;
            if !ids.insert(option.id.clone()) {
                return Err(invalid(
                    format!("{field}.id"),
                    "An option is declared more than once.",
                ));
            }
        }
        Ok(ids)
    }

    fn validate_invocation(&mut self, field: &str, options: &BTreeSet<String>) -> Validation<()> {
        let invocation = &mut self.invocation;
        let field = format!("{field}.invocation");
        if invocation.environment_inputs.len() > MAX_LIST {
            return Err(invalid(
                format!("{field}.environmentInputs"),
                "Too many environment inputs.",
            ));
        }
        if let Some(index) = invocation
            .environment_inputs
            .iter()
            .position(|name| !is_environment_name(name))
        {
            return Err(invalid(
                format!("{field}.environmentInputs[{index}]"),
                "Environment variable names use uppercase letters, digits, and _.",
            ));
        }
        invocation.environment_inputs =
            sorted_unique(std::mem::take(&mut invocation.environment_inputs));

        let mut runtimes = BTreeSet::new();
        for (index, runtime) in invocation.runtime_dependencies.iter_mut().enumerate() {
            let field = format!("{field}.runtimeDependencies[{index}]");
            if !is_entry_identifier(&runtime.id) || !runtimes.insert(runtime.id.clone()) {
                return Err(invalid(
                    format!("{field}.id"),
                    "Runtime IDs are unique identifiers.",
                ));
            }
            if let Some(name) = &runtime.display_name {
                check_text(name, &format!("{field}.displayName"), "display name")?;
            }
            if let Some(minimum) = &runtime.minimum_version {
                validate_minimum_version(minimum, &format!("{field}.minimumVersion"))?;
            }
            if runtime.is_host_managed() {
                // The host finds these with the user's own runtime settings
                // (the JDK chosen for the project, for example); a plugin
                // must not route around that choice.
                if !runtime.executables.is_empty() || runtime.version.is_some() {
                    return Err(invalid(
                        field,
                        format!(
                            "{} is discovered by the host; declare only its minimumVersion.",
                            runtime.id
                        ),
                    ));
                }
                continue;
            }
            if runtime.executables.is_empty() || runtime.executables.len() > MAX_LIST {
                return Err(invalid(
                    format!("{field}.executables"),
                    "A plugin-described runtime needs 1-32 executable candidates.",
                ));
            }
            for (candidate_index, candidate) in runtime.executables.iter_mut().enumerate() {
                let candidate_field = format!("{field}.executables[{candidate_index}]");
                if matches!(candidate, ExecutableCandidate::Runtime { .. }) {
                    return Err(invalid(
                        candidate_field,
                        "A runtime cannot be provided by another runtime.",
                    ));
                }
                check_candidate(
                    candidate,
                    &candidate_field,
                    &invocation.environment_inputs,
                    &BTreeSet::new(),
                )?;
            }
            match &runtime.version {
                Some(probe) => probe.validate(&format!("{field}.version"))?,
                None if runtime.minimum_version.is_some() => {
                    return Err(invalid(
                        format!("{field}.version"),
                        "A minimumVersion needs a version probe.",
                    ))
                }
                None => {}
            }
        }

        if invocation.executables.is_empty() || invocation.executables.len() > MAX_LIST {
            return Err(invalid(
                format!("{field}.executables"),
                "The invocation needs 1-32 executable candidates.",
            ));
        }
        for (index, candidate) in invocation.executables.iter_mut().enumerate() {
            check_candidate(
                candidate,
                &format!("{field}.executables[{index}]"),
                &invocation.environment_inputs,
                &runtimes,
            )?;
        }
        if let Some(probe) = &invocation.version {
            probe.validate(&format!("{field}.version"))?;
        }
        if let Some(minimum) = &invocation.minimum_version {
            if invocation.version.is_none() {
                return Err(invalid(
                    format!("{field}.minimumVersion"),
                    "A minimumVersion needs a version probe.",
                ));
            }
            validate_minimum_version(minimum, &format!("{field}.minimumVersion"))?;
        }
        check_argument_count(
            &invocation.global_arguments,
            &format!("{field}.globalArguments"),
        )?;
        template::validate_arguments(
            &invocation.global_arguments,
            &Allowed {
                root: true,
                options: Some(options),
                ..Allowed::none()
            },
            &format!("{field}.globalArguments"),
        )
    }

    /// Validates the catalog and returns the IDs of `fromModel` templates.
    fn validate_tasks(
        &mut self,
        field: &str,
        options: &BTreeSet<String>,
    ) -> Validation<BTreeSet<String>> {
        if self.tasks.len() > MAX_TASKS {
            return Err(invalid(format!("{field}.tasks"), "Too many tasks."));
        }
        let mut ids = BTreeSet::new();
        let mut templates = BTreeSet::new();
        for (index, task) in self.tasks.iter_mut().enumerate() {
            let field = format!("{field}.tasks[{index}]");
            if !is_entry_identifier(&task.id) || !ids.insert(task.id.clone()) {
                return Err(invalid(
                    format!("{field}.id"),
                    "Task IDs are unique identifiers that start with a letter.",
                ));
            }
            check_text(
                &task.display_name,
                &format!("{field}.displayName"),
                "display name",
            )?;
            if let Some(description) = &task.description {
                if description.len() > 1024 {
                    return Err(invalid(
                        format!("{field}.description"),
                        "The description is too long.",
                    ));
                }
            }
            if !task.category.is_empty() && category_labels(&task.category).is_none() {
                return Err(invalid(
                    format!("{field}.category"),
                    format!(
                        "A category is 1-{MAX_CATEGORY_DEPTH} headings of 1-{MAX_TEXT} printable characters."
                    ),
                ));
            }
            let allowed = if task.from_model {
                if !task.scopes.is_empty() || !task.target_tags.is_empty() {
                    return Err(invalid(
                        field,
                        "A fromModel task acts on its model task; it has no scopes or targetTags.",
                    ));
                }
                templates.insert(task.id.clone());
                Allowed {
                    root: true,
                    project: Availability::Always,
                    task: true,
                    user_arguments: true,
                    conditions: true,
                    options: Some(options),
                    ..Allowed::none()
                }
            } else {
                check_scopes(
                    &mut task.scopes,
                    &format!("{field}.scopes"),
                    &[Scope::Workspace, Scope::Project, Scope::Target],
                )?;
                check_target_tags(&mut task.target_tags, &task.scopes, &field)?;
                Allowed {
                    root: true,
                    project: availability(&task.scopes, Scope::Project),
                    target: availability(&task.scopes, Scope::Target),
                    user_arguments: true,
                    conditions: true,
                    options: Some(options),
                    ..Allowed::none()
                }
            };
            check_argument_count(&task.arguments, &format!("{field}.arguments"))?;
            template::validate_arguments(&task.arguments, &allowed, &format!("{field}.arguments"))?;
            if task.requires_user_arguments
                && !template::uses(&task.arguments, &Variable::UserArguments)
            {
                return Err(invalid(
                    format!("{field}.requiresUserArguments"),
                    "A task that asks for arguments must pass ${userArguments}.",
                ));
            }
        }
        if !templates.is_empty() && self.model.is_none() {
            return Err(invalid(
                format!("{field}.model"),
                "fromModel tasks need a model.",
            ));
        }
        Ok(templates)
    }

    fn validate_model(&self, field: &str, options: &BTreeSet<String>) -> Validation<()> {
        let field = format!("{field}.model");
        let model_options: BTreeSet<String> = self
            .options
            .iter()
            .filter(|option| option.choices_from_model)
            .map(|option| option.id.clone())
            .collect();
        match &self.model {
            None => {
                if !model_options.is_empty() {
                    return Err(invalid(field, "choicesFromModel needs a model."));
                }
                Ok(())
            }
            Some(ModelSource::Static { file, map, .. }) => {
                if !is_safe_relative_path(file) {
                    return Err(PluginRejection::at(
                        "plugin.path.invalid",
                        format!("{field}.file"),
                        "The model file must be relative to the build-system root.",
                    ));
                }
                map.validate(&format!("{field}.map"), &model_options)
            }
            Some(ModelSource::Command {
                arguments,
                output,
                decoder,
                map,
                ..
            }) => {
                check_argument_count(arguments, &format!("{field}.arguments"))?;
                template::validate_arguments(
                    arguments,
                    &Allowed {
                        root: true,
                        host_directories: true,
                        options: Some(options),
                        ..Allowed::none()
                    },
                    &format!("{field}.arguments"),
                )?;
                check_output_channel(*output, arguments, &field)?;
                match (decoder, map) {
                    (ModelDecoder::LitheBuildModel, None) => Ok(()),
                    (ModelDecoder::LitheBuildModel, Some(_)) => Err(invalid(
                        format!("{field}.map"),
                        "The litheBuildModel format needs no map.",
                    )),
                    (_, None) => Err(invalid(
                        format!("{field}.map"),
                        "A model command with a generic format needs a map.",
                    )),
                    (_, Some(map)) => map.validate(&format!("{field}.map"), &model_options),
                }
            }
            Some(ModelSource::HostIntegration | ModelSource::Provider) => Ok(()),
        }
    }

    fn validate_run(
        &mut self,
        field: &str,
        options: &BTreeSet<String>,
        templates: &BTreeSet<String>,
    ) -> Validation<()> {
        if self.run.is_empty() {
            return Ok(());
        }
        if self.model.is_none() {
            return Err(invalid(
                format!("{field}.run"),
                "Run entries come from the model; declare a model.",
            ));
        }
        if self.run.len() > MAX_LIST {
            return Err(invalid(
                format!("{field}.run"),
                "Too many run declarations.",
            ));
        }
        let mut ids = BTreeSet::new();
        for (index, run) in self.run.iter_mut().enumerate() {
            let field = format!("{field}.run[{index}]");
            if !is_entry_identifier(&run.id) || !ids.insert(run.id.clone()) {
                return Err(invalid(
                    format!("{field}.id"),
                    "Run IDs are unique identifiers that start with a letter.",
                ));
            }
            let from_tasks = match (&mut run.from_targets, &mut run.from_tasks) {
                (Some(targets), None) => {
                    if targets.tags.is_empty() || targets.tags.iter().any(|tag| !is_tag(tag)) {
                        return Err(invalid(
                            format!("{field}.fromTargets.tags"),
                            "fromTargets needs one or more tag identifiers.",
                        ));
                    }
                    targets.tags = sorted_unique(std::mem::take(&mut targets.tags));
                    if run.arguments.is_empty() {
                        return Err(invalid(
                            format!("{field}.arguments"),
                            "Target run entries need arguments.",
                        ));
                    }
                    false
                }
                (None, Some(tasks)) => {
                    if tasks.templates.is_empty() && tasks.executions.is_empty() {
                        return Err(invalid(
                            format!("{field}.fromTasks"),
                            "fromTasks needs templates, executions, or both.",
                        ));
                    }
                    if let Some(unknown) =
                        tasks.templates.iter().find(|id| !templates.contains(*id))
                    {
                        return Err(invalid(
                            format!("{field}.fromTasks.templates"),
                            format!("{unknown} is not a fromModel task."),
                        ));
                    }
                    tasks.templates = sorted_unique(std::mem::take(&mut tasks.templates));
                    tasks.executions.sort();
                    tasks.executions.dedup();
                    if !run.arguments.is_empty() {
                        return Err(invalid(
                            format!("{field}.arguments"),
                            "Task run entries reuse the task's arguments.",
                        ));
                    }
                    true
                }
                _ => {
                    return Err(invalid(
                        field,
                        "A run declaration needs exactly one of fromTargets and fromTasks.",
                    ))
                }
            };
            let allowed = Allowed {
                root: true,
                project: Availability::Always,
                target: if from_tasks {
                    Availability::Never
                } else {
                    Availability::Always
                },
                task: from_tasks,
                user_arguments: true,
                options: Some(options),
                ..Allowed::none()
            };
            check_argument_count(&run.arguments, &format!("{field}.arguments"))?;
            template::validate_arguments(&run.arguments, &allowed, &format!("{field}.arguments"))?;
            let names = Allowed {
                user_arguments: false,
                options: None,
                ..allowed.clone()
            };
            if let Some(name) = &run.name {
                template::validate_text(name, &names, &format!("{field}.name"))?;
            }
            if run.extension.len() > MAX_LIST {
                return Err(invalid(
                    format!("{field}.extension"),
                    "Too many extension values.",
                ));
            }
            for (key, value) in &run.extension {
                if !template::is_property_key(key) {
                    return Err(invalid(
                        format!("{field}.extension"),
                        "Extension keys use letters, digits, ., _, and -.",
                    ));
                }
                template::validate_text(value, &names, &format!("{field}.extension.{key}"))?;
            }
        }
        Ok(())
    }

    fn validate_test(&mut self, field: &str, options: &BTreeSet<String>) -> Validation<()> {
        let Some(test) = &mut self.test else {
            return Ok(());
        };
        let field = format!("{field}.test");
        check_scopes(
            &mut test.scopes,
            &format!("{field}.scopes"),
            &[Scope::Workspace, Scope::Project, Scope::Target],
        )?;
        check_target_tags(&mut test.target_tags, &test.scopes, &field)?;
        test.filters.sort();
        test.filters.dedup();
        check_argument_count(&test.arguments, &format!("{field}.arguments"))?;
        template::validate_arguments(
            &test.arguments,
            &Allowed {
                root: true,
                project: availability(&test.scopes, Scope::Project),
                target: availability(&test.scopes, Scope::Target),
                test: true,
                user_arguments: true,
                conditions: true,
                options: Some(options),
                ..Allowed::none()
            },
            &format!("{field}.arguments"),
        )?;
        match &mut test.results {
            Some(TestResultsSource::JunitXml { reports })
            | Some(TestResultsSource::LitheTestResults { reports }) => {
                if reports.is_empty() {
                    return Err(invalid(
                        format!("{field}.results.reports"),
                        "Declare at least one report pattern.",
                    ));
                }
                check_paths(reports, &format!("{field}.results.reports"), true)
            }
            _ => Ok(()),
        }
    }

    fn validate_diagnostics(&self, field: &str) -> Validation<()> {
        let Some(DiagnosticsDeclaration::LineMatcher { patterns }) = &self.diagnostics else {
            return Ok(());
        };
        let field = format!("{field}.diagnostics.patterns");
        if patterns.is_empty() || patterns.len() > MAX_LIST {
            return Err(invalid(field, "A line matcher needs 1-32 patterns."));
        }
        for (index, pattern) in patterns.iter().enumerate() {
            let field = format!("{field}[{index}]");
            let groups = [
                Some(pattern.file),
                Some(pattern.line),
                pattern.column,
                Some(pattern.message),
                pattern.severity,
            ];
            let highest = groups.iter().flatten().copied().max().unwrap_or(0);
            check_regex(&pattern.regex, &format!("{field}.regex"), highest)?;
            if groups.iter().flatten().any(|group| *group == 0) {
                return Err(invalid(field, "Capture groups are numbered from 1."));
            }
            if !pattern.severities.is_empty() && pattern.severity.is_none() {
                return Err(invalid(
                    format!("{field}.severities"),
                    "Severity names need a severity group.",
                ));
            }
        }
        Ok(())
    }

    fn validate_dependencies(&mut self, field: &str, options: &BTreeSet<String>) -> Validation<()> {
        if let Some(DependenciesSource::Provider { scopes }) = &mut self.dependencies {
            return check_scopes(
                scopes,
                &format!("{field}.dependencies.scopes"),
                &[Scope::Workspace, Scope::Project],
            );
        }
        let Some(DependenciesSource::Command {
            scopes,
            arguments,
            output,
            decoder,
            map,
            ..
        }) = &mut self.dependencies
        else {
            return Ok(());
        };
        let field = format!("{field}.dependencies");
        check_scopes(
            scopes,
            &format!("{field}.scopes"),
            &[Scope::Workspace, Scope::Project],
        )?;
        check_argument_count(arguments, &format!("{field}.arguments"))?;
        template::validate_arguments(
            arguments,
            &Allowed {
                root: true,
                project: availability(scopes, Scope::Project),
                host_directories: true,
                conditions: true,
                options: Some(options),
                ..Allowed::none()
            },
            &format!("{field}.arguments"),
        )?;
        check_output_channel(*output, arguments, &field)?;
        match (decoder, map) {
            (DependencyDecoder::LitheDependencies, None) => Ok(()),
            (DependencyDecoder::LitheDependencies, Some(_)) => Err(invalid(
                format!("{field}.map"),
                "The litheDependencies format needs no map.",
            )),
            (_, None) => Err(invalid(
                format!("{field}.map"),
                "A dependency command with a generic format needs a map.",
            )),
            (_, Some(rule)) => rule.validate(&format!("{field}.map")),
        }
    }

    /// An option's arguments must be emitted at most once per command line:
    /// either all options in one place, or each option in exactly one of the
    /// global and the command-specific lists, and once within each list.
    fn validate_option_emission(&self, field: &str) -> Validation<()> {
        let twice = |list_field: String| {
            template_error(
                list_field,
                "An option's arguments would be emitted twice; reference each option in one place.",
            )
        };
        let globals = &self.invocation.global_arguments;
        if template::repeats_option_arguments(globals) {
            return Err(twice(format!("{field}.invocation.globalArguments")));
        }
        let (global_all, global_named) = template::option_references(globals);
        let mut lists: Vec<(String, &[BuildArgument])> = Vec::new();
        for (index, task) in self.tasks.iter().enumerate() {
            lists.push((format!("{field}.tasks[{index}].arguments"), &task.arguments));
        }
        for (index, run) in self.run.iter().enumerate() {
            lists.push((format!("{field}.run[{index}].arguments"), &run.arguments));
        }
        if let Some(test) = &self.test {
            lists.push((format!("{field}.test.arguments"), &test.arguments));
        }
        if let Some(ModelSource::Command { arguments, .. }) = &self.model {
            lists.push((format!("{field}.model.arguments"), arguments));
        }
        if let Some(DependenciesSource::Command { arguments, .. }) = &self.dependencies {
            lists.push((format!("{field}.dependencies.arguments"), arguments));
        }
        for (list_field, arguments) in lists {
            let (all, named) = template::option_references(arguments);
            if (global_all && (all || !named.is_empty()))
                || (all && !global_named.is_empty())
                || global_named.intersection(&named).next().is_some()
                || template::repeats_option_arguments(arguments)
            {
                return Err(twice(list_field));
            }
        }
        Ok(())
    }
}

fn check_output_channel(
    output: OutputChannel,
    arguments: &[BuildArgument],
    field: &str,
) -> Validation<()> {
    let uses_file = template::uses(arguments, &Variable::OutputFile);
    match output {
        OutputChannel::OutputFile if !uses_file => Err(invalid(
            format!("{field}.output"),
            "An outputFile command must pass ${outputFile}.",
        )),
        OutputChannel::Stdout if uses_file => Err(invalid(
            format!("{field}.output"),
            "${outputFile} needs \"output\": \"outputFile\".",
        )),
        _ => Ok(()),
    }
}

fn executable_path(field: &str) -> PluginRejection {
    PluginRejection::at(
        "plugin.path.invalid",
        format!("{field}.path"),
        "Executable paths are relative, use /, and stay inside their base directory.",
    )
}

fn check_candidate(
    candidate: &mut ExecutableCandidate,
    field: &str,
    environment_inputs: &[String],
    runtimes: &BTreeSet<String>,
) -> Validation<()> {
    match candidate {
        ExecutableCandidate::ProjectFile { path, requires, .. } => {
            *requires = sorted_unique(std::mem::take(requires));
            if !is_safe_relative_path(path)
                || !requires.iter().all(|value| is_safe_relative_path(value))
            {
                return Err(executable_path(field));
            }
        }
        ExecutableCandidate::Environment { variable, path, .. } => {
            if !environment_inputs.contains(variable) {
                return Err(invalid(
                    format!("{field}.variable"),
                    "The variable must be listed in environmentInputs.",
                ));
            }
            if !is_safe_relative_path(path) {
                return Err(executable_path(field));
            }
        }
        ExecutableCandidate::Command { command, .. } => {
            if !is_bare_command(command) {
                return Err(invalid(
                    format!("{field}.command"),
                    "A command is a bare name looked up on PATH.",
                ));
            }
        }
        ExecutableCandidate::Runtime { runtime, .. } => {
            if !runtimes.contains(runtime) {
                return Err(invalid(
                    format!("{field}.runtime"),
                    "The runtime must be declared in runtimeDependencies.",
                ));
            }
        }
    }
    let platforms = candidate.platforms_mut();
    platforms.sort();
    platforms.dedup();
    Ok(())
}

impl VersionProbe {
    fn validate(&self, field: &str) -> Validation<()> {
        if self.arguments.len() > 8
            || self
                .arguments
                .iter()
                .any(|argument| argument.contains('\0') || argument.contains("${"))
        {
            return Err(invalid(
                format!("{field}.arguments"),
                "Version arguments are at most 8 literal strings.",
            ));
        }
        check_regex(&self.pattern, &format!("{field}.pattern"), 1).map(|_| ())
    }

    /// The dotted version the probe output reports, if any.
    pub(crate) fn version(&self, output: &str) -> Option<Vec<u64>> {
        let pattern = Regex::new(&self.pattern).ok()?;
        let text = pattern.captures(output)?.get(1)?.as_str().to_string();
        let components: Vec<u64> = text
            .split('.')
            .take(3)
            .map(|part| part.parse().ok())
            .collect::<Option<_>>()?;
        (!components.is_empty()).then_some(components)
    }
}

impl OptionDeclaration {
    fn validate(&mut self, field: &str) -> Validation<()> {
        if !is_setting_identifier(&self.id) {
            return Err(invalid(
                format!("{field}.id"),
                "Option IDs start with a lowercase letter and use letters and digits.",
            ));
        }
        check_text(
            &self.display_name,
            &format!("{field}.displayName"),
            "display name",
        )?;
        let select = self.is_select();
        if !select && (!self.choices.is_empty() || self.choices_from_model || self.allow_custom) {
            return Err(invalid(
                field,
                "Choices apply to singleSelect and multiSelect options only.",
            ));
        }
        if select && self.choices.is_empty() && !self.choices_from_model && !self.allow_custom {
            return Err(invalid(
                format!("{field}.choices"),
                "A select option needs choices, choicesFromModel, or allowCustom.",
            ));
        }
        if let Some(separator) = &self.separator {
            if self.kind != OptionKind::MultiSelect
                || separator.is_empty()
                || separator.len() > 4
                || separator.chars().any(char::is_control)
            {
                return Err(invalid(
                    format!("{field}.separator"),
                    "Only multiSelect options take a separator of 1-4 printable characters.",
                ));
            }
        }
        if self.choices.len() > MAX_CHOICES {
            return Err(invalid(format!("{field}.choices"), "Too many choices."));
        }
        let mut values = BTreeSet::new();
        for (index, choice) in self.choices.iter().enumerate() {
            let bad_value = !is_option_value(&choice.value)
                || (self.kind == OptionKind::MultiSelect
                    && choice.value.contains(self.separator()));
            if bad_value || !values.insert(choice.value.clone()) {
                return Err(invalid(
                    format!("{field}.choices[{index}].value"),
                    "Choice values are unique, printable, and free of the separator.",
                ));
            }
            if let Some(title) = &choice.title {
                check_text(title, &format!("{field}.choices[{index}].title"), "title")?;
            }
        }
        self.validate_presentation(field)?;
        self.validate_default(field)?;
        if self.arguments.is_empty() && self.environment.is_empty() {
            return Err(invalid(
                field,
                "An option must map to arguments, environment variables, or both.",
            ));
        }
        if self.arguments.len() > 8 || self.environment.len() > 8 {
            return Err(invalid(
                field,
                "An option maps to at most 8 arguments and 8 variables.",
            ));
        }
        let boolean = self.kind == OptionKind::Boolean;
        let allowed = Allowed {
            value: !boolean,
            ..Allowed::none()
        };
        let mut uses_value = false;
        for (index, argument) in self.arguments.iter().enumerate() {
            template::validate_text(argument, &allowed, &format!("{field}.arguments[{index}]"))?;
            uses_value |= argument.contains("${value}");
        }
        for (name, value) in &self.environment {
            if !is_environment_name(name) {
                return Err(invalid(
                    format!("{field}.environment"),
                    "Environment variable names use uppercase letters, digits, and _.",
                ));
            }
            template::validate_text(value, &allowed, &format!("{field}.environment.{name}"))?;
            uses_value |= value.contains("${value}");
        }
        if !boolean && !uses_value {
            return Err(template_error(
                field,
                "The option's value is never passed; use ${value}.",
            ));
        }
        Ok(())
    }

    fn validate_presentation(&self, field: &str) -> Validation<()> {
        if let Some(icon) = &self.icon {
            icon.validate_at(&format!("{field}.icon"))?;
        }
        match self.presentation {
            Some(OptionPresentation::Toolbar)
                if self.kind != OptionKind::Boolean || self.icon.is_none() =>
            {
                Err(invalid(
                    format!("{field}.presentation"),
                    "A toolbar option is a boolean option with an icon.",
                ))
            }
            Some(OptionPresentation::Tree) if self.kind != OptionKind::MultiSelect => Err(invalid(
                format!("{field}.presentation"),
                "A tree option is a multiSelect option.",
            )),
            None if self.icon.is_some() => Err(invalid(
                format!("{field}.icon"),
                "Only toolbar options have an icon.",
            )),
            _ => Ok(()),
        }
    }

    fn validate_default(&self, field: &str) -> Validation<()> {
        let Some(default) = &self.default else {
            return Ok(());
        };
        let field = format!("{field}.default");
        let valid = match (self.kind, default) {
            (OptionKind::Boolean, Value::Bool(_)) => true,
            (OptionKind::MultiSelect, Value::Array(items)) => items.iter().all(|item| {
                item.as_str()
                    .is_some_and(|value| self.accepts_value(value, Some(&[])))
            }),
            (OptionKind::SingleSelect, Value::String(value)) => {
                self.accepts_value(value, Some(&[]))
            }
            (OptionKind::Text, Value::String(value)) => value.is_empty() || is_option_value(value),
            // Paths are the user's: a plugin cannot know one on this machine.
            (OptionKind::File | OptionKind::Directory, Value::String(value)) => value.is_empty(),
            _ => false,
        };
        if !valid {
            return Err(invalid(
                field,
                "The default does not fit the option's kind and choices; file and directory options have no default.",
            ));
        }
        Ok(())
    }
}

impl ModelMap {
    fn validate(&self, field: &str, model_options: &BTreeSet<String>) -> Validation<()> {
        if self.projects.is_empty() {
            return Err(invalid(
                format!("{field}.projects"),
                "A model map needs at least one project rule.",
            ));
        }
        check_rule_count(self.projects.len(), &format!("{field}.projects"))?;
        for (index, rule) in self.projects.iter().enumerate() {
            let field = format!("{field}.projects[{index}]");
            check_rule(rule, &field)?;
            rule.name.validate(&format!("{field}.name"))?;
            for spec in [&rule.display_name, &rule.path].into_iter().flatten() {
                spec.validate(&field)?;
            }
            check_properties(&rule.properties, &field)?;
            check_rule_count(rule.targets.len(), &format!("{field}.targets"))?;
            for (target_index, target) in rule.targets.iter().enumerate() {
                target.validate(&format!("{field}.targets[{target_index}]"))?;
            }
            check_rule_count(rule.content_roots.len(), &format!("{field}.contentRoots"))?;
            for (root_index, content_root) in rule.content_roots.iter().enumerate() {
                let field = format!("{field}.contentRoots[{root_index}]");
                check_rule(content_root, &field)?;
                content_root.path.validate(&format!("{field}.path"))?;
            }
        }
        for (id, rule) in &self.option_values {
            let field = format!("{field}.optionValues.{id}");
            if !model_options.contains(id) {
                return Err(invalid(
                    field,
                    "optionValues may only fill options declared with choicesFromModel.",
                ));
            }
            select::validate(&rule.each, &format!("{field}.each"), false)?;
            check_predicates(&rule.filter, &field)?;
            rule.value.validate(&format!("{field}.value"))?;
        }
        Ok(())
    }
}

fn check_rule_count(count: usize, field: &str) -> Validation<()> {
    if count > MAX_LIST {
        return Err(invalid(field, "Too many rules."));
    }
    Ok(())
}

fn check_rule(rule: &impl RuleMatch, field: &str) -> Validation<()> {
    if let Some(each) = rule.each() {
        select::validate(each, &format!("{field}.each"), false)?;
    }
    check_predicates(rule.filter(), field)?;
    if let Some(file) = rule.when_file() {
        if !is_safe_relative_path(file) {
            return Err(PluginRejection::at(
                "plugin.path.invalid",
                format!("{field}.whenFile"),
                "whenFile is relative to the project directory.",
            ));
        }
    }
    Ok(())
}

fn check_predicates(predicates: &[Predicate], field: &str) -> Validation<()> {
    if predicates.len() > 8 {
        return Err(invalid(format!("{field}.where"), "Too many predicates."));
    }
    for (index, predicate) in predicates.iter().enumerate() {
        predicate.validate(&format!("{field}.where[{index}]"))?;
    }
    Ok(())
}

fn check_properties(properties: &BTreeMap<String, FieldSpec>, field: &str) -> Validation<()> {
    if properties.len() > MAX_LIST {
        return Err(invalid(
            format!("{field}.properties"),
            "Too many properties.",
        ));
    }
    for (key, spec) in properties {
        if !template::is_property_key(key) {
            return Err(invalid(
                format!("{field}.properties"),
                "Property keys use letters, digits, ., _, and -.",
            ));
        }
        spec.validate(&format!("{field}.properties.{key}"))?;
    }
    Ok(())
}

impl TargetRule {
    fn validate(&self, field: &str) -> Validation<()> {
        check_rule(self, field)?;
        self.name.validate(&format!("{field}.name"))?;
        if let Some(path) = &self.path {
            path.validate(&format!("{field}.path"))?;
        }
        check_properties(&self.properties, field)?;
        if self.tags.iter().any(|tag| !is_tag(tag)) {
            return Err(invalid(format!("{field}.tags"), "Tags are identifiers."));
        }
        Ok(())
    }
}

impl DependencyRule {
    fn validate(&self, field: &str) -> Validation<()> {
        select::validate(&self.each, &format!("{field}.each"), false)?;
        check_predicates(&self.filter, field)?;
        self.name.validate(&format!("{field}.name"))?;
        for spec in [&self.group, &self.version, &self.scope]
            .into_iter()
            .flatten()
        {
            spec.validate(field)?;
        }
        check_properties(&self.properties, field)
    }
}
