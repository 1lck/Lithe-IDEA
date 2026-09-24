//! Removal of Eclipse project metadata that earlier JDT LS launches wrote into
//! the user's module directories.
//!
//! JDT LS now keeps `.project`, `.classpath`, `.factorypath`, and
//! `.settings/*.prefs` in its `-data` metadata area (see `jdt::adapt_start`).
//! A file that already exists at a module root still wins over that area, so
//! files written by earlier Lithe versions would otherwise stay in the project
//! forever. Only files Git does not track are removed: a tracked file is a
//! team decision, and outside a Git work tree ownership cannot be established.

use crate::lsp::languages::java_workspace::IGNORED_DIRECTORIES;
use crate::protocol::{CoreError, ErrorCode};
use std::fs;
use std::path::{Path, PathBuf};

/// Build descriptors for which JDT LS's Maven and Gradle importers create an
/// Eclipse project, and therefore the only directories they write metadata to.
const MODULE_DESCRIPTOR_NAMES: &[&str] = &["pom.xml", "build.gradle", "build.gradle.kts"];
/// Metadata files JDT LS writes directly into a module directory.
const METADATA_FILE_NAMES: &[&str] = &[".classpath", ".factorypath", ".project"];
/// Directory holding the per-project Eclipse preference files.
const SETTINGS_DIRECTORY_NAME: &str = ".settings";
/// Extension of the preference files JDT LS redirects together with the files above.
const PREFERENCES_EXTENSION: &str = "prefs";

/// Removes legacy metadata before JDT LS starts for `workspace_root`.
///
/// When any file was removed, the JDT LS state in `data_directory` still
/// describes those projects at their old location, so it is deleted and the
/// launch imports the workspace afresh. Returns the removed files as sorted
/// workspace-relative paths with `/` separators.
pub(crate) fn prepare_workspace(
    workspace_root: &Path,
    data_directory: &Path,
) -> Result<Vec<String>, CoreError> {
    let removed = remove_untracked_metadata(workspace_root);
    if !removed.is_empty() && data_directory.exists() {
        fs::remove_dir_all(data_directory).map_err(|error| {
            CoreError::new(
                ErrorCode::ProcessStartFailed,
                "Could not reset the Java language-server state after moving its project files out of the workspace.",
            )
            .with_details(error.to_string())
        })?;
    }
    Ok(removed)
}

fn remove_untracked_metadata(workspace_root: &Path) -> Vec<String> {
    let mut removed = Vec::new();
    for module in module_directories(workspace_root) {
        let candidates = metadata_candidates(&module);
        // Removal is best effort: a file that cannot be queried or deleted keeps
        // working for JDT LS exactly as before, so it never blocks the launch.
        let Some(untracked) = crate::git::untracked_candidates(&module, &candidates) else {
            continue;
        };
        let mut removed_preferences = false;
        for candidate in untracked {
            if fs::remove_file(module.join(&candidate)).is_err() {
                continue;
            }
            removed_preferences |= candidate.starts_with(SETTINGS_DIRECTORY_NAME);
            removed.push(workspace_relative(workspace_root, &module, &candidate));
        }
        if removed_preferences {
            // Fails, as intended, while the directory still holds other files.
            let _ = fs::remove_dir(module.join(SETTINGS_DIRECTORY_NAME));
        }
    }
    removed.sort();
    removed
}

/// Directories below `workspace_root` that declare a Maven or Gradle module.
///
/// Hidden, ignored, and symbolically linked directories are not entered, so the
/// walk stays inside the project's own sources and cannot leave the workspace.
fn module_directories(workspace_root: &Path) -> Vec<PathBuf> {
    let mut modules = Vec::new();
    let mut pending = vec![workspace_root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        let Ok(entries) = fs::read_dir(&directory) else {
            continue;
        };
        let mut is_module = false;
        for entry in entries.flatten() {
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if file_type.is_file() && MODULE_DESCRIPTOR_NAMES.contains(&name.as_ref()) {
                is_module = true;
            } else if file_type.is_dir()
                && !name.starts_with('.')
                && !IGNORED_DIRECTORIES.contains(&name.as_ref())
            {
                pending.push(entry.path());
            }
        }
        if is_module {
            modules.push(directory);
        }
    }
    modules.sort();
    modules
}

/// Existing metadata files of one module, relative to it with `/` separators.
fn metadata_candidates(module: &Path) -> Vec<String> {
    let mut candidates = METADATA_FILE_NAMES
        .iter()
        .filter(|name| is_regular_file(&module.join(name)))
        .map(|name| name.to_string())
        .collect::<Vec<_>>();
    let settings = module.join(SETTINGS_DIRECTORY_NAME);
    let is_settings_directory =
        fs::symlink_metadata(&settings).is_ok_and(|metadata| metadata.file_type().is_dir());
    if is_settings_directory {
        if let Ok(entries) = fs::read_dir(&settings) {
            let mut preferences = entries
                .flatten()
                .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_file()))
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .filter(|name| {
                    Path::new(name)
                        .extension()
                        .is_some_and(|extension| extension == PREFERENCES_EXTENSION)
                })
                .map(|name| format!("{SETTINGS_DIRECTORY_NAME}/{name}"))
                .collect::<Vec<_>>();
            preferences.sort();
            candidates.extend(preferences);
        }
    }
    candidates
}

fn is_regular_file(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_file())
}

fn workspace_relative(workspace_root: &Path, module: &Path, candidate: &str) -> String {
    let module = module
        .strip_prefix(workspace_root)
        .unwrap_or(module)
        .to_string_lossy()
        .replace('\\', "/");
    if module.is_empty() {
        candidate.to_string()
    } else {
        format!("{module}/{candidate}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_WORKSPACE: AtomicU64 = AtomicU64::new(0);

    /// A scratch directory holding a workspace and a JDT data directory, removed
    /// on drop so a failed assertion does not leak it.
    struct Scratch {
        root: PathBuf,
    }

    impl Scratch {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "lithe-jdt-metadata-{}-{}",
                std::process::id(),
                NEXT_WORKSPACE.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(root.join("workspace")).expect("workspace should be created");
            Self { root }
        }

        fn workspace(&self) -> PathBuf {
            self.root.join("workspace")
        }

        fn data_directory(&self) -> PathBuf {
            let directory = self.root.join("data");
            fs::create_dir_all(directory.join(".metadata")).expect("data should be created");
            directory
        }

        fn write(&self, relative: &str) {
            let path = self.workspace().join(relative);
            fs::create_dir_all(path.parent().unwrap()).expect("parent should be created");
            fs::write(path, relative).expect("file should be written");
        }

        fn exists(&self, relative: &str) -> bool {
            self.workspace().join(relative).exists()
        }

        fn git(&self, arguments: &[&str]) {
            let status = Command::new("git")
                .args(arguments)
                .current_dir(self.workspace())
                .status()
                .expect("git should run");
            assert!(status.success(), "git {arguments:?} failed");
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    /// The reported layout: a Maven reactor whose modules sit one and two
    /// levels deep, each carrying the files JDT LS used to write in place.
    fn write_reactor_with_legacy_metadata(scratch: &Scratch) {
        for module in ["", "domain/", "infrastructure/sdk/"] {
            scratch.write(&format!("{module}pom.xml"));
            scratch.write(&format!("{module}.project"));
            scratch.write(&format!("{module}.classpath"));
            scratch.write(&format!("{module}.factorypath"));
            scratch.write(&format!("{module}.settings/org.eclipse.jdt.core.prefs"));
            scratch.write(&format!("{module}.settings/org.eclipse.m2e.core.prefs"));
        }
    }

    #[test]
    fn removes_untracked_module_metadata_and_resets_the_jdt_state() {
        let scratch = Scratch::new();
        write_reactor_with_legacy_metadata(&scratch);
        scratch.git(&["init", "-q"]);
        let data_directory = scratch.data_directory();

        let removed = prepare_workspace(&scratch.workspace(), &data_directory)
            .expect("preparation should succeed");

        assert_eq!(removed.len(), 15, "{removed:?}");
        assert_eq!(removed.first().map(String::as_str), Some(".classpath"));
        assert!(removed
            .contains(&"infrastructure/sdk/.settings/org.eclipse.m2e.core.prefs".to_string()));
        for module in ["", "domain/", "infrastructure/sdk/"] {
            assert!(scratch.exists(&format!("{module}pom.xml")));
            assert!(!scratch.exists(&format!("{module}.project")));
            assert!(!scratch.exists(&format!("{module}.settings")));
        }
        assert!(!data_directory.exists(), "stale JDT state must not survive");
    }

    #[test]
    fn keeps_tracked_metadata_and_user_files_in_settings() {
        let scratch = Scratch::new();
        write_reactor_with_legacy_metadata(&scratch);
        scratch.write("domain/.settings/team-notes.txt");
        scratch.git(&["init", "-q"]);
        // A team that commits Eclipse files for its Eclipse users owns them.
        scratch.git(&[
            "add",
            "domain/.classpath",
            "domain/.settings/org.eclipse.jdt.core.prefs",
        ]);

        prepare_workspace(&scratch.workspace(), &scratch.data_directory())
            .expect("preparation should succeed");

        assert!(scratch.exists("domain/.classpath"));
        assert!(scratch.exists("domain/.settings/org.eclipse.jdt.core.prefs"));
        assert!(!scratch.exists("domain/.settings/org.eclipse.m2e.core.prefs"));
        assert!(scratch.exists("domain/.settings/team-notes.txt"));
        assert!(!scratch.exists("domain/.project"));
    }

    #[test]
    fn leaves_workspaces_outside_git_and_their_jdt_state_untouched() {
        let scratch = Scratch::new();
        write_reactor_with_legacy_metadata(&scratch);
        let data_directory = scratch.data_directory();

        let removed = prepare_workspace(&scratch.workspace(), &data_directory)
            .expect("preparation should succeed");

        assert!(removed.is_empty(), "{removed:?}");
        assert!(scratch.exists(".project"));
        assert!(scratch.exists("infrastructure/sdk/.settings/org.eclipse.m2e.core.prefs"));
        assert!(data_directory.join(".metadata").is_dir());
    }

    #[test]
    fn ignores_directories_that_are_not_modules_or_not_project_sources() {
        let scratch = Scratch::new();
        scratch.write("pom.xml");
        // No build descriptor: an Eclipse project JDT LS did not generate.
        scratch.write("tools/.project");
        // Vendored and build-output copies are not the opened project's modules.
        scratch.write("node_modules/dep/pom.xml");
        scratch.write("node_modules/dep/.project");
        scratch.write("target/nested/pom.xml");
        scratch.write("target/nested/.classpath");
        scratch.git(&["init", "-q"]);
        let data_directory = scratch.data_directory();

        let removed = prepare_workspace(&scratch.workspace(), &data_directory)
            .expect("preparation should succeed");

        assert!(removed.is_empty(), "{removed:?}");
        assert!(scratch.exists("tools/.project"));
        assert!(scratch.exists("node_modules/dep/.project"));
        assert!(scratch.exists("target/nested/.classpath"));
        assert!(
            data_directory.join(".metadata").is_dir(),
            "nothing moved, so the state is kept"
        );
    }
}
