//! Shared Git console compression, query grouping, repository labels and search locations.
mod command;
mod output;
#[cfg(test)]
mod tests;
mod types;
use crate::protocol::{CoreError, ErrorCode};
use types::*;
pub use types::{Request, Source};

/// Generates a lossless display plan from already-retained, sanitized native records.
/// Folded ranges always refer to the input; this operation never launches a process.
pub fn present(request: Request) -> Result<Presentation, CoreError> {
    if request.records.len() > 200
        || request.search.len() > 1024
        || request.repository_roots.len() > 200
        || request
            .repository_roots
            .iter()
            .map(String::len)
            .sum::<usize>()
            > 256 * 1024
        || request
            .records
            .iter()
            .map(|r| {
                r.lines.iter().map(|l| l.text.len()).sum::<usize>()
                    + r.arguments.iter().map(String::len).sum::<usize>()
                    + r.lines.len() * 32
                    + r.arguments.len() * 8
                    + r.temporary_config
                        .iter()
                        .map(|(key, value)| key.len() + value.len() + 16)
                        .sum::<usize>()
                    + r.id.len()
                    + r.root.len()
                    + r.state.len()
                    + r.error.as_ref().map_or(0, String::len)
                    + r.progress.as_ref().map_or(0, String::len)
                    + r.executable.as_ref().map_or(0, String::len)
            })
            .sum::<usize>()
            > 4 * 1024 * 1024
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Git console presentation exceeds its retained history limit",
        ));
    }
    let mut presentation = Presentation {
        entries: Vec::new(),
        groups: Vec::new(),
        matches: Vec::new(),
        total_matches: 0,
    };
    let query = request.search.to_lowercase();
    let mut roots = request
        .records
        .iter()
        .map(|r| r.root.replace('\\', "/"))
        .collect::<Vec<_>>();
    roots.extend(
        request
            .repository_roots
            .iter()
            .map(|root| root.replace('\\', "/")),
    );
    for (index, record) in request.records.iter().enumerate() {
        let previous_matches = presentation.total_matches;
        let mut entry = Entry {
            id: record.id.clone(),
            repository_label: repository_label(index, &roots),
            command: command::project(record),
            output: output::project(record),
            failed: record.failed(),
        };
        if !query.is_empty() {
            add_matches(
                &mut presentation,
                record,
                "repository",
                None,
                occurrences(&record.root, &query),
            );
            for fragment in &mut entry.command {
                fragment.matches = occurrences(&fragment.text, &query);
                add_matches(
                    &mut presentation,
                    record,
                    &fragment.id,
                    None,
                    fragment.matches,
                );
            }
            for fragment in &mut entry.output {
                for (index, line) in record
                    .lines
                    .iter()
                    .enumerate()
                    .take(fragment.end)
                    .skip(fragment.start)
                {
                    let count = occurrences(&line.text, &query);
                    fragment.matches += count;
                    add_matches(&mut presentation, record, &fragment.id, Some(index), count);
                }
            }
            for (id, text) in [
                ("error", record.error.as_deref()),
                ("progress", record.progress.as_deref()),
            ] {
                if let Some(text) = text {
                    add_matches(
                        &mut presentation,
                        record,
                        id,
                        None,
                        occurrences(text, &query),
                    );
                }
            }
        }
        if index > 0 && can_merge(&request.records[index - 1], record) {
            if let Some(group) = presentation.groups.last_mut() {
                group.record_ids.push(record.id.clone());
                group.matches += presentation.total_matches - previous_matches;
            }
        } else {
            presentation.groups.push(Group {
                matches: presentation.total_matches - previous_matches,
                id: record.id.clone(),
                record_ids: vec![record.id.clone()],
            });
        }
        presentation.entries.push(entry);
    }
    Ok(presentation)
}
fn occurrences(text: &str, query: &str) -> usize {
    text.to_lowercase().match_indices(query).count()
}
fn add_matches(
    presentation: &mut Presentation,
    record: &Record,
    fragment: &str,
    line_index: Option<usize>,
    count: usize,
) {
    presentation.total_matches += count;
    for _ in 0..count.min(1000usize.saturating_sub(presentation.matches.len())) {
        presentation.matches.push(SearchHit {
            record_id: record.id.clone(),
            fragment_id: fragment.into(),
            line_index,
        });
    }
}
fn can_merge(left: &Record, right: &Record) -> bool {
    let adjacent = match (left.sequence, right.sequence) {
        (Some(left), Some(right)) => left.checked_add(1) == Some(right),
        (None, None) => true,
        _ => false,
    };
    adjacent
        && left.source == Source::Background
        && right.source == Source::Background
        && left.succeeded()
        && right.succeeded()
        && !left.truncated
        && !right.truncated
        && command::is_query(left)
        && command::is_query(right)
        && left.root == right.root
        && left.arguments == right.arguments
        && left.temporary_config == right.temporary_config
        && left.executable == right.executable
        && left.exit_code == right.exit_code
        && left.expected_exit == right.expected_exit
        && left.lines == right.lines
        && left.progress == right.progress
}
fn repository_label(index: usize, roots: &[String]) -> String {
    let components = |root: &str| {
        root.trim_end_matches('/')
            .split('/')
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .collect::<Vec<_>>()
    };
    let parts = components(&roots[index]);
    if parts.is_empty() {
        return roots[index].clone();
    }
    for count in 1..=parts.len() {
        let suffix = parts[parts.len() - count..].join("/");
        let collision = roots.iter().enumerate().any(|(other, root)| {
            if other == index || root == &roots[index] {
                return false;
            }
            let parts = components(root);
            parts.len() >= count && parts[parts.len() - count..].join("/") == suffix
        });
        if !collision {
            return suffix;
        }
    }
    roots[index].clone()
}
