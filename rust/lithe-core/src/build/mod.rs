//! Build systems declared by API level 3 plugins: one model for every
//! project-level build tool, and the deterministic half of running one.
//!
//! A plugin describes a build tool as data (`buildSystems` in `plugin.json`):
//! how to recognize its projects, which executable runs it, which options,
//! tasks, run entries, and tests it has, and how to read its output. Core
//! validates the declaration, reads static models during the shared project
//! walk, expands argument templates into argv plans, and decodes model, test,
//! diagnostic, and dependency output into one normalized shape. Hosts resolve
//! executables, start processes, watch files, and store user choices.
//!
//! Nothing here starts a process or writes a file. Workspace files are only
//! read, and only where a command says so (static models, test reports, sync
//! fingerprints, and the `maven` integration).
//!
//! Note: the contract is recorded in .agents/notes/implemented/architecture/2026-10-17-build-system-plugin-contract.md

mod commands;
mod decode;
mod detect;
mod integrations;
mod invocation;
mod language_import;
mod manifest;
mod model;
mod options;
mod outputs;
mod plans;
mod select;
mod template;

pub(crate) use commands::*;
pub(crate) use manifest::{
    activation_event, programs, validate_declarations, BuildSystemDeclaration, DeclarationContext,
    ProviderProcess,
};
