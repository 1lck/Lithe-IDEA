//! Locates a Java type, method, or field declaration inside one source text.
//!
//! Copied from lithe-core's `languages/java.rs` (`java.sourceDefinition`). Core
//! keeps its own copy for macOS; this one serves the Windows host until the Java
//! plugin backend replaces both.

use crate::contracts::JavaSourceDefinitionResponse;
use lithe_core::{CoreError, ErrorCode};
use regex::Regex;
use serde::Deserialize;
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Source lookup for a type, method, or field declaration.
pub struct JavaSourceDefinitionRequest {
    pub source: String,
    pub declaration_name: String,
    #[serde(default)]
    pub member_name: Option<String>,
    /// Only a real member declaration counts, never a call or an assignment.
    #[serde(default)]
    pub declarations_only: bool,
    /// Where the member is used. Resolves it from that scope instead of as a
    /// member of `declaration_name`, and finds nothing when syntax cannot tell.
    #[serde(default)]
    pub reference: Option<JavaSourceReference>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Zero-based position of the first character of a member reference.
pub struct JavaSourceReference {
    pub line: usize,
    pub utf16_column: usize,
}

/// Finds a type or member declaration in one Java source document.
pub fn source_definition(
    request: JavaSourceDefinitionRequest,
) -> Result<Option<JavaSourceDefinitionResponse>, CoreError> {
    let lines = request.source.split('\n').collect::<Vec<_>>();
    if let Some(member) = request.member_name {
        let declared = match &request.reference {
            Some(reference) => referenced_member(&request.source, &member, reference),
            None => member_declaration(&request.source, &request.declaration_name, &member),
        };
        if let Some((line, utf16_column)) = declared {
            return Ok(Some(JavaSourceDefinitionResponse { line, utf16_column }));
        }
        if request.declarations_only {
            return Ok(None);
        }
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
                    return Ok(Some(JavaSourceDefinitionResponse {
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
                return Ok(Some(JavaSourceDefinitionResponse {
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
            return Ok(Some(JavaSourceDefinitionResponse {
                line: line_number,
                utf16_column: utf16_column(line, offset),
            }));
        }
    }
    Ok(None)
}

fn parse_java(source: &str) -> Option<tree_sitter::Tree> {
    let mut parser = tree_sitter::Parser::new();
    parser
        .set_language(&tree_sitter_java::LANGUAGE.into())
        .ok()?;
    parser.parse(source, None)
}

/// Zero-based line and UTF-16 column of a declared name.
fn declaration_position(source: &str, declared: tree_sitter::Node) -> Option<(usize, usize)> {
    let point = declared.start_position();
    let line = source.split('\n').nth(point.row)?;
    Some((point.row, utf16_column(line, point.column)))
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum MemberKind {
    Method,
    Field,
}

fn is_type_body(node: tree_sitter::Node) -> bool {
    matches!(
        node.kind(),
        "class_body" | "interface_body" | "enum_body" | "annotation_type_body"
    )
}

fn has_name(node: tree_sitter::Node, source: &str, name: &str) -> bool {
    node.child_by_field_name("name")
        .is_some_and(|declared| declared.utf8_text(source.as_bytes()) == Ok(name))
}

/// Finds a member declared directly in a type body, not in a type nested inside it.
///
/// `kind` narrows the search because Java keeps methods and fields in separate
/// namespaces; `None` accepts either.
fn direct_member<'tree>(
    body: tree_sitter::Node<'tree>,
    name: &str,
    kind: Option<MemberKind>,
    source: &str,
) -> Option<tree_sitter::Node<'tree>> {
    let accepts = |wanted: MemberKind| kind.is_none_or(|kind| kind == wanted);
    let named = |node: tree_sitter::Node<'tree>| {
        has_name(node, source, name)
            .then(|| node.child_by_field_name("name"))
            .flatten()
    };
    // A record component is a field the body can use without declaring it.
    if let Some(components) = body
        .parent()
        .filter(|parent| parent.kind() == "record_declaration" && accepts(MemberKind::Field))
        .and_then(|parent| parent.child_by_field_name("parameters"))
    {
        let mut cursor = components.walk();
        let component = components
            .named_children(&mut cursor)
            .find_map(|component| named(component));
        if component.is_some() {
            return component;
        }
    }
    let mut cursor = body.walk();
    for member in body.named_children(&mut cursor) {
        let declared = match member.kind() {
            "method_declaration" if accepts(MemberKind::Method) => named(member),
            "enum_constant" | "annotation_type_element_declaration"
                if accepts(MemberKind::Field) =>
            {
                named(member)
            }
            "field_declaration" | "constant_declaration" if accepts(MemberKind::Field) => {
                let mut declarators = member.walk();
                let declared = member
                    .children_by_field_name("declarator", &mut declarators)
                    .find_map(|declarator| named(declarator));
                declared
            }
            "enum_body_declarations" => direct_member(member, name, kind, source),
            _ => None,
        };
        if declared.is_some() {
            return declared;
        }
    }
    None
}

/// Finds a method, field, or enum constant that the type `type_name` declares itself.
fn member_declaration(source: &str, type_name: &str, name: &str) -> Option<(usize, usize)> {
    let tree = parse_java(source)?;
    let mut pending = vec![tree.root_node()];
    while let Some(node) = pending.pop() {
        if let Some(body) = node
            .child_by_field_name("body")
            .filter(|body| is_type_body(*body) && has_name(node, source, type_name))
        {
            let declared = direct_member(body, name, None, source)?;
            return declaration_position(source, declared);
        }
        // Reversed so the stack visits declarations in source order.
        let mut cursor = node.walk();
        let children: Vec<_> = node.children(&mut cursor).collect();
        pending.extend(children.into_iter().rev());
    }
    None
}

/// Whether a type may inherit a member, which syntax cannot see.
fn may_inherit(declaration: tree_sitter::Node) -> bool {
    let mut cursor = declaration.walk();
    let extends_interfaces = declaration
        .children(&mut cursor)
        .any(|child| child.kind() == "extends_interfaces");
    extends_interfaces
        || matches!(
            declaration.kind(),
            "object_creation_expression" | "enum_constant"
        )
        || declaration.child_by_field_name("superclass").is_some()
        || declaration.child_by_field_name("interfaces").is_some()
}

/// Whether a member's code declares a local variable or parameter called `name`.
///
/// This ignores block scope on purpose. A same-named local elsewhere in the
/// member makes the answer uncertain, and an uncertain name stays unanswered.
fn declares_local(member: tree_sitter::Node, name: &str, source: &str) -> bool {
    let mut pending = vec![member];
    while let Some(node) = pending.pop() {
        let declares = match node.kind() {
            "variable_declarator" => {
                !matches!(
                    node.parent().map(|parent| parent.kind()),
                    Some("field_declaration" | "constant_declaration")
                ) && has_name(node, source, name)
            }
            "formal_parameter"
            | "catch_formal_parameter"
            | "enhanced_for_statement"
            | "resource"
            | "instanceof_expression" => has_name(node, source, name),
            "inferred_parameters"
            | "lambda_expression"
            | "type_pattern"
            | "record_pattern_component" => {
                let mut cursor = node.walk();
                let declares = node
                    .named_children(&mut cursor)
                    .filter(|child| child.kind() == "identifier")
                    .any(|child| child.utf8_text(source.as_bytes()) == Ok(name));
                declares
            }
            _ => false,
        };
        if declares {
            return true;
        }
        let mut cursor = node.walk();
        pending.extend(
            node.named_children(&mut cursor)
                .filter(|child| !is_type_body(*child)),
        );
    }
    false
}

/// Resolves a member reference to the declaration its scope binds it to.
///
/// Only a plain name or a `this.` access qualifies: any other receiver has a
/// type that syntax cannot resolve. The search starts in the innermost type and
/// moves outward, stopping at a type that may inherit the name and, for a plain
/// field name, at a local that may shadow it.
fn referenced_member(
    source: &str,
    name: &str,
    reference: &JavaSourceReference,
) -> Option<(usize, usize)> {
    let tree = parse_java(source)?;
    let line = source.split('\n').nth(reference.line)?;
    let mut utf16_offset = 0;
    let byte = line
        .char_indices()
        .find(|(_, character)| {
            let reached = utf16_offset >= reference.utf16_column;
            utf16_offset += character.len_utf16();
            reached
        })?
        .0;
    let start = tree_sitter::Point::new(reference.line, byte);
    let end = tree_sitter::Point::new(reference.line, byte + 1);
    let identifier = tree.root_node().descendant_for_point_range(start, end)?;
    if identifier.kind() != "identifier" || identifier.utf8_text(source.as_bytes()) != Ok(name) {
        return None;
    }

    let parent = identifier.parent()?;
    let receiver = match parent.kind() {
        "method_invocation" if parent.child_by_field_name("name") == Some(identifier) => {
            parent.child_by_field_name("object")
        }
        "field_access" if parent.child_by_field_name("field") == Some(identifier) => {
            parent.child_by_field_name("object")
        }
        "method_reference" | "element_value_pair" | "labeled_statement" | "break_statement"
        | "continue_statement" => return None,
        _ => None,
    };
    if receiver.is_some_and(|receiver| receiver.kind() != "this") {
        return None;
    }
    let is_call = parent.kind() == "method_invocation"
        && parent.child_by_field_name("name") == Some(identifier);
    let kind = if is_call {
        MemberKind::Method
    } else {
        MemberKind::Field
    };

    let mut inner = identifier;
    while let Some(scope) = inner.parent() {
        if is_type_body(scope) {
            if kind == MemberKind::Field
                && receiver.is_none()
                && declares_local(inner, name, source)
            {
                return None;
            }
            if let Some(declared) = direct_member(scope, name, Some(kind), source) {
                return declaration_position(source, declared);
            }
            if receiver.is_some() || scope.parent().is_none_or(may_inherit) {
                return None;
            }
        }
        inner = scope;
    }
    None
}

fn utf16_column(line: &str, byte: usize) -> usize {
    line[..byte.min(line.len())].encode_utf16().count()
}
