//! Declarative plugin contract v1: manifest validation and deterministic
//! expansion of run/test command templates.
//!
//! A declarative plugin carries no host-loaded code. The host reads its
//! `plugin.json`, asks this module to validate and normalize it, and launches
//! the declared external processes itself. Both products must produce the
//! same outcome for the fixtures in `shared/contracts/plugins/v1/`.
//!
//! Content problems in a manifest or request are reported as `rejected`
//! outcomes with a stable `plugin.*` code instead of Core failures, so hosts
//! can show them next to the affected plugin. Only a malformed command
//! payload is a Core `invalid_request` failure.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeSet;

/// `plugin.json` schema version that identifies a declarative manifest.
/// Version 1 was the retired macOS native-bundle manifest.
pub const DECLARATIVE_MANIFEST_SCHEMA_VERSION: u32 = 2;
/// Declarative plugin API levels this Core build can host. The level is
/// independent of the Lithe application version.
pub const SUPPORTED_PLUGIN_API_VERSIONS: &[u32] = &[1];

/// ID prefix reserved to plugins published and signed by Lithe.
pub const OFFICIAL_PLUGIN_NAMESPACE: &str = "dev.lithe";

const PERMISSION_LANGUAGE_SERVER: &str = "languageServer.launch";
const PERMISSION_RUN: &str = "process.run";
const PERMISSION_TEST: &str = "process.test";
const KNOWN_PERMISSIONS: &[&str] = &[PERMISSION_LANGUAGE_SERVER, PERMISSION_RUN, PERMISSION_TEST];
/// Runtime tools the host knows how to discover and pass to a language
/// server. The host exports each as `LITHE_<TOOL>_PATH` and puts its
/// directory on the server's `PATH`; gopls, for example, runs `go` itself.
const KNOWN_RUNTIME_TOOLS: &[&str] = &["go", "node"];

/// Stable reason a declarative manifest or plan request was refused.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PluginRejection {
    /// Stable `plugin.*` code listed in the contract README.
    pub code: &'static str,
    /// User-facing English summary without host paths.
    pub message: String,
    /// JSON path of the offending manifest field, when one applies.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub field: Option<String>,
}

impl PluginRejection {
    pub(crate) fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            field: None,
        }
    }

    pub(crate) fn at(
        code: &'static str,
        field: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            code,
            message: message.into(),
            field: Some(field.into()),
        }
    }
}

pub(crate) type Validation<T> = Result<T, PluginRejection>;

/// Root of a declarative `plugin.json`. Unknown fields are refused so a newer
/// manifest feature cannot be silently ignored by an older host.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeclarativePluginManifest {
    schema_version: u32,
    id: String,
    display_name: String,
    version: String,
    #[serde(rename = "pluginAPIVersion")]
    plugin_api_version: u32,
    vendor: PluginVendor,
    #[serde(default)]
    permissions: Vec<String>,
    #[serde(default)]
    activation_events: Vec<String>,
    languages: Vec<LanguageDeclaration>,
    #[serde(default)]
    language_servers: Vec<LanguageServerDeclaration>,
    #[serde(default)]
    execution_providers: Vec<ExecutionProviderDeclaration>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PluginVendor {
    id: String,
    display_name: String,
    signature_requirement: SignatureRequirement,
}

/// How a package proves its origin. `sameTeamAsHost` is only honored by a
/// host for packages shipped inside its own signed installation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
enum SignatureRequirement {
    SameTeamAsHost,
    PublisherPackage,
    /// Community package without a Lithe signature. Its integrity comes from
    /// the marketplace index checksum and its trust from the user's explicit
    /// confirmation, so the official namespace can never use it.
    None,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LanguageDeclaration {
    id: String,
    display_name: String,
    #[serde(default)]
    file_extensions: Vec<String>,
    #[serde(default)]
    file_names: Vec<String>,
    #[serde(default)]
    project_file_names: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    dependencies: Option<DependencyDeclaration>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DependencyDeclaration {
    #[serde(default)]
    management_file_names: Vec<String>,
    #[serde(default)]
    project_dependency_paths: Vec<String>,
    #[serde(default)]
    project_binary_paths: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LanguageServerDeclaration {
    #[serde(rename = "languageID")]
    language_id: String,
    /// LSP `languageId` sent for documents; defaults to the language ID.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    language_identifier: Option<String>,
    launch: LanguageServerLaunch,
    #[serde(default)]
    arguments: Vec<String>,
    /// Arguments of a probe that must exit successfully before the host
    /// trusts a candidate executable; empty means no probe.
    #[serde(default)]
    validation_arguments: Vec<String>,
    #[serde(default)]
    runtime_dependencies: Vec<RuntimeDependency>,
}

/// Where the language-server executable comes from.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
enum LanguageServerLaunch {
    /// An executable inside the plugin package, relative to the package root.
    Packaged { path: String },
    /// Bare command names the host resolves through its tool discovery.
    SystemCommand { commands: Vec<String> },
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RuntimeDependency {
    tool: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ExecutionProviderDeclaration {
    #[serde(rename = "languageID")]
    language_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    run: Option<RunTemplate>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    test: Option<TestTemplate>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RunTemplate {
    executable: ExecutableDeclaration,
    arguments: Vec<ArgumentTemplate>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TestTemplate {
    #[serde(rename = "frameworkID")]
    framework_id: String,
    workspace_label: String,
    project_markers: Vec<String>,
    test_file_patterns: Vec<String>,
    executable: ExecutableDeclaration,
    workspace_arguments: Vec<ArgumentTemplate>,
    file_arguments: Vec<ArgumentTemplate>,
    test_case_arguments: Vec<ArgumentTemplate>,
}

/// Exactly one of a bare command resolved on the host's tool path or a
/// host-owned project toolchain ID such as `project-go`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ExecutableDeclaration {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    command: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    toolchain: Option<String>,
}

/// One argv element. A conditional element is emitted only when the request
/// selects (or does not select) a file.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(untagged)]
enum ArgumentTemplate {
    Literal(String),
    Conditional {
        value: String,
        when: ArgumentCondition,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
enum ArgumentCondition {
    FileSelected,
    NoFileSelected,
}

/// Template variables. `${userArguments}` expands to zero or more elements;
/// the others substitute into a single element.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TemplateVariable {
    File,
    FileDirectory,
    TestName,
    TestNameRegex,
    UserArguments,
}

impl TemplateVariable {
    fn parse(name: &str) -> Option<Self> {
        match name {
            "file" => Some(Self::File),
            "fileDirectory" => Some(Self::FileDirectory),
            "testName" => Some(Self::TestName),
            "testName:regex" => Some(Self::TestNameRegex),
            "userArguments" => Some(Self::UserArguments),
            _ => None,
        }
    }

    fn needs_file(self) -> bool {
        matches!(self, Self::File | Self::FileDirectory)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum TemplatePart {
    Text(String),
    Variable(TemplateVariable),
}

/// Which command template an argument list belongs to; each allows a
/// different set of variables.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TemplateContext {
    Run,
    TestWorkspace,
    TestFile,
    TestCase,
}

impl TemplateContext {
    fn allows(self, variable: TemplateVariable) -> bool {
        use TemplateVariable::*;
        match self {
            Self::Run => matches!(variable, File | FileDirectory | UserArguments),
            Self::TestWorkspace => false,
            Self::TestFile => matches!(variable, File | FileDirectory),
            Self::TestCase => matches!(variable, File | FileDirectory | TestName | TestNameRegex),
        }
    }
}

fn parse_template(value: &str) -> Option<Vec<TemplatePart>> {
    let mut parts = Vec::new();
    let mut rest = value;
    while let Some(start) = rest.find("${") {
        if start > 0 {
            parts.push(TemplatePart::Text(rest[..start].to_string()));
        }
        let after = &rest[start + 2..];
        let end = after.find('}')?;
        parts.push(TemplatePart::Variable(TemplateVariable::parse(
            &after[..end],
        )?));
        rest = &after[end + 1..];
    }
    if !rest.is_empty() {
        parts.push(TemplatePart::Text(rest.to_string()));
    }
    Some(parts)
}

/// Validates a raw manifest value and returns its normalized form.
pub fn validate_manifest_value(value: Value) -> Validation<DeclarativePluginManifest> {
    // Check the version gates first so a future schema reports the precise
    // reason instead of an unknown-field decoding failure.
    if let Some(version) = value.get("schemaVersion").and_then(Value::as_u64) {
        if version != u64::from(DECLARATIVE_MANIFEST_SCHEMA_VERSION) {
            return Err(PluginRejection::at(
                "plugin.schema.unsupported",
                "schemaVersion",
                format!("Plugin manifest schema {version} is not supported."),
            ));
        }
    }
    if let Some(version) = value.get("pluginAPIVersion").and_then(Value::as_u64) {
        if !SUPPORTED_PLUGIN_API_VERSIONS
            .iter()
            .any(|supported| u64::from(*supported) == version)
        {
            return Err(PluginRejection::at(
                "plugin.api.unsupported",
                "pluginAPIVersion",
                format!("Plugin API {version} is not supported by this version of Lithe."),
            ));
        }
    }
    let manifest: DeclarativePluginManifest = serde_json::from_value(value).map_err(|error| {
        PluginRejection::new(
            "plugin.manifest.invalid",
            format!("The plugin manifest is invalid: {error}"),
        )
    })?;
    manifest.validated()
}

impl DeclarativePluginManifest {
    fn validated(mut self) -> Validation<Self> {
        if !is_plugin_id(&self.id) {
            return Err(invalid(
                "id",
                "The plugin ID must use lowercase letters, digits, dots, and hyphens.",
            ));
        }
        if !is_semantic_version(&self.version) {
            return Err(invalid(
                "version",
                "The plugin version must use major.minor.patch.",
            ));
        }
        if self.display_name.trim().is_empty() {
            return Err(invalid("displayName", "The plugin display name is empty."));
        }
        if self.vendor.id.trim().is_empty() || self.vendor.display_name.trim().is_empty() {
            return Err(invalid("vendor", "The plugin vendor is incomplete."));
        }
        if self.vendor.signature_requirement == SignatureRequirement::None
            && is_official_namespace(&self.id)
        {
            return Err(invalid(
                "vendor.signatureRequirement",
                "Official plugin IDs must carry a Lithe signature.",
            ));
        }
        if self.languages.is_empty() {
            return Err(invalid("languages", "The plugin declares no languages."));
        }

        let mut language_ids = BTreeSet::new();
        for (index, language) in self.languages.iter_mut().enumerate() {
            language.normalize(index)?;
            if !language_ids.insert(language.id.clone()) {
                return Err(invalid(
                    format!("languages[{index}].id"),
                    "A language is declared more than once.",
                ));
            }
        }
        self.languages.sort_by(|left, right| left.id.cmp(&right.id));

        let mut server_languages = BTreeSet::new();
        for (index, server) in self.language_servers.iter().enumerate() {
            let field = format!("languageServers[{index}]");
            if !language_ids.contains(&server.language_id) {
                return Err(invalid(
                    format!("{field}.languageID"),
                    "The language server references an undeclared language.",
                ));
            }
            if !server_languages.insert(server.language_id.clone()) {
                return Err(invalid(
                    format!("{field}.languageID"),
                    "A language declares more than one language server.",
                ));
            }
            server.validate(&field)?;
        }
        self.language_servers
            .sort_by(|left, right| left.language_id.cmp(&right.language_id));

        let mut execution_languages = BTreeSet::new();
        for (index, provider) in self.execution_providers.iter_mut().enumerate() {
            let field = format!("executionProviders[{index}]");
            if !language_ids.contains(&provider.language_id) {
                return Err(invalid(
                    format!("{field}.languageID"),
                    "The execution provider references an undeclared language.",
                ));
            }
            if !execution_languages.insert(provider.language_id.clone()) {
                return Err(invalid(
                    format!("{field}.languageID"),
                    "A language declares more than one execution provider.",
                ));
            }
            provider.normalize(&field)?;
        }
        self.execution_providers
            .sort_by(|left, right| left.language_id.cmp(&right.language_id));

        if self.language_servers.is_empty() && self.execution_providers.is_empty() {
            return Err(invalid(
                "languages",
                "The plugin declares no language server or execution provider.",
            ));
        }
        self.validate_permissions()?;
        self.validate_activation_events()?;
        Ok(self)
    }

    fn validate_permissions(&mut self) -> Validation<()> {
        for permission in &self.permissions {
            if !KNOWN_PERMISSIONS.contains(&permission.as_str()) {
                return Err(PluginRejection::at(
                    "plugin.permission.unknown",
                    "permissions",
                    format!("The plugin requests an unknown permission: {permission}."),
                ));
            }
        }
        self.permissions = sorted_unique(std::mem::take(&mut self.permissions));
        let mut required = BTreeSet::new();
        if !self.language_servers.is_empty() {
            required.insert(PERMISSION_LANGUAGE_SERVER);
        }
        for provider in &self.execution_providers {
            if provider.run.is_some() {
                required.insert(PERMISSION_RUN);
            }
            if provider.test.is_some() {
                required.insert(PERMISSION_TEST);
            }
        }
        for permission in required {
            if !self
                .permissions
                .iter()
                .any(|declared| declared == permission)
            {
                return Err(PluginRejection::at(
                    "plugin.permission.undeclared",
                    "permissions",
                    format!("The plugin uses {permission} without declaring the permission."),
                ));
            }
        }
        Ok(())
    }

    fn validate_activation_events(&mut self) -> Validation<()> {
        let mut expected = BTreeSet::new();
        for server in &self.language_servers {
            expected.insert(format!("onLanguage:{}", server.language_id));
        }
        for provider in &self.execution_providers {
            if provider.run.is_some() {
                expected.insert(format!("onRun:{}", provider.language_id));
            }
            if provider.test.is_some() {
                expected.insert(format!("onTest:{}", provider.language_id));
            }
        }
        self.activation_events = sorted_unique(std::mem::take(&mut self.activation_events));
        let declared: BTreeSet<String> = self.activation_events.iter().cloned().collect();
        // Every provider needs an event, and every event needs a provider:
        // an event without one would promise activation the host cannot do.
        if let Some(missing) = expected.difference(&declared).next() {
            return Err(PluginRejection::at(
                "plugin.activation.invalid",
                "activationEvents",
                format!("The plugin must declare the activation event {missing}."),
            ));
        }
        if let Some(extra) = declared.difference(&expected).next() {
            return Err(PluginRejection::at(
                "plugin.activation.invalid",
                "activationEvents",
                format!("The activation event {extra} has no matching provider."),
            ));
        }
        Ok(())
    }

    fn execution_provider(&self, language_id: &str) -> Option<&ExecutionProviderDeclaration> {
        self.execution_providers
            .iter()
            .find(|provider| provider.language_id == language_id)
    }
}

impl DeclarativePluginManifest {
    /// Stable plugin ID.
    pub(crate) fn id(&self) -> &str {
        &self.id
    }

    /// Plugin version, `major.minor.patch`.
    pub(crate) fn version(&self) -> &str {
        &self.version
    }

    /// Normalized, sorted permission list.
    pub(crate) fn permissions(&self) -> &[String] {
        &self.permissions
    }

    /// Every program the host may start on this plugin's behalf, in a stable
    /// order. Each entry carries everything that decides what actually runs:
    /// the executable plus its arguments, the language server's validation
    /// probe, and the run/test argument templates. An update that changes any
    /// of these, even with the same executable, is a new program and must be
    /// approved again.
    pub(crate) fn programs(&self) -> Vec<Value> {
        let mut programs = Vec::new();
        for server in &self.language_servers {
            programs.push(match &server.launch {
                LanguageServerLaunch::Packaged { path } => json!({
                    "kind": "packagedLanguageServer",
                    "languageID": server.language_id,
                    "path": path,
                    "arguments": server.arguments,
                    "validationArguments": server.validation_arguments,
                }),
                LanguageServerLaunch::SystemCommand { commands } => json!({
                    "kind": "systemLanguageServer",
                    "languageID": server.language_id,
                    "commands": commands,
                    "arguments": server.arguments,
                    "validationArguments": server.validation_arguments,
                }),
            });
            for dependency in &server.runtime_dependencies {
                programs.push(json!({ "kind": "runtime", "tool": dependency.tool }));
            }
        }
        for provider in &self.execution_providers {
            if let Some(run) = &provider.run {
                programs.push(json!({
                    "kind": "run",
                    "languageID": provider.language_id,
                    "executable": run.executable,
                    "arguments": run.arguments,
                }));
            }
            if let Some(test) = &provider.test {
                programs.push(json!({
                    "kind": "test",
                    "languageID": provider.language_id,
                    "executable": test.executable,
                    "workspaceArguments": test.workspace_arguments,
                    "fileArguments": test.file_arguments,
                    "testCaseArguments": test.test_case_arguments,
                }));
            }
        }
        // Order by kind, then language or tool, then the full serialized
        // value as a total tie-breaker; duplicates (two servers needing the
        // same runtime) collapse to one entry.
        programs.sort_by_key(|program| {
            let text = |key: &str| program[key].as_str().unwrap_or_default().to_string();
            (
                text("kind"),
                text("languageID"),
                text("tool"),
                program.to_string(),
            )
        });
        programs.dedup();
        programs
    }
}

impl LanguageDeclaration {
    fn normalize(&mut self, index: usize) -> Validation<()> {
        let field = format!("languages[{index}]");
        let id = self.id.trim().to_lowercase();
        if id.is_empty()
            || id != self.id
            || !id.chars().all(|character| {
                character.is_ascii_lowercase()
                    || character.is_ascii_digit()
                    || "+-_".contains(character)
            })
        {
            return Err(invalid(
                format!("{field}.id"),
                "The language ID must be lowercase.",
            ));
        }
        if self.display_name.trim().is_empty() {
            return Err(invalid(
                format!("{field}.displayName"),
                "The language display name is empty.",
            ));
        }
        self.file_extensions = normalized_extensions(&self.file_extensions);
        self.file_names = normalized_names(&self.file_names);
        self.project_file_names = normalized_names(&self.project_file_names);
        if self.file_extensions.is_empty()
            && self.file_names.is_empty()
            && self.project_file_names.is_empty()
        {
            return Err(invalid(
                field,
                "The language declares no file extensions or file names.",
            ));
        }
        if self
            .file_extensions
            .iter()
            .chain(&self.file_names)
            .chain(&self.project_file_names)
            .any(|name| name.contains('/') || name.contains('\\'))
        {
            return Err(invalid(
                field,
                "Language file names must not contain path separators.",
            ));
        }
        if let Some(dependencies) = &mut self.dependencies {
            dependencies.management_file_names =
                normalized_names(&dependencies.management_file_names);
            dependencies.project_dependency_paths =
                sorted_unique(dependencies.project_dependency_paths.clone());
            dependencies.project_binary_paths =
                sorted_unique(dependencies.project_binary_paths.clone());
            if dependencies
                .management_file_names
                .iter()
                .chain(&dependencies.project_dependency_paths)
                .chain(&dependencies.project_binary_paths)
                .any(|path| !is_safe_relative_path(path))
            {
                return Err(invalid(
                    format!("{field}.dependencies"),
                    "Dependency paths must stay inside the project.",
                ));
            }
        }
        Ok(())
    }
}

impl LanguageServerDeclaration {
    fn validate(&self, field: &str) -> Validation<()> {
        match &self.launch {
            LanguageServerLaunch::Packaged { path } => {
                if !is_safe_relative_path(path) {
                    return Err(invalid(
                        format!("{field}.launch.path"),
                        "The packaged language server must stay inside the plugin package.",
                    ));
                }
            }
            LanguageServerLaunch::SystemCommand { commands } => {
                if commands.is_empty() || commands.iter().any(|command| !is_bare_command(command)) {
                    return Err(invalid(
                        format!("{field}.launch.commands"),
                        "System commands must be bare executable names.",
                    ));
                }
            }
        }
        if let Some(identifier) = &self.language_identifier {
            if identifier.trim().is_empty() {
                return Err(invalid(
                    format!("{field}.languageIdentifier"),
                    "The LSP language identifier is empty.",
                ));
            }
        }
        if self
            .arguments
            .iter()
            .chain(&self.validation_arguments)
            .any(|argument| argument.contains('\0'))
        {
            return Err(invalid(
                format!("{field}.arguments"),
                "Language server arguments must not contain NUL.",
            ));
        }
        for dependency in &self.runtime_dependencies {
            if !KNOWN_RUNTIME_TOOLS.contains(&dependency.tool.as_str()) {
                return Err(PluginRejection::at(
                    "plugin.runtime.unsupported",
                    format!("{field}.runtimeDependencies"),
                    format!("The host cannot provide the runtime {}.", dependency.tool),
                ));
            }
        }
        Ok(())
    }
}

impl ExecutionProviderDeclaration {
    fn normalize(&mut self, field: &str) -> Validation<()> {
        if self.run.is_none() && self.test.is_none() {
            return Err(invalid(
                field.to_string(),
                "The execution provider declares neither run nor test.",
            ));
        }
        if let Some(run) = &self.run {
            validate_executable(&run.executable, &format!("{field}.run.executable"))?;
            validate_arguments(
                &run.arguments,
                TemplateContext::Run,
                &format!("{field}.run.arguments"),
            )?;
        }
        if let Some(test) = &mut self.test {
            let test_field = format!("{field}.test");
            if !is_identifier(&test.framework_id) {
                return Err(invalid(
                    format!("{test_field}.frameworkID"),
                    "The test framework ID is invalid.",
                ));
            }
            if test.workspace_label.trim().is_empty() {
                return Err(invalid(
                    format!("{test_field}.workspaceLabel"),
                    "The workspace test label is empty.",
                ));
            }
            test.project_markers = normalized_names(&test.project_markers);
            test.test_file_patterns = normalized_names(&test.test_file_patterns);
            if test.project_markers.is_empty()
                || test.project_markers.iter().any(|name| name.contains('/'))
            {
                return Err(invalid(
                    format!("{test_field}.projectMarkers"),
                    "Project markers must be file names.",
                ));
            }
            if test.test_file_patterns.is_empty()
                || test.test_file_patterns.iter().any(|pattern| {
                    pattern.contains('/') || pattern.contains('?') || pattern.contains('[')
                })
            {
                return Err(invalid(
                    format!("{test_field}.testFilePatterns"),
                    "Test file patterns must be file names using only *.",
                ));
            }
            validate_executable(&test.executable, &format!("{test_field}.executable"))?;
            validate_arguments(
                &test.workspace_arguments,
                TemplateContext::TestWorkspace,
                &format!("{test_field}.workspaceArguments"),
            )?;
            validate_arguments(
                &test.file_arguments,
                TemplateContext::TestFile,
                &format!("{test_field}.fileArguments"),
            )?;
            validate_arguments(
                &test.test_case_arguments,
                TemplateContext::TestCase,
                &format!("{test_field}.testCaseArguments"),
            )?;
            let names_test = test.test_case_arguments.iter().any(|argument| {
                parse_template(argument.value()).is_some_and(|parts| {
                    parts.iter().any(|part| {
                        matches!(
                            part,
                            TemplatePart::Variable(
                                TemplateVariable::TestName | TemplateVariable::TestNameRegex
                            )
                        )
                    })
                })
            });
            if !names_test {
                return Err(template(
                    format!("{test_field}.testCaseArguments"),
                    "The test case command must reference the test name.",
                ));
            }
        }
        Ok(())
    }
}

impl ArgumentTemplate {
    fn value(&self) -> &str {
        match self {
            Self::Literal(value) | Self::Conditional { value, .. } => value,
        }
    }

    fn condition(&self) -> Option<ArgumentCondition> {
        match self {
            Self::Literal(_) => None,
            Self::Conditional { when, .. } => Some(*when),
        }
    }
}

fn validate_executable(executable: &ExecutableDeclaration, field: &str) -> Validation<()> {
    match (&executable.command, &executable.toolchain) {
        (Some(command), None) if is_bare_command(command) => Ok(()),
        (None, Some(toolchain)) if is_identifier(toolchain) => Ok(()),
        _ => Err(invalid(
            field.to_string(),
            "The executable must be exactly one bare command or toolchain ID.",
        )),
    }
}

fn validate_arguments(
    arguments: &[ArgumentTemplate],
    context: TemplateContext,
    field: &str,
) -> Validation<()> {
    for (index, argument) in arguments.iter().enumerate() {
        let element = format!("{field}[{index}]");
        let value = argument.value();
        if value.contains('\0') {
            return Err(template(element, "Arguments must not contain NUL."));
        }
        let Some(parts) = parse_template(value) else {
            return Err(template(
                element,
                "The argument uses an unknown or unterminated template variable.",
            ));
        };
        let condition = argument.condition();
        if condition.is_some() && context != TemplateContext::TestCase {
            return Err(template(
                element,
                "Conditional arguments are only allowed in test case commands.",
            ));
        }
        for part in &parts {
            let TemplatePart::Variable(variable) = part else {
                continue;
            };
            if !context.allows(*variable) {
                return Err(template(
                    element,
                    "The argument uses a variable that is not available in this command.",
                ));
            }
            if *variable == TemplateVariable::UserArguments && parts.len() != 1 {
                return Err(template(
                    element,
                    "${userArguments} must be a whole argument.",
                ));
            }
            // A test case may run without a selected file, so file variables
            // must be guarded instead of expanding to an empty argument.
            if context == TemplateContext::TestCase
                && variable.needs_file()
                && condition != Some(ArgumentCondition::FileSelected)
            {
                return Err(template(
                    element,
                    "File variables in a test case command require \"when\": \"fileSelected\".",
                ));
            }
        }
    }
    Ok(())
}

// MARK: Plans

/// A run request for one workspace-relative file.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunPlanRequest {
    relative_file_path: String,
    #[serde(default)]
    arguments: Vec<String>,
}

/// A test discovery request over the workspace's relative file list.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TestDiscoveryRequest {
    relative_project_file_paths: Vec<String>,
}

/// A test launch request for a workspace, file, or single test case.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TestPlanRequest {
    scope: TestScope,
    relative_project_file_paths: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
enum TestScope {
    Workspace,
    File {
        #[serde(rename = "relativeFilePath")]
        relative_file_path: String,
    },
    TestCase {
        identifier: String,
        #[serde(default, rename = "relativeFilePath")]
        relative_file_path: Option<String>,
    },
}

/// Values substituted into one command template.
struct ExpansionValues<'a> {
    file: Option<&'a str>,
    test_name: Option<&'a str>,
    user_arguments: &'a [String],
}

fn run_plan(
    manifest: &DeclarativePluginManifest,
    language_id: &str,
    request: &RunPlanRequest,
) -> Validation<Value> {
    let run = manifest
        .execution_provider(language_id)
        .and_then(|provider| provider.run.as_ref())
        .ok_or_else(|| unavailable(language_id, "run"))?;
    let path = checked_path(&request.relative_file_path)?;
    let arguments = expand(
        &run.arguments,
        &ExpansionValues {
            file: Some(&path),
            test_name: None,
            user_arguments: &request.arguments,
        },
    );
    Ok(json!({
        "executable": run.executable,
        "arguments": arguments,
        "workingDirectory": "."
    }))
}

fn discover_tests(
    manifest: &DeclarativePluginManifest,
    language_id: &str,
    request: &TestDiscoveryRequest,
) -> Validation<Value> {
    let test = test_template(manifest, language_id)?;
    let paths = checked_paths(&request.relative_project_file_paths)?;
    if !supports_project(test, &paths) {
        return Ok(json!([]));
    }
    let mut files: Vec<&String> = paths
        .iter()
        .filter(|path| {
            let name = file_name(path).to_lowercase();
            test.test_file_patterns
                .iter()
                .any(|pattern| matches_pattern(pattern, &name))
        })
        .collect();
    files.sort();
    files.dedup();
    let mut items = vec![json!({
        "id": format!("{language_id}:workspace"),
        "label": test.workspace_label,
        "kind": "workspace"
    })];
    items.extend(files.into_iter().map(|path| {
        json!({
            "id": format!("{language_id}:file:{path}"),
            "label": path,
            "kind": "file",
            "relativeFilePath": path
        })
    }));
    Ok(Value::Array(items))
}

fn test_plan(
    manifest: &DeclarativePluginManifest,
    language_id: &str,
    request: &TestPlanRequest,
) -> Validation<Value> {
    let test = test_template(manifest, language_id)?;
    let paths = checked_paths(&request.relative_project_file_paths)?;
    if !supports_project(test, &paths) {
        return Err(PluginRejection::new(
            "plugin.test.unsupportedProject",
            format!("The workspace is not a supported {language_id} test project."),
        ));
    }
    let (label, arguments) = match &request.scope {
        TestScope::Workspace => (
            test.workspace_label.clone(),
            expand(
                &test.workspace_arguments,
                &ExpansionValues {
                    file: None,
                    test_name: None,
                    user_arguments: &[],
                },
            ),
        ),
        TestScope::File { relative_file_path } => {
            let path = checked_path(relative_file_path)?;
            let arguments = expand(
                &test.file_arguments,
                &ExpansionValues {
                    file: Some(&path),
                    test_name: None,
                    user_arguments: &[],
                },
            );
            (file_name(&path).to_string(), arguments)
        }
        TestScope::TestCase {
            identifier,
            relative_file_path,
        } => {
            let name = identifier.trim();
            if name.is_empty() || name.contains('\n') || name.contains('\r') {
                return Err(PluginRejection::new(
                    "plugin.test.invalidIdentifier",
                    "The selected test identifier is invalid.",
                ));
            }
            let path = relative_file_path
                .as_deref()
                .map(checked_path)
                .transpose()?;
            let arguments = expand(
                &test.test_case_arguments,
                &ExpansionValues {
                    file: path.as_deref(),
                    test_name: Some(name),
                    user_arguments: &[],
                },
            );
            (name.to_string(), arguments)
        }
    };
    Ok(json!({
        "label": label,
        "frameworkID": test.framework_id,
        "executable": test.executable,
        "arguments": arguments,
        "workingDirectory": "."
    }))
}

fn test_template<'a>(
    manifest: &'a DeclarativePluginManifest,
    language_id: &str,
) -> Validation<&'a TestTemplate> {
    manifest
        .execution_provider(language_id)
        .and_then(|provider| provider.test.as_ref())
        .ok_or_else(|| unavailable(language_id, "test"))
}

fn supports_project(test: &TestTemplate, paths: &[String]) -> bool {
    paths.iter().any(|path| {
        test.project_markers
            .contains(&file_name(path).to_lowercase())
    })
}

fn expand(arguments: &[ArgumentTemplate], values: &ExpansionValues<'_>) -> Vec<String> {
    let mut result = Vec::new();
    for argument in arguments {
        match argument.condition() {
            Some(ArgumentCondition::FileSelected) if values.file.is_none() => continue,
            Some(ArgumentCondition::NoFileSelected) if values.file.is_some() => continue,
            _ => {}
        }
        // Validation guarantees the template parses and that every variable
        // it uses has a value in this context.
        let parts = parse_template(argument.value()).unwrap_or_default();
        if parts == [TemplatePart::Variable(TemplateVariable::UserArguments)] {
            result.extend(values.user_arguments.iter().cloned());
            continue;
        }
        let mut element = String::new();
        for part in parts {
            match part {
                TemplatePart::Text(text) => element.push_str(&text),
                TemplatePart::Variable(TemplateVariable::File) => {
                    element.push_str(&command_path(values.file.unwrap_or_default()))
                }
                TemplatePart::Variable(TemplateVariable::FileDirectory) => {
                    element.push_str(&directory_argument(values.file.unwrap_or_default()))
                }
                TemplatePart::Variable(TemplateVariable::TestName) => {
                    element.push_str(values.test_name.unwrap_or_default())
                }
                TemplatePart::Variable(TemplateVariable::TestNameRegex) => {
                    element.push_str(&regex_literal(values.test_name.unwrap_or_default()))
                }
                TemplatePart::Variable(TemplateVariable::UserArguments) => {}
            }
        }
        result.push(element);
    }
    result
}

/// A file name beginning with `-` would be parsed as an option by most
/// tools, so it is passed as an explicit relative path.
fn command_path(path: &str) -> String {
    if path.starts_with('-') {
        format!("./{path}")
    } else {
        path.to_string()
    }
}

/// The selected file's directory as a `./`-relative argument; `.` for a file
/// at the workspace root.
fn directory_argument(path: &str) -> String {
    match path.rsplit_once('/') {
        Some((directory, _)) if !directory.is_empty() => format!("./{directory}"),
        _ => ".".to_string(),
    }
}

/// Escapes regular-expression metacharacters so a test name matches only
/// literally, in both PCRE (PHPUnit) and RE2 (Go) syntax.
fn regex_literal(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        if "\\*?+[](){}^$|.".contains(character) {
            escaped.push('\\');
        }
        escaped.push(character);
    }
    escaped
}

fn matches_pattern(pattern: &str, name: &str) -> bool {
    let pieces: Vec<&str> = pattern.split('*').collect();
    if pieces.len() == 1 {
        return pattern == name;
    }
    let (first, last) = (pieces[0], pieces[pieces.len() - 1]);
    if !name.starts_with(first) || !name[first.len()..].ends_with(last) {
        return false;
    }
    let mut remainder = &name[first.len()..name.len() - last.len()];
    for piece in &pieces[1..pieces.len() - 1] {
        match remainder.find(piece) {
            Some(index) => remainder = &remainder[index + piece.len()..],
            None => return false,
        }
    }
    true
}

fn checked_path(value: &str) -> Validation<String> {
    // Paths are not trimmed: surrounding spaces are part of a real file name.
    if is_safe_relative_path(value) {
        Ok(value.to_string())
    } else {
        Err(PluginRejection::new(
            "plugin.path.invalid",
            "A path must stay inside the current workspace.",
        ))
    }
}

fn checked_paths(values: &[String]) -> Validation<Vec<String>> {
    values.iter().map(|value| checked_path(value)).collect()
}

fn unavailable(language_id: &str, operation: &str) -> PluginRejection {
    PluginRejection::new(
        "plugin.execution.unavailable",
        format!("The plugin does not provide {operation} support for {language_id}."),
    )
}

fn invalid(field: impl Into<String>, message: impl Into<String>) -> PluginRejection {
    PluginRejection::at("plugin.manifest.invalid", field, message)
}

fn template(field: impl Into<String>, message: impl Into<String>) -> PluginRejection {
    PluginRejection::at("plugin.template.invalid", field, message)
}

fn file_name(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

fn is_safe_relative_path(value: &str) -> bool {
    !value.is_empty()
        && !value.starts_with('/')
        && !value.contains('\0')
        && !value.contains('\\')
        && !value.split('/').any(|component| component == "..")
}

fn is_bare_command(value: &str) -> bool {
    !value.is_empty()
        && value != "."
        && value != ".."
        && !value.contains('/')
        && !value.contains('\\')
        && !value.contains('\0')
        && !value.chars().any(char::is_whitespace)
}

fn is_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.chars().all(|character| {
            character.is_ascii_lowercase() || character.is_ascii_digit() || character == '-'
        })
}

/// True for IDs reserved to Lithe's official plugins (`dev.lithe` and
/// `dev.lithe.*`). Third-party sources and unsigned packages may not use it.
pub(crate) fn is_official_namespace(id: &str) -> bool {
    id == OFFICIAL_PLUGIN_NAMESPACE || id.starts_with(&format!("{OFFICIAL_PLUGIN_NAMESPACE}."))
}

pub(crate) fn is_plugin_id(value: &str) -> bool {
    !value.is_empty()
        && value != "."
        && value != ".."
        && value.chars().all(|character| {
            character.is_ascii_lowercase() || character.is_ascii_digit() || ".-".contains(character)
        })
}

pub(crate) fn is_semantic_version(value: &str) -> bool {
    let parts: Vec<&str> = value.split('.').collect();
    parts.len() == 3
        && parts.iter().all(|part| {
            !part.is_empty() && part.chars().all(|character| character.is_ascii_digit())
        })
}

/// Trims and lowercases complete file names and markers. A leading `.` is
/// part of the name (`.toolrc`, `.env.example`) and is kept.
fn normalized_names(values: &[String]) -> Vec<String> {
    sorted_unique(
        values
            .iter()
            .filter_map(|value| {
                let name = value.trim().to_lowercase();
                (!name.is_empty()).then_some(name)
            })
            .collect(),
    )
}

/// Normalizes file extensions, where a leading `.` is optional notation:
/// `.php` and `php` both declare the `php` extension.
fn normalized_extensions(values: &[String]) -> Vec<String> {
    let names = normalized_names(values);
    sorted_unique(
        names
            .iter()
            .filter_map(|name| {
                let extension = name.strip_prefix('.').unwrap_or(name);
                (!extension.is_empty()).then(|| extension.to_string())
            })
            .collect(),
    )
}

fn sorted_unique(values: Vec<String>) -> Vec<String> {
    values
        .into_iter()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

// MARK: Command entry points

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ValidatePayload {
    manifest: Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlanPayload<Request> {
    manifest: Value,
    #[serde(rename = "languageID")]
    language_id: String,
    request: Request,
}

fn decode_payload<T: for<'de> Deserialize<'de>>(
    payload: Value,
    command: &str,
) -> Result<T, CoreError> {
    serde_json::from_value(payload).map_err(|error| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            format!("Invalid {command} payload"),
        )
        .with_details(error.to_string())
    })
}

fn outcome(result: Validation<(&'static str, Value)>) -> Value {
    match result {
        Ok((key, value)) => {
            let mut object = serde_json::Map::new();
            object.insert("status".to_string(), json!("ok"));
            object.insert(key.to_string(), value);
            Value::Object(object)
        }
        Err(rejection) => json!({ "status": "rejected", "error": rejection }),
    }
}

/// `plugins.declarative.validate`: returns `{status: "ok", plugin}` with the
/// normalized manifest, or `{status: "rejected", error}`.
pub fn validate_command(payload: Value) -> Result<Value, CoreError> {
    let payload: ValidatePayload = decode_payload(payload, "plugins.declarative.validate")?;
    Ok(outcome(validate_manifest_value(payload.manifest).and_then(
        |manifest| {
            serde_json::to_value(manifest)
                .map(|value| ("plugin", value))
                .map_err(|error| PluginRejection::new("plugin.manifest.invalid", error.to_string()))
        },
    )))
}

/// `plugins.declarative.runPlan`: expands the run template for one file.
pub fn run_plan_command(payload: Value) -> Result<Value, CoreError> {
    let payload: PlanPayload<RunPlanRequest> =
        decode_payload(payload, "plugins.declarative.runPlan")?;
    Ok(outcome(validate_manifest_value(payload.manifest).and_then(
        |manifest| {
            run_plan(&manifest, &payload.language_id, &payload.request).map(|plan| ("plan", plan))
        },
    )))
}

/// `plugins.declarative.discoverTests`: lists workspace and file test items.
pub fn discover_tests_command(payload: Value) -> Result<Value, CoreError> {
    let payload: PlanPayload<TestDiscoveryRequest> =
        decode_payload(payload, "plugins.declarative.discoverTests")?;
    Ok(outcome(validate_manifest_value(payload.manifest).and_then(
        |manifest| {
            discover_tests(&manifest, &payload.language_id, &payload.request)
                .map(|items| ("items", items))
        },
    )))
}

/// `plugins.declarative.testPlan`: expands the test template for one scope.
pub fn test_plan_command(payload: Value) -> Result<Value, CoreError> {
    let payload: PlanPayload<TestPlanRequest> =
        decode_payload(payload, "plugins.declarative.testPlan")?;
    Ok(outcome(validate_manifest_value(payload.manifest).and_then(
        |manifest| {
            test_plan(&manifest, &payload.language_id, &payload.request).map(|plan| ("plan", plan))
        },
    )))
}
