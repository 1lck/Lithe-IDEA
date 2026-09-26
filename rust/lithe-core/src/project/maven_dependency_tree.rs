//! Maven dependency trees read from the file the dependency plugin writes.
//!
//! The tool window asks `maven-dependency-plugin:tree` for its verbose text
//! tree and sends it to a platform-owned file through `-DoutputFile`, so the
//! tree never shares a channel or a size budget with Maven's console log.
//! Resolution semantics stay with Maven: Core only validates the file's
//! structure and turns each node's annotations into explicit fields.
//!
//! The plugin version is pinned, which fixes the serialization format. Every
//! line after the root must therefore be a well-formed node carrying only
//! annotations that version produces; anything else is reported as a format
//! failure instead of being skipped, because skipping would present a partial
//! tree as a successful result.
//!
//! Note: the data-source decision is recorded in .agents/notes/implemented/architecture/2026-09-26-maven-dependency-tree-output-file.md

use super::maven::normalized_project_path;
use crate::protocol::{
    CoreError, ErrorCode, MavenDependenciesResponse, MavenDependencyResolutionResponse,
    MavenDependencyResponse,
};
use serde::Deserialize;
use std::fs::File;
use std::io::{BufRead, BufReader, ErrorKind, Read};
use std::path::Path;

/// Fully qualified goal; pinning the version pins the text format parsed here.
const DEPENDENCY_PLUGIN_GOAL: &str = "org.apache.maven.plugins:maven-dependency-plugin:3.8.1:tree";
/// Most nodes accepted from one module's tree.
const MAX_NODES: usize = 10_000;
/// Deepest nesting accepted; each level adds one three-character indent.
const MAX_DEPTH: usize = 64;
/// Longest accepted line in bytes. The deepest indent plus a long coordinate
/// and every annotation the plugin writes stays well below this.
const MAX_LINE_BYTES: usize = 4 * 1024;
/// Largest accepted tree file: the root line plus the node limit, each at the
/// line limit. The budget follows from the tree limits, not from log volume.
const MAX_TREE_BYTES: u64 = ((MAX_NODES + 1) * MAX_LINE_BYTES) as u64;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Dependency-tree file written by one `maven.dependencyPlan` invocation.
pub struct MavenDependenciesRequest {
    /// Reactor-relative module the plan selected; `.` is the reactor root.
    pub module_path: String,
    /// Absolute platform-owned path passed to the same plan as `outputFile`.
    /// The platform creates a fresh path per invocation and removes it after
    /// the result, cancellation, or failure, so a file from an earlier run is
    /// never read here.
    pub output_file: String,
}

/// Validates the platform-owned file the plugin will write the tree to.
pub(crate) fn validated_output_file(value: &str) -> Result<String, CoreError> {
    let invalid = || {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Maven dependency-tree output path is invalid",
        )
    };
    let trimmed = value.trim();
    // The path becomes one `-DoutputFile=` argument. Surrounding whitespace or
    // control characters would change which file Maven writes.
    if trimmed.is_empty() || trimmed != value || value.chars().any(char::is_control) {
        return Err(invalid());
    }
    if !Path::new(value).is_absolute() {
        return Err(invalid());
    }
    Ok(value.to_string())
}

/// Plugin goal and properties that write one module's verbose tree to a file.
///
/// Every format-affecting property is explicit so user or project defaults
/// cannot change the parsed representation: text output, standard tree
/// tokens, UTF-8, and overwrite rather than append.
pub(crate) fn dependency_tree_arguments(output_file: &str) -> Vec<String> {
    vec![
        DEPENDENCY_PLUGIN_GOAL.to_string(),
        "-Dverbose=true".to_string(),
        "-DoutputType=text".to_string(),
        "-Dtokens=standard".to_string(),
        format!("-DoutputFile={output_file}"),
        "-DoutputEncoding=UTF-8".to_string(),
        "-DappendOutput=false".to_string(),
        "-Dstyle.color=never".to_string(),
        "-Duser.language=en".to_string(),
        "-Duser.country=US".to_string(),
    ]
}

/// Reads and normalizes the tree file written by a finished dependency plan.
pub fn dependencies(
    request: MavenDependenciesRequest,
) -> Result<MavenDependenciesResponse, CoreError> {
    let module_path = normalized_project_path(&request.module_path, "Maven module")?;
    let output_file = validated_output_file(&request.output_file)?;
    let parsed = read_tree_file(Path::new(&output_file), &module_path)?;

    let mut cursor = 0;
    let dependencies = if parsed.is_empty() {
        Vec::new()
    } else {
        if parsed[0].depth != 0 {
            return Err(invalid_structure());
        }
        let dependencies = build_level(&parsed, &mut cursor, 0)?;
        if cursor != parsed.len() {
            return Err(invalid_structure());
        }
        dependencies
    };
    Ok(MavenDependenciesResponse {
        module_path,
        dependencies,
    })
}

struct ParsedDependency {
    depth: usize,
    node: MavenDependencyResponse,
}

fn read_tree_file(path: &Path, module_path: &str) -> Result<Vec<ParsedDependency>, CoreError> {
    let file = File::open(path).map_err(|error| {
        if error.kind() == ErrorKind::NotFound {
            // A successful exit without the file means the plugin did not
            // honor `outputFile`, for example because the project's POM
            // configures a different output for the dependency plugin.
            CoreError::new(
                ErrorCode::ProcessFailed,
                "Maven finished without writing the dependency tree",
            )
        } else {
            CoreError::new(
                ErrorCode::ProcessFailed,
                "Unable to read the Maven dependency tree",
            )
            .with_details(error.kind().to_string())
        }
    })?;
    let length = file
        .metadata()
        .map_err(|error| {
            CoreError::new(
                ErrorCode::ProcessFailed,
                "Unable to read the Maven dependency tree",
            )
            .with_details(error.kind().to_string())
        })?
        .len();
    if length > MAX_TREE_BYTES {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Maven dependency tree exceeds the supported size",
        )
        .with_details(format!("maximumBytes={MAX_TREE_BYTES}")));
    }

    // `take` keeps the bound even if the file grows after the size check.
    let mut reader = BufReader::new(file.take(MAX_TREE_BYTES + 1));
    let mut line = Vec::new();
    let mut line_number = 0usize;
    let mut saw_root = false;
    let mut parsed = Vec::new();
    loop {
        line.clear();
        let read = reader.read_until(b'\n', &mut line).map_err(|error| {
            CoreError::new(
                ErrorCode::ProcessFailed,
                "Unable to read the Maven dependency tree",
            )
            .with_details(error.kind().to_string())
        })?;
        if read == 0 {
            break;
        }
        line_number += 1;
        if line.len() > MAX_LINE_BYTES {
            return Err(unexpected_format(line_number));
        }
        let text = std::str::from_utf8(&line).map_err(|_| unexpected_format(line_number))?;
        // The plugin writes with the JVM line separator, so Windows files use CRLF.
        let text = text.trim_end_matches(['\n', '\r']);
        if text.trim().is_empty() {
            continue;
        }
        if !saw_root {
            if !is_root_line(text) {
                return Err(unexpected_format(line_number));
            }
            saw_root = true;
            continue;
        }
        let entry = parse_line(text, module_path)?.ok_or_else(|| unexpected_format(line_number))?;
        if parsed.len() == MAX_NODES {
            return Err(CoreError::new(
                ErrorCode::ParseFailed,
                "Maven dependency count exceeds the supported limit",
            )
            .with_details(format!("maximumNodes={MAX_NODES}")));
        }
        parsed.push(entry);
    }
    if !saw_root {
        return Err(unexpected_format(0));
    }
    Ok(parsed)
}

/// The first line names the module itself as `group:artifact:packaging:version`.
fn is_root_line(line: &str) -> bool {
    let parts = line.split(':').collect::<Vec<_>>();
    !line.starts_with(char::is_whitespace)
        && !line.starts_with(['+', '\\', '|', '('])
        && parts.len() >= 4
        && parts.iter().all(|part| !part.trim().is_empty())
}

fn parse_line(line: &str, module_path: &str) -> Result<Option<ParsedDependency>, CoreError> {
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
    if depth >= MAX_DEPTH {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Maven dependency tree exceeds the supported depth",
        )
        .with_details(format!("maximumDepth={MAX_DEPTH}")));
    }

    let value = &line[(marker + 3)..];
    // Included nodes are written as `coordinate (items)` and omitted nodes as
    // `(coordinate - items)`; items are separated by `; ` in both forms.
    let (coordinate, items) = if let Some(inner) = value
        .strip_prefix('(')
        .and_then(|value| value.strip_suffix(')'))
    {
        match inner.split_once(" - ") {
            Some((coordinate, items)) => (coordinate, Some(items)),
            None => return Ok(None),
        }
    } else if let Some((coordinate, items)) = value.split_once(" (") {
        match items.strip_suffix(')') {
            Some(items) => (coordinate, Some(items)),
            None => return Ok(None),
        }
    } else {
        (value, None)
    };
    let Some(coordinate) = parse_coordinate(coordinate) else {
        return Ok(None);
    };
    let Some(annotations) = parse_annotations(items) else {
        return Ok(None);
    };
    // Only the omitted form may carry the omission item, and it must carry one.
    if value.starts_with('(') != annotations.omission.is_some() {
        return Ok(None);
    }
    let (resolution, selected_version) = match annotations.omission {
        None => (MavenDependencyResolutionResponse::Resolved, None),
        Some(Omission::Duplicate) => (MavenDependencyResolutionResponse::OmittedDuplicate, None),
        Some(Omission::Conflict(winner)) => (
            MavenDependencyResolutionResponse::OmittedConflict,
            Some(winner),
        ),
    };
    Ok(Some(ParsedDependency {
        depth,
        node: MavenDependencyResponse {
            module_path: module_path.to_string(),
            group_id: coordinate.group_id.to_string(),
            artifact_id: coordinate.artifact_id.to_string(),
            version: coordinate.version.to_string(),
            r#type: coordinate.artifact_type.to_string(),
            classifier: coordinate.classifier.map(str::to_string),
            scope: coordinate.scope.to_string(),
            resolution,
            selected_version,
            premanaged_version: annotations.premanaged_version,
            premanaged_scope: annotations.premanaged_scope,
            original_scope: annotations.original_scope,
            ignored_scope: annotations.ignored_scope,
            children: Vec::new(),
        },
    }))
}

struct Coordinate<'a> {
    group_id: &'a str,
    artifact_id: &'a str,
    artifact_type: &'a str,
    classifier: Option<&'a str>,
    version: &'a str,
    scope: &'a str,
}

/// Splits `group:artifact:type[:classifier]:version:scope`.
fn parse_coordinate(value: &str) -> Option<Coordinate<'_>> {
    let parts = value.split(':').collect::<Vec<_>>();
    let coordinate = match parts.as_slice() {
        [group_id, artifact_id, artifact_type, version, scope] => Coordinate {
            group_id,
            artifact_id,
            artifact_type,
            classifier: None,
            version,
            scope,
        },
        [group_id, artifact_id, artifact_type, classifier, version, scope] => Coordinate {
            group_id,
            artifact_id,
            artifact_type,
            classifier: Some(classifier),
            version,
            scope,
        },
        _ => return None,
    };
    let required = [
        coordinate.group_id,
        coordinate.artifact_id,
        coordinate.artifact_type,
        coordinate.version,
        coordinate.scope,
    ];
    let valid = required
        .iter()
        .chain(coordinate.classifier.iter())
        .all(|part| !part.is_empty() && !part.contains(char::is_whitespace));
    valid.then_some(coordinate)
}

/// Why Maven left an occurrence out of the effective tree.
enum Omission {
    /// The same version was already selected elsewhere in the tree.
    Duplicate,
    /// Another version won mediation; holds the selected version.
    Conflict(String),
}

/// Annotation items the pinned plugin writes after a node's coordinate.
#[derive(Default)]
struct Annotations {
    /// `version managed from X`: the version before dependency management.
    premanaged_version: Option<String>,
    /// `scope managed from X`: the scope before dependency management.
    premanaged_scope: Option<String>,
    /// `scope updated from X`: the declared scope before mediation widened it.
    original_scope: Option<String>,
    /// `scope not updated to X`: a wider scope mediation did not apply.
    ignored_scope: Option<String>,
    omission: Option<Omission>,
}

fn parse_annotations(items: Option<&str>) -> Option<Annotations> {
    let mut annotations = Annotations::default();
    let Some(items) = items else {
        return Some(annotations);
    };
    for item in items.split("; ") {
        let slot_and_value = [
            ("version managed from ", &mut annotations.premanaged_version),
            ("scope managed from ", &mut annotations.premanaged_scope),
            ("scope updated from ", &mut annotations.original_scope),
            ("scope not updated to ", &mut annotations.ignored_scope),
        ]
        .into_iter()
        .find_map(|(prefix, slot)| item.strip_prefix(prefix).map(|value| (slot, value)));
        if let Some((slot, value)) = slot_and_value {
            if slot.is_some() || !is_token(value) {
                return None;
            }
            *slot = Some(value.to_string());
            continue;
        }
        if annotations.omission.is_some() {
            return None;
        }
        if item == "omitted for duplicate" {
            annotations.omission = Some(Omission::Duplicate);
        } else if let Some(winner) = item.strip_prefix("omitted for conflict with ") {
            if !is_token(winner) {
                return None;
            }
            annotations.omission = Some(Omission::Conflict(winner.to_string()));
        } else {
            return None;
        }
    }
    Some(annotations)
}

fn is_token(value: &str) -> bool {
    !value.is_empty() && !value.contains(char::is_whitespace)
}

fn build_level(
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
            return Err(invalid_structure());
        }
        let mut dependency = parsed[*cursor].node.clone();
        *cursor += 1;
        if *cursor < parsed.len() {
            let next_depth = parsed[*cursor].depth;
            if next_depth > depth + 1 {
                return Err(invalid_structure());
            }
            if next_depth == depth + 1 {
                dependency.children = build_level(parsed, cursor, depth + 1)?;
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

fn invalid_structure() -> CoreError {
    CoreError::new(
        ErrorCode::ParseFailed,
        "Maven dependency tree structure is invalid",
    )
}

fn unexpected_format(line_number: usize) -> CoreError {
    CoreError::new(
        ErrorCode::ParseFailed,
        "Maven dependency tree is not in the expected text format",
    )
    .with_details(format!("line={line_number}"))
}
