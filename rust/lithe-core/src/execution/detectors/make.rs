//! Runnable Make target discovery with conservative service classification.

use super::super::types::Confidence;
use super::{Detected, DirectoryContext};

const FILES: &[&str] = &["Makefile", "makefile", "GNUmakefile"];

/// Targets whose name conventionally starts something long-running. Everything
/// else is a task, so `make clean` does not show up in the service list.
const SERVICE_TARGETS: &[&str] = &["run", "dev", "serve", "start", "up", "watch"];

/// Only targets the user could plausibly want to run are offered: a Makefile
/// commonly has dozens of internal rules, and listing all of them buries the
/// two that matter.
pub fn detect(ctx: &DirectoryContext) -> Vec<Detected> {
    let Some(file) = ctx.any_of(FILES) else {
        return Vec::new();
    };
    let Some(text) = ctx.read(file) else {
        return Vec::new();
    };
    targets(&text)
        .into_iter()
        .filter(|name| SERVICE_TARGETS.contains(&name.as_str()) || is_common(name))
        .map(|name| {
            let detected = if SERVICE_TARGETS.contains(&name.as_str()) {
                Detected::service("make.target", &name, "make", vec![&name], ctx, file)
            } else {
                Detected::task("make.target", &name, "make", vec![&name], ctx, file)
            };
            detected
                .with_confidence(Confidence::Declared)
                .with_extension("make", serde_json::json!({ "target": name }))
        })
        .collect()
}

fn is_common(name: &str) -> bool {
    matches!(
        name,
        "build" | "test" | "install" | "lint" | "fmt" | "check"
    )
}

/// Recognises `target:` at the start of a line. Pattern rules, variables, and
/// `.PHONY`-style directives are excluded because they are not invocable names.
fn targets(text: &str) -> Vec<String> {
    text.lines()
        .filter_map(|line| {
            if line.starts_with([' ', '\t', '#']) {
                return None;
            }
            let (name, rest) = line.split_once(':')?;
            if rest.starts_with('=') {
                return None;
            }
            let name = name.trim();
            let valid = !name.is_empty()
                && !name.starts_with('.')
                && name
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
            valid.then(|| name.to_string())
        })
        .collect()
}
