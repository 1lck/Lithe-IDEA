use super::{Detected, DirectoryContext};
use crate::run_configuration::Confidence;

const FILES: &[&str] = &["Procfile", "Procfile.dev", "Procfile.local"];

/// Every Procfile line is `name: command args...`. The command is a shell string
/// rather than an argv, so it is split on whitespace and anything with shell
/// metacharacters is skipped -- the launcher spawns directly, and pretending a
/// pipeline is a single program produces a broken entry.
pub fn detect(ctx: &DirectoryContext) -> Vec<Detected> {
    FILES
        .iter()
        .filter(|file| ctx.has(file))
        .filter_map(|file| ctx.read(file).map(|text| (*file, text)))
        .flat_map(|(file, text)| entries(ctx, file, &text))
        .collect()
}

fn entries(ctx: &DirectoryContext, file: &str, text: &str) -> Vec<Detected> {
    text.lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                return None;
            }
            let (name, rest) = line.split_once(':')?;
            let name = name.trim();
            let mut parts = rest.split_whitespace();
            let command = parts.next()?;
            if name.is_empty() || shell_syntax(rest) {
                return None;
            }
            let args = parts.collect::<Vec<_>>();
            Some(
                Detected::service("procfile.process", name, command, args, ctx, file)
                    .with_confidence(Confidence::Declared)
                    .with_extension("procfile", serde_json::json!({ "file": file })),
            )
        })
        .collect()
}

fn shell_syntax(value: &str) -> bool {
    value.contains(['|', '&', ';', '>', '<', '$', '`'])
}
