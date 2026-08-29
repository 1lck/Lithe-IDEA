//! Deterministic Spring Boot configuration and source semantic indexing.

use crate::protocol::{
    CoreError, ErrorCode, SpringBeanResponse, SpringConfigurationValueResponse,
    SpringDiagnosticResponse, SpringEndpointResponse, SpringIndexResponse, SpringInjectionResponse,
    SpringPropertyReferenceResponse, SpringPropertyResponse,
};
use regex::Regex;
use serde::Deserialize;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::Read;
use std::path::{Component, Path, PathBuf};
use std::sync::{LazyLock, Mutex, OnceLock};
use zip::ZipArchive;

const MAX_METADATA_ARCHIVES: usize = 20_000;

static REPOSITORY_METADATA_CACHE: OnceLock<Mutex<HashMap<PathBuf, Vec<SpringPropertyResponse>>>> =
    OnceLock::new();

/// One Java parameter declaration: optional annotations, an optional `final`,
/// the type, and the parameter name. Record components and constructor
/// parameters share this grammar, so they must not drift into two patterns.
static JAVA_PARAMETER_DECLARATION: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?:@[A-Za-z0-9_$.]+(?:\([^)]*\))?\s+)*(?:final\s+)?([A-Za-z0-9_$.<>?]+)\s+([A-Za-z_$][A-Za-z0-9_$]*)$",
    )
    .expect("literal pattern is valid")
});

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Workspace paths and an optional trusted dependency repository to index.
pub struct SpringIndexRequest {
    pub root: String,
    #[serde(default)]
    pub paths: Vec<String>,
    #[serde(default)]
    pub metadata_repository: Option<String>,
    /// Trusted dependency repositories whose Spring metadata may be indexed.
    #[serde(default)]
    pub metadata_repositories: Vec<String>,
    /// Forces a dependency metadata rescan. Interactive document updates keep
    /// this false so they reuse the process-local repository snapshot.
    #[serde(default)]
    pub refresh_dependency_metadata: bool,
    #[serde(default)]
    pub text_overrides: HashMap<String, String>,
}

/// Builds one cross-file Spring index without starting an additional server.
pub fn spring_index(request: SpringIndexRequest) -> Result<SpringIndexResponse, CoreError> {
    let root = existing_directory(&request.root)?;
    let paths = request
        .paths
        .into_iter()
        .filter_map(|path| normalize_relative(&path))
        .collect::<Vec<_>>();
    let mut properties = built_in_properties();
    for path in &paths {
        if is_metadata_path(path) {
            if let Some(content) = source_content(&root, path, &request.text_overrides) {
                append_metadata(&content, None, &mut properties);
            }
        }
    }
    let mut repositories = request.metadata_repositories;
    if let Some(repository) = request.metadata_repository {
        repositories.push(repository);
    }
    repositories.sort();
    repositories.dedup();
    for repository in repositories {
        properties.extend(repository_metadata(
            Path::new(&repository),
            request.refresh_dependency_metadata,
        ));
    }

    let mut java_sources = Vec::new();
    for path in &paths {
        if path.extension().and_then(|value| value.to_str()) == Some("java") {
            if let Some(source) = source_content(&root, path, &request.text_overrides) {
                java_sources.push((slash_path(path), source));
            }
        }
    }
    append_configuration_properties(&java_sources, &mut properties);
    deduplicate_properties(&mut properties);

    let mut values = Vec::new();
    for path in &paths {
        let relative = slash_path(path);
        let name = path
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or_default();
        if !is_application_configuration(name) {
            continue;
        }
        let Some(content) = source_content(&root, path, &request.text_overrides) else {
            continue;
        };
        if name.ends_with(".properties") {
            values.extend(parse_properties(&relative, &content));
        } else {
            values.extend(parse_yaml(&relative, &content));
        }
    }
    attach_property_targets(&properties, &mut values);
    mark_profile_overrides(&mut values);
    let mut diagnostics = configuration_diagnostics(&properties, &values);
    let property_references = property_reference_index(&java_sources);
    let (beans, injections, injection_diagnostics) = bean_index(&java_sources);
    diagnostics.extend(injection_diagnostics);
    diagnostics.sort_by(|left, right| {
        left.path
            .cmp(&right.path)
            .then_with(|| left.line.cmp(&right.line))
            .then_with(|| left.column.cmp(&right.column))
            .then_with(|| left.message.cmp(&right.message))
    });
    let endpoints = endpoint_index(&java_sources);

    Ok(SpringIndexResponse {
        properties,
        values,
        property_references,
        diagnostics,
        beans,
        injections,
        endpoints,
    })
}

fn property_reference_index(sources: &[(String, String)]) -> Vec<SpringPropertyReferenceResponse> {
    static ANNOTATION: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"@Value\s*\(\s*[\"']\$\{\s*([^}:\s]+)(?::[^}]*)?\s*\}[\"']\s*\)"#)
            .expect("literal pattern is valid")
    });
    let mut references = Vec::new();
    for (path, source) in sources {
        for (index, line) in source.lines().enumerate() {
            for capture in ANNOTATION.captures_iter(line) {
                let Some(key) = capture.get(1) else { continue };
                references.push(SpringPropertyReferenceResponse {
                    key: canonical_property_name(key.as_str()),
                    path: path.clone(),
                    line: index + 1,
                    column: key.start() + 1,
                });
            }
        }
    }
    references.sort_by(|left, right| {
        left.path
            .cmp(&right.path)
            .then_with(|| left.line.cmp(&right.line))
            .then_with(|| left.column.cmp(&right.column))
    });
    references
}

fn source_content(root: &Path, path: &Path, overrides: &HashMap<String, String>) -> Option<String> {
    overrides
        .get(&slash_path(path))
        .cloned()
        .or_else(|| fs::read_to_string(root.join(path)).ok())
}

fn existing_directory(value: &str) -> Result<PathBuf, CoreError> {
    let path = PathBuf::from(value);
    if !path.is_absolute() || !path.is_dir() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Spring index root must be an existing absolute directory",
        ));
    }
    Ok(path)
}

fn normalize_relative(value: &str) -> Option<PathBuf> {
    let path = Path::new(value);
    if path.is_absolute() || value.contains('\0') {
        return None;
    }
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Normal(value) => normalized.push(value),
            Component::CurDir => {}
            _ => return None,
        }
    }
    (!normalized.as_os_str().is_empty()).then_some(normalized)
}

fn slash_path(path: &Path) -> String {
    path.components()
        .filter_map(|part| match part {
            Component::Normal(value) => value.to_str(),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("/")
}

fn is_metadata_path(path: &Path) -> bool {
    matches!(
        path.file_name().and_then(|value| value.to_str()),
        Some("spring-configuration-metadata.json")
            | Some("additional-spring-configuration-metadata.json")
    )
}

fn repository_metadata(repository: &Path, refresh: bool) -> Vec<SpringPropertyResponse> {
    if !repository.is_absolute() || !repository.is_dir() {
        return Vec::new();
    }
    let key = repository
        .canonicalize()
        .unwrap_or_else(|_| repository.to_path_buf());
    let cache = REPOSITORY_METADATA_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if !refresh {
        if let Some(properties) = cache
            .lock()
            .ok()
            .and_then(|values| values.get(&key).cloned())
        {
            return properties;
        }
    }

    let properties = scan_repository_metadata(&key);
    if let Ok(mut values) = cache.lock() {
        values.insert(key, properties.clone());
    }
    properties
}

fn scan_repository_metadata(repository: &Path) -> Vec<SpringPropertyResponse> {
    let mut properties = Vec::new();
    let mut pending = vec![repository.to_path_buf()];
    let mut archive_count = 0usize;
    while let Some(directory) = pending.pop() {
        let Ok(entries) = fs::read_dir(directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                pending.push(path);
            } else if path.extension().and_then(|value| value.to_str()) == Some("jar") {
                archive_count += 1;
                if archive_count > MAX_METADATA_ARCHIVES {
                    return properties;
                }
                append_archive_metadata(&path, &mut properties);
            }
        }
    }
    deduplicate_properties(&mut properties);
    properties
}

fn append_archive_metadata(path: &Path, properties: &mut Vec<SpringPropertyResponse>) {
    let Ok(file) = File::open(path) else { return };
    let Ok(mut archive) = ZipArchive::new(file) else {
        return;
    };
    for name in [
        "META-INF/spring-configuration-metadata.json",
        "META-INF/additional-spring-configuration-metadata.json",
    ] {
        let Ok(mut entry) = archive.by_name(name) else {
            continue;
        };
        let mut content = String::new();
        if entry.read_to_string(&mut content).is_ok() {
            append_metadata(&content, None, properties);
        }
    }
}

fn append_metadata(
    content: &str,
    source_path: Option<&str>,
    properties: &mut Vec<SpringPropertyResponse>,
) {
    let Ok(document) = serde_json::from_str::<Value>(content) else {
        return;
    };
    let Some(items) = document.get("properties").and_then(Value::as_array) else {
        return;
    };
    for item in items {
        let Some(name) = item.get("name").and_then(Value::as_str) else {
            continue;
        };
        properties.push(SpringPropertyResponse {
            name: name.to_string(),
            type_name: item.get("type").and_then(Value::as_str).map(String::from),
            description: item
                .get("description")
                .and_then(Value::as_str)
                .map(String::from),
            default_value: item.get("defaultValue").map(json_scalar),
            source_path: source_path.map(String::from),
            source_line: None,
            source_column: None,
        });
    }
}

fn json_scalar(value: &Value) -> String {
    value
        .as_str()
        .map(String::from)
        .unwrap_or_else(|| value.to_string())
}

fn built_in_properties() -> Vec<SpringPropertyResponse> {
    [
        (
            "server.port",
            "java.lang.Integer",
            "HTTP server port.",
            "8080",
        ),
        (
            "spring.application.name",
            "java.lang.String",
            "Application name.",
            "",
        ),
        (
            "spring.profiles.active",
            "java.util.List<java.lang.String>",
            "Active profiles.",
            "",
        ),
        (
            "spring.config.activate.on-profile",
            "java.lang.String",
            "Profile expression for this document.",
            "",
        ),
        (
            "spring.datasource.url",
            "java.lang.String",
            "JDBC URL of the database.",
            "",
        ),
        (
            "spring.datasource.username",
            "java.lang.String",
            "Database login username.",
            "",
        ),
        (
            "spring.datasource.password",
            "java.lang.String",
            "Database login password.",
            "",
        ),
        (
            "spring.jpa.hibernate.ddl-auto",
            "java.lang.String",
            "Hibernate schema generation mode.",
            "none",
        ),
        (
            "logging.level.root",
            "java.lang.String",
            "Root logger level.",
            "info",
        ),
        (
            "management.endpoints.web.exposure.include",
            "java.util.Set<java.lang.String>",
            "Exposed actuator endpoints.",
            "",
        ),
    ]
    .into_iter()
    .map(
        |(name, type_name, description, default_value)| SpringPropertyResponse {
            name: name.to_string(),
            type_name: Some(type_name.to_string()),
            description: Some(description.to_string()),
            default_value: (!default_value.is_empty()).then(|| default_value.to_string()),
            source_path: None,
            source_line: None,
            source_column: None,
        },
    )
    .collect()
}

fn append_configuration_properties(
    sources: &[(String, String)],
    properties: &mut Vec<SpringPropertyResponse>,
) {
    static ANNOTATION: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#"(?s)@ConfigurationProperties\s*\(\s*(?:prefix\s*=\s*)?[\"']([^\"']+)[\"'][^)]*\).*?\b(?:class|record)\s+([A-Za-z_$][A-Za-z0-9_$]*)"#,
        )
        .expect("literal pattern is valid")
    });
    let mut types = HashMap::new();
    for (path, source) in sources {
        for value in parse_configuration_types(path, source) {
            types.insert(value.name.clone(), value);
        }
    }
    for (_, source) in sources {
        for capture in ANNOTATION.captures_iter(source) {
            let Some(prefix) = capture.get(1) else {
                continue;
            };
            let Some(type_name) = capture.get(2) else {
                continue;
            };
            append_configuration_type(
                canonical_property_name(prefix.as_str()),
                type_name.as_str(),
                &types,
                &mut HashSet::new(),
                properties,
            );
        }
    }
}

#[derive(Clone)]
struct ConfigurationField {
    name: String,
    type_name: String,
    path: String,
    line: usize,
    column: usize,
    default_value: Option<String>,
}

struct ConfigurationType {
    name: String,
    fields: Vec<ConfigurationField>,
    body_depth: isize,
}

fn parse_configuration_types(path: &str, source: &str) -> Vec<ConfigurationType> {
    static DECLARATION: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"\b(?:class|record)\s+([A-Za-z_$][A-Za-z0-9_$]*)(?:\s*\(([^)]*)\))?")
            .expect("literal pattern is valid")
    });
    static FIELD: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"(?:private|protected|public)\s+(?:static\s+)?(?:final\s+)?([A-Za-z0-9_$.<>?, ]+)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*(?:=\s*([^;]+))?;",
        )
        .expect("literal pattern is valid")
    });
    let mut types = Vec::<ConfigurationType>::new();
    let mut stack = Vec::<usize>::new();
    let mut depth = 0isize;
    for (index, line) in source.lines().enumerate() {
        if let Some(capture) = DECLARATION.captures(line) {
            let name = capture.get(1).unwrap();
            let body_depth = depth + brace_delta(line);
            let mut value = ConfigurationType {
                name: name.as_str().to_string(),
                fields: Vec::new(),
                body_depth,
            };
            if let Some(components) = capture.get(2) {
                value.fields.extend(parse_record_components(
                    path,
                    index + 1,
                    line,
                    components.as_str(),
                ));
            }
            types.push(value);
            stack.push(types.len() - 1);
        } else if let Some(type_index) = stack.last().copied() {
            if depth == types[type_index].body_depth {
                if let Some(capture) = FIELD.captures(line) {
                    let name = capture.get(2).unwrap();
                    types[type_index].fields.push(ConfigurationField {
                        name: name.as_str().to_string(),
                        type_name: capture.get(1).unwrap().as_str().trim().to_string(),
                        path: path.to_string(),
                        line: index + 1,
                        column: name.start() + 1,
                        default_value: capture.get(3).map(|value| {
                            value.as_str().trim().trim_matches(['\'', '"']).to_string()
                        }),
                    });
                }
            }
        }
        depth += brace_delta(line);
        while stack
            .last()
            .is_some_and(|type_index| depth < types[*type_index].body_depth)
        {
            stack.pop();
        }
    }
    types
}

fn parse_record_components(
    path: &str,
    line_number: usize,
    line: &str,
    components: &str,
) -> Vec<ConfigurationField> {
    split_parameters(components)
        .into_iter()
        .filter_map(|value| {
            let capture = JAVA_PARAMETER_DECLARATION.captures(value.trim())?;
            let name = capture.get(2)?;
            Some(ConfigurationField {
                name: name.as_str().to_string(),
                type_name: capture.get(1)?.as_str().trim().to_string(),
                path: path.to_string(),
                line: line_number,
                column: line.find(name.as_str()).unwrap_or(0) + 1,
                default_value: None,
            })
        })
        .collect()
}

fn brace_delta(line: &str) -> isize {
    line.chars().fold(0, |value, character| match character {
        '{' => value + 1,
        '}' => value - 1,
        _ => value,
    })
}

fn append_configuration_type(
    prefix: String,
    type_name: &str,
    types: &HashMap<String, ConfigurationType>,
    visiting: &mut HashSet<String>,
    properties: &mut Vec<SpringPropertyResponse>,
) {
    let type_name = simple_type(type_name);
    if !visiting.insert(type_name.clone()) {
        return;
    }
    let Some(value) = types.get(&type_name) else {
        visiting.remove(&type_name);
        return;
    };
    for field in &value.fields {
        let name = format!("{}.{}", prefix, kebab_case(&field.name));
        let nested_type = simple_type(&field.type_name);
        if types.contains_key(&nested_type) {
            append_configuration_type(name, &nested_type, types, visiting, properties);
        } else {
            properties.push(SpringPropertyResponse {
                name,
                type_name: Some(field.type_name.clone()),
                description: Some(format!("Binds to `{}`.", field.name)),
                default_value: field.default_value.clone(),
                source_path: Some(field.path.clone()),
                source_line: Some(field.line),
                source_column: Some(field.column),
            });
        }
    }
    visiting.remove(&type_name);
}

fn kebab_case(value: &str) -> String {
    let mut result = String::new();
    for character in value.chars() {
        if character.is_uppercase() {
            if !result.is_empty() {
                result.push('-');
            }
            result.extend(character.to_lowercase());
        } else if character == '_' {
            result.push('-');
        } else {
            result.push(character);
        }
    }
    result
}

fn canonical_property_name(value: &str) -> String {
    value
        .split('.')
        .map(|part| kebab_case(part.trim()).to_ascii_lowercase())
        .collect::<Vec<_>>()
        .join(".")
}

fn deduplicate_properties(properties: &mut Vec<SpringPropertyResponse>) {
    properties.sort_by(|left, right| {
        left.name
            .cmp(&right.name)
            .then_with(|| left.source_path.is_none().cmp(&right.source_path.is_none()))
    });
    properties.dedup_by(|right, left| right.name == left.name);
}

fn is_application_configuration(name: &str) -> bool {
    name == "application.properties"
        || (name.starts_with("application")
            && (name.ends_with(".yml") || name.ends_with(".yaml") || name.ends_with(".properties")))
}

fn profile_from_path(path: &str) -> Option<String> {
    let name = Path::new(path).file_name()?.to_str()?;
    let stem = name
        .strip_suffix(".properties")
        .or_else(|| name.strip_suffix(".yaml"))
        .or_else(|| name.strip_suffix(".yml"))?;
    stem.strip_prefix("application-")
        .filter(|value| !value.is_empty())
        .map(String::from)
}

fn parse_properties(path: &str, content: &str) -> Vec<SpringConfigurationValueResponse> {
    let profile = profile_from_path(path);
    logical_property_lines(content)
        .into_iter()
        .filter_map(|(index, line)| {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with('!') {
                return None;
            }
            let separator = property_separator(trimmed)?;
            let key = trimmed[..separator].trim();
            if key.is_empty() {
                return None;
            }
            Some(SpringConfigurationValueResponse {
                key: canonical_property_name(&unescape_property(key)),
                value: unescape_property(trimmed[separator + 1..].trim()),
                path: path.to_string(),
                line: index,
                column: line.find(key).unwrap_or(0) + 1,
                profile: profile.clone(),
                overrides_base_value: false,
                target_path: None,
                target_line: None,
                target_column: None,
            })
        })
        .collect()
}

fn logical_property_lines(content: &str) -> Vec<(usize, String)> {
    let mut values = Vec::new();
    let mut pending: Option<(usize, String)> = None;
    for (index, line) in content.lines().enumerate() {
        let start_line = index + 1;
        let mut part = line.to_string();
        let continued = part
            .chars()
            .rev()
            .take_while(|value| *value == '\\')
            .count()
            % 2
            == 1;
        if continued {
            part.pop();
        }
        if let Some((_, value)) = pending.as_mut() {
            value.push_str(part.trim_start());
        } else {
            pending = Some((start_line, part));
        }
        if !continued {
            if let Some(value) = pending.take() {
                values.push(value);
            }
        }
    }
    if let Some(value) = pending {
        values.push(value);
    }
    values
}

fn property_separator(value: &str) -> Option<usize> {
    let mut escaped = false;
    for (index, character) in value.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if character == '\\' {
            escaped = true;
        } else if character == '=' || character == ':' || character.is_whitespace() {
            return Some(index);
        }
    }
    None
}

fn unescape_property(value: &str) -> String {
    value
        .replace("\\:", ":")
        .replace("\\=", "=")
        .replace("\\ ", " ")
        .replace("\\\\", "\\")
}

fn parse_yaml(path: &str, content: &str) -> Vec<SpringConfigurationValueResponse> {
    let file_profile = profile_from_path(path);
    let lines = content.lines().collect::<Vec<_>>();
    let mut values = Vec::new();
    let mut document_start = 0usize;
    for index in 0..=lines.len() {
        if index == lines.len() || lines[index].trim() == "---" {
            values.extend(parse_yaml_document(
                path,
                &lines[document_start..index],
                document_start,
                file_profile.clone(),
            ));
            document_start = index + 1;
        }
    }
    values
}

fn parse_yaml_document(
    path: &str,
    lines: &[&str],
    line_offset: usize,
    file_profile: Option<String>,
) -> Vec<SpringConfigurationValueResponse> {
    let mut stack: Vec<(usize, String)> = Vec::new();
    let mut values = Vec::new();
    for (index, line) in lines.iter().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if let Some(item) = trimmed
            .strip_prefix('-')
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            let key = stack
                .iter()
                .map(|(_, part)| part.as_str())
                .collect::<Vec<_>>()
                .join(".");
            if !key.is_empty() {
                values.push(SpringConfigurationValueResponse {
                    key: canonical_property_name(&key),
                    value: item.trim_matches(['\'', '"']).to_string(),
                    path: path.to_string(),
                    line: line_offset + index + 1,
                    column: line.find('-').unwrap_or(0) + 1,
                    profile: None,
                    overrides_base_value: false,
                    target_path: None,
                    target_line: None,
                    target_column: None,
                });
            }
            continue;
        }
        let Some(separator) = trimmed.find(':') else {
            continue;
        };
        let key = trimmed[..separator].trim().trim_matches(['\'', '"']);
        if key.is_empty() {
            continue;
        }
        let indent = line
            .chars()
            .take_while(|value| value.is_whitespace())
            .count();
        while stack.last().is_some_and(|(level, _)| *level >= indent) {
            stack.pop();
        }
        let value = trimmed[separator + 1..].trim().trim_matches(['\'', '"']);
        let mut parts = stack
            .iter()
            .map(|(_, part)| part.clone())
            .collect::<Vec<_>>();
        parts.push(key.to_string());
        let full_key = canonical_property_name(&parts.join("."));
        if value.is_empty() {
            stack.push((indent, key.to_string()));
            continue;
        }
        values.push(SpringConfigurationValueResponse {
            key: full_key,
            value: value.to_string(),
            path: path.to_string(),
            line: line_offset + index + 1,
            column: line.find(key).unwrap_or(0) + 1,
            profile: None,
            overrides_base_value: false,
            target_path: None,
            target_line: None,
            target_column: None,
        });
    }
    let profile = file_profile.or_else(|| {
        values
            .iter()
            .find(|value| value.key == "spring.config.activate.on-profile")
            .map(|value| value.value.clone())
    });
    for value in &mut values {
        value.profile = profile.clone();
    }
    values
}

fn attach_property_targets(
    properties: &[SpringPropertyResponse],
    values: &mut [SpringConfigurationValueResponse],
) {
    let by_name = properties
        .iter()
        .map(|property| (canonical_property_name(&property.name), property))
        .collect::<HashMap<_, _>>();
    for value in values {
        if let Some(property) = by_name.get(&canonical_property_name(&value.key)) {
            value.target_path = property.source_path.clone();
            value.target_line = property.source_line;
            value.target_column = property.source_column;
        }
    }
}

fn mark_profile_overrides(values: &mut [SpringConfigurationValueResponse]) {
    let base_keys = values
        .iter()
        .filter(|value| value.profile.is_none())
        .map(|value| value.key.clone())
        .collect::<HashSet<_>>();
    for value in values {
        value.overrides_base_value = value.profile.is_some() && base_keys.contains(&value.key);
    }
}

fn configuration_diagnostics(
    properties: &[SpringPropertyResponse],
    values: &[SpringConfigurationValueResponse],
) -> Vec<SpringDiagnosticResponse> {
    let known = properties
        .iter()
        .map(|property| canonical_property_name(&property.name))
        .collect::<HashSet<_>>();
    let types = properties
        .iter()
        .filter_map(|property| {
            property
                .type_name
                .as_deref()
                .map(|type_name| (canonical_property_name(&property.name), type_name))
        })
        .collect::<HashMap<_, _>>();
    let mut diagnostics = Vec::new();
    for value in values {
        let canonical_key = canonical_property_name(&value.key);
        if !known.contains(&canonical_key) {
            diagnostics.push(SpringDiagnosticResponse {
                path: value.path.clone(),
                line: value.line,
                column: value.column,
                severity: "warning".to_string(),
                message: format!("Unknown Spring configuration property `{}`", value.key),
            });
            continue;
        }
        let Some(type_name) = types.get(&canonical_key) else {
            continue;
        };
        let valid = if type_name.contains("Boolean") || *type_name == "boolean" {
            matches!(value.value.as_str(), "true" | "false")
        } else if type_name.contains("Integer") || *type_name == "int" || *type_name == "long" {
            value.value.parse::<i64>().is_ok()
        } else {
            true
        };
        if !valid {
            diagnostics.push(SpringDiagnosticResponse {
                path: value.path.clone(),
                line: value.line,
                column: value.column,
                severity: "error".to_string(),
                message: format!("`{}` is not a valid value for `{}`", value.value, type_name),
            });
        }
    }
    diagnostics
}

#[derive(Clone)]
struct IndexedBean {
    response: SpringBeanResponse,
    names: HashSet<String>,
    assignable_types: HashSet<String>,
    primary: bool,
}

struct RawInjection {
    path: String,
    line: usize,
    column: usize,
    type_name: String,
    qualifier: Option<String>,
}

fn bean_index(
    sources: &[(String, String)],
) -> (
    Vec<SpringBeanResponse>,
    Vec<SpringInjectionResponse>,
    Vec<SpringDiagnosticResponse>,
) {
    static TYPE_DECLARATION: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"\b(class|interface|record)\s+([A-Za-z_$][A-Za-z0-9_$]*)([^\{]*)")
            .expect("literal pattern is valid")
    });
    static METHOD: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"(?:public|protected|private)?\s*(?:static\s+)?(?:final\s+)?([A-Za-z0-9_$.<>?]+)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(",
        )
        .expect("literal pattern is valid")
    });
    static FIELD: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"(?:private|protected|public)\s+(?:static\s+)?(?:final\s+)?([A-Za-z0-9_$.<>?]+)\s+([A-Za-z_$][A-Za-z0-9_$]*)",
        )
        .expect("literal pattern is valid")
    });
    let mut supertypes = HashMap::<String, Vec<String>>::new();
    for (_, source) in sources {
        for capture in TYPE_DECLARATION.captures_iter(source) {
            let Some(name) = capture.get(2) else { continue };
            let tail = capture
                .get(3)
                .map(|value| value.as_str())
                .unwrap_or_default();
            supertypes.insert(name.as_str().to_string(), declared_supertypes(tail));
        }
    }

    let mut indexed_beans = Vec::new();
    let mut raw_injections = Vec::new();
    for (path, source) in sources {
        let lines = source.lines().collect::<Vec<_>>();
        let source_type = TYPE_DECLARATION
            .captures(source)
            .and_then(|capture| capture.get(2))
            .map(|value| value.as_str().to_string());
        // The constructor pattern depends on the declaring type, so it cannot be
        // a file-independent constant, but it is identical for every line of one
        // source and must not be rebuilt inside the line loop below.
        let constructor_pattern = source_type.as_deref().and_then(constructor_regex);
        let constructor_count = constructor_pattern
            .as_ref()
            .map_or(0, |pattern| pattern.captures_iter(source).count());
        for (index, line) in lines.iter().enumerate() {
            let context = annotation_context(&lines, index);
            if let Some(capture) = TYPE_DECLARATION.captures(line) {
                if has_component_annotation(&context) {
                    let name = capture.get(2).unwrap();
                    let default_name = lower_camel(name.as_str());
                    let bean_name = component_name(&context).unwrap_or(default_name);
                    let mut names = HashSet::from([bean_name.clone()]);
                    names.extend(qualifier_names(&context));
                    indexed_beans.push(IndexedBean {
                        response: SpringBeanResponse {
                            id: format!("{}:{}", path, bean_name),
                            name: bean_name,
                            type_name: name.as_str().to_string(),
                            path: path.clone(),
                            line: index + 1,
                            column: name.start() + 1,
                            kind: "component".to_string(),
                        },
                        names,
                        assignable_types: assignable_types(name.as_str(), &supertypes),
                        primary: SpringAnnotation::Primary.is_present(&context),
                    });
                }
            }
            if SpringAnnotation::Bean.is_present(&context) {
                if let Some(capture) = METHOD.captures(line) {
                    let type_name = simple_type(capture.get(1).unwrap().as_str());
                    let declaration_name = capture.get(2).unwrap();
                    let aliases = bean_names(&context);
                    let bean_name = aliases
                        .first()
                        .cloned()
                        .unwrap_or_else(|| declaration_name.as_str().to_string());
                    let mut names = aliases.into_iter().collect::<HashSet<_>>();
                    names.insert(bean_name.clone());
                    names.extend(qualifier_names(&context));
                    indexed_beans.push(IndexedBean {
                        response: SpringBeanResponse {
                            id: format!("{}:{}", path, bean_name),
                            name: bean_name,
                            type_name: type_name.clone(),
                            path: path.clone(),
                            line: index + 1,
                            column: declaration_name.start() + 1,
                            kind: "beanMethod".to_string(),
                        },
                        names,
                        assignable_types: assignable_types(&type_name, &supertypes),
                        primary: SpringAnnotation::Primary.is_present(&context),
                    });
                }
            }
            if is_injection_context(&context) {
                if let Some(capture) = FIELD.captures(line) {
                    let type_name = simple_type(capture.get(1).unwrap().as_str());
                    let name = capture.get(2).unwrap();
                    raw_injections.push(RawInjection {
                        path: path.clone(),
                        line: index + 1,
                        column: name.start() + 1,
                        type_name,
                        qualifier: injection_qualifier(&context),
                    });
                }
            }
            let Some(pattern) = constructor_pattern.as_ref() else {
                continue;
            };
            let Some(opening) = pattern.find(line).map(|value| value.end() - 1) else {
                continue;
            };
            if !is_injection_context(&context) && constructor_count != 1 {
                continue;
            }
            let Some(closing) = line.rfind(')').filter(|value| *value > opening) else {
                continue;
            };
            raw_injections.extend(parse_constructor_injections(
                path,
                index + 1,
                line,
                &line[opening + 1..closing],
            ));
        }
    }

    indexed_beans.sort_by(|left, right| {
        left.response
            .name
            .cmp(&right.response.name)
            .then_with(|| left.response.path.cmp(&right.response.path))
    });
    let mut diagnostics = Vec::new();
    let mut injections = raw_injections
        .into_iter()
        .map(|injection| {
            let mut candidates = indexed_beans
                .iter()
                .filter(|bean| bean.assignable_types.contains(&injection.type_name))
                .collect::<Vec<_>>();
            if let Some(qualifier) = injection.qualifier.as_deref() {
                candidates.retain(|bean| bean.names.contains(qualifier));
            } else {
                let primary = candidates
                    .iter()
                    .copied()
                    .filter(|bean| bean.primary)
                    .collect::<Vec<_>>();
                if !primary.is_empty() {
                    candidates = primary;
                }
            }
            if candidates.is_empty() {
                diagnostics.push(SpringDiagnosticResponse {
                    path: injection.path.clone(),
                    line: injection.line,
                    column: injection.column,
                    severity: "warning".to_string(),
                    message: format!(
                        "No Spring bean satisfies injection type `{}`{}",
                        injection.type_name,
                        injection
                            .qualifier
                            .as_deref()
                            .map(|value| format!(" with qualifier `{value}`"))
                            .unwrap_or_default()
                    ),
                });
            } else if candidates.len() > 1 {
                diagnostics.push(SpringDiagnosticResponse {
                    path: injection.path.clone(),
                    line: injection.line,
                    column: injection.column,
                    severity: "warning".to_string(),
                    message: format!(
                        "Multiple Spring beans satisfy injection type `{}`",
                        injection.type_name
                    ),
                });
            }
            SpringInjectionResponse {
                path: injection.path,
                line: injection.line,
                column: injection.column,
                type_name: injection.type_name,
                qualifier: injection.qualifier,
                bean_ids: candidates
                    .into_iter()
                    .map(|bean| bean.response.id.clone())
                    .collect(),
            }
        })
        .collect::<Vec<_>>();
    injections.sort_by(|left, right| {
        left.path
            .cmp(&right.path)
            .then_with(|| left.line.cmp(&right.line))
            .then_with(|| left.column.cmp(&right.column))
    });
    let beans = indexed_beans
        .into_iter()
        .map(|bean| bean.response)
        .collect();
    (beans, injections, diagnostics)
}

fn annotation_context(lines: &[&str], index: usize) -> String {
    let mut values = vec![lines[index].trim().to_string()];
    for previous in lines[..index].iter().rev().take(8) {
        let trimmed = previous.trim();
        if trimmed.is_empty() {
            continue;
        }
        if trimmed.starts_with('@')
            || trimmed.starts_with("value")
            || trimmed.starts_with("name")
            || trimmed == ")"
            || trimmed == "}"
        {
            values.insert(0, trimmed.to_string());
        } else {
            break;
        }
    }
    values.join(" ")
}

/// Matches `@Name` only when the name is not a prefix of a longer annotation,
/// so `@Bean` does not match `@BeanFactory`.
fn annotation_boundary_pattern(name: &str) -> Regex {
    Regex::new(&format!(r"@{}(?:\s|\(|$)", regex::escape(name)))
        .expect("an escaped annotation name is a valid pattern")
}

/// Declares the Spring annotations this module recognizes exactly once, and
/// derives the type, the spelling, the full list, and the compiled pattern from
/// that one declaration.
///
/// Detection runs several times for every line of every Java source, so each
/// pattern is compiled once for the process. `pattern` matches on `self` instead
/// of looking the annotation up in a table, which leaves the compiler to reject
/// a case that was added without a pattern.
macro_rules! spring_annotations {
    ($($variant:ident => $name:literal),+ $(,)?) => {
        #[derive(Clone, Copy)]
        pub(crate) enum SpringAnnotation {
            $($variant),+
        }

        impl SpringAnnotation {
            /// Every recognized annotation, in declaration order. Production
            /// code reaches a pattern through a case rather than this list.
            #[cfg(test)]
            pub(crate) const ALL: &'static [Self] = &[$(Self::$variant),+];

            pub(crate) fn name(self) -> &'static str {
                match self {
                    $(Self::$variant => $name),+
                }
            }

            pub(crate) fn pattern(self) -> &'static Regex {
                match self {
                    $(Self::$variant => {
                        static PATTERN: LazyLock<Regex> =
                            LazyLock::new(|| annotation_boundary_pattern($name));
                        &PATTERN
                    })+
                }
            }
        }
    };
}

spring_annotations! {
    Autowired => "Autowired",
    Bean => "Bean",
    Component => "Component",
    Configuration => "Configuration",
    Controller => "Controller",
    Inject => "Inject",
    Primary => "Primary",
    Repository => "Repository",
    Resource => "Resource",
    RestController => "RestController",
    Service => "Service",
}

impl SpringAnnotation {
    /// Annotations that declare a Spring component on a type declaration. The
    /// order also drives the alternation in [`component_name`], so changing it
    /// changes which annotation wins on a type carrying several of them.
    const COMPONENTS: [Self; 6] = [
        Self::Component,
        Self::Service,
        Self::Repository,
        Self::Controller,
        Self::RestController,
        Self::Configuration,
    ];

    /// Annotations that mark a field or constructor parameter for injection.
    const INJECTIONS: [Self; 3] = [Self::Autowired, Self::Inject, Self::Resource];

    pub(crate) fn is_present(self, context: &str) -> bool {
        self.pattern().is_match(context)
    }
}

fn has_component_annotation(context: &str) -> bool {
    SpringAnnotation::COMPONENTS
        .iter()
        .any(|annotation| annotation.is_present(context))
}

fn component_name(context: &str) -> Option<String> {
    // Built from COMPONENTS so the recognized set cannot diverge from the one
    // has_component_annotation uses.
    static ANNOTATION: LazyLock<Regex> = LazyLock::new(|| {
        let alternation = SpringAnnotation::COMPONENTS
            .iter()
            .map(|annotation| regex::escape(annotation.name()))
            .collect::<Vec<_>>()
            .join("|");
        Regex::new(&format!(
            r#"@({alternation})\s*\([^\)]*[\"']([^\"']+)[\"']"#
        ))
        .expect("escaped annotation names produce a valid pattern")
    });
    ANNOTATION
        .captures(context)
        .and_then(|capture| capture.get(2))
        .map(|value| value.as_str().to_string())
}

fn qualifier_names(context: &str) -> Vec<String> {
    static PATTERN: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"@Qualifier\s*\(\s*[\"']([^\"']+)[\"']\s*\)"#)
            .expect("literal pattern is valid")
    });
    PATTERN
        .captures_iter(context)
        .filter_map(|capture| capture.get(1).map(|value| value.as_str().to_string()))
        .collect()
}

fn bean_names(context: &str) -> Vec<String> {
    let Some(start) = context.find("@Bean") else {
        return Vec::new();
    };
    let remaining = &context[start..];
    let end = remaining.find(')').unwrap_or(remaining.len());
    quoted_values(&remaining[..end])
}

fn quoted_values(value: &str) -> Vec<String> {
    static PATTERN: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r#"[\"']([^\"']*)[\"']"#).expect("literal pattern is valid"));
    PATTERN
        .captures_iter(value)
        .filter_map(|capture| capture.get(1).map(|item| item.as_str().to_string()))
        .collect()
}

fn declared_supertypes(tail: &str) -> Vec<String> {
    // Indexed by the fixed keyword order below, which the result order depends on.
    static PATTERNS: LazyLock<[Regex; 2]> = LazyLock::new(|| {
        ["extends", "implements"].map(|keyword| {
            Regex::new(&format!(
                r"\b{}\s+([^\{{]+?)(?:\b(?:extends|implements)\b|$)",
                keyword
            ))
            .expect("literal keyword produces a valid pattern")
        })
    });
    let mut values = Vec::new();
    for pattern in PATTERNS.iter() {
        if let Some(capture) = pattern.captures(tail) {
            values.extend(
                capture[1]
                    .split(',')
                    .map(simple_type)
                    .filter(|value| !value.is_empty()),
            );
        }
    }
    values
}

fn assignable_types(type_name: &str, supertypes: &HashMap<String, Vec<String>>) -> HashSet<String> {
    let mut values = HashSet::new();
    let mut pending = vec![simple_type(type_name)];
    while let Some(value) = pending.pop() {
        if !values.insert(value.clone()) {
            continue;
        }
        if let Some(parents) = supertypes.get(&value) {
            pending.extend(parents.iter().cloned());
        }
    }
    values
}

fn is_injection_context(context: &str) -> bool {
    SpringAnnotation::INJECTIONS
        .iter()
        .any(|annotation| annotation.is_present(context))
}

fn injection_qualifier(context: &str) -> Option<String> {
    qualifier_names(context).into_iter().next().or_else(|| {
        static RESOURCE: LazyLock<Regex> = LazyLock::new(|| {
            Regex::new(r#"@Resource\s*\([^\)]*name\s*=\s*[\"']([^\"']+)[\"']"#)
                .expect("literal pattern is valid")
        });
        RESOURCE
            .captures(context)
            .and_then(|capture| capture.get(1))
            .map(|value| value.as_str().to_string())
    })
}

fn constructor_regex(type_name: &str) -> Option<Regex> {
    Regex::new(&format!(
        r"(?:public|protected|private)?\s*{}\s*\(",
        regex::escape(type_name)
    ))
    .ok()
}

fn parse_constructor_injections(
    path: &str,
    line_number: usize,
    line: &str,
    parameters: &str,
) -> Vec<RawInjection> {
    split_parameters(parameters)
        .into_iter()
        .filter_map(|parameter| {
            let capture = JAVA_PARAMETER_DECLARATION.captures(parameter.trim())?;
            let variable = capture.get(2)?;
            Some(RawInjection {
                path: path.to_string(),
                line: line_number,
                column: line.find(variable.as_str()).unwrap_or(0) + 1,
                type_name: simple_type(capture.get(1)?.as_str()),
                qualifier: injection_qualifier(parameter),
            })
        })
        .collect()
}

fn split_parameters(value: &str) -> Vec<&str> {
    let mut values = Vec::new();
    let mut start = 0usize;
    let mut depth = 0usize;
    for (index, character) in value.char_indices() {
        match character {
            '<' | '(' | '{' | '[' => depth += 1,
            '>' | ')' | '}' | ']' => depth = depth.saturating_sub(1),
            ',' if depth == 0 => {
                values.push(&value[start..index]);
                start = index + 1;
            }
            _ => {}
        }
    }
    if start < value.len() {
        values.push(&value[start..]);
    }
    values
}

fn endpoint_index(sources: &[(String, String)]) -> Vec<SpringEndpointResponse> {
    static CLASS: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"\bclass\s+([A-Za-z_$][A-Za-z0-9_$]*)").expect("literal pattern is valid")
    });
    static METHOD: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"[A-Za-z0-9_$.<>?]+\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(")
            .expect("literal pattern is valid")
    });
    let mut endpoints = Vec::new();
    for (path, source) in sources {
        if !SpringAnnotation::Controller.is_present(source)
            && !SpringAnnotation::RestController.is_present(source)
        {
            continue;
        }
        let controller = CLASS
            .captures(source)
            .and_then(|capture| capture.get(1))
            .map(|value| value.as_str().to_string())
            .unwrap_or_else(|| "Controller".to_string());
        let lines = source.lines().collect::<Vec<_>>();
        let mut base_routes = vec![String::new()];
        let mut index = 0usize;
        while index < lines.len() {
            if !lines[index].trim_start().starts_with('@') {
                index += 1;
                continue;
            }
            let (annotation, annotation_end) = annotation_block(&lines, index);
            let Some((methods, routes)) = mapping(&annotation) else {
                index = annotation_end + 1;
                continue;
            };
            let declaration_index = next_declaration_index(&lines, annotation_end + 1);
            let declaration = declaration_index
                .and_then(|value| lines.get(value).copied())
                .unwrap_or_default();
            if annotation.contains("@RequestMapping") && CLASS.is_match(declaration) {
                base_routes = routes;
                index = annotation_end + 1;
                continue;
            }
            let method_name = METHOD
                .captures(declaration)
                .and_then(|capture| capture.get(1))
                .map(|value| value.as_str())
                .unwrap_or("handler");
            for base_route in &base_routes {
                for route in &routes {
                    let joined = join_route(base_route, route);
                    endpoints.push(SpringEndpointResponse {
                        id: format!("{}:{}:{}:{}", path, index + 1, methods.join(","), joined),
                        http_methods: methods.clone(),
                        route: joined,
                        controller: controller.clone(),
                        method: method_name.to_string(),
                        path: path.clone(),
                        line: index + 1,
                        column: lines[index].find('@').unwrap_or(0) + 1,
                    });
                }
            }
            index = annotation_end + 1;
        }
    }
    endpoints.sort_by(|left, right| {
        left.route
            .cmp(&right.route)
            .then_with(|| left.http_methods.cmp(&right.http_methods))
    });
    endpoints
}

fn mapping(annotation_text: &str) -> Option<(Vec<String>, Vec<String>)> {
    for (annotation, method) in [
        ("@GetMapping", "GET"),
        ("@PostMapping", "POST"),
        ("@PutMapping", "PUT"),
        ("@DeleteMapping", "DELETE"),
        ("@PatchMapping", "PATCH"),
    ] {
        if annotation_text.contains(annotation) {
            return Some((vec![method.to_string()], annotation_routes(annotation_text)));
        }
    }
    if annotation_text.contains("@RequestMapping") {
        static METHOD_PATTERN: LazyLock<Regex> = LazyLock::new(|| {
            Regex::new(r"RequestMethod\.(GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS|TRACE)")
                .expect("literal pattern is valid")
        });
        let mut methods = METHOD_PATTERN
            .captures_iter(annotation_text)
            .filter_map(|capture| capture.get(1).map(|value| value.as_str().to_string()))
            .collect::<Vec<_>>();
        if methods.is_empty() {
            methods.push("ANY".to_string());
        }
        methods.sort();
        methods.dedup();
        return Some((methods, annotation_routes(annotation_text)));
    }
    None
}

fn annotation_routes(annotation: &str) -> Vec<String> {
    static NAMED: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(?:value|path)\s*=\s*(\{[^}]*\}|[\"'][^\"']*[\"'])"#)
            .expect("literal pattern is valid")
    });
    let expression = NAMED
        .captures(annotation)
        .and_then(|capture| capture.get(1))
        .map(|value| value.as_str())
        .or_else(|| {
            let start = annotation.find('(')? + 1;
            let end = annotation.rfind(')')?;
            let value = annotation[start..end].trim();
            (value.starts_with(['\'', '"', '{'])).then_some(value)
        });
    let mut routes = expression.map(quoted_values).unwrap_or_default();
    if routes.is_empty() {
        routes.push(String::new());
    }
    routes.sort();
    routes.dedup();
    routes
}

fn annotation_block(lines: &[&str], start: usize) -> (String, usize) {
    let mut value = String::new();
    let mut depth = 0isize;
    let mut saw_parenthesis = false;
    let mut end = start;
    for (index, line) in lines.iter().enumerate().skip(start) {
        if !value.is_empty() {
            value.push(' ');
        }
        value.push_str(line.trim());
        for character in line.chars() {
            if character == '(' {
                depth += 1;
                saw_parenthesis = true;
            } else if character == ')' {
                depth -= 1;
            }
        }
        end = index;
        if !saw_parenthesis || depth <= 0 {
            break;
        }
    }
    (value, end)
}

fn next_declaration_index(lines: &[&str], start: usize) -> Option<usize> {
    lines
        .iter()
        .enumerate()
        .skip(start)
        .take(12)
        .find_map(|(index, line)| {
            let trimmed = line.trim();
            (!trimmed.is_empty() && !trimmed.starts_with('@')).then_some(index)
        })
}

fn join_route(base: &str, route: &str) -> String {
    let value = format!("{}/{}", base.trim_matches('/'), route.trim_matches('/'));
    let trimmed = value.trim_matches('/');
    if trimmed.is_empty() {
        "/".to_string()
    } else {
        format!("/{trimmed}")
    }
}

fn simple_type(value: &str) -> String {
    value
        .split('<')
        .next()
        .unwrap_or(value)
        .rsplit('.')
        .next()
        .unwrap_or(value)
        .trim()
        .to_string()
}

fn lower_camel(value: &str) -> String {
    let mut characters = value.chars();
    characters
        .next()
        .map(|first| first.to_lowercase().collect::<String>() + characters.as_str())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    /// `spring_annotations!` derives the type, the spelling, `ALL`, and the
    /// compiled pattern from one declaration, so a case cannot exist without a
    /// pattern. This covers the boundary each entry has to keep.
    #[test]
    fn every_supported_annotation_has_a_compiled_boundary_pattern() {
        for annotation in SpringAnnotation::ALL.iter().copied() {
            let name = annotation.name();
            assert!(
                annotation.is_present(&format!("@{name} public class Demo")),
                "{name} should match its own annotation"
            );
            assert!(
                annotation.is_present(&format!("@{name}(\"value\")")),
                "{name} should match when it carries arguments"
            );
            assert!(
                annotation.is_present(&format!("@{name}")),
                "{name} should match at the end of a context"
            );
            assert!(
                !annotation.is_present(&format!("@{name}Extended public class Demo")),
                "{name} must not match a longer annotation sharing its prefix"
            );
        }

        let names = SpringAnnotation::ALL
            .iter()
            .map(|annotation| annotation.name())
            .collect::<HashSet<_>>();
        assert_eq!(
            names.len(),
            SpringAnnotation::ALL.len(),
            "every case needs a distinct annotation name"
        );
    }

    /// Component detection and component naming must recognize the same
    /// annotations, so both read COMPONENTS instead of repeating the list.
    #[test]
    fn component_detection_and_naming_recognize_the_same_annotations() {
        for annotation in SpringAnnotation::COMPONENTS {
            let name = annotation.name();
            assert!(
                has_component_annotation(&format!("@{name}\npublic class Demo")),
                "{name} should be detected as a component annotation"
            );
            assert_eq!(
                component_name(&format!("@{name}(\"custom\")\npublic class Demo")).as_deref(),
                Some("custom"),
                "{name} should expose its declared bean name"
            );
        }

        assert!(!has_component_annotation("@Bean\npublic Clock clock()"));
        assert_eq!(component_name("@Qualifier(\"custom\")"), None);
    }

    /// Record components and constructor parameters share one pattern, so a
    /// declaration parsed by one path must be parsed identically by the other.
    #[test]
    fn record_components_and_constructor_parameters_share_one_declaration_pattern() {
        let parameters = "@Qualifier(\"stripe\") final PaymentService payments";
        let fields = parse_record_components("Demo.java", 1, parameters, parameters);
        let injections = parse_constructor_injections("Demo.java", 1, parameters, parameters);

        assert_eq!(fields.len(), 1);
        assert_eq!(injections.len(), 1);
        assert_eq!(fields[0].name, "payments");
        assert_eq!(fields[0].type_name, "PaymentService");
        assert_eq!(injections[0].type_name, "PaymentService");
    }
}
