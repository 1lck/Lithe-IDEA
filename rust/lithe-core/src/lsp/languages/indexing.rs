//! Provider-owned native scan settings. These are not build-system exclusions.
use serde_json::{json, Value};

/// Overlay the current policy without mutating the user's stored configuration.
/// Removing exclusions therefore restores the original settings exactly.
pub(crate) fn configuration(provider: &str, root_uri: &str, base: Option<&Value>) -> Option<Value> {
    if !matches!(provider, "rust" | "go") {
        return base.cloned();
    }
    let Some(root) = url::Url::parse(root_uri)
        .ok()
        .and_then(|uri| uri.to_file_path().ok())
    else {
        return base.cloned();
    };
    let root = root.canonicalize().unwrap_or(root);
    if crate::project::indexing::context(&root).is_none() {
        return base.cloned();
    }
    Some(with_roots(
        provider,
        base,
        &crate::project::indexing::excluded_roots(&root),
    ))
}

fn with_roots(provider: &str, base: Option<&Value>, roots: &[String]) -> Value {
    let mut configuration = base.cloned().unwrap_or_else(|| json!({}));
    match provider {
        // rust-analyzer.files.exclude takes literal workspace-relative paths, not globs.
        // https://rust-analyzer.github.io/book/configuration#rust-analyzerfilesexclude
        "rust" => append_array(
            &mut configuration,
            &["rust-analyzer", "files", "exclude"],
            roots.to_vec(),
            &[],
        ),
        // https://go.dev/gopls/settings#directoryFilters: ordered filters, last match wins.
        // Preserve its documented default when the user did not configure this array.
        "go" => append_array(
            &mut configuration,
            &["gopls", "directoryFilters"],
            roots
                .iter()
                .filter(|path| !path.contains(['*', '?', '[', ']', '{', '}']))
                .map(|path| {
                    if path == "." {
                        "-".into()
                    } else {
                        format!("-{path}")
                    }
                })
                .collect(),
            &["-**/node_modules"],
        ),
        _ => {}
    }
    configuration
}

/// Normalize owned dotted prefixes, so a request for the provider section sees them too.
fn append_array(value: &mut Value, path: &[&str], additions: Vec<String>, defaults: &[&str]) {
    for length in 2..=path.len() {
        let dotted = path[..length].join(".");
        let previous = value
            .as_object_mut()
            .and_then(|object| object.remove(&dotted));
        if let Some(previous) = previous {
            if let Some(slot) = nested_slot(value, &path[..length]) {
                merge_dotted_configuration(slot, previous);
            }
        }
    }
    let Some(slot) = nested_slot(value, path) else {
        return;
    };
    if slot.is_null() {
        *slot = json!(defaults);
    }
    if let Some(array) = slot.as_array_mut() {
        for addition in additions {
            let value = Value::String(addition);
            // Go filters are ordered: an existing exclusion before a later inclusion
            // must move to the end rather than being treated as a harmless duplicate.
            array.retain(|item| item != &value);
            array.push(value);
        }
    }
}

// Dotted prefixes override conflicting leaves, with the longest prefix applied
// last. Unrelated nested provider settings must survive normalization.
fn merge_dotted_configuration(target: &mut Value, overlay: Value) {
    match (target, overlay) {
        (Value::Object(target), Value::Object(overlay)) => {
            for (key, value) in overlay {
                merge_dotted_configuration(target.entry(key).or_insert(Value::Null), value);
            }
        }
        (target, overlay) => *target = overlay,
    }
}

fn nested_slot<'a>(value: &'a mut Value, path: &[&str]) -> Option<&'a mut Value> {
    let object = value.as_object_mut()?;
    let child = object.entry(path[0]).or_insert(Value::Null);
    if path.len() == 1 {
        return Some(child);
    }
    if child.is_null() {
        *child = json!({});
    }
    nested_slot(child, &path[1..])
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dotted_native_settings_preserve_nested_siblings_and_override_only_conflicting_leaves() {
        let base = json!({
            "rust-analyzer":{"files":{"watcher":"client","exclude":["nested"]},"cargo":{"allFeatures":true}},
            "rust-analyzer.files":{"exclude":["prefix"],"otherSetting":true},
            "rust-analyzer.files.exclude":["leaf"]
        });
        let original = base.clone();
        let configured = with_roots("rust", Some(&base), &["vendor".into()]);
        assert_eq!(
            configured["rust-analyzer"]["files"],
            json!({
                "watcher":"client","exclude":["leaf","vendor"],"otherSetting":true
            })
        );
        assert_eq!(
            configured["rust-analyzer"]["cargo"],
            base["rust-analyzer"]["cargo"]
        );
        assert_eq!(
            base, original,
            "normalization must not mutate stored settings"
        );
    }
    #[test]
    fn native_exclusions_preserve_settings_and_restore_them_on_undo() {
        let base = json!({"rust-analyzer":{"files":{"exclude":["existing"]},"cargo":{"allFeatures":true}}});
        let excluded = with_roots("rust", Some(&base), &["vendor".into(), "带 空格".into()]);
        assert_eq!(
            excluded["rust-analyzer"]["files"]["exclude"],
            json!(["existing", "vendor", "带 空格"])
        );
        assert_eq!(
            excluded["rust-analyzer"]["cargo"],
            base["rust-analyzer"]["cargo"]
        );
        assert_eq!(with_roots("rust", Some(&base), &[]), base);
        let go = json!({"gopls.directoryFilters":["+vendor","-cache"]});
        assert_eq!(
            with_roots("go", Some(&go), &["vendor".into()])["gopls"]["directoryFilters"],
            json!(["+vendor", "-cache", "-vendor"])
        );
        assert_eq!(
            with_roots(
                "go",
                Some(&json!({"gopls":{"directoryFilters":["-vendor","+vendor"]}})),
                &["vendor".into()]
            )["gopls"]["directoryFilters"],
            json!(["+vendor", "-vendor"])
        );
        assert_eq!(
            with_roots("go", None, &["vendor".into()])["gopls"]["directoryFilters"],
            json!(["-**/node_modules", "-vendor"])
        );
    }
    #[test]
    fn native_patterns_do_not_accidentally_exclude_literal_metacharacter_siblings() {
        assert_eq!(
            with_roots("go", None, &["literal*".into()])["gopls"]["directoryFilters"],
            json!(["-**/node_modules"])
        );
        assert_eq!(
            with_roots("rust", None, &["literal*".into()])["rust-analyzer"]["files"]["exclude"],
            json!(["literal*"])
        );
    }
}
