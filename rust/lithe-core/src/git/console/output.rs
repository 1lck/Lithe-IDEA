//! Lossless output ranges with conservative summaries and visible failure context.
use super::types::{OutputFragment, Record};
use crate::git::execution_policy::command_index;

pub(super) fn project(record: &Record) -> Vec<OutputFragment> {
    let count = record.lines.len();
    let mut visible = vec![count <= 8; count];
    if count > 8 {
        for value in visible.iter_mut().take(3) {
            *value = true;
        }
        for value in visible
            .iter_mut()
            .rev()
            .take(if record.failed() { 8 } else { 2 })
        {
            *value = true;
        }
        if record.failed() {
            for (index, line) in record.lines.iter().enumerate() {
                let text = line.text.trim_start().to_lowercase();
                if ["fatal:", "error:", "conflict", "hint:"]
                    .iter()
                    .any(|prefix| text.starts_with(prefix))
                {
                    for value in &mut visible[index.saturating_sub(2)..(index + 3).min(count)] {
                        *value = true;
                    }
                }
            }
        }
    }
    let mut repeats = (1..=count).collect::<Vec<_>>();
    if record.state == "completed" && !record.failed() {
        let mut start = 0;
        while start < count {
            let end = (start + 1..count)
                .find(|i| record.lines[*i] != record.lines[start])
                .unwrap_or(count);
            repeats[start] = end;
            start = end;
        }
    }
    let mut result = Vec::new();
    let mut index = 0;
    while index < count {
        if repeats[index] > index + 1 {
            let end = repeats[index];
            result.push(range(index, index + 1, "text"));
            let mut repeat = range(index + 1, end, "repeat");
            repeat.count += 1;
            result.push(repeat);
            index = end;
            continue;
        }
        if !visible[index] {
            let end = (index + 1..count)
                .find(|i| visible[*i] || repeats[*i] > *i + 1)
                .unwrap_or(count);
            let mut fragment = range(index, end, "lines");
            if record.state == "completed" {
                classify(record, &mut fragment);
            }
            result.push(fragment);
            index = end;
            continue;
        }
        result.push(range(index, index + 1, "text"));
        index += 1;
    }
    result
}
fn range(start: usize, end: usize, kind: &str) -> OutputFragment {
    OutputFragment {
        id: format!("output-{start}"),
        start,
        end,
        kind: kind.into(),
        count: end - start,
        added: 0,
        updated: 0,
        deleted: 0,
        matches: 0,
    }
}

/// A business label requires an exact known grammar for every folded line.
fn classify(record: &Record, fragment: &mut OutputFragment) {
    let args = &record.arguments;
    let Some(command) = command_index(args) else {
        return;
    };
    let name = args[command].as_str();
    let lines = &record.lines[fragment.start..fragment.end];
    let texts = lines
        .iter()
        .map(|line| line.text.trim())
        .collect::<Vec<_>>();
    if texts
        .iter()
        .any(|text| text.is_empty() || text.contains('\0'))
    {
        return;
    }
    if name == "fetch" || name == "push" {
        let mut counts = (0, 0, 0);
        for text in &texts {
            if !text.contains(" -> ") {
                return;
            }
            if text.starts_with("* [new branch]") || text.starts_with("* [new tag]") {
                counts.0 += 1;
            } else if text.starts_with("- [deleted]") {
                counts.2 += 1;
            } else if text
                .split_whitespace()
                .next()
                .is_some_and(is_revision_range)
                || text
                    .strip_prefix("+ ")
                    .and_then(|s| s.split_whitespace().next())
                    .is_some_and(is_revision_range)
            {
                counts.1 += 1;
            } else {
                return;
            }
        }
        fragment.kind = "references".into();
        fragment.added = counts.0;
        fragment.updated = counts.1;
        fragment.deleted = counts.2;
        return;
    }
    if lines.iter().any(|line| line.stream != "stdout") {
        return;
    }
    // Custom formats and NUL framing may describe arbitrary text, not one item per line.
    if args
        .iter()
        .any(|s| s == "-z" || s.starts_with("--format") || s.starts_with("--pretty"))
    {
        return;
    }
    let kind = match name {
        "ls-files"
            if args[command + 1..]
                .iter()
                .all(|s| s == "--cached" || s == "--others" || s == "--exclude-standard") =>
        {
            "files"
        }
        "branch"
            if args.len() == command + 1
                || args[command + 1..]
                    .iter()
                    .all(|s| s == "--list" || s == "--all" || s == "--remotes") =>
        {
            if texts.iter().any(|s| {
                s.strip_prefix("* ")
                    .or_else(|| s.strip_prefix("+ "))
                    .unwrap_or(s)
                    .contains(char::is_whitespace)
                    || s.starts_with('(')
            }) {
                return;
            }
            "branches"
        }
        "tag" if args.len() == command + 1 || args[command + 1..].iter().all(|s| s == "--list") => {
            if texts.iter().any(|s| s.contains(char::is_whitespace)) {
                return;
            }
            "tags"
        }
        "log"
            if args.iter().any(|s| s == "--oneline")
                && texts
                    .iter()
                    .all(|s| s.split_once(' ').is_some_and(|(hash, _)| is_hash(hash))) =>
        {
            "commits"
        }
        "reflog"
            if texts.iter().all(|s| {
                s.split_once(' ').is_some_and(|(hash, rest)| {
                    is_hash(hash)
                        && rest.split_once(": ").is_some_and(|(selector, _)| {
                            selector.contains("@{") && selector.ends_with('}')
                        })
                })
            }) =>
        {
            "commits"
        }
        _ => return,
    };
    fragment.kind = kind.into();
}
fn is_hash(value: &str) -> bool {
    (4..=64).contains(&value.len()) && value.bytes().all(|c| c.is_ascii_hexdigit())
}
fn is_revision_range(value: &str) -> bool {
    value
        .split_once("...")
        .or_else(|| value.split_once(".."))
        .is_some_and(|(left, right)| is_hash(left) && is_hash(right))
}
