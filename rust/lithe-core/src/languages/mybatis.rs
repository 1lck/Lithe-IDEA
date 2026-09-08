//! Deterministic MyBatis mapper-interface and XML statement indexing.

use crate::protocol::{CoreError, ErrorCode, MybatisIndexResponse, MybatisStatementResponse};
use regex::Regex;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::sync::LazyLock;
use tree_sitter::{Node, Parser};

static XML_COMMENT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?s)<!--.*?-->").expect("literal pattern is valid"));
static MAPPER_TAG: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"(?is)<mapper\b([^>]*)>"#).expect("literal pattern is valid"));
static STATEMENT_TAG: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?is)<(select|insert|update|delete)\b([^>]*)>"#)
        .expect("literal pattern is valid")
});
static ATTRIBUTE_NAMESPACE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"namespace\s*=\s*["']([^"']+)["']"#).expect("literal pattern is valid")
});
static ATTRIBUTE_ID: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"\bid\s*=\s*["']([^"']+)["']"#).expect("literal pattern is valid")
});

/// Regular Java and mapper XML files stay well below this; larger dumps are skipped.
const MAX_SOURCE_BYTES: u64 = 2 * 1024 * 1024;

#[cfg(test)]
thread_local! {
    static DISK_READS: std::cell::RefCell<Vec<String>> = const { std::cell::RefCell::new(Vec::new()) };
}

#[cfg(test)]
pub(crate) fn take_mybatis_disk_reads() -> Vec<String> {
    DISK_READS.with(|paths| paths.take())
}

#[cfg(test)]
fn record_disk_read(path: &str) {
    DISK_READS.with(|paths| paths.borrow_mut().push(path.to_string()));
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Workspace paths used to pair mapper interfaces with XML statements.
pub struct MybatisIndexRequest {
    /// Absolute workspace root. Relative paths are rejected.
    pub root: String,
    /// Workspace-relative Java and XML files to read.
    #[serde(default)]
    pub paths: Vec<String>,
    /// Unsaved buffer text keyed by workspace-relative path.
    #[serde(default)]
    pub text_overrides: HashMap<String, String>,
}

#[derive(Clone)]
struct JavaMethod {
    name: String,
    line: usize,
    column: usize,
    end_column: usize,
    end_line: usize,
}

#[derive(Clone)]
struct JavaType {
    qualified_name: String,
    path: String,
    methods: Vec<JavaMethod>,
}

struct XmlStatement {
    statement_id: String,
    kind: String,
    line: usize,
    column: usize,
    end_column: usize,
}

struct XmlMapper {
    namespace: String,
    path: String,
    statements: Vec<XmlStatement>,
}

/// Builds one cross-file MyBatis mapper index without starting a language server.
pub fn mybatis_index(request: MybatisIndexRequest) -> Result<MybatisIndexResponse, CoreError> {
    let root = existing_directory(&request.root)?;
    let paths = request
        .paths
        .into_iter()
        .filter_map(|path| normalize_relative(&path))
        .collect::<Vec<_>>();

    let mut parser = Parser::new();
    let java_parser = parser
        .set_language(&tree_sitter_java::LANGUAGE.into())
        .is_ok();

    let mut java_types = Vec::new();
    let mut xml_mappers = Vec::new();
    for path in &paths {
        if !is_mybatis_source_path(path) {
            continue;
        }
        let Some(content) = source_content(&root, path, &request.text_overrides) else {
            continue;
        };
        let relative = slash_path(path);
        match path
            .extension()
            .and_then(|value| value.to_str())
            .map(str::to_ascii_lowercase)
            .as_deref()
        {
            Some("java") if java_parser => {
                java_types.extend(java_mapper_types(&mut parser, &relative, &content));
            }
            Some("xml") => {
                if let Some(mapper) = xml_mapper(&relative, &content) {
                    xml_mappers.push(mapper);
                }
            }
            _ => {}
        }
    }

    java_types.sort_by(|left, right| {
        left.qualified_name
            .cmp(&right.qualified_name)
            .then_with(|| left.path.cmp(&right.path))
    });
    xml_mappers.sort_by(|left, right| {
        left.namespace
            .cmp(&right.namespace)
            .then_with(|| left.path.cmp(&right.path))
    });

    let mut statements = Vec::new();
    for mapper in &xml_mappers {
        let Some(java_type) = java_types
            .iter()
            .find(|candidate| candidate.qualified_name == mapper.namespace)
        else {
            continue;
        };
        for xml_statement in &mapper.statements {
            let Some(method) = java_type
                .methods
                .iter()
                .find(|candidate| candidate.name == xml_statement.statement_id)
            else {
                continue;
            };
            statements.push(MybatisStatementResponse {
                id: format!(
                    "{}#{}:{}:{}",
                    mapper.namespace, xml_statement.statement_id, mapper.path, xml_statement.line
                ),
                namespace: mapper.namespace.clone(),
                statement_id: xml_statement.statement_id.clone(),
                kind: xml_statement.kind.clone(),
                java_path: java_type.path.clone(),
                java_line: method.line,
                java_column: method.column,
                java_end_line: method.end_line,
                java_end_column: method.end_column,
                xml_path: mapper.path.clone(),
                xml_line: xml_statement.line,
                xml_column: xml_statement.column,
                xml_end_column: xml_statement.end_column,
            });
        }
    }
    statements.sort_by(|left, right| {
        left.namespace
            .cmp(&right.namespace)
            .then_with(|| left.statement_id.cmp(&right.statement_id))
            .then_with(|| left.xml_path.cmp(&right.xml_path))
            .then_with(|| left.xml_line.cmp(&right.xml_line))
            .then_with(|| left.java_path.cmp(&right.java_path))
            .then_with(|| left.java_line.cmp(&right.java_line))
    });
    Ok(MybatisIndexResponse { statements })
}

fn java_mapper_types(parser: &mut Parser, path: &str, source: &str) -> Vec<JavaType> {
    let Some(tree) = parser.parse(source, None) else {
        return Vec::new();
    };
    let bytes = source.as_bytes();
    let package = package_name(tree.root_node(), bytes);
    let mut types = Vec::new();
    collect_types(tree.root_node(), path, &package, source, bytes, &mut types);
    types
}

fn collect_types(
    node: Node<'_>,
    path: &str,
    package: &str,
    source: &str,
    bytes: &[u8],
    types: &mut Vec<JavaType>,
) {
    if matches!(node.kind(), "class_declaration" | "interface_declaration") {
        if let Some(java_type) = java_type(node, path, package, source, bytes) {
            types.push(java_type);
        }
    }
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_types(child, path, package, source, bytes, types);
    }
}

fn java_type(
    node: Node<'_>,
    path: &str,
    package: &str,
    source: &str,
    bytes: &[u8],
) -> Option<JavaType> {
    let qualified_name = qualified_type_name(node, package, bytes)?;
    let mut methods = Vec::new();
    if let Some(body) = node.child_by_field_name("body") {
        collect_abstract_methods(body, source, bytes, &mut methods);
    }
    Some(JavaType {
        qualified_name,
        path: path.to_string(),
        methods,
    })
}

fn collect_abstract_methods(
    body: Node<'_>,
    source: &str,
    bytes: &[u8],
    methods: &mut Vec<JavaMethod>,
) {
    let mut cursor = body.walk();
    for child in body.children(&mut cursor) {
        if child.kind() != "method_declaration" {
            continue;
        }
        // Methods with a body, including default methods, are not XML-mapped.
        if child.child_by_field_name("body").is_some() {
            continue;
        }
        let Some(name_node) = child.child_by_field_name("name") else {
            continue;
        };
        let Ok(name) = name_node.utf8_text(bytes) else {
            continue;
        };
        if methods.iter().any(|existing| existing.name == name) {
            continue;
        }
        let (line, column) = line_column(source, name_node.start_byte());
        let (_, end_column) = line_column(source, name_node.end_byte());
        let (end_line, _) = line_column(source, child.end_byte().saturating_sub(1));
        methods.push(JavaMethod {
            name: name.to_string(),
            line,
            column,
            end_column,
            end_line,
        });
    }
}

fn package_name(root: Node<'_>, bytes: &[u8]) -> String {
    let mut cursor = root.walk();
    for child in root.children(&mut cursor) {
        if child.kind() != "package_declaration" {
            continue;
        }
        let mut inner = child.walk();
        for part in child.children(&mut inner) {
            if matches!(part.kind(), "identifier" | "scoped_identifier") {
                return part.utf8_text(bytes).unwrap_or_default().to_string();
            }
        }
    }
    String::new()
}

fn qualified_type_name(mut node: Node<'_>, package: &str, bytes: &[u8]) -> Option<String> {
    let mut parts = Vec::new();
    loop {
        if matches!(node.kind(), "class_declaration" | "interface_declaration") {
            let name = node.child_by_field_name("name")?.utf8_text(bytes).ok()?;
            parts.push(name.to_string());
        }
        match node.parent() {
            Some(parent) => node = parent,
            None => break,
        }
    }
    parts.reverse();
    if parts.is_empty() {
        return None;
    }
    let joined = parts.join(".");
    Some(if package.is_empty() {
        joined
    } else {
        format!("{package}.{joined}")
    })
}

fn xml_mapper(path: &str, source: &str) -> Option<XmlMapper> {
    let comments = XML_COMMENT
        .find_iter(source)
        .map(|matched| matched.range())
        .collect::<Vec<_>>();
    let mapper = MAPPER_TAG.captures_iter(source).find(|capture| {
        capture
            .get(0)
            .is_some_and(|matched| !in_ranges(&comments, matched.start()))
    })?;
    let attributes = mapper.get(1)?.as_str();
    let namespace = ATTRIBUTE_NAMESPACE
        .captures(attributes)
        .and_then(|capture| capture.get(1))
        .map(|value| value.as_str().trim().to_string())
        .filter(|value| !value.is_empty())?;
    let mapper_end = mapper.get(0)?.end();
    let mut statements = Vec::new();
    for capture in STATEMENT_TAG.captures_iter(source) {
        let Some(full) = capture.get(0) else { continue };
        if full.start() < mapper_end || in_ranges(&comments, full.start()) {
            continue;
        }
        let kind = capture
            .get(1)
            .map(|value| value.as_str().to_ascii_lowercase())?;
        let attributes = capture
            .get(2)
            .map(|value| value.as_str())
            .unwrap_or_default();
        let Some(id_capture) = ATTRIBUTE_ID.captures(attributes) else {
            continue;
        };
        let statement_id = id_capture.get(1)?.as_str().trim().to_string();
        if statement_id.is_empty() {
            continue;
        }
        let id_start_in_attributes = id_capture.get(1)?.start();
        let attribute_start = capture
            .get(2)
            .map(|value| value.start())
            .unwrap_or(full.start());
        let id_start = attribute_start + id_start_in_attributes;
        let (line, column) = line_column(source, id_start);
        let end_column = column + statement_id.encode_utf16().count();
        statements.push(XmlStatement {
            statement_id,
            kind,
            line,
            column,
            end_column,
        });
    }
    statements.sort_by(|left, right| {
        left.statement_id
            .cmp(&right.statement_id)
            .then_with(|| left.line.cmp(&right.line))
    });
    Some(XmlMapper {
        namespace,
        path: path.to_string(),
        statements,
    })
}

fn is_mybatis_source_path(path: &Path) -> bool {
    match path
        .extension()
        .and_then(|value| value.to_str())
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("java") => true,
        Some("xml") => !path
            .file_name()
            .and_then(|value| value.to_str())
            .is_some_and(|name| name.eq_ignore_ascii_case("pom.xml")),
        _ => false,
    }
}

fn source_content(root: &Path, path: &Path, overrides: &HashMap<String, String>) -> Option<String> {
    let relative = slash_path(path);
    if let Some(text) = overrides.get(&relative) {
        return Some(text.clone());
    }
    let absolute = root.join(path);
    let metadata = fs::metadata(&absolute).ok()?;
    if !metadata.is_file() || metadata.len() > MAX_SOURCE_BYTES {
        return None;
    }
    #[cfg(test)]
    record_disk_read(&relative);
    fs::read_to_string(absolute).ok()
}

fn existing_directory(value: &str) -> Result<PathBuf, CoreError> {
    let path = PathBuf::from(value);
    if !path.is_absolute() || !path.is_dir() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "MyBatis index root must be an existing absolute directory",
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

fn in_ranges(ranges: &[std::ops::Range<usize>], offset: usize) -> bool {
    ranges.iter().any(|range| range.contains(&offset))
}

fn line_column(source: &str, byte_offset: usize) -> (usize, usize) {
    let prefix = source.get(..byte_offset).unwrap_or(source);
    let line = prefix.bytes().filter(|byte| *byte == b'\n').count() + 1;
    let last_line_start = prefix.rfind('\n').map(|index| index + 1).unwrap_or(0);
    let column = source
        .get(last_line_start..byte_offset)
        .map(|value| value.encode_utf16().count() + 1)
        .unwrap_or(1);
    (line, column)
}
