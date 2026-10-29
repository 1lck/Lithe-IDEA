//! `backend` of an API level 3 plugin manifest: one long-lived process a
//! plugin starts for itself, independent of any build system, language, or
//! workspace.
//!
//! A build provider or VCS provider exists for one domain contract and one
//! workspace. A backend serves only the plugin itself: its web pages call the
//! backend's [plugin functions](crate::lsp::interface::plugin_function), and
//! the backend may ask the host for the primitive services its permissions
//! grant, such as private credential storage. The host keeps one process per
//! plugin on the machine that runs Lithe, and ends it when the plugin is
//! disabled, updated, or uninstalled.
//!
//! `backend` 1 starts on the first call from one of the plugin's pages, so
//! it needs a web tool window. `backend` 2 may also start when a workspace
//! opens (`onWorkspaceOpen`) or when one of the plugin's commands runs, so it
//! needs only some way to start. Version 2 is also the only one that can be
//! granted the `workspace` host service. Every workspace reaches the one
//! process as an explicit context in each call, never as process state, so
//! `${workspaceStateDir}` stays refused in both versions; the per-workspace
//! state directory travels in the context instead.
//!
//! The process shares the launch fields, templates, and install review of
//! every plugin server process.
//!
//! Note: the decisions are recorded in .agents/notes/implemented/architecture/2026-10-24-database-provider-plugin.md
//! and .agents/notes/implemented/architecture/2026-10-30-plugin-backend-workspace-context.md

use super::declarative::{invalid, ServerProcess, ServerRole, Validation};
use super::settings::DeclaredSettings;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// The plugin's own backend process.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct BackendDeclaration {
    #[serde(flatten)]
    pub(crate) process: ServerProcess,
}

/// Primitive host services a backend may request, each granted by one
/// manifest permission.
pub(crate) const HOST_SERVICE_CREDENTIALS: &str = "credentials";
/// Workspace contexts and their folders (`workspace.metadata`, `backend` 2).
pub(crate) const HOST_SERVICE_WORKSPACE: &str = "workspace";

/// First `backend` version that may start without a page and may use
/// workspace contexts.
pub(crate) const WORKSPACE_CONTEXT_VERSION: u32 = 2;

/// Activation event of a `backend` 2 process that starts once a workspace
/// is open. It names no ID: the backend is one process for every workspace.
pub(crate) const ON_WORKSPACE_OPEN: &str = "onWorkspaceOpen";

/// What backend validation needs from the rest of the manifest.
pub(crate) struct DeclarationContext<'a> {
    pub(crate) plugin_api_version: u32,
    /// `requires.backend`; 1 when absent, which only happens below level 3.
    pub(crate) version: u32,
    pub(crate) declared_settings: &'a DeclaredSettings,
    /// Whether a tool window of the plugin shows web content, the only
    /// caller of a backend in `backend` 1.
    pub(crate) has_web_window: bool,
    /// Whether the plugin declares a UI command, whose `onCommand` event
    /// starts a `backend` 2 process.
    pub(crate) has_command: bool,
    /// Whether the manifest lists `onWorkspaceOpen`.
    pub(crate) activates_on_workspace_open: bool,
}

impl BackendDeclaration {
    pub(crate) fn validate(&self, context: &DeclarationContext<'_>) -> Validation<()> {
        if context.plugin_api_version < 3 {
            return Err(invalid(
                "backend",
                "A plugin backend requires plugin API level 3.",
            ));
        }
        // Only the plugin's own pages call a backend in version 1, so one
        // without a web window could never start. Version 2 may also start
        // with a workspace or a command, but still needs one of the three.
        if context.version < WORKSPACE_CONTEXT_VERSION {
            if !context.has_web_window {
                return Err(invalid(
                    "backend",
                    "A plugin backend serves the plugin's own web pages; declare a web tool window.",
                ));
            }
        } else if !context.has_web_window
            && !context.has_command
            && !context.activates_on_workspace_open
        {
            return Err(invalid(
                "backend",
                "A plugin backend needs a way to start: a web tool window, a command, or onWorkspaceOpen.",
            ));
        }
        self.process.validate(
            "backend",
            context.plugin_api_version,
            context.declared_settings,
            ServerRole::Backend,
        )?;
        // One process serves every workspace, so a launch argument cannot
        // name one of them; version 2 receives the directory per context.
        if self.process.uses_workspace_state_directory() {
            return Err(invalid(
                "backend",
                "A plugin backend is not bound to a workspace and cannot use ${workspaceStateDir}.",
            ));
        }
        Ok(())
    }
}

/// Install-review entries: the backend process with the runtimes it needs.
pub(crate) fn programs(backend: &BackendDeclaration) -> Vec<Value> {
    let mut programs = vec![backend.process.program(ServerRole::Backend)];
    programs.extend(backend.process.runtime_programs());
    programs
}

/// The `backend` member of a launch plan: the host services the session may
/// request, which the host passes to `lsp.startServer` unchanged. Version 2
/// also names its version, so the host knows it may start the process
/// without a page; a version 1 plan keeps its original shape.
pub(crate) fn plan_descriptor(version: u32, host_services: &[&str]) -> Value {
    if version >= WORKSPACE_CONTEXT_VERSION {
        json!({ "hostServices": host_services, "version": version })
    } else {
        json!({ "hostServices": host_services })
    }
}
