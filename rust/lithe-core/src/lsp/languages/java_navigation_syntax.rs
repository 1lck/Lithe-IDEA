//! Java syntax candidates for semantic navigation-marker verification.

use tree_sitter::{Node, Parser};

/// One declaration whose semantic parent or implementation relation must be verified by JDT LS.
#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) struct JavaNavigationCandidate {
    pub line: i64,
    pub utf16_column: i64,
    pub direction: &'static str,
    pub relation: &'static str,
}

/// Extracts real Java method declarations without guessing across statement text.
///
/// Syntax only selects bounded candidates. A candidate never becomes a visible
/// marker until JDT LS confirms at least one target, so incomplete or erroneous
/// source cannot create a false gutter icon by itself.
pub(crate) fn navigation_candidates(source: &str) -> Vec<JavaNavigationCandidate> {
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
    let mut candidates = Vec::new();
    collect_candidates(tree.root_node(), source.as_bytes(), &mut candidates);
    candidates.sort_by(|left, right| {
        left.line
            .cmp(&right.line)
            .then_with(|| left.utf16_column.cmp(&right.utf16_column))
            .then_with(|| left.direction.cmp(right.direction))
            .then_with(|| left.relation.cmp(right.relation))
    });
    candidates.dedup();
    candidates
}

fn collect_candidates(
    node: Node<'_>,
    source: &[u8],
    candidates: &mut Vec<JavaNavigationCandidate>,
) {
    if node.kind() == "method_declaration" {
        collect_method_candidates(node, source, candidates);
    }
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_candidates(child, source, candidates);
    }
}

fn collect_method_candidates(
    method: Node<'_>,
    source: &[u8],
    candidates: &mut Vec<JavaNavigationCandidate>,
) {
    let Some(name) = method.child_by_field_name("name") else {
        return;
    };
    let modifiers = method
        .children(&mut method.walk())
        .find(|child| child.kind() == "modifiers");
    let modifier_text = modifiers
        .and_then(|value| value.utf8_text(source).ok())
        .unwrap_or_default();
    let enclosing_type = enclosing_type(method);
    let relation = if enclosing_type.is_some_and(|value| value.kind() == "interface_declaration") {
        "interface"
    } else {
        "inheritance"
    };
    let point = name.start_position();
    let position = JavaNavigationCandidate {
        line: i64::try_from(point.row).unwrap_or(i64::MAX),
        utf16_column: utf16_column(source, point.row, point.column),
        direction: "down",
        relation,
    };

    if is_possible_override_target(modifier_text, enclosing_type, source) {
        candidates.push(position.clone());
    }
    if has_override_annotation(modifiers, source) {
        candidates.push(JavaNavigationCandidate {
            direction: "up",
            relation: super_relation(enclosing_type, source),
            ..position
        });
    }
}

fn enclosing_type(mut node: Node<'_>) -> Option<Node<'_>> {
    while let Some(parent) = node.parent() {
        if matches!(
            parent.kind(),
            "class_declaration"
                | "interface_declaration"
                | "enum_declaration"
                | "record_declaration"
        ) {
            return Some(parent);
        }
        node = parent;
    }
    None
}

fn is_possible_override_target(
    modifier_text: &str,
    enclosing_type: Option<Node<'_>>,
    source: &[u8],
) -> bool {
    if modifier_text
        .split_whitespace()
        .any(|modifier| matches!(modifier, "private" | "static" | "final"))
    {
        return false;
    }
    let Some(enclosing_type) = enclosing_type else {
        return false;
    };
    if enclosing_type.kind() == "interface_declaration" {
        return true;
    }
    let type_modifiers = enclosing_type
        .children(&mut enclosing_type.walk())
        .find(|child| child.kind() == "modifiers")
        .and_then(|value| value.utf8_text(source).ok())
        .unwrap_or_default();
    !type_modifiers
        .split_whitespace()
        .any(|value| value == "final")
}

fn has_override_annotation(modifiers: Option<Node<'_>>, source: &[u8]) -> bool {
    let Some(modifiers) = modifiers else {
        return false;
    };
    let mut cursor = modifiers.walk();
    let found = modifiers.children(&mut cursor).any(|child| {
        matches!(child.kind(), "marker_annotation" | "annotation")
            && child
                .utf8_text(source)
                .is_ok_and(|text| text.trim() == "@Override")
    });
    found
}

fn super_relation(enclosing_type: Option<Node<'_>>, source: &[u8]) -> &'static str {
    let Some(enclosing_type) = enclosing_type else {
        return "inheritance";
    };
    if enclosing_type.kind() == "interface_declaration" {
        return "interface";
    }
    let header_end = enclosing_type
        .child_by_field_name("body")
        .map(|body| body.start_byte())
        .unwrap_or(enclosing_type.end_byte());
    let header = source
        .get(enclosing_type.start_byte()..header_end)
        .and_then(|value| std::str::from_utf8(value).ok())
        .unwrap_or_default();
    // JDT LS 1.38 findLinks identifies the parent method but does not report
    // whether its declaring type is an interface. Prefer the interface visual
    // for implementing classes; ordinary subclass overrides remain inheritance.
    // A class that both extends and implements can be ambiguous until JDT LS
    // exposes the declaring-type kind in this response.
    if header
        .split(|character: char| !character.is_ascii_alphanumeric() && character != '_')
        .any(|word| word == "implements")
    {
        "interface"
    } else {
        "inheritance"
    }
}

fn utf16_column(source: &[u8], row: usize, byte_column: usize) -> i64 {
    let line = source
        .split(|value| *value == b'\n')
        .nth(row)
        .unwrap_or_default();
    let prefix = line.get(..byte_column).unwrap_or(line);
    let units = String::from_utf8_lossy(prefix).encode_utf16().count();
    i64::try_from(units).unwrap_or(i64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn multiline_declarations_are_candidates_but_constructor_calls_are_not() {
        let source = r#"
interface UploadService {
    UploadResponse createDirectUploadSession(
        UploadRequest request,
        String objectKey
    );
}

class Response {
    Response upload() {
        return new Response(
        );
    }
}
"#;

        let candidates = navigation_candidates(source);

        assert!(candidates.iter().any(|candidate| {
            candidate.line == 2
                && candidate.direction == "down"
                && candidate.relation == "interface"
        }));
        assert_eq!(
            candidates
                .iter()
                .filter(|candidate| candidate.line >= 9)
                .count(),
            1
        );
    }

    #[test]
    fn override_methods_get_up_and_possible_down_candidates() {
        let source = r#"
class ServiceImpl implements Service {
    @Override
    public void run() {}
}
"#;

        let candidates = navigation_candidates(source);

        assert!(candidates
            .iter()
            .any(|candidate| { candidate.direction == "up" && candidate.relation == "interface" }));
        assert!(candidates
            .iter()
            .any(|candidate| candidate.direction == "down"));
    }

    #[test]
    fn private_static_final_and_final_class_methods_are_not_down_candidates() {
        let source = r#"
final class Closed {
    void ordinary() {}
    private void hidden() {}
    static void utility() {}
    final void fixed() {}
}
"#;

        assert!(navigation_candidates(source).is_empty());
    }
}
