//! `build.languageImport`: the Java language server's project import
//! settings for one build-system instance, from the user's build options.
//!
//! The result has the shapes `lsp.startServer` already accepts, the Maven
//! launch context (`mavenContext`) and the Gradle import context
//! (`javaGradle`), so a host forwards it without knowing which plugin
//! declared the build system.

use super::decode::{self, Workspace};
use super::manifest::{BuildSystemDeclaration, LanguageImportKind};
use super::options;
use crate::plugins::declarative::Validation;
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;

/// Where Buildship looks for the wrapper, relative to the instance root.
const GRADLE_WRAPPER_DESCRIPTOR: &str = "gradle/wrapper/gradle-wrapper.properties";

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct LanguageImportRequest {
    pub(crate) workspace_root: String,
    pub(crate) root: String,
    /// Stored option values by option ID.
    #[serde(default)]
    pub(crate) options: BTreeMap<String, Value>,
    /// The tool executable the host resolved for this instance; Maven reads
    /// its installation settings next to it.
    #[serde(default)]
    pub(crate) executable_path: Option<String>,
}

/// `null` when the build system declares no import, otherwise
/// `{ kind: "maven", mavenContext }` or `{ kind: "gradle", javaGradle }`.
pub(crate) fn language_import(
    build_system: &BuildSystemDeclaration,
    request: &LanguageImportRequest,
) -> Validation<Value> {
    let workspace = Workspace::new(&request.workspace_root)?;
    let root = decode::request_path(&request.root, "root")?;
    let Some(import) = &build_system.language_import else {
        return Ok(Value::Null);
    };
    let resolved = options::resolve(build_system, &request.options, None);
    // Each setting is the effective value of the option the plugin mapped it
    // to; an option with no effective value leaves the setting unset.
    let setting = |name: &str| {
        import
            .options
            .get(name)
            .and_then(|option| resolved.values.get(option))
    };
    let text = |name: &str| setting(name).and_then(Value::as_str).map(str::to_string);
    Ok(match import.kind {
        LanguageImportKind::Maven => {
            let profiles: Vec<&str> = setting("profiles")
                .and_then(Value::as_array)
                .map(|items| items.iter().filter_map(Value::as_str).collect())
                .unwrap_or_default();
            let mut context = Map::new();
            context.insert(
                "version".into(),
                json!(crate::project::MAVEN_CONTEXT_VERSION),
            );
            context.insert("reactorPath".into(), json!(root));
            context.insert("profiles".into(), json!(profiles));
            for (key, value) in [
                ("settingsPath", text("settingsFile")),
                ("localRepositoryPath", text("localRepository")),
                ("mavenExecutablePath", request.executable_path.clone()),
            ] {
                if let Some(value) = value {
                    context.insert(key.into(), json!(value));
                }
            }
            json!({ "kind": "maven", "mavenContext": context })
        }
        LanguageImportKind::Gradle => {
            let wrapper = decode::join_relative(&root, GRADLE_WRAPPER_DESCRIPTOR);
            let mut gradle = Map::new();
            gradle.insert(
                "wrapperPresent".into(),
                json!(workspace
                    .read_path(&wrapper)
                    .is_some_and(|path| path.is_file())),
            );
            gradle.insert(
                "offline".into(),
                json!(setting("offline") == Some(&Value::Bool(true))),
            );
            if let Some(home) = text("gradleUserHome") {
                gradle.insert("userHome".into(), json!(home));
            }
            json!({ "kind": "gradle", "javaGradle": gradle })
        }
    })
}
