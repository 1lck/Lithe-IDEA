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
/// Fold contiguous Git configuration arguments in place, as IDEA's console does.
/// Token boundaries preserve quoted values and avoid folding behavior flags or paths.
pub(super) fn project(record: &Record) -> Vec<CommandFragment> {
    let mut args = Vec::new();
    for (key, value) in &record.temporary_config {
        args.extend(["-c".into(), format!("{key}={value}")]);
    }
    args.extend_from_slice(&record.arguments);
    let command = command_index(&args).unwrap_or(0);
    let mut result = Vec::new();
    let mut index = 0;
    while index < args.len() {
        let start = index;
        while index + 1 < command && args[index] == "-c" && args[index + 1].contains('=') {
            index += 2;
        }
        let folded = index > start;
        if !folded {
            index += 1;
        }
        result.push(CommandFragment {
            id: if folded {
                format!("configuration-{start}")
            } else {
                format!("argument-{start}")
            },
            kind: if folded { "configuration" } else { "text" }.into(),
            text: join(&args[start..index]),
            preview: if folded { "-c …" } else { "" }.into(),
            count: if folded { (index - start) / 2 } else { 1 },
            matches: 0,
        });
    }
    result
}
