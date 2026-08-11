use crate::protocol::{CoreError, ErrorCode};
use crate::protocol::{
    JavaClassNameResponse, JavaCodeVisionHintResponse, JavaCodeVisionResponse,
    JavaFoldRegionResponse, JavaImplementationMarkerResponse, JavaInlayHintResponse,
    JavaMainClassResponse, JavaRunConfigurationResponse, JavaRunConfigurationsResponse,
    JavaServerPortResponse, JavaStructureResponse,
};
use regex::Regex;
use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Component, Path, PathBuf};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaRunConfigurationsRequest {
    pub root: String,
    #[serde(default)]
    pub paths: Vec<String>,
    #[serde(default)]
    pub module_paths: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaStructureRequest {
    pub source: String,
    #[serde(default)]
    pub declaration_sources: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaCodeVisionRequest {
    pub root: String,
    pub target_path: String,
    #[serde(default)]
    pub paths: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaClassNameRequest {
    pub source: String,
    pub simple_name: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaSourceDefinitionRequest {
    pub source: String,
    pub declaration_name: String,
    #[serde(default)]
    pub member_name: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaServerPortRequest {
    pub content: String,
    pub file_extension: String,
}

pub fn run_configurations(
    request: JavaRunConfigurationsRequest,
) -> Result<JavaRunConfigurationsResponse, CoreError> {
    let root = existing_root(&request.root)?;
    let mut main_classes = Vec::new();
    for path in request.paths {
        if !path.to_lowercase().ends_with(".java") {
            continue;
        }
        let relative = normalize_relative(&path).ok_or_else(|| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "Java source path must be relative",
            )
        })?;
        let source = fs::read_to_string(root.join(&relative)).map_err(|error| {
            CoreError::new(ErrorCode::ParseFailed, "Could not read Java source")
                .with_details(error.to_string())
        })?;
        if let Some(value) = main_class(&relative, &source) {
            main_classes.push(value);
        }
    }

    let mut configurations = main_classes
        .iter()
        .map(|value| JavaRunConfigurationResponse {
            id: if value.is_spring_boot {
                format!("spring:{}", value.qualified_name)
            } else {
                format!("java-main:{}", value.qualified_name)
            },
            name: value.simple_name.clone(),
            kind: if value.is_spring_boot {
                "springBoot".to_string()
            } else {
                "javaMain".to_string()
            },
            module_path: module_path(&value.path, &request.module_paths),
            main_class: Some(value.qualified_name.clone()),
        })
        .collect::<Vec<_>>();
    configurations.sort_by(|left, right| {
        kind_order(&left.kind)
            .cmp(&kind_order(&right.kind))
            .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
    });

    Ok(JavaRunConfigurationsResponse {
        main_classes,
        configurations,
    })
}

pub fn structure(request: JavaStructureRequest) -> Result<JavaStructureResponse, CoreError> {
    let source = request.source;
    Ok(JavaStructureResponse {
        fold_regions: fold_regions(&source),
        implementation_markers: implementation_markers(&source),
        inlay_hints: parameter_hints(&source, &request.declaration_sources),
    })
}

pub fn code_vision(request: JavaCodeVisionRequest) -> Result<JavaCodeVisionResponse, CoreError> {
    let root = existing_root(&request.root)?;
    let target_path = normalize_relative(&request.target_path).ok_or_else(|| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Java target path must be relative",
        )
    })?;
    let target_source = fs::read_to_string(root.join(&target_path)).map_err(|error| {
        CoreError::new(ErrorCode::ParseFailed, "Could not read Java target source")
            .with_details(error.to_string())
    })?;
    let mut sources = Vec::new();
    for path in request.paths {
        let Some(relative) = normalize_relative(&path) else {
            continue;
        };
        if !relative.to_lowercase().ends_with(".java") {
            continue;
        }
        if let Ok(source) = fs::read_to_string(root.join(relative)) {
            sources.push(source);
        }
    }
    let mut hints = Vec::new();
    for (line, column, symbol) in java_declarations(&target_source) {
        let expression =
            Regex::new(&format!(r"\b{}\b", regex::escape(&symbol))).map_err(|error| {
                CoreError::new(ErrorCode::ParseFailed, "Could not parse Java symbol")
                    .with_details(error.to_string())
            })?;
        let count = sources
            .iter()
            .map(|source| expression.find_iter(source).count())
            .sum::<usize>();
        hints.push(JavaCodeVisionHintResponse {
            line,
            utf16_column: column,
            symbol,
            usage_count: count.saturating_sub(1),
        });
    }
    Ok(JavaCodeVisionResponse { hints })
}

pub fn class_name(request: JavaClassNameRequest) -> Result<JavaClassNameResponse, CoreError> {
    let package = Regex::new(r"(?m)^\s*package\s+([A-Za-z_][A-Za-z0-9_.]*)\s*;")
        .expect("static Java package expression is valid")
        .captures(&request.source)
        .and_then(|captures| captures.get(1).map(|value| value.as_str().to_string()));
    Ok(JavaClassNameResponse {
        class_name: package
            .map(|value| format!("{}.{}", value, request.simple_name))
            .unwrap_or(request.simple_name),
    })
}

pub fn source_definition(
    request: JavaSourceDefinitionRequest,
) -> Result<Option<crate::protocol::JavaSourceDefinitionResponse>, CoreError> {
    let lines = request.source.split('\n').collect::<Vec<_>>();
    if let Some(member) = request.member_name {
        let method =
            Regex::new(&format!(r"\b{}\s*\(", regex::escape(&member))).map_err(|error| {
                CoreError::new(ErrorCode::ParseFailed, "Could not parse Java member")
                    .with_details(error.to_string())
            })?;
        for (line_number, line) in lines.iter().enumerate() {
            if let Some(found) = method.find(line) {
                let prefix = line[..found.start()].trim();
                if !prefix.starts_with('*')
                    && !prefix.starts_with("//")
                    && !prefix.contains('#')
                    && !prefix.ends_with('.')
                {
                    return Ok(Some(crate::protocol::JavaSourceDefinitionResponse {
                        line: line_number,
                        utf16_column: utf16_column(line, found.start()),
                    }));
                }
            }
        }
        let field =
            Regex::new(&format!(r"\b{}\s*(?:=|;)", regex::escape(&member))).map_err(|error| {
                CoreError::new(ErrorCode::ParseFailed, "Could not parse Java field")
                    .with_details(error.to_string())
            })?;
        for (line_number, line) in lines.iter().enumerate() {
            if let Some(found) = field.find(line) {
                return Ok(Some(crate::protocol::JavaSourceDefinitionResponse {
                    line: line_number,
                    utf16_column: utf16_column(line, found.start()),
                }));
            }
        }
    }

    let declaration = Regex::new(&format!(
        r"\b(?:class|interface|enum|record)\s+{}\b",
        regex::escape(&request.declaration_name)
    ))
    .map_err(|error| {
        CoreError::new(ErrorCode::ParseFailed, "Could not parse Java declaration")
            .with_details(error.to_string())
    })?;
    for (line_number, line) in lines.iter().enumerate() {
        if let Some(found) = declaration.find(line) {
            let offset = line[found.start()..found.end()]
                .find(&request.declaration_name)
                .map(|value| found.start() + value)
                .unwrap_or(found.start());
            return Ok(Some(crate::protocol::JavaSourceDefinitionResponse {
                line: line_number,
                utf16_column: utf16_column(line, offset),
            }));
        }
    }
    Ok(None)
}

pub fn server_port(request: JavaServerPortRequest) -> Result<JavaServerPortResponse, CoreError> {
    if request.file_extension.eq_ignore_ascii_case("properties") {
        for line in request.content.lines() {
            let value = line.trim();
            if value.starts_with('#') {
                continue;
            }
            let Some((key, port)) =
                value.split_once(|character| character == ':' || character == '=')
            else {
                continue;
            };
            if key.trim() == "server.port" {
                return Ok(JavaServerPortResponse {
                    port: port.trim().parse().ok(),
                });
            }
        }
        return Ok(JavaServerPortResponse { port: None });
    }

    let mut in_server_section = false;
    for line in request.content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if trimmed == "server:" {
            in_server_section = true;
            continue;
        }
        if in_server_section && line.chars().next().is_some_and(char::is_whitespace) {
            if let Some((key, port)) = trimmed.split_once(':') {
                if key.trim() == "port" {
                    return Ok(JavaServerPortResponse {
                        port: port.trim().parse().ok(),
                    });
                }
            }
            continue;
        }
        in_server_section = false;
    }
    Ok(JavaServerPortResponse { port: None })
}

fn main_class(path: &str, source: &str) -> Option<JavaMainClassResponse> {
    let main_pattern = Regex::new(r"\bstatic\s+(?:final\s+)?void\s+main\s*\(").ok()?;
    if !main_pattern.is_match(source) {
        return None;
    }
    let class_pattern =
        Regex::new(r"\b(?:public\s+)?(?:final\s+)?class\s+([A-Za-z_$][A-Za-z0-9_$]*)").ok()?;
    let simple_name = class_pattern.captures(source)?.get(1)?.as_str().to_string();
    let package = Regex::new(r"(?m)^\s*package\s+([A-Za-z_$][A-Za-z0-9_$.]*)\s*;")
        .ok()?
        .captures(source)
        .and_then(|captures| captures.get(1).map(|value| value.as_str().to_string()));
    let qualified_name = package
        .map(|value| format!("{}.{}", value, simple_name))
        .unwrap_or_else(|| simple_name.clone());
    Some(JavaMainClassResponse {
        path: path.to_string(),
        qualified_name,
        simple_name,
        is_spring_boot: source.contains("@SpringBootApplication"),
    })
}

fn module_path(path: &str, modules: &[String]) -> Option<String> {
    modules
        .iter()
        .filter(|module| is_inside(path, module))
        .max_by_key(|module| module.len())
        .cloned()
}

fn is_inside(path: &str, directory: &str) -> bool {
    path == directory || path.starts_with(&(directory.trim_end_matches('/').to_string() + "/"))
}

fn kind_order(kind: &str) -> usize {
    match kind {
        "springBoot" => 0,
        "javaMain" => 1,
        _ => 2,
    }
}

fn fold_regions(source: &str) -> Vec<JavaFoldRegionResponse> {
    let mut regions = import_region(source).into_iter().collect::<Vec<_>>();
    regions.extend(comment_regions(source));
    regions.extend(brace_regions(source));
    regions.sort_by(|left, right| {
        left.start_line
            .cmp(&right.start_line)
            .then_with(|| right.end_line.cmp(&left.end_line))
    });
    regions
}

fn import_region(source: &str) -> Option<JavaFoldRegionResponse> {
    let expression = Regex::new(r"(?m)^[ \t]*import[ \t]+[^;]+;[ \t]*$").ok()?;
    let matches = expression.find_iter(source).collect::<Vec<_>>();
    let first = matches.first()?;
    let last = matches.last()?;
    if matches.len() < 2 {
        return None;
    }
    Some(JavaFoldRegionResponse {
        kind: "imports".to_string(),
        start_line: line_number(source, first.start()),
        end_line: line_number(source, last.start()),
        hidden_start: utf16_offset(source, line_end(source, first.start())),
        hidden_length: utf16_offset(source, line_end(source, last.start()))
            .saturating_sub(utf16_offset(source, line_end(source, first.start()))),
    })
}

fn comment_regions(source: &str) -> Vec<JavaFoldRegionResponse> {
    let Ok(expression) = Regex::new(r"/\*[\s\S]*?\*/") else {
        return Vec::new();
    };
    expression
        .find_iter(source)
        .filter_map(|matched| {
            let start_line = line_number(source, matched.start());
            let end_line = line_number(source, matched.end());
            (end_line > start_line).then(|| JavaFoldRegionResponse {
                kind: "comment".to_string(),
                start_line,
                end_line,
                hidden_start: utf16_offset(source, line_end(source, matched.start())),
                hidden_length: utf16_offset(source, matched.end())
                    .saturating_sub(utf16_offset(source, line_end(source, matched.start()))),
            })
        })
        .collect()
}

fn brace_regions(source: &str) -> Vec<JavaFoldRegionResponse> {
    let bytes = source.as_bytes();
    let mut stack: Vec<(usize, String)> = Vec::new();
    let mut regions = Vec::new();
    let mut index = 0;
    let mut state = ScanState::Code;
    while index < bytes.len() {
        let character = bytes[index];
        let next = bytes.get(index + 1).copied().unwrap_or_default();
        match state {
            ScanState::Code => match character {
                b'"' => state = ScanState::String,
                b'\'' => state = ScanState::Character,
                b'/' if next == b'/' => {
                    state = ScanState::LineComment;
                    index += 1;
                }
                b'/' if next == b'*' => {
                    state = ScanState::BlockComment;
                    index += 1;
                }
                b'{' => {
                    let start = line_start(source, index);
                    stack.push((index, source[start..index].to_string()));
                }
                b'}' => {
                    if let Some((opening, prefix)) = stack.pop() {
                        let start_line = line_number(source, opening);
                        let end_line = line_number(source, index);
                        let hidden_start = line_end(source, opening);
                        let hidden_end = line_start(source, index);
                        if end_line > start_line && hidden_end > hidden_start {
                            regions.push(JavaFoldRegionResponse {
                                kind: classify(&prefix),
                                start_line,
                                end_line,
                                hidden_start: utf16_offset(source, hidden_start),
                                hidden_length: utf16_offset(source, hidden_end)
                                    .saturating_sub(utf16_offset(source, hidden_start)),
                            });
                        }
                    }
                }
                _ => {}
            },
            ScanState::String => {
                if character == b'\\' {
                    index += 1;
                } else if character == b'"' {
                    state = ScanState::Code;
                }
            }
            ScanState::Character => {
                if character == b'\\' {
                    index += 1;
                } else if character == b'\'' {
                    state = ScanState::Code;
                }
            }
            ScanState::LineComment => {
                if character == b'\n' {
                    state = ScanState::Code;
                }
            }
            ScanState::BlockComment => {
                if character == b'*' && next == b'/' {
                    state = ScanState::Code;
                    index += 1;
                }
            }
        }
        index += 1;
    }
    regions
}

fn classify(prefix: &str) -> String {
    if Regex::new(r"\b(class|interface|enum|record|struct|protocol|extension|actor)\b")
        .expect("static Java type expression is valid")
        .is_match(prefix)
    {
        "type".to_string()
    } else if prefix.contains('(') && prefix.contains(')') {
        "method".to_string()
    } else {
        "block".to_string()
    }
}

fn implementation_markers(source: &str) -> Vec<JavaImplementationMarkerResponse> {
    let mut markers = Vec::new();
    if let Ok(expression) = Regex::new(
        r"(?m)^[ \t]*(?:(?:public|protected|private|abstract|sealed|non-sealed)\s+)*interface\s+[A-Za-z_$][A-Za-z0-9_$]*",
    ) {
        for matched in expression.find_iter(source) {
            let location = source[matched.start()..matched.end()]
                .find("interface")
                .map(|value| matched.start() + value)
                .unwrap_or(matched.start());
            markers.push(JavaImplementationMarkerResponse {
                line: line_number(source, location),
                utf16_column: utf16_offset(source, location)
                    .saturating_sub(utf16_offset(source, line_start(source, location))),
                implementation_count: 0,
                direction: "down".to_string(),
            });
        }
    }
    if let Ok(expression) = Regex::new(
        r"(?m)^[ \t]*(?:(?:public|protected|private|abstract|static|default|final|native|synchronized|strictfp)\s+)*(?:<[^>\n]+>\s+)?(?:[A-Za-z_$][A-Za-z0-9_$<>,.?\[\]]*\s+)+[A-Za-z_$][A-Za-z0-9_$]*\s*\([^;{}\n]*\)\s*(?:throws\s+[^;]+)?;\s*$",
    ) {
        for matched in expression.find_iter(source) {
            let location = method_name_location(source, matched.start(), matched.end());
            markers.push(JavaImplementationMarkerResponse {
                line: line_number(source, location),
                utf16_column: utf16_offset(source, location)
                    .saturating_sub(utf16_offset(source, line_start(source, location))),
                implementation_count: 0,
                direction: if has_override_annotation(source, line_number(source, location)) {
                    "up"
                } else {
                    "down"
                }
                .to_string(),
            });
        }
    }
    if let Ok(method_expression) = Regex::new(
        r"(?:(?:public|protected|private|abstract|static|default|final|native|synchronized|strictfp)\s+)*(?:<[^>\n]+>\s+)?(?:[A-Za-z_$][A-Za-z0-9_$<>,.?\[\]]*\s+)+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(",
    ) {
        let lines = source.split('\n').collect::<Vec<_>>();
        for (line_index, line) in lines.iter().enumerate() {
            if line.contains("@Override") {
                let mut candidate_line = line_index;
                if !line.contains('(') {
                    for next_line in (line_index + 1)..lines.len().min(line_index + 4) {
                        if lines[next_line].contains('(') {
                            candidate_line = next_line;
                            break;
                        }
                    }
                }
                let candidate_start = lines[..candidate_line]
                    .iter()
                    .map(|value| value.len() + 1)
                    .sum::<usize>();
                if let Some(matched) = method_expression.find(lines[candidate_line]) {
                    let name_start = method_expression
                        .captures(lines[candidate_line])
                        .and_then(|captures| captures.get(1).map(|value| value.start()))
                        .unwrap_or(matched.start());
                    let location = candidate_start + name_start;
                    markers.push(JavaImplementationMarkerResponse {
                        line: candidate_line,
                        utf16_column: utf16_offset(source, location)
                            .saturating_sub(utf16_offset(source, line_start(source, location))),
                        implementation_count: 0,
                        direction: "up".to_string(),
                    });
                }
            }
        }
    }
    deduplicate_markers(markers)
}

fn deduplicate_markers(
    values: Vec<JavaImplementationMarkerResponse>,
) -> Vec<JavaImplementationMarkerResponse> {
    let mut seen = HashSet::new();
    let mut values = values
        .into_iter()
        .filter(|value| seen.insert((value.line, value.utf16_column, value.direction.clone())))
        .collect::<Vec<_>>();
    values.sort_by(|left, right| {
        left.line
            .cmp(&right.line)
            .then_with(|| left.utf16_column.cmp(&right.utf16_column))
    });
    values
}

fn parameter_hints(source: &str, declaration_sources: &[String]) -> Vec<JavaInlayHintResponse> {
    let declaration_pattern =
        Regex::new(r"\b([A-Za-z_$][A-Za-z0-9_$]*)[ \t]*\(([^(){};]*)\)[ \t]*(?:throws[^{]+)?\{")
            .expect("static Java declaration expression is valid");
    let mut declarations: HashMap<String, Vec<Vec<String>>> = HashMap::new();
    for text in declaration_sources {
        for matched in declaration_pattern.captures_iter(text) {
            let Some(name) = matched.get(1).map(|value| value.as_str()) else {
                continue;
            };
            if ["if", "for", "while", "switch", "catch", "new"].contains(&name) {
                continue;
            }
            let parameters = matched
                .get(2)
                .map(|value| split_parameters(value.as_str()))
                .unwrap_or_default();
            if !parameters.is_empty() {
                declarations
                    .entry(name.to_string())
                    .or_default()
                    .push(parameters);
            }
        }
    }
    let call_pattern = Regex::new(r"\b([A-Za-z_$][A-Za-z0-9_$]*)[ \t]*\(([^(){};]*)\)")
        .expect("static Java call expression is valid");
    let mut hints = Vec::new();
    for matched in call_pattern.captures_iter(source) {
        let Some(name) = matched.get(1).map(|value| value.as_str()) else {
            continue;
        };
        let Some(arguments) = matched.get(2) else {
            continue;
        };
        if looks_like_parameter_list(arguments.as_str()) {
            continue;
        }
        let starts = argument_starts(source, arguments.start(), arguments.end());
        let Some(parameters) = declarations
            .get(name)
            .and_then(|values| values.iter().find(|value| value.len() == starts.len()))
        else {
            continue;
        };
        let suffix = source[matched.get(0).unwrap().end()..]
            .chars()
            .take(40)
            .collect::<String>();
        let suffix = suffix.trim_start();
        if suffix.starts_with('{') || suffix.starts_with("throws ") {
            continue;
        }
        for (index, start) in starts.iter().enumerate() {
            hints.push(JavaInlayHintResponse {
                line: line_number(source, *start),
                utf16_column: utf16_offset(source, *start)
                    .saturating_sub(utf16_offset(source, line_start(source, *start))),
                label: parameters[index].clone(),
            });
        }
    }
    let mut seen = HashSet::new();
    hints.retain(|value| seen.insert((value.line, value.utf16_column, value.label.clone())));
    hints.sort_by(|left, right| {
        left.line
            .cmp(&right.line)
            .then_with(|| left.utf16_column.cmp(&right.utf16_column))
    });
    hints
}

fn java_declarations(source: &str) -> Vec<(usize, usize, String)> {
    let type_pattern =
        Regex::new(r"\b(?:class|interface|enum|record)\s+([A-Za-z_$][A-Za-z0-9_$]*)")
            .expect("static Java type expression is valid");
    let method_pattern =
        Regex::new(r"\b([A-Za-z_$][A-Za-z0-9_$]*)\s*\([^;{}]*\)\s*(?:throws\s+[^{}]+)?\{")
            .expect("static Java method expression is valid");
    let ignored = [
        "if",
        "for",
        "while",
        "switch",
        "catch",
        "try",
        "synchronized",
        "new",
    ];
    let mut result = Vec::new();
    for (line_index, line) in source.split('\n').enumerate() {
        if let Some(captures) = type_pattern.captures(line) {
            if let Some(symbol) = captures.get(1) {
                result.push((
                    line_index,
                    utf16_column(line, symbol.start()),
                    symbol.as_str().to_string(),
                ));
                continue;
            }
        }
        if let Some(captures) = method_pattern.captures(line) {
            if let Some(symbol) = captures.get(1) {
                if !ignored.contains(&symbol.as_str()) {
                    result.push((
                        line_index,
                        utf16_column(line, symbol.start()),
                        symbol.as_str().to_string(),
                    ));
                }
            }
        }
    }
    result
}

fn utf16_column(line: &str, byte: usize) -> usize {
    line[..byte.min(line.len())].encode_utf16().count()
}

fn split_parameters(value: &str) -> Vec<String> {
    value
        .split(',')
        .filter_map(|parameter| {
            let cleaned = Regex::new(r"@[A-Za-z_$][A-Za-z0-9_$]*(?:\([^)]*\))?")
                .expect("static Java annotation expression is valid")
                .replace_all(parameter, "")
                .trim()
                .to_string();
            cleaned
                .split_whitespace()
                .last()
                .map(|value| value.to_string())
        })
        .collect()
}

fn looks_like_parameter_list(value: &str) -> bool {
    let identifier = Regex::new(r"^[A-Za-z_$][A-Za-z0-9_$]*$")
        .expect("static Java identifier expression is valid");
    !value.trim().is_empty()
        && value.split(',').all(|item| {
            let words = item.split_whitespace().collect::<Vec<_>>();
            words.len() >= 2 && identifier.is_match(words.last().copied().unwrap_or_default())
        })
}

fn argument_starts(source: &str, start: usize, end: usize) -> Vec<usize> {
    if start >= end {
        return Vec::new();
    }
    let bytes = source.as_bytes();
    let mut result = Vec::new();
    let mut item_start = start;
    let mut index = start;
    let mut depth: usize = 0;
    let mut quote = None;
    while index < end {
        let character = bytes[index];
        if let Some(active) = quote {
            if character == b'\\' {
                index += 1;
            } else if character == active {
                quote = None;
            }
        } else if character == b'"' || character == b'\'' {
            quote = Some(character);
        } else if matches!(character, b'(' | b'[' | b'{') {
            depth += 1;
        } else if matches!(character, b')' | b']' | b'}') {
            depth = depth.saturating_sub(1);
        } else if character == b',' && depth == 0 {
            if let Some(value) = first_non_whitespace(source, item_start, index) {
                result.push(value);
            }
            item_start = index + 1;
        }
        index += 1;
    }
    if let Some(value) = first_non_whitespace(source, item_start, end) {
        result.push(value);
    }
    result
}

fn first_non_whitespace(source: &str, start: usize, end: usize) -> Option<usize> {
    source[start..end]
        .char_indices()
        .find(|(_, character)| !character.is_whitespace())
        .map(|(offset, _)| start + offset)
}

fn method_name_location(source: &str, start: usize, end: usize) -> usize {
    let opening = source[start..end]
        .find('(')
        .map(|value| start + value)
        .unwrap_or(start);
    let before = &source[start..opening];
    before
        .char_indices()
        .rev()
        .skip_while(|(_, value)| value.is_whitespace())
        .take_while(|(_, value)| value.is_ascii_alphanumeric() || *value == '_' || *value == '$')
        .last()
        .map(|(offset, _)| start + offset)
        .unwrap_or(start)
}

fn has_override_annotation(source: &str, line: usize) -> bool {
    let lines = source.split('\n').collect::<Vec<_>>();
    let start = line.saturating_sub(3);
    lines[start..line.min(lines.len())]
        .iter()
        .any(|value| value.contains("@Override"))
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

fn normalize_relative(value: &str) -> Option<String> {
    let path = Path::new(value.trim());
    if path.as_os_str().is_empty()
        || path.is_absolute()
        || path
            .components()
            .any(|value| matches!(value, Component::ParentDir))
    {
        return None;
    }
    Some(
        path.to_string_lossy()
            .replace('\\', "/")
            .trim_matches('/')
            .to_string(),
    )
}

fn line_number(source: &str, byte: usize) -> usize {
    source[..byte.min(source.len())]
        .bytes()
        .filter(|value| *value == b'\n')
        .count()
}

fn line_start(source: &str, byte: usize) -> usize {
    source[..byte.min(source.len())]
        .rfind('\n')
        .map(|value| value + 1)
        .unwrap_or(0)
}

fn line_end(source: &str, byte: usize) -> usize {
    source[byte.min(source.len())..]
        .find('\n')
        .map(|value| byte.min(source.len()) + value + 1)
        .unwrap_or(source.len())
}

fn utf16_offset(source: &str, byte: usize) -> usize {
    source[..byte.min(source.len())].encode_utf16().count()
}

enum ScanState {
    Code,
    String,
    Character,
    LineComment,
    BlockComment,
}
