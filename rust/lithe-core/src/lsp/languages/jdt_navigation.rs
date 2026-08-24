//! JDT LS navigation-marker planning and normalization shared by every platform frontend.

use super::java_navigation_syntax::navigation_candidates;
use crate::protocol::JavaNavigationMarkerResponse;
use serde_json::json;
use serde_json::Value;
use std::collections::VecDeque;
use std::time::Instant;

/// Maximum semantic verification work accepted for one document version.
pub(crate) const MAX_JAVA_NAVIGATION_TASKS: usize = 64;

/// Bounded multi-request projection of JDT LS data into visible gutter markers.
pub(crate) struct JavaNavigationMarkerBatch {
    tasks: VecDeque<JavaNavigationMarkerTask>,
    active_task: Option<JavaNavigationMarkerTask>,
    resolved_lenses: Vec<Value>,
    semantic_markers: Vec<JavaNavigationMarkerResponse>,
    total_tasks: usize,
    created_at: Instant,
    deadline: Instant,
}

#[derive(Clone)]
/// One provider request needed to verify a possible Java navigation relation.
pub(crate) enum JavaNavigationMarkerTask {
    ResolveCodeLens(Value),
    FindImplementations(super::java_navigation_syntax::JavaNavigationCandidate),
    FindSuperImplementation(super::java_navigation_syntax::JavaNavigationCandidate),
}

impl JavaNavigationMarkerBatch {
    /// Plans a deterministic, bounded batch from initial CodeLens data and synchronized source.
    pub(crate) fn new(
        raw_lenses: &[Value],
        source: &str,
        created_at: Instant,
        deadline: Instant,
    ) -> Self {
        let mut implementation_lenses = implementation_code_lenses(raw_lenses);
        let (resolved_lenses, unresolved_lenses): (Vec<_>, Vec<_>) = implementation_lenses
            .drain(..)
            .partition(is_resolved_implementation_lens);
        let candidates = navigation_candidates(source);
        let mut tasks = unresolved_lenses
            .into_iter()
            .map(JavaNavigationMarkerTask::ResolveCodeLens)
            .collect::<VecDeque<_>>();
        // Parent checks run before child checks so an override arrow can appear
        // even when the fixed task budget is exhausted by a very large type.
        tasks.extend(
            candidates
                .iter()
                .filter(|candidate| candidate.direction == "up")
                .cloned()
                .map(JavaNavigationMarkerTask::FindSuperImplementation),
        );
        tasks.extend(
            candidates
                .into_iter()
                .filter(|candidate| candidate.direction == "down")
                .map(JavaNavigationMarkerTask::FindImplementations),
        );
        let total_tasks = tasks.len();
        tasks.truncate(MAX_JAVA_NAVIGATION_TASKS);
        Self {
            tasks,
            active_task: None,
            resolved_lenses,
            semantic_markers: Vec::new(),
            total_tasks,
            created_at,
            deadline,
        }
    }

    /// Removes and tracks the next semantic verification request.
    pub(crate) fn take_next(&mut self) -> Option<JavaNavigationMarkerTask> {
        let task = self.tasks.pop_front()?;
        self.active_task = Some(task.clone());
        Some(task)
    }

    /// Merges a successful provider response into the partial projection.
    pub(crate) fn record_active_result(&mut self, result: Option<&Value>) {
        let Some(task) = self.active_task.take() else {
            return;
        };
        match task {
            JavaNavigationMarkerTask::ResolveCodeLens(_) => {
                if let Some(lens) = result.cloned().filter(is_resolved_implementation_lens) {
                    self.resolved_lenses.push(lens);
                }
            }
            JavaNavigationMarkerTask::FindImplementations(candidate)
            | JavaNavigationMarkerTask::FindSuperImplementation(candidate) => {
                let count = raw_location_count(result);
                if count > 0 {
                    self.semantic_markers.push(JavaNavigationMarkerResponse {
                        line: usize::try_from(candidate.line).unwrap_or_default(),
                        utf16_column: usize::try_from(candidate.utf16_column).unwrap_or_default(),
                        implementation_count: count,
                        direction: candidate.direction.to_string(),
                        relation: candidate.relation.to_string(),
                    });
                }
            }
        }
    }

    /// Produces the deterministic final marker list, including partial successes.
    pub(crate) fn finish(self, source: &str) -> Vec<JavaNavigationMarkerResponse> {
        let mut markers = markers_from_resolved_code_lenses(&self.resolved_lenses, source);
        markers.extend(self.semantic_markers);
        normalized_markers(markers)
    }

    pub(crate) fn total_tasks(&self) -> usize {
        self.total_tasks
    }

    pub(crate) fn resolved_lens_count(&self) -> usize {
        self.resolved_lenses.len()
    }

    pub(crate) fn created_at(&self) -> Instant {
        self.created_at
    }

    pub(crate) fn deadline(&self) -> Instant {
        self.deadline
    }
}

impl JavaNavigationMarkerTask {
    /// Returns the provider method and params for this verification step.
    pub(crate) fn request(&self, uri: &str) -> (&'static str, Value) {
        match self {
            Self::ResolveCodeLens(lens) => ("codeLens/resolve", lens.clone()),
            Self::FindImplementations(candidate) => (
                "textDocument/implementation",
                json!({
                    "textDocument": { "uri": uri },
                    "position": {
                        "line": candidate.line,
                        "character": candidate.utf16_column
                    }
                }),
            ),
            Self::FindSuperImplementation(candidate) => (
                "java/findLinks",
                json!({
                    "type": "superImplementation",
                    "position": {
                        "textDocument": { "uri": uri },
                        "position": {
                            "line": candidate.line,
                            "character": candidate.utf16_column
                        }
                    }
                }),
            ),
        }
    }
}

fn raw_location_count(result: Option<&Value>) -> usize {
    match result {
        Some(Value::Array(locations)) => locations.len(),
        Some(Value::Object(_)) => 1,
        _ => 0,
    }
}

/// Keeps only JDT LS implementation lenses; reference lenses never drive gutter icons.
pub(crate) fn implementation_code_lenses(values: &[Value]) -> Vec<Value> {
    values
        .iter()
        .filter(|lens| {
            resolved_implementation_title(lens).is_some()
                || lens
                    .get("data")
                    .and_then(Value::as_array)
                    .and_then(|data| data.get(2))
                    .and_then(Value::as_str)
                    == Some("implementations")
        })
        .cloned()
        .collect()
}

/// Returns whether JDT LS has already attached the target count to a lens.
pub(crate) fn is_resolved_implementation_lens(lens: &Value) -> bool {
    resolved_implementation_title(lens).is_some()
}

/// Converts resolved JDT LS implementation CodeLens entries into gutter markers.
///
/// JDT LS 1.38 only emits implementation lenses for interfaces and abstract
/// classes. It does not encode the declaration kind in the lens, so the
/// synchronized source is used solely to distinguish those two relationships.
/// Zero-target lenses are intentionally omitted to match IDEA gutter behavior.
pub(crate) fn markers_from_resolved_code_lenses(
    code_lenses: &[Value],
    source: &str,
) -> Vec<JavaNavigationMarkerResponse> {
    let markers = code_lenses
        .iter()
        .filter_map(|lens| marker_from_resolved_code_lens(lens, source))
        .collect::<Vec<_>>();
    normalized_markers(markers)
}

/// Applies the deterministic ordering and identity used by the shared contract.
pub(crate) fn normalized_markers(
    mut markers: Vec<JavaNavigationMarkerResponse>,
) -> Vec<JavaNavigationMarkerResponse> {
    markers.sort_by(|left, right| {
        left.line
            .cmp(&right.line)
            .then_with(|| left.utf16_column.cmp(&right.utf16_column))
            .then_with(|| left.relation.cmp(&right.relation))
    });
    markers.dedup_by(|left, right| {
        left.line == right.line
            && left.utf16_column == right.utf16_column
            && left.direction == right.direction
            && left.relation == right.relation
    });
    markers
}

fn marker_from_resolved_code_lens(
    lens: &Value,
    source: &str,
) -> Option<JavaNavigationMarkerResponse> {
    let count = implementation_count(resolved_implementation_title(lens)?)?;
    if count == 0 {
        return None;
    }
    let start = lens.get("range")?.get("start")?;
    let line = usize::try_from(start.get("line")?.as_i64()?).ok()?;
    let utf16_column = start
        .get("utf16Column")
        .or_else(|| start.get("character"))
        .and_then(Value::as_i64)
        .and_then(|column| usize::try_from(column).ok())?;
    let relation = if declaration_prefix(source, line, utf16_column)
        .split(|character: char| !character.is_ascii_alphanumeric() && character != '_')
        .any(|word| word == "interface")
    {
        "interface"
    } else {
        "inheritance"
    };
    Some(JavaNavigationMarkerResponse {
        line,
        utf16_column,
        implementation_count: count,
        direction: "down".to_string(),
        relation: relation.to_string(),
    })
}

fn resolved_implementation_title(lens: &Value) -> Option<&str> {
    let title = lens.get("command")?.get("title")?.as_str()?.trim();
    implementation_count(title).map(|_| title)
}

fn implementation_count(title: &str) -> Option<usize> {
    let mut parts = title.split_whitespace();
    let count = parts.next()?.parse::<usize>().ok()?;
    let noun = parts.next()?;
    if matches!(noun, "implementation" | "implementations") && parts.next().is_none() {
        Some(count)
    } else {
        None
    }
}

fn declaration_prefix(source: &str, line: usize, utf16_column: usize) -> &str {
    let Some(line_text) = source.lines().nth(line) else {
        return "";
    };
    let byte_column = line_text
        .char_indices()
        .scan(0usize, |units, (offset, character)| {
            let current = *units;
            *units += character.len_utf16();
            Some((offset, current))
        })
        .find_map(|(offset, units)| (units >= utf16_column).then_some(offset))
        .unwrap_or(line_text.len());
    &line_text[..byte_column]
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn resolved_lenses_distinguish_interface_and_abstract_class_declarations() {
        let source = "public interface Service {}\npublic abstract class Base {}\n";
        let lenses = vec![
            json!({
                "range": { "start": { "line": 0, "utf16Column": 17 } },
                "command": { "title": "2 implementations" }
            }),
            json!({
                "range": { "start": { "line": 1, "utf16Column": 22 } },
                "command": { "title": "1 implementation" }
            }),
        ];

        let markers = markers_from_resolved_code_lenses(&lenses, source);

        assert_eq!(markers.len(), 2);
        assert_eq!(markers[0].relation, "interface");
        assert_eq!(markers[0].implementation_count, 2);
        assert_eq!(markers[1].relation, "inheritance");
    }

    #[test]
    fn unresolved_zero_target_and_reference_lenses_do_not_create_markers() {
        let lenses = vec![
            json!({ "range": { "start": { "line": 0, "utf16Column": 0 } } }),
            json!({
                "range": { "start": { "line": 0, "utf16Column": 0 } },
                "command": { "title": "0 implementations" }
            }),
            json!({
                "range": { "start": { "line": 0, "utf16Column": 0 } },
                "command": { "title": "3 references" }
            }),
        ];

        assert!(markers_from_resolved_code_lenses(&lenses, "interface Service {}").is_empty());
    }

    #[test]
    fn implementation_filter_uses_jdt_data_before_lenses_are_resolved() {
        let lenses = vec![
            json!({ "data": ["file:///Service.java", { "line": 0 }, "implementations"] }),
            json!({ "data": ["file:///Service.java", { "line": 0 }, "references"] }),
            json!({ "command": { "title": "1 implementation" } }),
        ];

        let filtered = implementation_code_lenses(&lenses);

        assert_eq!(filtered.len(), 2);
        assert!(!is_resolved_implementation_lens(&filtered[0]));
        assert!(is_resolved_implementation_lens(&filtered[1]));
    }
}
