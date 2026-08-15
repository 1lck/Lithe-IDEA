//! Maven reactor inspection, profile discovery, and source diagnostics.

use crate::protocol::{CoreError, ErrorCode};
use crate::protocol::{
    MavenDiagnosticResponse, MavenDiagnosticsResponse, MavenModuleResponse, MavenProfileResponse,
    MavenScanResponse,
};
use quick_xml::events::Event;
use quick_xml::Reader;
use regex::Regex;
use serde::Deserialize;
use std::collections::HashSet;
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

#[derive(Debug, Default)]
/// Parsed POM fields needed by reactor discovery and run-configuration detection.
struct Descriptor {
    group_id: Option<String>,
    artifact_id: Option<String>,
    version: Option<String>,
    packaging: String,
    module_paths: Vec<String>,
    profiles: Vec<MavenProfileResponse>,
    plugins: Vec<String>,
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
        modules,
        profiles: root_descriptor.profiles,
        has_wrapper: has_wrapper(&root),
    }))
}

/// Selects one parseable Maven root from visible workspace paths. The
/// application model currently represents one Maven reactor, so the shallowest
/// valid descriptor wins; lexical ordering makes independent candidates
/// deterministic. Parse failures are retained only when no candidate is valid.
pub(crate) fn maven_root(
    root: &Path,
    paths: &[String],
) -> Result<Option<(PathBuf, String)>, CoreError> {
    let canonical_root = root.canonicalize().map_err(CoreError::from)?;
    let mut candidates = Vec::new();
    if canonical_root.join("pom.xml").is_file() {
        candidates.push((root.to_path_buf(), ".".to_string(), 0));
    }

    candidates.extend(
        paths
            .iter()
            .filter_map(|path| normalize_relative_path(path))
            .filter(|path| {
                Path::new(path)
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.eq_ignore_ascii_case("pom.xml"))
            })
            .filter_map(|path| {
                let directory = Path::new(&path).parent()?;
                let relative_path = if directory.as_os_str().is_empty() {
                    ".".to_string()
                } else {
                    directory.to_string_lossy().replace('\\', "/")
                };
                let candidate = root.join(directory);
                let canonical_candidate = candidate.canonicalize().ok()?;
                if !canonical_candidate.starts_with(&canonical_root) {
                    return None;
                }
                canonical_candidate.join("pom.xml").is_file().then_some((
                    candidate,
                    relative_path,
                    directory.components().count(),
                ))
            }),
    );
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
        modules: child_modules,
    })
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

    loop {
        match reader.read_event_into(&mut buffer) {
            Ok(Event::Start(event)) => {
                let name = local_name(event.name().as_ref());
                stack.push((name.clone(), String::new()));
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
                    "project/modules/module" => {
                        if let Some(module) = non_empty(text.clone()) {
                            value.module_paths.push(module);
                        }
                    }
                    // Only `<build><plugins>` counts. A plugin under
                    // `<pluginManagement>` pins a version for children without
                    // applying it, and one under `<reporting>` never runs.
                    "project/build/plugins/plugin/artifactId" => {
                        if let Some(artifact) = non_empty(text.clone()) {
                            value.plugins.push(artifact);
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
