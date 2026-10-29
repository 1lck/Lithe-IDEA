//! Read-only generator metadata, including disabled accepted packages. Trust
//! and installation-record validation stay in the existing details reader.
use super::{core, Error, Result};
use crate::plugin_host::{self, lifecycle::LifecycleState, PluginHostState, ScannedPackage};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use tauri::{AppHandle, Manager};

fn identity(root: &std::path::Path, source: &str, version: &str, digest: &str) -> String {
    format!(
        "{:x}",
        Sha256::digest(
            json!({"root":root,"source":source,
        "version":version,"digest":digest})
            .to_string()
            .as_bytes()
        )
    )
}

/// Caller owns a NativeLease. Reading disabled metadata grants no execution
/// permission; plan/runtime entry points retain their enabled-package check.
pub(super) fn read(app: &AppHandle, plugin_id: &str) -> Result<(ScannedPackage, String)> {
    if app.state::<LifecycleState>().blocked(plugin_id) {
        return Err(Error::new("generator.inactive"));
    }
    let mut package = app
        .state::<PluginHostState>()
        .packages()
        .into_iter()
        .find(|package| package.entry.plugin_id == plugin_id && package.entry.status == "accepted")
        .ok_or_else(|| Error::new("generator.inactive"))?;
    let details = plugin_host::details::build_details(
        &package,
        &plugin_host::store::install_root(app).map_err(|_| Error::new("generator.untrusted"))?,
        &plugin_host::store::bundled_root(app).map_err(|_| Error::new("generator.untrusted"))?,
    )
    .map_err(|_| Error::new("generator.untrusted"))?;
    let live: Value = serde_json::from_slice(
        &std::fs::read(package.root.join("plugin.json")).map_err(Error::io)?,
    )
    .map_err(|_| Error::new("generator.stale"))?;
    if live != package.manifest {
        return Err(Error::new("generator.stale"));
    }
    package.entry.enabled = details.enabled;
    let digest = plugin_host::signature::content_digest(&package.root)
        .map_err(|_| Error::new("generator.untrusted"))?;
    let identity = identity(
        &package.root,
        package.entry.source,
        &package.entry.version,
        &digest,
    );
    Ok((package, identity))
}

pub(super) fn load(app: &AppHandle) -> Result<Value> {
    load_required(app, &HashSet::new())
}

fn load_required(app: &AppHandle, required: &HashSet<String>) -> Result<Value> {
    load_packages(
        app.state::<PluginHostState>().packages(),
        required,
        plugin_host::host_capabilities(),
        |plugin_id| {
            let lease = app
                .state::<LifecycleState>()
                .acquire(plugin_id)
                .map_err(|_| Error::new("generator.inactive"))?;
            let (package, identity) = read(app, plugin_id)?;
            Ok((package, identity, lease))
        },
    )
}

fn load_packages<Lease>(
    packages: Vec<ScannedPackage>,
    required: &HashSet<String>,
    capabilities: Value,
    mut read: impl FnMut(&str) -> Result<(ScannedPackage, String, Lease)>,
) -> Result<Value> {
    let mut plugins = Vec::new();
    let mut identities = std::collections::HashMap::new();
    let mut leases = Vec::new();
    let mut issues = Vec::new();
    for package in packages
        .into_iter()
        .filter(|package| package.entry.status == "accepted")
    {
        let (package, identity, lease) = match read(&package.entry.plugin_id) {
            Ok(package) => package,
            Err(error) if required.contains(&package.entry.plugin_id) => return Err(error),
            // One retained mutation or unreadable unrelated package must not
            // prevent another generator from being inspected or reviewed.
            Err(error) => {
                issues.push(json!({"pluginID":package.entry.plugin_id,
                    "error":{"code":error.code}}));
                continue;
            }
        };
        leases.push(lease);
        plugins.push(json!({"manifest":package.manifest,"enabled":package.entry.enabled}));
        identities.insert(
            package.entry.plugin_id,
            (identity, package.entry.source == "installed"),
        );
    }
    if required
        .iter()
        .any(|plugin_id| !identities.contains_key(plugin_id))
    {
        return Err(Error::new("generator.inactive"));
    }
    let mut catalog = core(
        "project.generatorCatalog",
        json!({"plugins":plugins,"hostCapabilities":capabilities}),
        "catalog",
    )?;
    if let Some(rejections) = catalog["issues"].as_array_mut() {
        rejections.extend(issues);
    }
    for entry in catalog["generators"].as_array_mut().into_iter().flatten() {
        let (identity, can_enable) = identities
            .get(entry["pluginID"].as_str().unwrap_or_default())
            .ok_or_else(|| Error::new("generator.stale"))?;
        entry["packageIdentity"] = json!(identity);
        entry["canEnable"] = json!(can_enable);
        for requirement in entry["requirements"].as_array_mut().into_iter().flatten() {
            for provider in requirement["providers"]
                .as_array_mut()
                .into_iter()
                .flatten()
            {
                let (identity, can_enable) = identities
                    .get(provider["pluginID"].as_str().unwrap_or_default())
                    .ok_or_else(|| Error::new("generator.stale"))?;
                provider["packageIdentity"] = json!(identity);
                provider["canEnable"] = json!(can_enable);
            }
        }
    }
    Ok(catalog)
}

/// Advisory requirements are re-read before both review and execution. A
/// changed provider snapshot requires fresh review, never auto-enablement.
pub(super) fn requirements(
    app: &AppHandle,
    request: &super::Request,
    package: &ScannedPackage,
) -> Result<Value> {
    let form = core(
        "project.generatorForm",
        json!({"manifest":package.manifest,
        "generatorID":request.generator_id,"form":request.form}),
        "form",
    )?;
    // Requirements are advisory, including multiple interchangeable providers.
    // Only the generator owner is mandatory. Core projects the live readable
    // providers; a disappearance changes the review snapshot below, without
    // preventing a new review merely because one alternative is unavailable.
    let catalog = load_required(app, &HashSet::from([request.plugin_id.clone()]))?;
    let entry = catalog["generators"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|entry| {
            entry["pluginID"] == request.plugin_id
                && entry["generator"]["id"] == request.generator_id
        })
        .ok_or_else(|| Error::new("generator.inactive"))?;
    Ok(json!(form["activeRequirements"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|index| { entry["requirements"].get(index.as_u64()? as usize).cloned() })
        .collect::<Vec<_>>()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn package(id: &str) -> ScannedPackage {
        let mut manifest: Value = serde_json::from_str(include_str!(
            "../../../../../../shared/contracts/plugins/v1/fixtures/project-generator.plugin.json"
        ))
        .unwrap();
        manifest["id"] = json!(id);
        ScannedPackage {
            entry: plugin_host::CatalogEntry {
                plugin_id: id.into(),
                display_name: id.into(),
                version: "1.0.0".into(),
                api_version: 3,
                source: "installed",
                enabled: true,
                status: "accepted",
                languages: Vec::new(),
                declared_settings: Vec::new(),
                declares_tests: false,
                primary_language_id: None,
                rejection: None,
            },
            root: std::path::PathBuf::from("fixture-package"),
            manifest,
            trust: None,
        }
    }

    #[test]
    fn unreadable_unrelated_packages_do_not_disable_another_generator() {
        for code in ["generator.inactive", "generator.untrusted"] {
            let target = package("fixture.generator");
            let unrelated = package("fixture.other");
            let catalog = load_packages(
                vec![target.clone(), unrelated],
                &HashSet::from([target.entry.plugin_id.clone()]),
                json!({"projectGenerators":[1]}),
                |id| {
                    if id == target.entry.plugin_id {
                        Ok((target.clone(), "target-digest".into(), ()))
                    } else {
                        Err(Error::new(code))
                    }
                },
            )
            .unwrap();
            assert!(!catalog["generators"].as_array().unwrap().is_empty());
            assert!(catalog["generators"]
                .as_array()
                .unwrap()
                .iter()
                .all(|entry| entry["pluginID"] == "fixture.generator"));
            assert_eq!(catalog["issues"][0]["error"]["code"], code);
        }
    }

    #[test]
    fn unreadable_or_missing_generator_owner_remains_fail_closed() {
        let target = package("fixture.generator");
        for packages in [vec![target.clone()], Vec::new()] {
            let result = load_packages::<()>(
                packages,
                &HashSet::from([target.entry.plugin_id.clone()]),
                json!({"projectGenerators":[1]}),
                |_| Err(Error::new("generator.inactive")),
            );
            assert_eq!(result.unwrap_err().code, "generator.inactive");
        }
    }

    #[test]
    fn unavailable_advisory_alternatives_change_the_snapshot_without_blocking_a_new_review() {
        let target = package("fixture.generator");
        let mut provider = package("fixture.java");
        provider.manifest = serde_json::from_str(include_str!(
            "../../../../../../shared/contracts/plugins/v1/fixtures/node-runtime.plugin.json"
        ))
        .unwrap();
        provider.manifest["id"] = json!(provider.entry.plugin_id);
        provider.manifest["languages"][0]["id"] = json!("java");
        provider.manifest["languageServers"][0]["languageID"] = json!("java");
        provider.manifest["activationEvents"] = json!(["onLanguage:java"]);
        let mut alternative = provider.clone();
        alternative.entry.plugin_id = "fixture.other-java".into();
        alternative.entry.enabled = false;
        alternative.manifest["id"] = json!(alternative.entry.plugin_id);
        let packages = vec![target.clone(), provider.clone(), alternative.clone()];
        let snapshot = |unavailable: &[&str]| {
            let catalog = load_packages(
                packages.clone(),
                &HashSet::from([target.entry.plugin_id.clone()]),
                json!({"projectGenerators":[1]}),
                |id| {
                    if unavailable.contains(&id) {
                        Err(Error::new("generator.inactive"))
                    } else {
                        let package = packages
                            .iter()
                            .find(|package| package.entry.plugin_id == id)
                            .unwrap()
                            .clone();
                        Ok((package, format!("digest-{id}"), ()))
                    }
                },
            )
            .unwrap();
            catalog["generators"]
                .as_array()
                .unwrap()
                .iter()
                .find(|entry| {
                    entry["pluginID"] == target.entry.plugin_id && entry["generator"]["id"] == "app"
                })
                .unwrap()["requirements"][0]
                .clone()
        };
        let before = snapshot(&[]);
        let healthy = snapshot(&["fixture.other-java"]);
        assert_eq!(before["providers"].as_array().unwrap().len(), 2);
        assert_eq!(healthy["providers"].as_array().unwrap().len(), 1);
        assert_eq!(healthy["providers"][0]["pluginID"], "fixture.java");
        assert_ne!(before, healthy);
        let missing = snapshot(&["fixture.java", "fixture.other-java"]);
        assert!(missing["providers"].as_array().unwrap().is_empty());
        assert_ne!(healthy, missing);
    }
    #[test]
    fn same_version_replacement_changes_full_package_identity() {
        let root = std::path::Path::new("fixture-package");
        let first = identity(root, "installed", "1.0.0", "first-digest");
        assert_eq!(identity(root, "installed", "1.0.0", "first-digest"), first);
        assert_ne!(
            identity(root, "installed", "1.0.0", "replacement-digest"),
            first
        );
    }
}
