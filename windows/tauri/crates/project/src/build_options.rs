//! Read-only team Build document access. Core owns storage syntax and option
//! semantics; discovery never creates defaults or rewrites malformed data.
use serde_json::{Value, json};
use std::{fs, io::Read, path::Path};

pub fn read_build_options(workspace: &Path) -> Result<Value, String> {
    let root = workspace
        .canonicalize()
        .map_err(|_| "Build workspace is unavailable")?;
    let path = root.join(".lithe/build/options.json");
    let document = match fs::symlink_metadata(&path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            json!({"version":1,"systems":{}})
        }
        Err(_) => return Err("Build options could not be read".into()),
        Ok(_) => {
            let resolved = path
                .canonicalize()
                .map_err(|_| "Build options could not be resolved")?;
            if !resolved.starts_with(&root) {
                return Err("Build options leave the workspace".into());
            }
            // Reject directories/devices before opening: a pipe is not a
            // document and opening it can wait indefinitely for a writer.
            let metadata =
                fs::metadata(&resolved).map_err(|_| "Build options could not be read")?;
            if !metadata.is_file() || metadata.len() > 2 * 1024 * 1024 {
                return Err("Build options are oversized or not a file".into());
            }
            let mut file =
                fs::File::open(&resolved).map_err(|_| "Build options could not be read")?;
            let metadata = file
                .metadata()
                .map_err(|_| "Build options could not be read")?;
            if !metadata.is_file() || metadata.len() > 2 * 1024 * 1024 {
                return Err("Build options are oversized or not a file".into());
            }
            let mut bytes = Vec::new();
            (&mut file)
                .take(2 * 1024 * 1024 + 1)
                .read_to_end(&mut bytes)
                .map_err(|_| "Build options could not be read")?;
            if bytes.len() > 2 * 1024 * 1024 {
                return Err("Build options are oversized".into());
            }
            let text = std::str::from_utf8(&bytes).map_err(|_| "Build options are not UTF-8")?;
            serde_json::from_str(text.trim_start_matches('\u{feff}'))
                .map_err(|_| "Build options are not valid JSON")?
        }
    };
    let response: Value = serde_json::from_str(&lithe_core::execute_json(
        &json!({"command":"build.projectOptions","payload":{"document":document}}).to_string(),
    ))
    .map_err(|_| "Build options validation failed")?;
    if response["ok"] != true || response["data"]["status"] != "ok" {
        return Err(
            "The saved build options are invalid. The original configuration has been kept.".into(),
        );
    }
    Ok(response["data"]["document"].clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQUENCE: AtomicU64 = AtomicU64::new(0);
    struct Fixture(std::path::PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "lithe-build-options-{}-{}",
                std::process::id(),
                SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path.canonicalize().unwrap())
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn missing_team_options_do_not_create_a_document() {
        let f = Fixture::new();
        assert_eq!(
            read_build_options(&f.0).unwrap(),
            json!({"version":1,"systems":{}})
        );
        assert!(!f.0.join(".lithe").exists());
    }
    #[test]
    fn source_backed_options_preserve_per_root_empty_selections_and_shared_bytes() {
        let f = Fixture::new();
        let path = f.0.join(".lithe/build/options.json");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let bytes = include_bytes!(
            "../../../../../shared/fixtures/build-project-options/shared-defaults.json"
        );
        fs::write(&path, bytes).unwrap();
        let doc = read_build_options(&f.0).unwrap();
        assert_eq!(
            doc["systems"]["maven"]["instanceDefaults"]["profiles"],
            json!(["ci"])
        );
        assert_eq!(
            doc["systems"]["maven"]["instances"]["services/a"]["offline"],
            true
        );
        assert_eq!(fs::read(&path).unwrap(), bytes);
    }
    #[test]
    fn malformed_or_oversized_team_options_are_not_treated_as_defaults() {
        let f = Fixture::new();
        let path = f.0.join(".lithe/build/options.json");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        for text in [
            "broken".to_string(),
            "null".to_string(),
            "{\"version\":2,\"systems\":{}}".to_string(),
            "x".repeat(2 * 1024 * 1024 + 1),
        ] {
            fs::write(&path, &text).unwrap();
            assert!(read_build_options(&f.0).is_err());
            assert_eq!(fs::read_to_string(&path).unwrap(), text);
        }
        fs::remove_file(&path).unwrap();
        fs::create_dir(&path).unwrap();
        assert!(read_build_options(&f.0).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn a_team_options_link_cannot_read_outside_its_workspace() {
        let workspace = Fixture::new();
        let outside = Fixture::new();
        let source = outside.0.join("options.json");
        fs::write(&source, "{\"version\":1,\"systems\":{}}").unwrap();
        let target = workspace.0.join(".lithe/build/options.json");
        fs::create_dir_all(target.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(&source, &target).unwrap();
        assert!(read_build_options(&workspace.0).is_err());
        assert_eq!(
            fs::read_to_string(&source).unwrap(),
            "{\"version\":1,\"systems\":{}}"
        );
    }
}
