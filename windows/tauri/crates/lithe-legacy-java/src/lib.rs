//! Transitional Java, Maven, Spring and MyBatis logic for the Windows host.
//!
//! Issue #1495 moves this logic out of Rust Core and into the Java plugin. The
//! Windows host cannot reach a plugin yet, so it keeps calling the old Core
//! command names and a few Core helper functions. This crate answers exactly
//! those calls with the code Core used to hold, so the Windows frontend and its
//! JSON contract do not change while Core sheds the Java-specific parts.
//!
//! Two kinds of code live here:
//!
//! - Moved from Core, which no longer has them: the six `maven.*` command
//!   entries, the class-path JAR planner and the Java source listing. Core keeps
//!   only the Maven reading it still uses for builds and JDT LS settings.
//! - Copied from Core, which keeps its own: `java.*`, `spring.index`,
//!   `mybatis.index`, Java selection, launch-command planning, the JDT workspace
//!   key and the Maven settings writer. macOS or Core's own JDT LS adapter still
//!   call these, so both copies exist until the macOS migration lands.
//!
//! This crate is transitional. Delete it once the Windows host implements the
//! generic plugin interface and can install `lithe-plugin-java`; tracking Issue
//! #1495. Nothing here may grow new features: change `lithe-plugin-java` instead.

mod classpath_jar;
mod commands;
mod contracts;
mod java_run_markers;
mod java_selection;
mod java_source_definition;
mod java_workspace;
mod jdt_workspace_key;
mod launch_command;
mod local_fs;
mod maven;
mod mybatis;
mod run_sources;
mod spring;
#[cfg(test)]
mod tests;

pub use classpath_jar::{
    plan_classpath_jar_launch, ClasspathJarPlan, ClasspathJarRequest, ClasspathStyle,
};
pub use commands::try_execute;
pub use java_selection::{
    compare_java_candidates, select_java, JavaSelection, JavaSelectionCandidate,
    JavaSelectionRequest,
};
pub use jdt_workspace_key::jdt_workspace_key;
pub use launch_command::{
    java_feature_version_from_release, plan_launch_command, LaunchCommandPlan,
};
pub use maven::settings_with_local_repository;
pub use run_sources::{is_run_scan_excluded_directory, list_run_java_sources};
