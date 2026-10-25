//! `backend` of an API level 3 plugin manifest: one long-lived process a
//! plugin starts for its own pages, independent of any build system,
//! language, or workspace.
//!
//! A build provider or VCS provider exists for one domain contract and one
//! workspace. A backend serves only the plugin itself: its web pages call the
//! backend's [plugin functions](crate::lsp::interface::plugin_function), and
//! the backend may ask the host for the primitive services its permissions
//! grant, such as private credential storage. The host starts it on the first
//! call from one of the plugin's pages, keeps one process per plugin, and ends
//! it when the plugin is disabled, updated, or uninstalled.
//!
//! The process shares the launch fields, templates, and install review of
//! every plugin server process. It is not bound to a workspace, so
//! `${workspaceStateDir}` is refused.
//!
//! Note: the decision is recorded in .agents/notes/implemented/architecture/2026-10-24-database-provider-plugin.md

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

/// What backend validation needs from the rest of the manifest.
pub(crate) struct DeclarationContext<'a> {
    pub(crate) plugin_api_version: u32,
    pub(crate) declared_settings: &'a DeclaredSettings,
    /// Whether a tool window of the plugin shows web content, the only
    /// caller of a backend in `backend` 1.
    pub(crate) has_web_window: bool,
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
        // without a web window could never start.
        if !context.has_web_window {
            return Err(invalid(
                "backend",
                "A plugin backend serves the plugin's own web pages; declare a web tool window.",
            ));
        }
        self.process.validate(
            "backend",
            context.plugin_api_version,
            context.declared_settings,
            ServerRole::Backend,
        )?;
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
/// request, which the host passes to `lsp.startServer` unchanged.
pub(crate) fn plan_descriptor(host_services: &[&str]) -> Value {
    json!({ "hostServices": host_services })
}
