//! Project generators declared by API level 3 plugins: the entries of the
//! New Project window and the deterministic half of creating a project.
//!
//! A plugin describes a way to start a project as data (`projectGenerators`
//! in `plugin.json`): where it is listed, which fields the user fills in,
//! which plugins the result needs, and the steps that produce it — template
//! files from the package, a scaffolding command such as `mvn
//! archetype:generate`, or a zip archive such as Spring Initializr's. Core
//! validates the declaration, evaluates the form (derived defaults,
//! visibility, errors), and turns a filled form into a plan: expanded files,
//! argv, and URLs. Hosts own the window, resolve executables, download, run
//! processes in a staging directory, and move the finished project into
//! place.
//!
//! Core reads template files from the plugin package and extracts archives
//! into a staging directory the host created; it never writes anywhere else.
//!
//! Note: the decision is recorded in .agents/notes/implemented/feature/2026-10-23-plugin-project-generators.md

mod archive;
mod commands;
mod form;
mod manifest;
mod plan;
mod template;

pub(crate) use commands::*;
pub(crate) use manifest::{validate_declarations, ProjectGeneratorDeclaration};
