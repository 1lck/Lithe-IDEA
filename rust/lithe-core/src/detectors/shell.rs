use super::{Detected, DirectoryContext};
use crate::run_configuration::Confidence;

const JUSTFILES: &[&str] = &["justfile", "Justfile", ".justfile"];

const SERVICE_RECIPES: &[&str] = &["run", "dev", "serve", "start", "up", "watch"];

/// Recipes are declared as `name:` or `name arg1 arg2:` at column zero. Recipes
/// taking required arguments are skipped: the IDE has no value to supply, and a
/// run entry that always fails is worse than no entry.
pub fn detect_just(ctx: &DirectoryContext) -> Vec<Detected> {
    let Some(file) = ctx.any_of(JUSTFILES) else {
        return Vec::new();
    };
    let Some(text) = ctx.read(file) else {
        return Vec::new();
    };
    text.lines()
        .filter_map(|line| {
            if line.starts_with([' ', '\t', '#', '@']) {
                return None;
            }
            let (head, _) = line.split_once(':')?;
            let head = head.trim();
            if head.is_empty() || head.contains('=') {
                return None;
            }
            let mut parts = head.split_whitespace();
            let name = parts.next()?;
            if parts.next().is_some() {
                return None;
            }
            let valid = name
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
            if !valid {
                return None;
            }
            let detected = if SERVICE_RECIPES.contains(&name) {
                Detected::service("just.recipe", name, "just", vec![name], ctx, file)
            } else {
                Detected::task("just.recipe", name, "just", vec![name], ctx, file)
            };
            Some(
                detected
                    .with_confidence(Confidence::Declared)
                    .with_extension("just", serde_json::json!({ "recipe": name })),
            )
        })
        .collect()
}
