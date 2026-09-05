//! Maven reactor inspection, profile discovery, and source diagnostics.

use crate::protocol::{CoreError, ErrorCode};
use crate::protocol::{
    MavenDependenciesResponse, MavenDependencyResolutionResponse, MavenDependencyResponse,
    MavenDiagnosticResponse, MavenDiagnosticsResponse, MavenLaunchExecutableResponse,
    MavenLaunchPlanResponse, MavenModuleResponse, MavenProfileResponse, MavenScanResponse,
    MavenSourceRootKind, MavenSourceRootResponse,
};
use quick_xml::events::Event;
use quick_xml::Reader;
use regex::Regex;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::{BTreeSet, HashSet};
use std::fs;
use std::path::{Component, Path, PathBuf};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Workspace paths used to locate and inspect the owning Maven reactor.
pub struct MavenScanRequest {
    pub root: String,
    #[serde(default)]
    pub paths: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Maven process output to normalize into workspace diagnostics.
pub struct MavenDiagnosticsRequest {
    pub root: String,
    pub output: String,
}

const MAVEN_CONTEXT_VERSION: u32 = 1;
const MAVEN_DEPENDENCY_PLUGIN_GOAL: &str =
    "org.apache.maven.plugins:maven-dependency-plugin:3.8.1:tree";
const MAX_MAVEN_DEPENDENCY_OUTPUT_CHARACTERS: usize = 500_000;
const MAX_MAVEN_DEPENDENCY_NODES: usize = 10_000;
const MAX_MAVEN_DEPENDENCY_DEPTH: usize = 64;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Versioned Maven defaults merged by the platform before launch planning.
pub struct MavenLaunchContextRequest {
    pub version: u32,
    pub reactor_path: String,
    #[serde(default)]
    pub profiles: Vec<String>,
    #[serde(default)]
    pub settings_path: Option<String>,
    #[serde(default)]
    pub local_repository_path: Option<String>,
    #[serde(default)]
    pub skip_tests: bool,
    #[serde(default)]
    pub maven_executable_path: Option<String>,
    #[serde(default)]
    pub java_home_path: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Ordered Maven invocation tokens selected by a tool-window consumer.
///
/// The first token is a lifecycle or custom goal. Remaining tokens are passed
/// directly to Maven as arguments without shell interpretation.
pub struct MavenLaunchPlanRequest {
    pub root: String,
    pub context: MavenLaunchContextRequest,
    #[serde(default)]
    pub module: Option<String>,
    pub goals: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// One bounded dependency-tree invocation for a validated Maven module.
pub struct MavenDependencyPlanRequest {
    pub root: String,
    pub context: MavenLaunchContextRequest,
    #[serde(default)]
    pub module: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Captured Maven dependency-plugin output associated with one reactor module.
pub struct MavenDependenciesRequest {
    pub module_path: String,
    pub output: String,
}

#[derive(Debug, Clone)]
/// Validated Maven import settings consumed by the JDT LS adapter.
pub(crate) struct MavenJdtConfiguration {
    pub profiles: Vec<String>,
    pub settings_path: Option<String>,
    /// Workspace-relative reactor and recursive module directories.
    pub project_paths: Vec<String>,
    /// Workspace-relative Java source directories imported by JDT LS.
    pub source_paths: Vec<String>,
}

struct ValidatedMavenContext {
    reactor_path: String,
    canonical_reactor: PathBuf,
    profiles: Vec<String>,
    settings_path: Option<String>,
    local_repository_path: Option<String>,
    skip_tests: bool,
    maven_executable_path: Option<String>,
    java_home_path: Option<String>,
}

/// Produces a deterministic Maven plan without resolving a native executable.
pub fn launch_plan(request: MavenLaunchPlanRequest) -> Result<MavenLaunchPlanResponse, CoreError> {
    let arguments = normalized_tool_window_arguments(request.goals)?;
    launch_plan_with_arguments(
        request.root,
        request.context,
        request.module,
        arguments,
        true,
    )
}

/// Produces a fixed, non-recursive Maven dependency-tree invocation.
pub fn dependency_plan(
    request: MavenDependencyPlanRequest,
) -> Result<MavenLaunchPlanResponse, CoreError> {
    launch_plan_with_arguments(
        request.root,
        request.context,
        request.module,
        vec![
            MAVEN_DEPENDENCY_PLUGIN_GOAL.to_string(),
            "-Dverbose=true".to_string(),
            "-DoutputType=text".to_string(),
            "-Dstyle.color=never".to_string(),
            "-Duser.language=en".to_string(),
            "-Duser.country=US".to_string(),
        ],
        false,
    )
}

/// Applies a validated Maven context to Core-owned run/debug arguments.
///
/// Unlike the public tool-window command, the trailing arguments may contain
/// properties such as `-Dexec.mainClass`: those values were generated and
/// validated by the run-configuration domain rather than entered as goals.
pub(crate) fn launch_plan_with_arguments(
    root: String,
    context: MavenLaunchContextRequest,
    module: Option<String>,
    trailing_arguments: Vec<String>,
    also_make: bool,
) -> Result<MavenLaunchPlanResponse, CoreError> {
    let validated = validated_maven_context(&root, context)?;

    let module = module
        .as_deref()
        .map(|value| normalized_project_path(value, "Maven module"))
        .transpose()?;
    if let Some(module) = module.as_deref().filter(|value| *value != ".") {
        let declared = declared_modules(&validated.canonical_reactor)?;
        if !declared
            .iter()
            .any(|candidate| candidate.relative_path == module)
        {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Maven module is not part of the selected reactor",
            )
            .with_details(module));
        }
    }

    let arguments = maven_arguments(
        &validated.profiles,
        validated.settings_path.as_deref(),
        validated.local_repository_path.as_deref(),
        module.as_deref(),
        also_make,
        validated.skip_tests,
        &trailing_arguments,
    );
    let configuration_fingerprint = maven_context_fingerprint(
        &validated.reactor_path,
        &validated.profiles,
        validated.settings_path.as_deref(),
        validated.local_repository_path.as_deref(),
        validated.skip_tests,
        validated.maven_executable_path.as_deref(),
        validated.java_home_path.as_deref(),
    );

    Ok(MavenLaunchPlanResponse {
        version: MAVEN_CONTEXT_VERSION,
        executable: MavenLaunchExecutableResponse {
            toolchain: "project-maven".to_string(),
        },
        arguments,
        working_directory: validated.reactor_path,
        configuration_fingerprint,
    })
}

/// Resolves the same Maven profiles and settings for JDT LS project import.
pub(crate) fn jdt_configuration(
    root: &str,
    context: MavenLaunchContextRequest,
) -> Result<MavenJdtConfiguration, CoreError> {
    let validated = validated_maven_context(root, context)?;
    let declared = declared_modules(&validated.canonical_reactor)?;
    let mut project_paths = Vec::with_capacity(declared.len());
    let mut source_paths = BTreeSet::new();
    for module in declared {
        let module_path = {
            if module.relative_path == "." {
                validated.reactor_path.clone()
            } else if validated.reactor_path == "." {
                module.relative_path.clone()
            } else {
                format!("{}/{}", validated.reactor_path, module.relative_path)
            }
        };
        project_paths.push(module_path.clone());
        for source_root in module.source_roots {
            if !matches!(
                source_root.kind,
                MavenSourceRootKind::MainJava
                    | MavenSourceRootKind::TestJava
                    | MavenSourceRootKind::GeneratedMain
                    | MavenSourceRootKind::GeneratedTest
            ) {
                continue;
            }
            source_paths.insert(if module_path == "." {
                source_root.path
            } else {
                format!("{module_path}/{}", source_root.path)
            });
        }
    }
    Ok(MavenJdtConfiguration {
        profiles: validated.profiles,
        settings_path: validated.settings_path,
        project_paths,
        source_paths: source_paths.into_iter().collect(),
    })
}

fn validated_maven_context(
    root: &str,
    context: MavenLaunchContextRequest,
) -> Result<ValidatedMavenContext, CoreError> {
    let workspace_root = existing_root(root)?;
    if context.version != MAVEN_CONTEXT_VERSION {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Unsupported Maven context version",
        )
        .with_details(context.version.to_string()));
    }

    let reactor_path = normalized_project_path(&context.reactor_path, "Maven reactor")?;
    let reactor_root = if reactor_path == "." {
        workspace_root.clone()
    } else {
        workspace_root.join(&reactor_path)
    };
    let canonical_reactor = reactor_root.canonicalize().map_err(|_| {
        CoreError::new(ErrorCode::WorkspaceNotFound, "Maven reactor does not exist")
    })?;
    if !canonical_reactor.starts_with(&workspace_root)
        || !canonical_reactor.join("pom.xml").is_file()
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Maven reactor must contain pom.xml inside the workspace",
        ));
    }

    Ok(ValidatedMavenContext {
        reactor_path,
        canonical_reactor,
        profiles: normalized_profiles(context.profiles)?,
        settings_path: normalized_local_path(context.settings_path, "Maven settings")?,
        local_repository_path: normalized_local_path(
            context.local_repository_path,
            "Maven local repository",
        )?,
        skip_tests: context.skip_tests,
        maven_executable_path: normalized_local_path(
            context.maven_executable_path,
            "Maven executable",
        )?,
        java_home_path: normalized_local_path(context.java_home_path, "Maven JDK")?,
    })
}

/// Builds the shared Maven option prefix used by tool-window and run plans.
pub(crate) fn maven_arguments(
    profiles: &[String],
    settings_path: Option<&str>,
    local_repository_path: Option<&str>,
    module: Option<&str>,
    also_make: bool,
    skip_tests: bool,
    goals: &[String],
) -> Vec<String> {
    let mut arguments = vec!["-B".to_string(), "-ntp".to_string()];
    if !profiles.is_empty() {
        arguments.extend(["-P".to_string(), profiles.join(",")]);
    }
    if let Some(settings_path) = settings_path {
        arguments.extend(["-s".to_string(), settings_path.to_string()]);
    }
    if let Some(local_repository_path) = local_repository_path {
        arguments.push(format!("-Dmaven.repo.local={local_repository_path}"));
    }
    if let Some(module) = module.filter(|value| *value != ".") {
        arguments.extend(["-pl".to_string(), module.to_string()]);
        if also_make {
            arguments.push("-am".to_string());
        }
    }
    if skip_tests {
        arguments.push("-DskipTests".to_string());
    }
    arguments.extend(goals.iter().cloned());
    arguments
}

fn normalized_profiles(values: Vec<String>) -> Result<Vec<String>, CoreError> {
    let mut profiles = BTreeSet::new();
    for value in values {
        let profile = value.trim();
        if profile.is_empty() || profile.contains(',') || profile.chars().any(char::is_control) {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Maven profile ID is invalid",
            ));
        }
        profiles.insert(profile.to_string());
    }
    Ok(profiles.into_iter().collect())
}

fn normalized_tool_window_arguments(values: Vec<String>) -> Result<Vec<String>, CoreError> {
    if values.is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "At least one Maven goal is required",
        ));
    }

    let mut arguments = Vec::with_capacity(values.len());
    for (index, value) in values.into_iter().enumerate() {
        let argument = value.trim();
        if argument.is_empty() || argument.chars().any(char::is_control) {
            return Err(
                CoreError::new(ErrorCode::InvalidRequest, "Maven argument is invalid")
                    .with_details(argument),
            );
        }
        if index == 0 {
            let valid_goal = !argument.starts_with('-')
                && argument.chars().all(|character| {
                    character.is_ascii_alphanumeric() || ".:_-".contains(character)
                });
            if !valid_goal {
                return Err(
                    CoreError::new(ErrorCode::InvalidRequest, "Maven goal is invalid")
                        .with_details(argument),
                );
            }
        }
        arguments.push(argument.to_string());
    }
    Ok(arguments)
}

fn normalized_project_path(value: &str, label: &str) -> Result<String, CoreError> {
    let trimmed = value.trim();
    if trimmed == "." {
        return Ok(".".to_string());
    }
    normalize_relative_path(trimmed).ok_or_else(|| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            format!("{label} path is invalid"),
        )
    })
}

fn normalized_local_path(value: Option<String>, label: &str) -> Result<Option<String>, CoreError> {
    let Some(value) = value else { return Ok(None) };
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    if trimmed.chars().any(char::is_control) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            format!("{label} path is invalid"),
        ));
    }
    Ok(Some(trimmed.to_string()))
}

fn maven_context_fingerprint(
    reactor_path: &str,
    profiles: &[String],
    settings_path: Option<&str>,
    local_repository_path: Option<&str>,
    skip_tests: bool,
    maven_executable_path: Option<&str>,
    java_home_path: Option<&str>,
) -> String {
    let mut digest = Sha256::new();
    for value in [
        MAVEN_CONTEXT_VERSION.to_string(),
        reactor_path.to_string(),
        profiles.join(","),
        settings_path.unwrap_or_default().to_string(),
        local_repository_path.unwrap_or_default().to_string(),
        skip_tests.to_string(),
        maven_executable_path.unwrap_or_default().to_string(),
        java_home_path.unwrap_or_default().to_string(),
    ] {
        digest.update(value.as_bytes());
        digest.update([0]);
    }
    format!("sha256:{:x}", digest.finalize())
}

#[derive(Debug, Default)]
/// Parsed POM fields needed by reactor discovery and run-configuration detection.
struct Descriptor {
    group_id: Option<String>,
    artifact_id: Option<String>,
    version: Option<String>,
    packaging: String,
    build_directory: Option<String>,
    module_paths: Vec<String>,
    profiles: Vec<MavenProfileResponse>,
    plugins: Vec<String>,
    source_directory: Option<String>,
    test_source_directory: Option<String>,
    resource_directories: Vec<String>,
    test_resource_directories: Vec<String>,
    generated_source_directories: Vec<String>,
    generated_test_source_directories: Vec<String>,
}

#[derive(Debug, Default)]
/// Configuration buffered until the owning build plugin's `artifactId` is known.
struct PendingBuildPlugin {
    artifact_id: Option<String>,
    compiler_generated_source_directories: Vec<String>,
    compiler_generated_test_source_directories: Vec<String>,
    build_helper_source_directories: Vec<String>,
    build_helper_test_source_directories: Vec<String>,
}

/// One module of the declared build graph, flattened with the root first.
///
/// Callers inside the core read this instead of walking directories: Maven
/// modules are declared in `<modules>`, so a module may sit in a directory the
/// shared detector walk prunes -- one named `build` or `out` is invisible to a
/// directory-driven scan -- while a stray `pom.xml` outside the graph is not a
/// module at all.
#[derive(Debug, Clone)]
pub struct DeclaredModule {
    /// Project-relative, forward-slashed, `.` for the root module.
    pub relative_path: String,
    pub artifact_id: String,
    pub packaging: String,
    /// `artifactId` of every plugin the module applies in `<build><plugins>`.
    pub plugins: Vec<String>,
    /// Source roots parsed from this module's own POM.
    pub source_roots: Vec<MavenSourceRootResponse>,
}

impl DeclaredModule {
    /// Reports whether this module applies a build plugin directly.
    pub fn applies_plugin(&self, artifact_id: &str) -> bool {
        self.plugins.iter().any(|value| value == artifact_id)
    }

    /// `pom` packaging is an aggregator: it produces no artifact to run, so a
    /// plugin declared there configures its children rather than a service.
    pub fn is_aggregator(&self) -> bool {
        self.packaging == "pom"
    }
}

/// Reads the declared module graph, or an empty list when the root is not a
/// Maven project.
pub fn declared_modules(root: &Path) -> Result<Vec<DeclaredModule>, CoreError> {
    let Some(root_descriptor) = descriptor(&root.join("pom.xml"))? else {
        return Ok(Vec::new());
    };
    let mut modules = Vec::new();
    let mut visited = vec![root.to_path_buf()];
    collect_modules(root, root, root_descriptor, &mut modules, &mut visited);
    Ok(modules)
}

/// Flattens the graph depth-first. Unlike `module`, which builds the nested
/// response, a visited path is never released: a module reachable through two
/// parents is one module, and emitting it twice would produce two run
/// configurations for one service.
fn collect_modules(
    root: &Path,
    directory: &Path,
    current: Descriptor,
    modules: &mut Vec<DeclaredModule>,
    visited: &mut Vec<PathBuf>,
) {
    let relative_path = directory
        .strip_prefix(root)
        .ok()
        .map(|value| value.to_string_lossy().replace('\\', "/"))
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| ".".to_string());
    let current_source_roots = source_roots(Some(&current));
    modules.push(DeclaredModule {
        relative_path,
        artifact_id: current.artifact_id.unwrap_or_else(|| {
            directory
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or("module")
                .to_string()
        }),
        packaging: current.packaging,
        plugins: current.plugins,
        source_roots: current_source_roots,
    });
    for raw_path in &current.module_paths {
        let Some(relative) = normalize_relative_path(raw_path) else {
            continue;
        };
        let child = directory.join(&relative).clean();
        if visited.iter().any(|path| path == &child) || !child.starts_with(root) {
            continue;
        }
        let Ok(Some(child_descriptor)) = descriptor(&child.join("pom.xml")) else {
            continue;
        };
        visited.push(child.clone());
        collect_modules(root, &child, child_descriptor, modules, visited);
    }
}

/// Reads a Maven reactor and returns its nested module, profile, and identity data.
pub fn scan(request: MavenScanRequest) -> Result<Option<MavenScanResponse>, CoreError> {
    let workspace_root = existing_root(&request.root)?;
    let Some((root, relative_path)) = maven_root(&workspace_root, &request.paths)? else {
        return Ok(None);
    };
    let pom = root.join("pom.xml");
    let Some(root_descriptor) = descriptor(&pom)? else {
        return Ok(None);
    };

    let mut visited = vec![root.clone()];
    let modules = root_descriptor
        .module_paths
        .iter()
        .filter_map(|path| module(&root, &root, path, &mut visited))
        .collect();
    let source_roots = source_roots(Some(&root_descriptor));

    Ok(Some(MavenScanResponse {
        relative_path,
        group_id: root_descriptor.group_id,
        artifact_id: root_descriptor.artifact_id.unwrap_or_else(|| {
            root.file_name()
                .and_then(|v| v.to_str())
                .unwrap_or("Project")
                .to_string()
        }),
        version: root_descriptor.version,
        packaging: root_descriptor.packaging,
        source_roots,
        modules,
        profiles: root_descriptor.profiles,
        has_wrapper: has_wrapper(&root),
    }))
}

/// Selects one parseable Maven root from visible workspace paths and their
/// ancestors. The Maven project scan currently represents one reactor, so the
/// shallowest valid descriptor wins; lexical ordering makes independent candidates
/// deterministic. Parse failures are retained only when no candidate is valid.
pub(crate) fn maven_root(
    root: &Path,
    paths: &[String],
) -> Result<Option<(PathBuf, String)>, CoreError> {
    let canonical_root = root.canonicalize().map_err(CoreError::from)?;
    let mut candidate_directories = BTreeSet::from([PathBuf::new()]);
    for path in paths
        .iter()
        .filter_map(|path| normalize_relative_path(path))
    {
        let mut directory = Path::new(&path).parent();
        while let Some(relative) = directory {
            candidate_directories.insert(relative.to_path_buf());
            if relative.as_os_str().is_empty() {
                break;
            }
            directory = relative.parent();
        }
    }

    let mut candidates = candidate_directories
        .into_iter()
        .filter_map(|directory| {
            let candidate = root.join(&directory);
            if !candidate.join("pom.xml").is_file() {
                return None;
            }
            let canonical_candidate = candidate.canonicalize().ok()?;
            if !canonical_candidate.starts_with(&canonical_root) {
                return None;
            }
            let relative_path = if directory.as_os_str().is_empty() {
                ".".to_string()
            } else {
                directory.to_string_lossy().replace('\\', "/")
            };
            let depth = directory.components().count();
            Some((candidate, relative_path, depth))
        })
        .collect::<Vec<_>>();
    candidates.sort_by(|left, right| {
        left.2
            .cmp(&right.2)
            .then_with(|| left.1.to_lowercase().cmp(&right.1.to_lowercase()))
            .then_with(|| left.1.cmp(&right.1))
    });
    candidates.dedup_by(|left, right| left.0 == right.0);

    let mut first_parse_error = None;
    for (path, relative_path, _) in candidates {
        match descriptor(&path.join("pom.xml")) {
            Ok(Some(_)) => return Ok(Some((path, relative_path))),
            Ok(None) => {}
            Err(error) if first_parse_error.is_none() => first_parse_error = Some(error),
            Err(_) => {}
        }
    }
    match first_parse_error {
        Some(error) => Err(error),
        None => Ok(None),
    }
}

/// Parses Maven compiler output into stable workspace-relative diagnostics.
pub fn diagnostics(
    request: MavenDiagnosticsRequest,
) -> Result<MavenDiagnosticsResponse, CoreError> {
    let _ = existing_root(&request.root)?;
    let expression = Regex::new(r"\[(ERROR|WARNING)]\s+(.*?):\[(\d+)(?:,(\d+))?]\s+(.*)")
        .expect("static Maven diagnostic expression is valid");
    let mut seen = HashSet::new();
    let issues = request
        .output
        .lines()
        .filter_map(|line| {
            let captures = expression.captures(line)?;
            let path = captures.get(2)?.as_str().trim().to_string();
            let line_number = captures.get(3)?.as_str().parse().ok()?;
            let column = captures
                .get(4)
                .and_then(|value| value.as_str().parse().ok());
            let severity = captures.get(1)?.as_str().to_lowercase();
            let message = captures.get(5)?.as_str().trim().to_string();
            let key = (
                path.clone(),
                line_number,
                column,
                severity.clone(),
                message.clone(),
            );
            seen.insert(key).then_some(MavenDiagnosticResponse {
                path,
                line: line_number,
                column,
                severity,
                message,
            })
        })
        .collect();
    Ok(MavenDiagnosticsResponse { issues })
}

#[derive(Clone)]
struct ParsedDependency {
    depth: usize,
    node: MavenDependencyResponse,
}

/// Parses bounded Maven dependency-plugin text into a deterministic tree.
pub fn dependencies(
    request: MavenDependenciesRequest,
) -> Result<MavenDependenciesResponse, CoreError> {
    if request
        .output
        .chars()
        .nth(MAX_MAVEN_DEPENDENCY_OUTPUT_CHARACTERS)
        .is_some()
    {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Maven dependency output exceeds the supported limit",
        )
        .with_details(format!(
            "maximumCharacters={MAX_MAVEN_DEPENDENCY_OUTPUT_CHARACTERS}"
        )));
    }
    let module_path = normalized_project_path(&request.module_path, "Maven module")?;
    let ansi =
        Regex::new(r"\x1b\[[0-?]*[ -/]*[@-~]").expect("static ANSI escape expression is valid");
    let mut parsed = Vec::new();
    for raw_line in request.output.lines() {
        let line = ansi.replace_all(raw_line, "");
        let Some(entry) = parse_dependency_line(&line, &module_path)? else {
            continue;
        };
        if parsed.len() == MAX_MAVEN_DEPENDENCY_NODES {
            return Err(CoreError::new(
                ErrorCode::ParseFailed,
                "Maven dependency count exceeds the supported limit",
            )
            .with_details(format!("maximumNodes={MAX_MAVEN_DEPENDENCY_NODES}")));
        }
        parsed.push(entry);
    }

    let mut cursor = 0;
    let dependencies = if parsed.is_empty() {
        Vec::new()
    } else {
        if parsed[0].depth != 0 {
            return Err(invalid_dependency_structure());
        }
        let dependencies = build_dependency_level(&parsed, &mut cursor, 0)?;
        if cursor != parsed.len() {
            return Err(invalid_dependency_structure());
        }
        dependencies
    };
    Ok(MavenDependenciesResponse {
        module_path,
        dependencies,
    })
}

fn parse_dependency_line(
    raw_line: &str,
    module_path: &str,
) -> Result<Option<ParsedDependency>, CoreError> {
    let trimmed = raw_line.trim();
    let line = trimmed
        .strip_prefix("[INFO]")
        .and_then(|value| value.strip_prefix(' '))
        .unwrap_or(trimmed);
    let marker = match (line.find("+- "), line.find("\\- ")) {
        (Some(left), Some(right)) => left.min(right),
        (Some(index), None) | (None, Some(index)) => index,
        (None, None) => return Ok(None),
    };
    let prefix = &line[..marker];
    let mut chunks = prefix.as_bytes().chunks_exact(3);
    if !chunks.all(|chunk| chunk == b"|  " || chunk == b"   ") || !chunks.remainder().is_empty() {
        return Ok(None);
    }
    let depth = prefix.len() / 3;
    if depth >= MAX_MAVEN_DEPENDENCY_DEPTH {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Maven dependency tree exceeds the supported depth",
        )
        .with_details(format!("maximumDepth={MAX_MAVEN_DEPENDENCY_DEPTH}")));
    }

    let value = line[(marker + 3)..].trim();
    // Verbose dependency-plugin output wraps omitted nodes as
    // `(coordinate - annotation)`, while resolved nodes use
    // `coordinate (annotation)`. Normalize both forms before splitting the
    // Maven coordinate so duplicate/conflict markers remain observable.
    let (coordinate, annotation) = if let Some(inner) = value
        .strip_prefix('(')
        .and_then(|value| value.strip_suffix(')'))
    {
        inner
            .split_once(" - ")
            .map(|(coordinate, annotation)| (coordinate.trim(), Some(annotation.trim())))
            .unwrap_or((inner.trim(), None))
    } else {
        value
            .split_once(" (")
            .map(|(coordinate, annotation)| (coordinate, Some(annotation.trim_end_matches(')'))))
            .unwrap_or((value, None))
    };
    let parts = coordinate.split(':').collect::<Vec<_>>();
    let (group_id, artifact_id, artifact_type, classifier, version, scope) = match parts.as_slice()
    {
        [group_id, artifact_id, artifact_type, version, scope] => (
            *group_id,
            *artifact_id,
            *artifact_type,
            None,
            *version,
            *scope,
        ),
        [group_id, artifact_id, artifact_type, classifier, version, scope] => (
            *group_id,
            *artifact_id,
            *artifact_type,
            Some(*classifier),
            *version,
            *scope,
        ),
        _ => return Ok(None),
    };
    if [group_id, artifact_id, artifact_type, version, scope]
        .iter()
        .any(|value| value.trim().is_empty())
        || classifier.is_some_and(|value| value.trim().is_empty())
    {
        return Ok(None);
    }

    let (resolution, selected_version) = dependency_resolution(annotation);
    Ok(Some(ParsedDependency {
        depth,
        node: MavenDependencyResponse {
            module_path: module_path.to_string(),
            group_id: group_id.to_string(),
            artifact_id: artifact_id.to_string(),
            version: version.to_string(),
            r#type: artifact_type.to_string(),
            classifier: classifier.map(str::to_string),
            scope: scope.to_string(),
            resolution,
            selected_version,
            children: Vec::new(),
        },
    }))
}

fn dependency_resolution(
    annotation: Option<&str>,
) -> (MavenDependencyResolutionResponse, Option<String>) {
    let Some(annotation) = annotation else {
        return (MavenDependencyResolutionResponse::Resolved, None);
    };
    let normalized = annotation.to_ascii_lowercase();
    const CONFLICT: &str = "omitted for conflict with ";
    if let Some(index) = normalized.find(CONFLICT) {
        let selected_version = annotation[(index + CONFLICT.len())..]
            .split_whitespace()
            .next()
            .map(|value| value.trim_end_matches([',', ')']).to_string())
            .filter(|value| !value.is_empty());
        return (
            MavenDependencyResolutionResponse::OmittedConflict,
            selected_version,
        );
    }
    if normalized.contains("omitted for duplicate") {
        return (MavenDependencyResolutionResponse::OmittedDuplicate, None);
    }
    (MavenDependencyResolutionResponse::Resolved, None)
}

fn build_dependency_level(
    parsed: &[ParsedDependency],
    cursor: &mut usize,
    depth: usize,
) -> Result<Vec<MavenDependencyResponse>, CoreError> {
    let mut dependencies = Vec::new();
    while *cursor < parsed.len() {
        let entry_depth = parsed[*cursor].depth;
        if entry_depth < depth {
            break;
        }
        if entry_depth > depth {
            return Err(invalid_dependency_structure());
        }
        let mut dependency = parsed[*cursor].node.clone();
        *cursor += 1;
        if *cursor < parsed.len() {
            let next_depth = parsed[*cursor].depth;
            if next_depth > depth + 1 {
                return Err(invalid_dependency_structure());
            }
            if next_depth == depth + 1 {
                dependency.children = build_dependency_level(parsed, cursor, depth + 1)?;
            }
        }
        sort_dependencies(&mut dependency.children);
        dependencies.push(dependency);
    }
    sort_dependencies(&mut dependencies);
    Ok(dependencies)
}

fn sort_dependencies(dependencies: &mut [MavenDependencyResponse]) {
    dependencies.sort_by(|left, right| {
        (
            &left.group_id,
            &left.artifact_id,
            &left.r#type,
            &left.classifier,
            &left.version,
            &left.scope,
        )
            .cmp(&(
                &right.group_id,
                &right.artifact_id,
                &right.r#type,
                &right.classifier,
                &right.version,
                &right.scope,
            ))
    });
}

fn invalid_dependency_structure() -> CoreError {
    CoreError::new(
        ErrorCode::ParseFailed,
        "Maven dependency tree structure is invalid",
    )
}

fn module(
    root: &Path,
    base: &Path,
    raw_path: &str,
    visited: &mut Vec<PathBuf>,
) -> Option<MavenModuleResponse> {
    let relative = normalize_relative_path(raw_path)?;
    let module_path = base.join(&relative).clean();
    if visited.iter().any(|path| path == &module_path) || !module_path.starts_with(root) {
        return None;
    }
    visited.push(module_path.clone());
    let descriptor = descriptor(&module_path.join("pom.xml")).ok().flatten();
    let child_modules = descriptor
        .as_ref()
        .map(|value| {
            value
                .module_paths
                .iter()
                .filter_map(|path| module(root, &module_path, path, visited))
                .collect()
        })
        .unwrap_or_default();
    visited.pop();

    Some(MavenModuleResponse {
        relative_path: module_path
            .strip_prefix(root)
            .ok()?
            .to_string_lossy()
            .replace('\\', "/"),
        group_id: descriptor.as_ref().and_then(|value| value.group_id.clone()),
        artifact_id: descriptor
            .as_ref()
            .and_then(|value| value.artifact_id.clone())
            .unwrap_or_else(|| {
                module_path
                    .file_name()
                    .and_then(|v| v.to_str())
                    .unwrap_or("module")
                    .to_string()
            }),
        version: descriptor.as_ref().and_then(|value| value.version.clone()),
        packaging: descriptor
            .as_ref()
            .map(|value| value.packaging.clone())
            .unwrap_or_else(|| "jar".to_string()),
        source_roots: source_roots(descriptor.as_ref()),
        modules: child_modules,
    })
}

fn source_roots(descriptor: Option<&Descriptor>) -> Vec<MavenSourceRootResponse> {
    let Some(descriptor) = descriptor else {
        return Vec::new();
    };

    let mut roots = BTreeSet::new();
    let build_directory = descriptor.build_directory.as_deref().unwrap_or("target");
    let has_compiled_output = descriptor.packaging != "pom";
    if has_compiled_output {
        add_source_root(
            &mut roots,
            MavenSourceRootKind::MainJava,
            descriptor
                .source_directory
                .as_deref()
                .unwrap_or("src/main/java"),
            Some(build_directory),
        );
        if descriptor.resource_directories.is_empty() {
            add_source_root(
                &mut roots,
                MavenSourceRootKind::MainResources,
                "src/main/resources",
                Some(build_directory),
            );
        } else {
            for path in &descriptor.resource_directories {
                add_source_root(
                    &mut roots,
                    MavenSourceRootKind::MainResources,
                    path,
                    Some(build_directory),
                );
            }
        }
        add_source_root(
            &mut roots,
            MavenSourceRootKind::TestJava,
            descriptor
                .test_source_directory
                .as_deref()
                .unwrap_or("src/test/java"),
            Some(build_directory),
        );
        if descriptor.test_resource_directories.is_empty() {
            add_source_root(
                &mut roots,
                MavenSourceRootKind::TestResources,
                "src/test/resources",
                Some(build_directory),
            );
        } else {
            for path in &descriptor.test_resource_directories {
                add_source_root(
                    &mut roots,
                    MavenSourceRootKind::TestResources,
                    path,
                    Some(build_directory),
                );
            }
        }
    }

    if has_compiled_output {
        let default_generated_main = format!("{build_directory}/generated-sources");
        let generated_main = if descriptor.generated_source_directories.is_empty() {
            vec![default_generated_main.as_str()]
        } else {
            descriptor
                .generated_source_directories
                .iter()
                .map(String::as_str)
                .collect()
        };
        for path in generated_main {
            add_source_root(
                &mut roots,
                MavenSourceRootKind::GeneratedMain,
                path,
                Some(build_directory),
            );
        }

        let default_generated_test = format!("{build_directory}/generated-test-sources");
        let generated_test = if descriptor.generated_test_source_directories.is_empty() {
            vec![default_generated_test.as_str()]
        } else {
            descriptor
                .generated_test_source_directories
                .iter()
                .map(String::as_str)
                .collect()
        };
        for path in generated_test {
            add_source_root(
                &mut roots,
                MavenSourceRootKind::GeneratedTest,
                path,
                Some(build_directory),
            );
        }
    }

    roots
        .into_iter()
        .map(|(rank, path)| MavenSourceRootResponse {
            path,
            kind: source_root_kind(rank),
        })
        .collect()
}

fn add_source_root(
    roots: &mut BTreeSet<(u8, String)>,
    kind: MavenSourceRootKind,
    raw_path: &str,
    build_directory: Option<&str>,
) {
    if let Some(path) = normalize_maven_source_path(raw_path, build_directory) {
        roots.insert((source_root_kind_rank(kind), path));
    }
}

fn source_root_kind_rank(kind: MavenSourceRootKind) -> u8 {
    match kind {
        MavenSourceRootKind::MainJava => 0,
        MavenSourceRootKind::MainResources => 1,
        MavenSourceRootKind::TestJava => 2,
        MavenSourceRootKind::TestResources => 3,
        MavenSourceRootKind::GeneratedMain => 4,
        MavenSourceRootKind::GeneratedTest => 5,
    }
}

fn source_root_kind(rank: u8) -> MavenSourceRootKind {
    match rank {
        0 => MavenSourceRootKind::MainJava,
        1 => MavenSourceRootKind::MainResources,
        2 => MavenSourceRootKind::TestJava,
        3 => MavenSourceRootKind::TestResources,
        4 => MavenSourceRootKind::GeneratedMain,
        _ => MavenSourceRootKind::GeneratedTest,
    }
}

fn normalize_maven_source_path(raw_path: &str, build_directory: Option<&str>) -> Option<String> {
    let mut value = raw_path.trim().replace('\\', "/");
    value = value
        .replace("${project.basedir}", ".")
        .replace("${basedir}", ".");
    if value.contains("${project.build.directory}") {
        let build_directory = normalize_build_directory(build_directory)?;
        value = value.replace("${project.build.directory}", &build_directory);
    }
    normalize_maven_path_value(&value)
}

fn normalize_build_directory(raw_path: Option<&str>) -> Option<String> {
    let mut value = raw_path.unwrap_or("target").trim().replace('\\', "/");
    value = value
        .replace("${project.basedir}", ".")
        .replace("${basedir}", ".");
    normalize_maven_path_value(&value)
}

fn normalize_maven_path_value(raw_path: &str) -> Option<String> {
    let mut value = raw_path.trim().replace('\\', "/");
    if value.contains("${") || value.contains('}') {
        return None;
    }
    while let Some(stripped) = value.strip_prefix("./") {
        value = stripped.to_string();
    }
    let path = Path::new(&value);
    let is_windows_absolute = value.as_bytes().get(1).is_some_and(|byte| *byte == b':');
    if value.is_empty()
        || path.is_absolute()
        || is_windows_absolute
        || path.components().any(|component| {
            matches!(
                component,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
    {
        return None;
    }
    let normalized = value.trim_matches('/').to_string();
    if normalized.is_empty()
        || normalized
            .split('/')
            .any(|component| component.is_empty() || component == "." || component == "..")
    {
        return None;
    }
    Some(normalized)
}

fn descriptor(path: &Path) -> Result<Option<Descriptor>, CoreError> {
    let Ok(data) = fs::read(path) else {
        return Ok(None);
    };
    let mut reader = Reader::from_reader(data.as_slice());
    reader.config_mut().trim_text(true);
    let mut buffer = Vec::new();
    let mut stack: Vec<(String, String)> = Vec::new();
    let mut value = Descriptor {
        packaging: "jar".to_string(),
        ..Descriptor::default()
    };
    let mut profile_id = None;
    let mut profile_active_by_default = false;
    let mut pending_build_plugin = None;

    loop {
        match reader.read_event_into(&mut buffer) {
            Ok(Event::Start(event)) => {
                let name = local_name(event.name().as_ref());
                let starts_build_plugin = name == "plugin"
                    && stack.len() == 3
                    && stack[0].0 == "project"
                    && stack[1].0 == "build"
                    && stack[2].0 == "plugins";
                stack.push((name.clone(), String::new()));
                if starts_build_plugin {
                    pending_build_plugin = Some(PendingBuildPlugin::default());
                }
                if name == "profile" {
                    profile_id = None;
                    profile_active_by_default = false;
                }
            }
            Ok(Event::Empty(event)) => {
                let name = local_name(event.name().as_ref());
                if name == "module" {
                    value.module_paths.push(String::new());
                }
            }
            Ok(Event::Text(event)) => {
                if let Some((_, text)) = stack.last_mut() {
                    let decoded = event.unescape().map_err(|error| {
                        CoreError::new(ErrorCode::ParseFailed, "Could not decode pom.xml")
                            .with_details(error.to_string())
                    })?;
                    text.push_str(&decoded);
                }
            }
            Ok(Event::End(event)) => {
                let name = local_name(event.name().as_ref());
                let Some((_, raw_text)) = stack.pop() else {
                    return Err(CoreError::new(ErrorCode::ParseFailed, "Malformed pom.xml"));
                };
                let text = raw_text.trim().to_string();
                let path = stack
                    .iter()
                    .map(|(part, _)| part.as_str())
                    .chain(std::iter::once(name.as_str()))
                    .collect::<Vec<_>>()
                    .join("/");
                match path.as_str() {
                    "project/groupId" | "project/parent/groupId" => {
                        if value.group_id.is_none() || path == "project/groupId" {
                            value.group_id = non_empty(text.clone());
                        }
                    }
                    "project/artifactId" => value.artifact_id = non_empty(text.clone()),
                    "project/version" | "project/parent/version" => {
                        if value.version.is_none() || path == "project/version" {
                            value.version = non_empty(text.clone());
                        }
                    }
                    "project/packaging" => {
                        value.packaging =
                            non_empty(text.clone()).unwrap_or_else(|| "jar".to_string())
                    }
                    "project/build/directory" => {
                        value.build_directory = non_empty(text.clone())
                    }
                    "project/build/sourceDirectory" => {
                        value.source_directory = non_empty(text.clone())
                    }
                    "project/build/testSourceDirectory" => {
                        value.test_source_directory = non_empty(text.clone())
                    }
                    "project/build/resources/resource/directory" => {
                        if let Some(directory) = non_empty(text.clone()) {
                            value.resource_directories.push(directory);
                        }
                    }
                    "project/build/testResources/testResource/directory" => {
                        if let Some(directory) = non_empty(text.clone()) {
                            value.test_resource_directories.push(directory);
                        }
                    }
                    "project/build/plugins/plugin/configuration/generatedSourcesDirectory"
                    | "project/build/plugins/plugin/executions/execution/configuration/generatedSourcesDirectory" => {
                        if let Some(directory) = non_empty(text.clone()) {
                            if let Some(plugin) = pending_build_plugin.as_mut() {
                                plugin
                                    .compiler_generated_source_directories
                                    .push(directory);
                            }
                        }
                    }
                    "project/build/plugins/plugin/configuration/generatedTestSourcesDirectory"
                    | "project/build/plugins/plugin/executions/execution/configuration/generatedTestSourcesDirectory" => {
                        if let Some(directory) = non_empty(text.clone()) {
                            if let Some(plugin) = pending_build_plugin.as_mut() {
                                plugin
                                    .compiler_generated_test_source_directories
                                    .push(directory);
                            }
                        }
                    }
                    "project/build/plugins/plugin/configuration/sources/source"
                    | "project/build/plugins/plugin/executions/execution/configuration/sources/source" => {
                        if let Some(directory) = non_empty(text.clone()) {
                            if let Some(plugin) = pending_build_plugin.as_mut() {
                                plugin.build_helper_source_directories.push(directory);
                            }
                        }
                    }
                    "project/build/plugins/plugin/configuration/testSources/testSource"
                    | "project/build/plugins/plugin/executions/execution/configuration/testSources/testSource" => {
                        if let Some(directory) = non_empty(text.clone()) {
                            if let Some(plugin) = pending_build_plugin.as_mut() {
                                plugin.build_helper_test_source_directories.push(directory);
                            }
                        }
                    }
                    "project/modules/module" => {
                        if let Some(module) = non_empty(text.clone()) {
                            value.module_paths.push(module);
                        }
                    }
                    // Only `<build><plugins>` counts. A plugin under
                    // `<pluginManagement>` pins a version for children without
                    // applying it, and one under `<reporting>` never runs.
                    "project/build/plugins/plugin/artifactId" => {
                        if let Some(plugin) = pending_build_plugin.as_mut() {
                            plugin.artifact_id = non_empty(text.clone());
                        }
                    }
                    "project/build/plugins/plugin" => {
                        if let Some(plugin) = pending_build_plugin.take() {
                            if let Some(artifact_id) = plugin.artifact_id {
                                match artifact_id.as_str() {
                                    "maven-compiler-plugin" => {
                                        value.generated_source_directories.extend(
                                            plugin.compiler_generated_source_directories,
                                        );
                                        value.generated_test_source_directories.extend(
                                            plugin.compiler_generated_test_source_directories,
                                        );
                                    }
                                    "build-helper-maven-plugin" => {
                                        value.generated_source_directories
                                            .extend(plugin.build_helper_source_directories);
                                        value.generated_test_source_directories
                                            .extend(plugin.build_helper_test_source_directories);
                                    }
                                    _ => {}
                                }
                                value.plugins.push(artifact_id);
                            }
                        }
                    }
                    "project/profiles/profile/id" => profile_id = non_empty(text.clone()),
                    "project/profiles/profile/activation/activeByDefault" => {
                        profile_active_by_default = text.eq_ignore_ascii_case("true")
                    }
                    "project/profiles/profile" => {
                        if let Some(id) = profile_id.take() {
                            if !value.profiles.iter().any(|profile| profile.id == id) {
                                value.profiles.push(MavenProfileResponse {
                                    id,
                                    is_active_by_default: profile_active_by_default,
                                });
                            }
                        }
                    }
                    _ => {}
                }
            }
            Ok(Event::Eof) => break,
            Err(error) => {
                return Err(
                    CoreError::new(ErrorCode::ParseFailed, "Could not parse pom.xml")
                        .with_details(error.to_string()),
                )
            }
            _ => {}
        }
        buffer.clear();
    }
    if stack.is_empty() {
        Ok(Some(value))
    } else {
        Err(CoreError::new(ErrorCode::ParseFailed, "Malformed pom.xml"))
    }
}

fn existing_root(value: &str) -> Result<PathBuf, CoreError> {
    let path = PathBuf::from(value);
    let metadata = fs::metadata(&path)
        .map_err(|_| CoreError::new(ErrorCode::WorkspaceNotFound, "Workspace does not exist"))?;
    if !metadata.is_dir() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Workspace root must be a directory",
        ));
    }
    path.canonicalize().map_err(CoreError::from)
}

fn normalize_relative_path(value: &str) -> Option<String> {
    let path = Path::new(value.trim());
    if path.as_os_str().is_empty() || path.is_absolute() {
        return None;
    }
    if path.components().any(|component| {
        matches!(
            component,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        )
    }) {
        return None;
    }
    let value = path.to_string_lossy().replace('\\', "/");
    (!value.is_empty()).then_some(value.trim_matches('/').to_string())
}

fn local_name(value: &[u8]) -> String {
    String::from_utf8_lossy(value)
        .rsplit(':')
        .next()
        .unwrap_or_default()
        .to_string()
}

fn non_empty(value: String) -> Option<String> {
    (!value.is_empty()).then_some(value)
}

fn has_wrapper(root: &Path) -> bool {
    let unix = root.join("mvnw");
    let windows = root.join("mvnw.cmd");
    windows.is_file()
        || fs::metadata(unix)
            .map(|metadata| {
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
                }
                #[cfg(not(unix))]
                {
                    metadata.is_file()
                }
            })
            .unwrap_or(false)
}

trait CleanPath {
    fn clean(self) -> PathBuf;
}

impl CleanPath for PathBuf {
    fn clean(self) -> PathBuf {
        let mut result = PathBuf::new();
        for component in self.components() {
            match component {
                Component::CurDir => {}
                Component::ParentDir => {
                    result.pop();
                }
                other => result.push(other.as_os_str()),
            }
        }
        result
    }
}
