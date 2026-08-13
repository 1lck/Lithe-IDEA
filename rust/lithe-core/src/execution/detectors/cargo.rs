use super::{Detected, DirectoryContext};

/// Cargo binaries come from `[[bin]]` entries, or implicitly from `src/main.rs`.
/// Workspace roots with no package of their own contribute nothing -- their
/// members are separate directories and detect independently.
pub fn detect(ctx: &DirectoryContext) -> Vec<Detected> {
    let Some(text) = ctx.read("Cargo.toml") else {
        return Vec::new();
    };
    let Ok(document) = text.parse::<toml::Table>() else {
        return Vec::new();
    };
    let Some(package) = document.get("package") else {
        return Vec::new();
    };
    let declared = document
        .get("bin")
        .and_then(|value| value.as_array())
        .map(|entries| {
            entries
                .iter()
                .filter_map(|entry| entry.get("name")?.as_str())
                .map(str::to_string)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let names = if declared.is_empty() {
        package
            .get("name")
            .and_then(|value| value.as_str())
            .filter(|_| has_main(ctx))
            .map(|name| vec![name.to_string()])
            .unwrap_or_default()
    } else {
        declared
    };
    names
        .into_iter()
        .map(|name| {
            Detected::application(
                "cargo.binary",
                &name,
                "cargo",
                vec!["run", "--bin", &name],
                ctx,
                "Cargo.toml",
            )
            .with_extension("cargo", serde_json::json!({ "bin": name }))
        })
        .collect()
}

/// `src/main.rs` is what makes a package a binary rather than a library. It sits
/// one directory below the manifest, which the scan records separately, so this
/// is the one place a detector touches the filesystem directly.
fn has_main(ctx: &DirectoryContext) -> bool {
    ctx.path.join("src").join("main.rs").is_file()
}
