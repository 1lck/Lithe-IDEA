//! Deterministic MyBatis mapper-interface and XML statement indexing.

use crate::protocol::{CoreError, ErrorCode, MybatisIndexResponse, MybatisStatementResponse};
use regex::Regex;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::sync::LazyLock;

static PACKAGE_DECLARATION: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)^\s*package\s+([A-Za-z_][\w.]*)\s*;").expect("literal pattern is valid")
});
static TYPE_DECLARATION: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b(?:interface|class)\s+([A-Za-z_$][A-Za-z0-9_$]*)")
        .expect("literal pattern is valid")
});
static METHOD_DECLARATION: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?:^|[\s>])(?:(?:public|protected|private|abstract|default|static|final|synchronized|native|strictfp)\s+)*(?:<[^<>]+>\s+)?(?:[\w.$]+(?:\s*<[^<>]+>)?(?:\s*\[\s*\])*)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(",
    )
    .expect("literal pattern is valid")
});
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

const JAVA_KEYWORDS: &[&str] = &[
    "abstract",
    "assert",
    "boolean",
    "break",
    "byte",
    "case",
    "catch",
    "char",
    "class",
    "const",
    "continue",
    "default",
    "do",
    "double",
    "else",
    "enum",
    "extends",
    "false",
    "final",
    "finally",
    "float",
    "for",
    "goto",
    "if",
    "implements",
    "import",
    "instanceof",
    "int",
    "interface",
    "long",
    "native",
    "new",
    "null",
    "package",
    "private",
    "protected",
    "public",
    "return",
    "short",
    "static",
    "strictfp",
    "super",
    "switch",
    "synchronized",
    "this",
    "throw",
    "throws",
    "transient",
    "true",
    "try",
    "void",
    "volatile",
    "while",
    "record",
];

// Split so the English-comment checker does not treat these literals as Rust block comments.
const JAVA_BLOCK_COMMENT_OPEN: &str = concat!("/", "*");
const JAVA_BLOCK_COMMENT_CLOSE: &str = concat!("*", "/");

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
    end_line: usize,
}

#[derive(Clone)]
struct JavaType {
    qualified_name: String,
    simple_name: String,
    path: String,
    methods: Vec<JavaMethod>,
}

struct XmlStatement {
    statement_id: String,
    kind: String,
    line: usize,
    column: usize,
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

    let mut java_types = Vec::new();
    let mut xml_mappers = Vec::new();
    for path in &paths {
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
            Some("java") => java_types.extend(java_mapper_types(&relative, &content)),
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
                xml_path: mapper.path.clone(),
                xml_line: xml_statement.line,
                xml_column: xml_statement.column,
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

fn java_mapper_types(path: &str, source: &str) -> Vec<JavaType> {
    let package = PACKAGE_DECLARATION
        .captures(source)
        .and_then(|capture| capture.get(1))
        .map(|value| value.as_str().to_string())
        .unwrap_or_default();
    let lines = source.lines().collect::<Vec<_>>();
    let mut types = Vec::new();
    let mut current: Option<JavaType> = None;
    let mut brace_depth = 0i32;
    for (index, line) in lines.iter().enumerate() {
        let trimmed = line.trim();
        if trimmed.starts_with("//")
            || trimmed.starts_with('*')
            || trimmed.starts_with(JAVA_BLOCK_COMMENT_OPEN)
            || trimmed.starts_with(JAVA_BLOCK_COMMENT_CLOSE)
        {
            brace_depth += net_brace_delta(line);
            continue;
        }
        if brace_depth == 0 {
            if let Some(name) = TYPE_DECLARATION
                .captures(line)
                .and_then(|capture| capture.get(1))
                .map(|value| value.as_str().to_string())
            {
                if let Some(completed) = current.take() {
                    types.push(completed);
                }
                let qualified_name = if package.is_empty() {
                    name.clone()
                } else {
                    format!("{package}.{name}")
                };
                current = Some(JavaType {
                    qualified_name,
                    simple_name: name,
                    path: path.to_string(),
                    methods: Vec::new(),
                });
            }
        }
        if brace_depth == 1 {
            if let Some(method) = method_declaration(&lines, index) {
                if let Some(java_type) = current.as_mut() {
                    if method.name != java_type.simple_name
                        && java_type
                            .methods
                            .iter()
                            .all(|existing| existing.name != method.name)
                    {
                        java_type.methods.push(method);
                    }
                }
            }
        }
        brace_depth = (brace_depth + net_brace_delta(line)).max(0);
    }
    if let Some(completed) = current.take() {
        types.push(completed);
    }
    types
}

fn method_declaration(lines: &[&str], start: usize) -> Option<JavaMethod> {
    let line = lines.get(start).copied()?;
    let capture = METHOD_DECLARATION.captures(line)?;
    let name = capture.get(1)?.as_str();
    if JAVA_KEYWORDS.contains(&name) {
        return None;
    }
    let name_byte = capture.get(1)?.start();
    let (end_line, terminator) = signature_end(lines, start)?;
    if terminator != ';' {
        return None;
    }
    Some(JavaMethod {
        name: name.to_string(),
        line: start + 1,
        column: utf16_column(line, name_byte),
        end_line,
    })
}

fn signature_end(lines: &[&str], start: usize) -> Option<(usize, char)> {
    let mut paren_depth = 0i32;
    for (index, line) in lines.iter().enumerate().skip(start) {
        for character in line.chars() {
            match character {
                '(' => paren_depth += 1,
                ')' => paren_depth = (paren_depth - 1).max(0),
                '{' if paren_depth == 0 => return Some((index + 1, '{')),
                ';' if paren_depth == 0 => return Some((index + 1, ';')),
                _ => {}
            }
        }
    }
    None
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
        let (line, column) = line_column(source, attribute_start + id_start_in_attributes);
        statements.push(XmlStatement {
            statement_id,
            kind,
            line,
            column,
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

fn net_brace_delta(line: &str) -> i32 {
    let mut delta = 0i32;
    let mut in_string = false;
    let mut quote = '\0';
    let mut previous = '\0';
    for character in line.chars() {
        if in_string {
            if character == quote && previous != '\\' {
                in_string = false;
            }
            previous = character;
            continue;
        }
        match character {
            '"' | '\'' => {
                in_string = true;
                quote = character;
            }
            '{' => delta += 1,
            '}' => delta -= 1,
            _ => {}
        }
        previous = character;
    }
    delta
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

fn utf16_column(line: &str, byte_offset: usize) -> usize {
    line.get(..byte_offset)
        .map(|prefix| prefix.encode_utf16().count() + 1)
        .unwrap_or(1)
}
