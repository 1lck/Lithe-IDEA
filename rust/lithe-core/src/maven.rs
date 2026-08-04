use crate::error::{CoreError, ErrorCode};
use crate::model::{
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
pub struct MavenScanRequest {
    pub root: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MavenDiagnosticsRequest {
    pub root: String,
    pub output: String,
}

#[derive(Debug, Default)]
struct Descriptor {
    group_id: Option<String>,
    artifact_id: Option<String>,
    version: Option<String>,
    packaging: String,
    module_paths: Vec<String>,
    profiles: Vec<MavenProfileResponse>,
}

pub fn scan(request: MavenScanRequest) -> Result<Option<MavenScanResponse>, CoreError> {
    let root = existing_root(&request.root)?;
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

pub fn diagnostics(
    request: MavenDiagnosticsRequest,
) -> Result<MavenDiagnosticsResponse, CoreError> {
    let _ = existing_root(&request.root)?;
    let expression = Regex::new(r"\[(ERROR|WARNING)\]\s+(.*?):\[(\d+)(?:,(\d+))?\]\s+(.*)")
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
    if path
        .components()
        .any(|component| matches!(component, Component::ParentDir))
    {
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
