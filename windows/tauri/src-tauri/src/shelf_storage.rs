//! Windows-owned durable shelf storage; Git patch semantics remain in Core.

use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Read, Write},
    path::Path,
};
use tauri::Manager;

const MAX_ENTRY_BYTES: u64 = 128 * 1024 * 1024;

fn validate_id(id: &str) -> Result<(), String> {
    if id.len() != 36
        || !id
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() || byte == b'-')
    {
        return Err("Invalid shelf identity".into());
    }
    Ok(())
}

fn validate_entry(entry: &Value) -> Result<(), String> {
    if entry["version"] != 1
        || !entry["message"].is_string()
        || !entry["createdAt"].is_u64()
        || !entry["stagedPatch"].is_string()
        || !entry["workingPatch"].is_string()
        || !entry["paths"]
            .as_array()
            .is_some_and(|paths| paths.iter().all(Value::is_string))
    {
        return Err("Invalid shelf data; the saved file was retained".into());
    }
    validate_id(entry["id"].as_str().ok_or("Missing shelf identity")?)
}

fn storage_operation(
    directory: &Path,
    operation: &str,
    entry: Option<Value>,
    id: Option<String>,
) -> Result<Value, String> {
    fs::create_dir_all(directory).map_err(|error| error.to_string())?;
    match operation {
        "list" => {
            let mut entries = Vec::new();
            for item in fs::read_dir(directory).map_err(|error| error.to_string())? {
                let path = item.map_err(|error| error.to_string())?.path();
                if path.extension().and_then(|value| value.to_str()) != Some("json") {
                    continue;
                }
                let mut bytes = Vec::new();
                fs::File::open(&path)
                    .map_err(|error| error.to_string())?
                    .take(MAX_ENTRY_BYTES + 1)
                    .read_to_end(&mut bytes)
                    .map_err(|error| error.to_string())?;
                if bytes.len() as u64 > MAX_ENTRY_BYTES {
                    return Err("Saved shelf exceeds the storage limit".into());
                }
                let value: Value = serde_json::from_slice(&bytes)
                    .map_err(|error| format!("Could not read shelf: {error}"))?;
                validate_entry(&value)?;
                if path.file_stem().and_then(|value| value.to_str()) != value["id"].as_str() {
                    return Err("Shelf identity does not match its file".into());
                }
                entries.push(value);
            }
            entries.sort_by(|left, right| {
                right["createdAt"]
                    .as_u64()
                    .cmp(&left["createdAt"].as_u64())
                    .then_with(|| left["id"].as_str().cmp(&right["id"].as_str()))
            });
            Ok(json!(entries))
        }
        "save" => {
            let entry = entry.ok_or("Missing shelf data")?;
            validate_entry(&entry)?;
            let path = directory.join(format!("{}.json", entry["id"].as_str().unwrap()));
            if path.exists() {
                return Err("Shelf already exists".into());
            }
            let contents = serde_json::to_string(&entry).map_err(|error| error.to_string())?;
            if contents.len() as u64 > MAX_ENTRY_BYTES {
                return Err("Shelf exceeds the storage limit".into());
            }
            // Publish flushed bytes without replacing another recovery record.
            let temporary = directory.join(format!(
                "{}.{}.tmp",
                entry["id"].as_str().unwrap(),
                std::process::id()
            ));
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary)
                .map_err(|error| error.to_string())?;
            let result = (|| {
                file.write_all(contents.as_bytes())?;
                file.sync_all()?;
                drop(file);
                crate::file_publication::publish_new_record(&temporary, &path)
            })();
            let cleanup = fs::remove_file(&temporary);
            result.map_err(|error: std::io::Error| error.to_string())?;
            if let Err(error) = cleanup {
                if error.kind() != std::io::ErrorKind::NotFound {
                    return Err(error.to_string());
                }
            }
            Ok(Value::Null)
        }
        "delete" => {
            let id = id.ok_or("Missing shelf identity")?;
            validate_id(&id)?;
            fs::remove_file(directory.join(format!("{id}.json")))
                .map_err(|error| error.to_string())?;
            Ok(Value::Null)
        }
        _ => Err("Unsupported shelf storage operation".into()),
    }
}

fn repository_identity(root: &Path) -> String {
    let path = root.to_string_lossy();
    let normalized = path.replace('\\', "/");
    let unc = normalized
        .strip_prefix("//?/UNC/")
        .or_else(|| normalized.strip_prefix("//"));
    let is_wsl = unc
        .and_then(|value| value.split('/').next())
        .is_some_and(|server| {
            server.eq_ignore_ascii_case("wsl$") || server.eq_ignore_ascii_case("wsl.localhost")
        });
    let mut digest = Sha256::new();
    if is_wsl {
        // Legacy WSL buckets lost case information; keep them intact and separate.
        digest.update(b"wsl-case-sensitive-v1\0");
        digest.update(path.as_bytes());
    } else {
        // Preserve existing storage keys for ordinary canonical Windows paths.
        digest.update(path.to_lowercase().as_bytes());
    }
    format!("{:x}", digest.finalize())
}

#[tauri::command]
pub async fn saved_changes_storage(
    app: tauri::AppHandle,
    root: String,
    operation: String,
    entry: Option<Value>,
    id: Option<String>,
) -> Result<Value, String> {
    let storage = app
        .path()
        .app_data_dir()
        .map_err(|error| error.to_string())?;
    tauri::async_runtime::spawn_blocking(move || {
        let root = fs::canonicalize(root).map_err(|error| error.to_string())?;
        let identity = repository_identity(&root);
        storage_operation(
            &storage.join("git-shelves").join(identity),
            &operation,
            entry,
            id,
        )
    })
    .await
    .map_err(|error| error.to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        path::PathBuf,
        sync::atomic::{AtomicU64, Ordering},
    };
    static SEQUENCE: AtomicU64 = AtomicU64::new(1);
    struct Storage(PathBuf);
    impl Storage {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "lithe-shelf-{}-{}",
                std::process::id(),
                SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Storage {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn entry() -> Value {
        json!({"version":1,"id":"00000000-0000-4000-8000-000000000001","message":"恢复记录","createdAt":123,"stagedPatch":"staged","workingPatch":"binary","paths":["目录/文件.txt"]})
    }
    #[test]
    fn shelves_persist_without_replacing_recovery_records() {
        let storage = Storage::new();
        let value = entry();
        storage_operation(&storage.0, "save", Some(value.clone()), None).unwrap();
        assert!(storage_operation(&storage.0, "save", Some(value.clone()), None).is_err());
        assert_eq!(
            storage_operation(&storage.0, "list", None, None).unwrap(),
            json!([value])
        );
        storage_operation(
            &storage.0,
            "delete",
            None,
            Some(entry()["id"].as_str().unwrap().into()),
        )
        .unwrap();
        assert_eq!(
            storage_operation(&storage.0, "list", None, None).unwrap(),
            json!([])
        );
    }
    #[test]
    fn malformed_shelf_is_retained_and_storage_is_isolated() {
        let storage = Storage::new();
        let left = storage.0.join("left");
        let right = storage.0.join("right");
        storage_operation(&left, "save", Some(entry()), None).unwrap();
        assert_eq!(
            storage_operation(&right, "list", None, None).unwrap(),
            json!([])
        );
        let damaged = left.join("damaged.json");
        fs::write(&damaged, b"broken").unwrap();
        assert!(storage_operation(&left, "list", None, None).is_err());
        assert_eq!(fs::read(damaged).unwrap(), b"broken");
        assert!(storage_operation(&left, "delete", None, Some("../outside".into())).is_err());
    }

    #[test]
    fn ordinary_windows_repository_keys_remain_compatible() {
        for root in [r"\\?\C:\Fixture\Repo", r"\\?\UNC\Server\Share\Repo"] {
            let expected = format!("{:x}", Sha256::digest(root.to_lowercase().as_bytes()));
            assert_eq!(repository_identity(Path::new(root)), expected);
            assert_eq!(
                repository_identity(Path::new(&root.to_lowercase())),
                expected
            );
        }
    }

    #[test]
    fn wsl_repository_case_isolated_without_adopting_ambiguous_legacy_shelves() {
        let storage = Storage::new();
        for root in [
            r"\\wsl.localhost\Ubuntu\home\fixture\Repo",
            r"\\wsl$\Ubuntu\home\fixture\Repo",
            r"\\?\UNC\wsl.localhost\Ubuntu\home\fixture\Repo",
            r"\\?\UNC\WSL$\Ubuntu\home\fixture\Repo",
        ] {
            let lower = root.replace("Repo", "repo");
            let left = storage.0.join(repository_identity(Path::new(root)));
            let right = storage.0.join(repository_identity(Path::new(&lower)));
            let legacy = storage.0.join(format!(
                "{:x}",
                Sha256::digest(root.to_lowercase().as_bytes())
            ));
            assert_ne!(left, right);
            assert_ne!(left, legacy);
            assert_ne!(right, legacy);
            storage_operation(&legacy, "save", Some(entry()), None).unwrap();
            assert_eq!(
                storage_operation(&left, "list", None, None).unwrap(),
                json!([])
            );
            assert_eq!(
                storage_operation(&right, "list", None, None).unwrap(),
                json!([])
            );
            storage_operation(&left, "save", Some(entry()), None).unwrap();
            let mut other = entry();
            other["message"] = json!("other repository");
            storage_operation(&right, "save", Some(other.clone()), None).unwrap();
            storage_operation(
                &left,
                "delete",
                None,
                Some(entry()["id"].as_str().unwrap().into()),
            )
            .unwrap();
            assert_eq!(
                storage_operation(&right, "list", None, None).unwrap(),
                json!([other])
            );
            assert_eq!(
                storage_operation(&legacy, "list", None, None).unwrap(),
                json!([entry()])
            );
        }
    }
}
