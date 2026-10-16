//! One-time Stable -> Dev snapshot, before any WebView or settings store opens.
//! Note: .agents/notes/implemented/process/2026-09-13-macos-update-signing-and-release-strategy.md
//! Only durable settings/Maven preferences and closed WebView localStorage are
//! copied. Downloads, caches, cookies, logs, indexes and process locks are rebuilt.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::path::Path;

const MARKER: &str = ".stable-profile-import-v1";
const STAGING: &str = ".stable-profile-import-v1-staging";
const LOCAL_STORAGE: &str = "EBWebView/Default/Local Storage/leveldb";

// Run on every document, before application modules hydrate Zustand. The native
// marker survives a crash before this script first runs; the local marker makes
// later explicit Dev channel choices survive subsequent windows and launches.
pub const IMPORT_BOOTSTRAP: &str = r#"
if (window.location.origin === 'http://tauri.localhost' || window.location.origin === 'tauri://localhost' || window.location.origin === 'http://127.0.0.1:1420') {
  if (localStorage.getItem('lithe-dev-stable-import-v1') === null) {
    localStorage.removeItem('lithe-update-channel');
    localStorage.removeItem('lithe-update-preferences');
    localStorage.setItem('lithe-dev-stable-import-v1', 'complete');
  }
}
"#;

#[cfg(target_os = "windows")]
pub fn prepare(app: &tauri::AppHandle) -> Result<bool, String> {
    use tauri::Manager;
    if app.config().identifier != "app.lithe.windows.dev" {
        return Ok(false);
    }
    let local = app.path().app_local_data_dir().map_err(|e| e.to_string())?;
    let data = app.path().app_data_dir().map_err(|e| e.to_string())?;
    let stable_local = local.with_file_name("app.lithe.windows");
    let stable_data = data.with_file_name("app.lithe.windows");
    prepare_paths(&stable_local, &local, &stable_data, &data).map_err(|error| {
        format!("Could not copy your Stable settings and workspaces. Close Stable and restart Lithe-Dev to try again. Your original data has been preserved.\n\n{error}")
    })
}

#[cfg(not(target_os = "windows"))]
pub fn prepare(_app: &tauri::AppHandle) -> Result<bool, String> {
    Ok(false)
}

fn prepare_paths(stable_local: &Path, local: &Path, stable_data: &Path, data: &Path) -> io::Result<bool> {
    for root in [local, data] {
        reject_existing_path(root)?;
    }
    let marker = local.join(MARKER);
    reject_existing_path(&marker)?;
    let pending = match fs::read_to_string(&marker) {
        Ok(value) if value == "imported" => return Ok(true),
        Ok(value) if value == "existing" || value == "fresh" => return Ok(false),
        Ok(value) if value == "pending" => true,
        Ok(_) => return Err(io::Error::other("Invalid profile migration marker")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => false,
        Err(error) => return Err(error),
    };
    if !pending && (has_state(local)? || has_state(data)?) {
        fs::create_dir_all(local)?;
        atomic_write(&marker, b"existing")?;
        return Ok(false);
    }
    fs::create_dir_all(local)?;
    // No application windows can write Dev state until this transaction commits.
    // An interrupted install may therefore resume without overwriting user edits.
    atomic_write(&marker, b"pending")?;
    let staging = local.join(STAGING);
    reject_existing_path(&staging)?;
    let ready = staging.join("ready");
    if !ready.try_exists()? {
        // Completed Dev profiles and frozen snapshots no longer depend on Stable.
        // Validate the source only when a new snapshot actually needs to read it.
        for root in [stable_local, stable_data] {
            reject_existing_path(root)?;
        }
        if staging.try_exists()? {
            reject_links(&staging)?;
            fs::remove_dir_all(&staging)?;
        }
        fs::create_dir(&staging)?;
        let mut source_component = stable_local.to_path_buf();
        for component in Path::new(LOCAL_STORAGE).components() {
            source_component.push(component);
            reject_existing_path(&source_component)?;
        }
        let source_storage = source_component;
        // Opening LOCK with no Windows sharing is also a guard against Stable
        // opening its database while the complete localStorage snapshot is read.
        let _profile_lock = lock_if_present(&stable_local.join("EBWebView/lockfile"))?;
        let _storage_lock = if source_storage.try_exists()? {
            Some(lock_file(&source_storage.join("LOCK"))?)
        } else {
            None
        };
        let mut imported = false;
        if source_storage.try_exists()? {
            copy_tree(&source_storage, &staging.join("local").join(LOCAL_STORAGE), true)?;
            imported = true;
        }
        let settings = stable_data.join("settings.json");
        if settings.try_exists()? {
            reject_links(&settings)?;
            let mut bytes = Vec::new();
            lock_file(&settings)?.read_to_end(&mut bytes)?;
            let value: serde_json::Value = serde_json::from_slice(&bytes)?;
            if !value.is_object() {
                return Err(io::Error::other("Invalid Stable settings"));
            }
            atomic_write(&staging.join("data/settings.json"), &bytes)?;
            imported = true;
        }
        let maven = stable_data.join("maven");
        if maven.try_exists()? {
            reject_links(&maven)?;
            for entry in fs::read_dir(&maven)? {
                let entry = entry?;
                if entry.path().extension().and_then(|value| value.to_str()) != Some("json") {
                    continue;
                }
                let mut bytes = Vec::new();
                lock_file(&entry.path())?.read_to_end(&mut bytes)?;
                let _: serde_json::Value = serde_json::from_slice(&bytes)?;
                atomic_write(&staging.join("data/maven").join(entry.file_name()), &bytes)?;
                imported = true;
            }
        }
        atomic_write(&ready, if imported { b"imported" } else { b"fresh" })?;
    }
    reject_links(&ready)?;
    let outcome = fs::read(&ready)?;
    if outcome != b"imported" && outcome != b"fresh" {
        return Err(io::Error::other("Invalid staged profile migration outcome"));
    }
    // Stage completely before installing either directory. A retry uses the same
    // frozen snapshot and never re-reads changed Stable preferences mid-install.
    for (source, destination) in [(staging.join("local"), local), (staging.join("data"), data)] {
        if source.try_exists()? {
            copy_tree(&source, destination, false)?;
        }
    }
    atomic_write(&marker, &outcome)?;
    fs::remove_dir_all(&staging)?;
    Ok(outcome == b"imported")
}

fn has_state(directory: &Path) -> io::Result<bool> {
    if !directory.try_exists()? {
        return Ok(false);
    }
    reject_links(directory)?;
    for entry in fs::read_dir(directory)? {
        let name = entry?.file_name();
        if name != format!("{MARKER}.import-tmp").as_str() {
            return Ok(true);
        }
    }
    Ok(false)
}

fn atomic_write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    reject_existing_path(path)?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let name = path.file_name().ok_or_else(|| io::Error::other("Missing migration filename"))?;
    let temporary = path.with_file_name(format!("{}.import-tmp", name.to_string_lossy()));
    reject_existing_path(&temporary)?;
    {
        use std::io::Write;
        let mut file = File::create(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    fs::rename(temporary, path)
}

fn reject_existing_path(path: &Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(_) => reject_links(path),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn reject_links(path: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(io::Error::other("Profile migration does not follow reparse points"));
        }
    }
    if metadata.file_type().is_symlink() || (!metadata.is_file() && !metadata.is_dir()) {
        return Err(io::Error::other("Profile migration requires regular files and directories"));
    }
    Ok(())
}

fn copy_tree(source: &Path, destination: &Path, storage: bool) -> io::Result<()> {
    reject_links(source)?;
    reject_existing_path(destination)?;
    if source.is_dir() {
        fs::create_dir_all(destination)?;
        for entry in fs::read_dir(source)? {
            let entry = entry?;
            // *.log is LevelDB's durable write-ahead log; it MUST be copied.
            // Uppercase LOG/LOG.old are diagnostic output and are discarded.
            if storage && matches!(entry.file_name().to_str(), Some("LOCK" | "LOG" | "LOG.old")) {
                continue;
            }
            copy_tree(&entry.path(), &destination.join(entry.file_name()), storage)?;
        }
    } else {
        atomic_write(destination, &fs::read(source)?)?;
    }
    Ok(())
}

fn lock_if_present(path: &Path) -> io::Result<Option<File>> {
    if path.try_exists()? { lock_file(path).map(Some) } else { Ok(None) }
}

fn lock_file(path: &Path) -> io::Result<File> {
    reject_links(path)?;
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(0);
    }
    options.open(path)
}

#[cfg(test)]
#[path = "profile_migration_tests.rs"]
mod tests;
