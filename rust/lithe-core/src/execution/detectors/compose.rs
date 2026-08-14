//! Docker Compose service discovery from the standard manifest names.

use super::{Detected, DirectoryContext};

const FILES: &[&str] = &[
    "docker-compose.yml",
    "docker-compose.yaml",
    "compose.yml",
    "compose.yaml",
];

/// Returns one service configuration for each declared Compose service.
pub fn detect(ctx: &DirectoryContext) -> Vec<Detected> {
    let Some(file) = ctx.any_of(FILES) else {
        return Vec::new();
    };
    let Some(text) = ctx.read(file) else {
        return Vec::new();
    };
    let Ok(document) = serde_yaml_ng::from_str::<serde_yaml_ng::Value>(&text) else {
        return Vec::new();
    };
    let Some(services) = document
        .get("services")
        .and_then(|value| value.as_mapping())
    else {
        return Vec::new();
    };
    let mut detected = services
        .keys()
        .filter_map(|key| key.as_str())
        .map(|name| {
            Detected::service(
                "compose.service",
                name,
                "docker",
                vec!["compose", "-f", file, "up", name],
                ctx,
                file,
            )
            .with_extension(
                "compose",
                serde_json::json!({ "file": file, "service": name }),
            )
        })
        .collect::<Vec<_>>();
    // The whole stack is usually what the user wants first, so offer it as a
    // single entry alongside the individual services rather than making them
    // start each one by hand.
    if !detected.is_empty() {
        detected.push(
            Detected::service(
                "compose.stack",
                "compose up",
                "docker",
                vec!["compose", "-f", file, "up"],
                ctx,
                file,
            )
            .with_extension("compose", serde_json::json!({ "file": file })),
        );
    }
    detected
}
