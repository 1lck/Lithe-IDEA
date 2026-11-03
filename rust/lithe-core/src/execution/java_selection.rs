//! Selects an automatic project JDK from platform-probed candidates.
//! Project requirements remain owned by the existing run-configuration document.

use super::configuration::{
    java_feature_version_parts, read_requirements, version_parts, version_satisfies,
    ToolchainRequirementsDocument,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// A probed candidate; `id` is opaque and is never persisted or opened by Core.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaSelectionCandidate {
    /// Opaque machine-local identity supplied by the host.
    pub id: String,
    /// Version reported by the Java executable; empty means unknown.
    pub version: String,
    /// Lower values win: JAVA_HOME, PATH, installations, project-managed JDK.
    pub priority: u32,
}

/// Platform candidates and the workspace whose existing requirements apply.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaSelectionRequest {
    /// Open workspace; absent means no project requirements.
    pub root: Option<PathBuf>,
    /// Host-read snapshot for UI-safe selection; mutually exclusive with `root`.
    /// The same document validation and selection policy apply to both sources.
    pub requirements: Option<ToolchainRequirementsDocument>,
    /// Usable executable homes probed by the platform.
    pub candidates: Vec<JavaSelectionCandidate>,
    /// The platform's unconstrained choice; used when requirements are absent
    /// or no candidate satisfies them. This keeps fallback behavior explicit.
    pub fallback_id: Option<String>,
}

/// Selected candidate and an actionable warning when no compatible JDK exists.
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaSelection {
    /// Selected identity, or absent when the host found no usable JDK.
    pub id: Option<String>,
    /// No candidate satisfies the minimum; the fallback remains usable.
    pub warning: Option<String>,
}

/// Orders equivalent sources numerically, including legacy Java `1.8` versions.
/// Stable IDs break equal-version ties independently of filesystem enumeration.
pub fn compare_java_candidates(
    left: &JavaSelectionCandidate,
    right: &JavaSelectionCandidate,
) -> std::cmp::Ordering {
    left.priority
        .cmp(&right.priority)
        .then_with(|| {
            java_feature_version_parts(version_parts(&right.version))
                .cmp(&java_feature_version_parts(version_parts(&left.version)))
        })
        .then_with(|| left.id.cmp(&right.id))
}

/// Reuses Core's requirement reader and version semantics without generating
/// requirements, probing executables, or changing an explicit user selection.
pub fn select_java(request: JavaSelectionRequest) -> Result<JavaSelection, CoreError> {
    if request.root.is_some() && request.requirements.is_some() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Java selection must use either a workspace or a requirements snapshot",
        ));
    }
    let document = request.requirements.or(request
        .root
        .as_deref()
        .map(read_requirements)
        .transpose()?
        .flatten());
    if let Some(document) = &document {
        super::configuration::validate_sidecar_version(document.version)?;
    }
    let minimum = document
        .as_ref()
        .and_then(|doc| doc.toolchains.get("project-jdk"))
        .filter(|requirement| requirement.kind == "java")
        .and_then(|requirement| requirement.minimum_version.as_deref());
    Ok(select_java_candidates(
        &request.candidates,
        request.fallback_id.as_deref(),
        minimum,
    ))
}

/// Java feature version (`8` for `1.8.0_402`, `21` for `21.0.4`); `None` when unknown.
fn java_feature(version: &str) -> Option<u32> {
    java_feature_version_parts(version_parts(version))
        .first()
        .copied()
}

/// Applies only the project's declared Java version; explicit paths and vendor
/// preferences remain the responsibility of existing launch validation and diagnostics.
///
/// A JDK of exactly the declared feature version wins over a newer one, even from a
/// higher-priority source such as `JAVA_HOME`: a Java 8 project must not run on the
/// JDK 21 a shell exports. Without one, the oldest newer JDK is the closest match.
/// Source priority only breaks ties within the same feature version.
///
/// The policy follows OpenIDEA's `pick_jdk` (`crates/ide-sdk/src/java.rs`,
/// <https://github.com/l0ng-ai/openidea>, Apache-2.0); see the repository `NOTICE`.
pub fn select_java_candidates(
    candidates: &[JavaSelectionCandidate],
    fallback_id: Option<&str>,
    minimum: Option<&str>,
) -> JavaSelection {
    let fallback = candidates
        .iter()
        .find(|candidate| Some(candidate.id.as_str()) == fallback_id)
        .or_else(|| {
            candidates
                .iter()
                .min_by(|a, b| compare_java_candidates(a, b))
        });
    let Some(minimum) = minimum else {
        return JavaSelection {
            id: fallback.map(|candidate| candidate.id.clone()),
            warning: None,
        };
    };
    let required = java_feature(minimum);
    let distance = |candidate: &JavaSelectionCandidate| {
        java_feature(&candidate.version)
            .zip(required)
            .map(|(feature, required)| feature.saturating_sub(required))
    };
    let matching = candidates
        .iter()
        .filter(|candidate| version_satisfies("java", &candidate.version, minimum, true))
        .min_by(|a, b| {
            distance(a)
                .cmp(&distance(b))
                .then_with(|| compare_java_candidates(a, b))
        });
    JavaSelection {
        id: matching.or(fallback).map(|candidate| candidate.id.clone()),
        warning: matching.is_none().then(|| format!("No installed JDK satisfies Java {minimum} or newer. Install a compatible JDK or choose one in project settings.")),
    }
}
