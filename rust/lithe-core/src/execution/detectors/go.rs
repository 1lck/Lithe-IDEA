//! Go application discovery from module roots and conventional command layouts.

use super::super::types::Confidence;
use super::{Detected, DirectoryContext};

/// A Go module is runnable when a `package main` sits next to its `go.mod`, or
/// under the conventional `cmd/<name>` layout. There is no declaration listing
/// entry points, so both are heuristics.
pub fn detect(ctx: &DirectoryContext) -> Vec<Detected> {
    let mut detected = Vec::new();
    if ctx.has("go.mod") && has_main_package(ctx) {
        detected.push(
            Detected::application(
                "go.main",
                &ctx.label(),
                "go",
                vec!["run", "."],
                ctx,
                "go.mod",
            )
            .with_confidence(Confidence::Heuristic),
        );
    }
    // `cmd/<name>` directories carry their own main package but no manifest.
    // `go run .` resolves through the module root further up the tree.
    if is_command_directory(ctx) && has_main_package(ctx) {
        detected.push(
            Detected::application(
                "go.command",
                &ctx.label(),
                "go",
                vec!["run", "."],
                ctx,
                "main.go",
            )
            .with_confidence(Confidence::Heuristic),
        );
    }
    detected
}

fn is_command_directory(ctx: &DirectoryContext) -> bool {
    ctx.relative.split('/').rev().nth(1) == Some("cmd")
}

fn has_main_package(ctx: &DirectoryContext) -> bool {
    ctx.read("main.go")
        .is_some_and(|text| text.lines().any(|line| line.trim() == "package main"))
}
