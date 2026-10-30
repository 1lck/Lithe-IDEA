//! Shared Java launch preparation, using JDT-owned entry points and runtime paths.
//! The session engine owns requests, build serialization, cancellation and deadlines.

use super::java_entrypoints::{is_windows_path, workspace_relative_path, workspace_root_path};
use crate::lsp::LspRuntimeError;
use serde_json::{json, Value};

const TARGET_ERROR: &str =
    "The Java language service could not identify one launch target for this source file.";

/// The next upstream request, or the completed product preparation result.
pub(crate) enum JavaLaunchAction {
    Build(Value),
    Classpath(Value),
    Complete(Value),
}

/// Preserves upstream failures; malformed successful replies have no upstream error.
pub(crate) enum JavaLaunchFailure {
    Upstream(LspRuntimeError),
    Invalid(&'static str),
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    Entrypoints,
    Build,
    Classpath,
}

/// One launch attempt. No project model or launch facts survive its completion.
pub(crate) struct JavaLaunchPreparation {
    source_path: String,
    source_file: String,
    configured_main_class: Option<String>,
    windows_paths: bool,
    phase: Phase,
    target: Value,
    build_failure: Option<Value>,
}

impl JavaLaunchPreparation {
    /// Validates the selected source against the same roots as JDT entry normalization.
    pub(crate) fn new(
        root_uri: &str,
        canonical_root: Option<&str>,
        source_file: String,
        configured_main_class: Option<String>,
    ) -> Result<Self, &'static str> {
        let root = workspace_root_path(root_uri).ok_or(TARGET_ERROR)?;
        let source_path = workspace_relative_path(&root, &source_file)
            .or_else(|| {
                canonical_root.and_then(|root| {
                    workspace_relative_path(
                        root.replace('\\', "/").trim_end_matches('/'),
                        &source_file,
                    )
                })
            })
            .ok_or(TARGET_ERROR)?;
        Ok(Self {
            windows_paths: is_windows_path(&root),
            source_path,
            source_file,
            configured_main_class: configured_main_class.filter(|value| !value.trim().is_empty()),
            phase: Phase::Entrypoints,
            target: Value::Null,
            build_failure: None,
        })
    }

    /// Advances only on a terminal upstream answer. Cancellation and unknown outcomes
    /// never become a successful preparation, including after a failed build.
    pub(crate) fn advance(
        &mut self,
        result: Option<Value>,
        error: Option<LspRuntimeError>,
    ) -> Result<JavaLaunchAction, JavaLaunchFailure> {
        if let Some(error) = error {
            if self.phase == Phase::Build
                && matches!(
                    error.code.as_str(),
                    "javaBuildCompilationErrors" | "javaBuildFailed"
                )
            {
                self.build_failure = Some(json!({
                    "code": error.code,
                    "message": error.message,
                    "report": error.java_build_report,
                }));
            } else {
                return Err(JavaLaunchFailure::Upstream(error));
            }
        }
        let result = result.unwrap_or(Value::Null);
        match self.phase {
            Phase::Entrypoints => {
                let entries = result["entries"]
                    .as_array()
                    .ok_or(JavaLaunchFailure::Invalid(TARGET_ERROR))?;
                let exact: Vec<_> = entries
                    .iter()
                    .filter(|entry| {
                        entry["sourcePath"].as_str().is_some_and(|path| {
                            if self.windows_paths {
                                path.eq_ignore_ascii_case(&self.source_path)
                            } else {
                                path == self.source_path
                            }
                        })
                    })
                    .collect();
                let selected = if exact.len() == 1 {
                    exact.first().copied()
                } else {
                    let matches: Vec<_> = exact
                        .into_iter()
                        .filter(|entry| {
                            let Some(configured) = self.configured_main_class.as_deref() else {
                                return false;
                            };
                            entry["mainClass"].as_str().is_some_and(|main| {
                                main == configured || main.rsplit('/').next() == Some(configured)
                            })
                        })
                        .collect();
                    (matches.len() == 1).then(|| matches[0])
                }
                .ok_or(JavaLaunchFailure::Invalid(TARGET_ERROR))?;
                self.target = json!({"mainClass": selected["mainClass"]});
                if let Some(project) = selected.get("projectName") {
                    self.target["projectName"] = project.clone();
                }
                let mut build = json!({
                    "mainClass": self.target["mainClass"],
                    "filePath": self.source_file,
                    "isFullBuild": false,
                });
                if let Some(project) = self.target.get("projectName") {
                    build["projectName"] = project.clone();
                }
                self.phase = Phase::Build;
                Ok(JavaLaunchAction::Build(json!({
                    "command": "vscode.java.buildWorkspace",
                    "arguments": [build.to_string()],
                })))
            }
            Phase::Build => {
                if self.build_failure.is_none()
                    && result["value"] != json!(1)
                    && result["value"] != json!("1")
                {
                    return Err(JavaLaunchFailure::Invalid(
                        "The Java language service returned an unexpected project build status.",
                    ));
                }
                self.phase = Phase::Classpath;
                // Omitting scope lets Java Debug Server include test/custom roots
                // for the selected main; never infer paths from source folder names.
                Ok(JavaLaunchAction::Classpath(json!({
                    "command": "vscode.java.resolveClasspath",
                    "arguments": [self.target["mainClass"], self.target["projectName"].as_str().unwrap_or("")],
                })))
            }
            Phase::Classpath => {
                let groups = result["value"]
                    .as_array()
                    .filter(|groups| groups.len() == 2)
                    .ok_or(JavaLaunchFailure::Invalid(
                        "The Java language service returned an invalid runtime classpath.",
                    ))?;
                let paths = |group: &Value| -> Option<Vec<String>> {
                    group
                        .as_array()?
                        .iter()
                        .map(|value| {
                            value
                                .as_str()
                                .filter(|value| !value.trim().is_empty())
                                .map(str::to_owned)
                        })
                        .collect()
                };
                let module_paths = paths(&groups[0]);
                let class_paths = paths(&groups[1]);
                let (Some(module_paths), Some(class_paths)) = (module_paths, class_paths) else {
                    return Err(JavaLaunchFailure::Invalid(
                        "The Java language service returned an invalid runtime classpath.",
                    ));
                };
                if module_paths.is_empty() && class_paths.is_empty() {
                    return Err(JavaLaunchFailure::Invalid(
                        "The Java language service returned no runtime paths.",
                    ));
                }
                self.target["modulePaths"] = json!(module_paths);
                self.target["classPaths"] = json!(class_paths);
                Ok(JavaLaunchAction::Complete(
                    match self.build_failure.take() {
                        Some(failure) => {
                            json!({"kind": "buildFailed", "target": self.target, "failure": failure})
                        }
                        None => json!({"kind": "ready", "target": self.target}),
                    },
                ))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lsp::languages::java_entrypoints::normalize_java_entrypoints;

    #[test]
    fn shared_launch_fixtures_preserve_source_identity_and_upstream_paths() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../../shared/fixtures/lsp/java-launch-preparation-v1.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let root = case["rootUri"].as_str().unwrap();
            let mut preparation = JavaLaunchPreparation::new(
                root,
                None,
                case["sourcePath"].as_str().unwrap().into(),
                Some(case["mainClass"].as_str().unwrap().into()),
            )
            .unwrap();
            let entries = normalize_java_entrypoints(root, None, &case["entries"]).unwrap();
            assert!(
                matches!(
                    preparation.advance(Some(serde_json::to_value(entries).unwrap()), None),
                    Ok(JavaLaunchAction::Build(_))
                ),
                "{}",
                case["id"]
            );
            assert!(matches!(
                preparation.advance(Some(json!({"value": 1})), None),
                Ok(JavaLaunchAction::Classpath(_))
            ));
            let Ok(JavaLaunchAction::Complete(result)) =
                preparation.advance(Some(json!({"value": case["paths"]})), None)
            else {
                panic!("fixture did not prepare: {}", case["id"]);
            };
            assert_eq!(result, json!({"kind": "ready", "target": case["target"]}));
        }
    }

    #[test]
    fn selection_never_borrows_another_file_or_guesses_an_ambiguous_module() {
        for entries in [
            json!([{ "sourcePath": "other/Main.java", "mainClass": "demo.Main" }]),
            json!([
                { "sourcePath": "app/Main.java", "mainClass": "one/demo.Main" },
                { "sourcePath": "app/Main.java", "mainClass": "two/demo.Main" }
            ]),
        ] {
            let mut preparation = JavaLaunchPreparation::new(
                "file:///workspace",
                None,
                "/workspace/app/Main.java".into(),
                Some("demo.Main".into()),
            )
            .unwrap();
            assert!(matches!(
                preparation.advance(Some(json!({"entries": entries})), None),
                Err(JavaLaunchFailure::Invalid(TARGET_ERROR))
            ));
        }
        assert!(JavaLaunchPreparation::new(
            "file:///workspace",
            None,
            "/workspace-other/Main.java".into(),
            None
        )
        .is_err());
    }
}
