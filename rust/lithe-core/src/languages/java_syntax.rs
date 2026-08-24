//! Deterministic Java syntax classification for native editor renderers.

use crate::protocol::JavaSyntaxHighlightResponse;
use std::collections::HashSet;
use tree_sitter::{Node, Parser};

#[derive(Default)]
struct JavaSymbols<'a> {
    fields: HashSet<&'a str>,
    constants: HashSet<&'a str>,
    parameters: HashSet<&'a str>,
}

/// Classifies Java source into sorted, non-overlapping UTF-16 token ranges.
pub(super) fn syntax_highlights(source: &str) -> Vec<JavaSyntaxHighlightResponse> {
    let mut parser = Parser::new();
    if parser
        .set_language(&tree_sitter_java::LANGUAGE.into())
        .is_err()
    {
        return Vec::new();
    }
    let Some(tree) = parser.parse(source, None) else {
        return Vec::new();
    };
    let mut values = Vec::new();
    let utf16_offsets = utf16_offsets(source);
    let mut symbols = JavaSymbols::default();
    collect_symbols(tree.root_node(), source.as_bytes(), &mut symbols);
    collect_highlights(
        tree.root_node(),
        source,
        &utf16_offsets,
        &symbols,
        &mut values,
    );
    values.sort_by_key(|value| (value.utf16_start, value.utf16_length));
    values.dedup_by(|left, right| {
        left.utf16_start == right.utf16_start && left.utf16_length == right.utf16_length
    });
    values
}

fn collect_highlights(
    node: Node<'_>,
    source: &str,
    utf16_offsets: &[usize],
    symbols: &JavaSymbols<'_>,
    values: &mut Vec<JavaSyntaxHighlightResponse>,
) {
    if let Some(role) = whole_node_role(node, source.as_bytes()) {
        push_highlight(node, role, utf16_offsets, values);
        return;
    }
    if node.child_count() == 0 {
        if let Some(role) = role_for_leaf(node, source.as_bytes(), symbols) {
            push_highlight(node, role, utf16_offsets, values);
        }
        return;
    }
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_highlights(child, source, utf16_offsets, symbols, values);
    }
}

fn collect_symbols<'a>(node: Node<'_>, source: &'a [u8], symbols: &mut JavaSymbols<'a>) {
    if matches!(node.kind(), "formal_parameter" | "spread_parameter") {
        if let Some(name) = node
            .child_by_field_name("name")
            .and_then(|value| value.utf8_text(source).ok())
        {
            symbols.parameters.insert(name);
        }
    } else if node.kind() == "variable_declarator" && has_ancestor(node, "field_declaration") {
        if let Some(name) = node
            .child_by_field_name("name")
            .and_then(|value| value.utf8_text(source).ok())
        {
            let is_constant = ancestor_text(node, "field_declaration", source)
                .is_some_and(|text| has_modifier(text, "static") && has_modifier(text, "final"));
            if is_constant {
                symbols.constants.insert(name);
            } else {
                symbols.fields.insert(name);
            }
        }
    }
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_symbols(child, source, symbols);
    }
}

fn utf16_offsets(source: &str) -> Vec<usize> {
    let mut offsets = vec![0; source.len() + 1];
    let mut utf16_offset = 0;
    for (byte_offset, character) in source.char_indices() {
        offsets[byte_offset] = utf16_offset;
        utf16_offset += character.len_utf16();
        offsets[byte_offset + character.len_utf8()] = utf16_offset;
    }
    offsets
}

fn whole_node_role(node: Node<'_>, source: &[u8]) -> Option<&'static str> {
    match node.kind() {
        "line_comment" | "block_comment" => Some(
            if node
                .utf8_text(source)
                .is_ok_and(|text| text.as_bytes().starts_with(&[b'/', b'*', b'*']))
            {
                "documentationComment"
            } else {
                "comment"
            },
        ),
        "string_literal" | "character_literal" | "text_block" => Some("string"),
        "decimal_integer_literal"
        | "hex_integer_literal"
        | "octal_integer_literal"
        | "binary_integer_literal"
        | "decimal_floating_point_literal"
        | "hex_floating_point_literal" => Some("number"),
        "boolean_type" | "integral_type" | "floating_point_type" | "void_type" => Some("keyword"),
        _ => None,
    }
}

fn push_highlight(
    node: Node<'_>,
    role: &str,
    utf16_offsets: &[usize],
    values: &mut Vec<JavaSyntaxHighlightResponse>,
) {
    let Some(&utf16_start) = utf16_offsets.get(node.start_byte()) else {
        return;
    };
    let Some(&utf16_end) = utf16_offsets.get(node.end_byte()) else {
        return;
    };
    let utf16_length = utf16_end.saturating_sub(utf16_start);
    if utf16_length == 0 {
        return;
    }
    values.push(JavaSyntaxHighlightResponse {
        utf16_start,
        utf16_length,
        role: role.to_string(),
    });
}

fn role_for_leaf(node: Node<'_>, source: &[u8], symbols: &JavaSymbols<'_>) -> Option<&'static str> {
    let kind = node.kind();
    if kind == "@"
        || (matches!(kind, "identifier" | "type_identifier")
            && (has_ancestor(node, "marker_annotation") || has_ancestor(node, "annotation")))
    {
        return Some("annotation");
    }
    if matches!(kind, "true" | "false") {
        return Some("boolean");
    }
    if kind == "null_literal" {
        return Some("null");
    }
    if kind == "identifier" {
        return Some(identifier_role(node, source, symbols));
    }
    if kind == "type_identifier" {
        return Some(if has_ancestor(node, "type_parameters") {
            "typeParameter"
        } else {
            "type"
        });
    }
    if is_keyword(kind) {
        return Some("keyword");
    }
    if !node.is_named() {
        return Some(if is_operator(kind) {
            "operator"
        } else {
            "punctuation"
        });
    }
    None
}

fn identifier_role(node: Node<'_>, source: &[u8], symbols: &JavaSymbols<'_>) -> &'static str {
    let Some(parent) = node.parent() else {
        return "variable";
    };
    if field_is(parent, "name", node) {
        return match parent.kind() {
            "method_declaration" | "constructor_declaration" => "functionDeclaration",
            "method_invocation" => "functionCall",
            "formal_parameter" | "spread_parameter" | "receiver_parameter" => "parameter",
            "class_declaration"
            | "interface_declaration"
            | "enum_declaration"
            | "record_declaration"
            | "annotation_type_declaration" => "type",
            _ => declaration_identifier_role(node, source),
        };
    }
    if has_ancestor(node, "method_invocation") && field_is(parent, "name", node) {
        return "functionCall";
    }
    if parent.kind() == "field_access" && field_is(parent, "field", node) {
        return "field";
    }
    if has_ancestor(node, "type_parameters") {
        return "typeParameter";
    }
    if has_type_ancestor(node) {
        return "type";
    }
    if let Ok(name) = node.utf8_text(source) {
        if symbols.parameters.contains(name) {
            return "parameter";
        }
        if symbols.constants.contains(name) {
            return "constant";
        }
        if symbols.fields.contains(name) {
            return "field";
        }
        if name
            .chars()
            .next()
            .is_some_and(|character| character.is_ascii_uppercase())
        {
            return "type";
        }
    }
    "variable"
}

fn declaration_identifier_role(node: Node<'_>, source: &[u8]) -> &'static str {
    if has_ancestor(node, "formal_parameter") || has_ancestor(node, "spread_parameter") {
        return "parameter";
    }
    if has_ancestor(node, "field_declaration") {
        return if ancestor_text(node, "field_declaration", source)
            .is_some_and(|text| has_modifier(text, "static") && has_modifier(text, "final"))
        {
            "constant"
        } else {
            "field"
        };
    }
    if has_ancestor(node, "local_variable_declaration")
        || has_ancestor(node, "resource")
        || has_ancestor(node, "catch_formal_parameter")
        || has_ancestor(node, "enhanced_for_statement")
    {
        return "variable";
    }
    "variable"
}

fn field_is(parent: Node<'_>, name: &str, node: Node<'_>) -> bool {
    parent
        .child_by_field_name(name)
        .is_some_and(|value| value.id() == node.id())
}

fn has_ancestor(mut node: Node<'_>, kind: &str) -> bool {
    while let Some(parent) = node.parent() {
        if parent.kind() == kind {
            return true;
        }
        node = parent;
    }
    false
}

fn has_type_ancestor(mut node: Node<'_>) -> bool {
    while let Some(parent) = node.parent() {
        if matches!(
            parent.kind(),
            "type_arguments"
                | "superclass"
                | "super_interfaces"
                | "extends_interfaces"
                | "object_creation_expression"
                | "cast_expression"
                | "instanceof_expression"
                | "array_type"
                | "generic_type"
                | "scoped_type_identifier"
        ) {
            return true;
        }
        if matches!(parent.kind(), "method_invocation" | "expression_statement") {
            return false;
        }
        node = parent;
    }
    false
}

fn ancestor_text<'a>(mut node: Node<'_>, kind: &str, source: &'a [u8]) -> Option<&'a str> {
    while let Some(parent) = node.parent() {
        if parent.kind() == kind {
            return parent.utf8_text(source).ok();
        }
        node = parent;
    }
    None
}

fn has_modifier(text: &str, expected: &str) -> bool {
    text.split(|character: char| !character.is_ascii_alphanumeric() && character != '_')
        .any(|word| word == expected)
}

fn is_keyword(kind: &str) -> bool {
    matches!(
        kind,
        "abstract"
            | "assert"
            | "break"
            | "case"
            | "catch"
            | "class"
            | "continue"
            | "default"
            | "do"
            | "else"
            | "enum"
            | "exports"
            | "extends"
            | "final"
            | "finally"
            | "for"
            | "if"
            | "implements"
            | "import"
            | "instanceof"
            | "interface"
            | "module"
            | "native"
            | "new"
            | "non-sealed"
            | "open"
            | "opens"
            | "package"
            | "permits"
            | "private"
            | "protected"
            | "provides"
            | "public"
            | "record"
            | "requires"
            | "return"
            | "sealed"
            | "static"
            | "strictfp"
            | "super"
            | "switch"
            | "synchronized"
            | "this"
            | "throw"
            | "throws"
            | "to"
            | "transient"
            | "transitive"
            | "try"
            | "uses"
            | "volatile"
            | "while"
            | "with"
            | "yield"
            | "void"
            | "boolean_type"
            | "integral_type"
            | "floating_point_type"
    )
}

fn is_operator(kind: &str) -> bool {
    matches!(
        kind,
        "=" | ">"
            | "<"
            | "!"
            | "~"
            | "?"
            | ":"
            | "->"
            | "=="
            | ">="
            | "<="
            | "!="
            | "&&"
            | "||"
            | "++"
            | "--"
            | "+"
            | "-"
            | "*"
            | "/"
            | "&"
            | "|"
            | "^"
            | "%"
            | "<<"
            | ">>"
            | ">>>"
            | "+="
            | "-="
            | "*="
            | "/="
            | "&="
            | "|="
            | "^="
            | "%="
            | "<<="
            | ">>="
            | ">>>="
            | "::"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_java_declarations_references_and_literals() {
        let source = concat!(
            "/",
            "** Docs *",
            "/\n",
            r#"@Deprecated class Demo<T> {
    static final int LIMIT = 2;
    String field;
    Demo(String value) {
        String local = value;
        this.field = call(local);
    }
}"#
        );

        let values = syntax_highlights(source);
        let classified = values
            .iter()
            .map(|value| {
                let token = String::from_utf16(
                    &source.encode_utf16().collect::<Vec<_>>()
                        [value.utf16_start..value.utf16_start + value.utf16_length],
                )
                .expect("highlight range should contain valid UTF-16");
                (token, value.role.as_str())
            })
            .collect::<Vec<_>>();

        let documentation = ["/", "** Docs *", "/"].concat();
        assert!(classified.contains(&(documentation, "documentationComment")));
        assert!(classified.contains(&("@".to_string(), "annotation")));
        assert!(classified.contains(&("Deprecated".to_string(), "annotation")));
        assert!(classified.contains(&("Demo".to_string(), "type")));
        assert!(classified.contains(&("T".to_string(), "typeParameter")));
        assert!(classified.contains(&("LIMIT".to_string(), "constant")));
        assert!(classified.contains(&("field".to_string(), "field")));
        assert!(classified.contains(&("Demo".to_string(), "functionDeclaration")));
        assert!(classified.contains(&("value".to_string(), "parameter")));
        assert!(classified.contains(&("local".to_string(), "variable")));
        assert!(classified.contains(&("call".to_string(), "functionCall")));
        assert!(classified.contains(&("2".to_string(), "number")));
        assert!(
            classified
                .iter()
                .filter(|(token, role)| token == "field" && *role == "field")
                .count()
                >= 2
        );
        assert!(
            classified
                .iter()
                .filter(|(token, role)| token == "local" && *role == "variable")
                .count()
                >= 2
        );
    }

    #[test]
    fn reports_document_relative_utf16_offsets_after_non_ascii_text() {
        let source = "class Demo { String text = \"😀\"; int count = 1; }";
        let values = syntax_highlights(source);
        let count_start = source.find("count").expect("count should exist");
        let expected = source[..count_start].encode_utf16().count();

        assert!(values.iter().any(|value| {
            value.utf16_start == expected && value.utf16_length == 5 && value.role == "field"
        }));
    }
}
