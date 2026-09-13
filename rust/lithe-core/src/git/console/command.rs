//! Conservative command compression: behavior-changing flags always remain visible.
use super::types::{CommandFragment, Record};
use crate::git::execution_policy::command_index;

pub(super) fn quote(value: &str) -> String {
    if !value.is_empty()
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "_@%+=:,./-".contains(c))
    {
        value.to_string()
    } else {
        format!("'{}'", value.replace('\r', "\\r").replace('\'', "'\\''"))
    }
}
fn join(values: &[String]) -> String {
    values
        .iter()
        .map(|s| quote(s))
        .collect::<Vec<_>>()
        .join(" ")
}
fn common_config(value: &str) -> bool {
    value
        .split_once('=')
        .is_some_and(|(key, _)| matches!(key, "color.ui" | "core.quotepath" | "log.showSignature"))
}
fn fragment(
    id: String,
    kind: &str,
    text: String,
    preview: String,
    count: usize,
) -> CommandFragment {
    CommandFragment {
        id,
        kind: kind.into(),
        text,
        preview,
        count,
        matches: 0,
    }
}

pub(super) fn project(record: &Record) -> Vec<CommandFragment> {
    let args = &record.arguments;
    let command = command_index(args).unwrap_or(0);
    let mut configuration = Vec::new();
    let mut visible = Vec::new();
    for (key, value) in &record.temporary_config {
        let pair = vec!["-c".into(), format!("{key}={value}")];
        if common_config(&pair[1]) {
            configuration.extend(pair);
        } else {
            visible.extend(pair);
        }
    }
    let mut index = 0;
    while index < command {
        if args[index] == "--no-pager" {
            configuration.push(args[index].clone());
            index += 1;
        } else if args[index] == "-c" && index + 1 < command && common_config(&args[index + 1]) {
            configuration.extend_from_slice(&args[index..index + 2]);
            index += 2;
        } else if args[index].starts_with("-c") && common_config(&args[index][2..]) {
            configuration.push(args[index].clone());
            index += 1;
        } else {
            visible.push(args[index].clone());
            index += 1;
        }
    }
    let mut fragments = Vec::new();
    if !configuration.is_empty() {
        fragments.push(fragment(
            "configuration".into(),
            "configuration",
            join(&configuration),
            "-c …".into(),
            configuration.len(),
        ));
    }
    if !visible.is_empty() {
        fragments.push(fragment(
            "global".into(),
            "text",
            join(&visible),
            String::new(),
            0,
        ));
    }
    let list = list_start(args, command);
    index = command;
    while index < args.len() {
        if let Some((start, kind)) = list {
            if index == start + 2 && args.len() - start > 3 {
                fragments.push(fragment(
                    format!("arguments-{index}"),
                    kind,
                    join(&args[index..]),
                    String::new(),
                    args.len() - index,
                ));
                break;
            }
        }
        let value = &args[index];
        let is_message = matches!(args[command].as_str(), "commit" | "tag" | "stash")
            && ((index > command && matches!(args[index - 1].as_str(), "-m" | "--message"))
                || value.starts_with("--message="));
        let long = (is_message || list.is_some_and(|(start, _)| index >= start))
            && (value.chars().count() > 100 || value.contains('\n'));
        let preview = if long {
            let beginning = value
                .lines()
                .next()
                .unwrap_or_default()
                .chars()
                .take(80)
                .collect::<String>();
            format!("{} …", quote(&beginning))
        } else {
            String::new()
        };
        fragments.push(fragment(
            format!("argument-{index}"),
            if long { "argument" } else { "text" },
            quote(value),
            preview,
            1,
        ));
        index += 1;
    }
    fragments
}

/// Only known positional lists are folded. Unknown flags or command grammars stay literal.
fn list_start(args: &[String], command: usize) -> Option<(usize, &'static str)> {
    let name = args.get(command)?.as_str();
    let boundary = args
        .iter()
        .enumerate()
        .skip(command + 1)
        .find(|(_, s)| s.as_str() == "--")
        .map(|(i, _)| i + 1);
    if matches!(
        name,
        "add" | "restore" | "rm" | "diff" | "checkout" | "reset" | "ls-files" | "check-ignore"
    ) {
        return boundary.map(|i| (i, "files"));
    }
    if matches!(name, "push" | "fetch") {
        // The first argument after -- is the remote, and is never collapsed.
        return boundary
            .filter(|i| *i < args.len())
            .map(|i| (i + 1, "references"));
    }
    None
}

pub(super) fn is_query(record: &Record) -> bool {
    let args = &record.arguments;
    let Some(index) = command_index(args) else {
        return false;
    };
    match args[index].as_str() {
        "status" | "log" | "diff" | "ls-files" | "for-each-ref" | "show-ref" | "rev-parse"
        | "ls-tree" => !args.iter().any(|s| s.starts_with("--output")),
        "reflog" => !args[index + 1..]
            .iter()
            .any(|s| matches!(s.as_str(), "delete" | "drop" | "expire" | "write")),
        "branch" | "tag" => {
            args.len() == index + 1 || args[index + 1..].iter().all(|s| s == "--list")
        }
        _ => false,
    }
}
