//! Extracting a downloaded project archive into the staging directory.
//!
//! The archive comes from a server the user can change, so it is untrusted:
//! every entry must stay inside the destination, symbolic links are refused,
//! existing files are never replaced, and the bytes actually written are
//! bounded regardless of what the headers claim.

use crate::plugins::declarative::{PluginRejection, Validation};
use crate::protocol::CoreError;
use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Component, Path, PathBuf};

const MAX_ENTRIES: usize = 20_000;
const MAX_EXTRACTED_BYTES: u64 = 512 * 1024 * 1024;
const COPY_CHUNK_BYTES: usize = 32 * 1024;
const MAX_DEPTH: usize = 64;
const MAX_PATH_BYTES: usize = 16 * 1024 * 1024;
const ARCHIVE_INVALID: &str = "plugin.project.archiveInvalid";

/// `S_IFMT` and `S_IFLNK` of a Unix mode stored in a zip entry.
const FILE_TYPE_MASK: u32 = 0o170000;
const SYMLINK_TYPE: u32 = 0o120000;

/// Separates invalid archive content from the first typed operation interruption.
#[derive(Debug)]
pub(crate) enum ExtractionError {
    /// The archive or destination violates the extraction contract.
    Invalid(PluginRejection),
    /// Cancellation or timeout detected while all extraction handles are owned.
    Interrupted(CoreError),
}

impl From<PluginRejection> for ExtractionError {
    fn from(error: PluginRejection) -> Self {
        Self::Invalid(error)
    }
}

impl From<CoreError> for ExtractionError {
    fn from(error: CoreError) -> Self {
        Self::Interrupted(error)
    }
}

/// Extracts `archive` into `destination`, which must be an existing
/// directory. Returns the number of files written after closing its descriptors.
pub(crate) fn extract(archive: &Path, destination: &Path) -> Result<usize, ExtractionError> {
    extract_with_checkpoint(archive, destination, MAX_EXTRACTED_BYTES, &mut checkpoint)
}

fn checkpoint() -> Result<(), CoreError> {
    crate::protocol::cancellation::check()
}

fn extract_with_checkpoint(
    archive: &Path,
    destination: &Path,
    maximum_bytes: u64,
    checkpoint: &mut dyn FnMut() -> Result<(), CoreError>,
) -> Result<usize, ExtractionError> {
    checkpoint()?;
    let rejected = |message: String| PluginRejection::at(ARCHIVE_INVALID, "archive", message);
    let destination_metadata = fs::symlink_metadata(destination)
        .map_err(|error| rejected(format!("The destination cannot be read: {error}")))?;
    if !real_directory(&destination_metadata) {
        return Err(rejected("The destination is not a directory.".into()).into());
    }
    let file = File::open(archive)
        .map_err(|error| rejected(format!("The archive cannot be read: {error}")))?;
    let mut zip = zip::ZipArchive::new(file)
        .map_err(|error| rejected(format!("The download is not a zip archive: {error}")))?;
    if zip.len() > MAX_ENTRIES {
        return Err(rejected("The archive has too many entries.".into()).into());
    }
    validate_entries(&mut zip, checkpoint, MAX_ENTRIES, MAX_PATH_BYTES)?;

    let mut written: u64 = 0;
    let mut files = 0;
    for index in 0..zip.len() {
        checkpoint()?;
        let mut entry = zip
            .by_index(index)
            .map_err(|error| rejected(format!("Entry {index} cannot be read: {error}")))?;
        let name = entry.name().to_string();
        let relative = relative_entry(&entry)?;
        let mode = entry.unix_mode();
        if mode.is_some_and(|mode| mode & FILE_TYPE_MASK == SYMLINK_TYPE) {
            return Err(rejected(format!("{name} is a symbolic link.")).into());
        }
        let target = destination.join(&relative);
        ensure_directories(destination, relative.parent().unwrap_or(Path::new("")))
            .map_err(|error| rejected(format!("{name}: {error}")))?;
        if entry.is_dir() {
            ensure_directories(destination, &relative)
                .map_err(|error| rejected(format!("{name}: {error}")))?;
            continue;
        }
        let mut output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&target)
            .map_err(|error| rejected(format!("{name} cannot be created: {error}")))?;
        let remaining = maximum_bytes - written;
        let mut limited = (&mut entry).take(remaining + 1);
        let mut copied = 0u64;
        let mut buffer = [0u8; COPY_CHUNK_BYTES];
        loop {
            checkpoint()?;
            let count = limited
                .read(&mut buffer)
                .map_err(|error| rejected(format!("{name} cannot be extracted: {error}")))?;
            if count == 0 {
                break;
            }
            checkpoint()?;
            // Read one byte beyond the budget to detect a dishonest size, but
            // never write that sentinel byte into the transaction.
            if copied + count as u64 > remaining {
                return Err(rejected("The archive expands beyond the size limit.".into()).into());
            }
            output
                .write_all(&buffer[..count])
                .map_err(|error| rejected(format!("{name} cannot be extracted: {error}")))?;
            copied += count as u64;
        }
        output
            .flush()
            .map_err(|error| rejected(format!("{name}: {error}")))?;
        written += copied;
        files += 1;
        set_executable(&target, mode).map_err(|error| rejected(format!("{name}: {error}")))?;
    }
    checkpoint()?;
    Ok(files)
}

fn relative_entry(entry: &zip::read::ZipFile<'_>) -> Validation<PathBuf> {
    let name = entry.name();
    // Reject traversal before ZipArchive normalizes it. Backslashes are path
    // separators on Windows, so they cannot be literal names on another host.
    let path = name.strip_suffix('/').unwrap_or(name);
    if name.contains('\\') || path.split('/').any(|part| matches!(part, "" | "." | "..")) {
        return Err(PluginRejection::at(
            ARCHIVE_INVALID,
            "archive",
            format!("{name} leaves the project directory."),
        ));
    }
    entry
        .enclosed_name()
        .filter(|path| is_plain_relative(path))
        .ok_or_else(|| {
            PluginRejection::at(
                ARCHIVE_INVALID,
                "archive",
                format!("{name} leaves the project directory."),
            )
        })
}

/// Preflights the existing ZIP parser's entries before creating anything. The
/// node budget includes implicit parent directories; the path-byte budget bounds
/// memory even when a few deeply nested names expand into many parent paths.
fn validate_entries(
    zip: &mut zip::ZipArchive<File>,
    checkpoint: &mut dyn FnMut() -> Result<(), CoreError>,
    maximum_entries: usize,
    maximum_path_bytes: usize,
) -> Result<(), ExtractionError> {
    let mut paths = HashSet::new();
    let mut path_bytes = 0usize;
    for index in 0..zip.len() {
        checkpoint()?;
        let entry = zip.by_index(index).map_err(|error| {
            PluginRejection::at(
                ARCHIVE_INVALID,
                "archive",
                format!("Entry {index}: {error}"),
            )
        })?;
        let relative = relative_entry(&entry)?;
        if entry
            .unix_mode()
            .is_some_and(|mode| mode & FILE_TYPE_MASK == SYMLINK_TYPE)
        {
            return Err(PluginRejection::at(
                ARCHIVE_INVALID,
                "archive",
                format!("{} is a symbolic link.", entry.name()),
            )
            .into());
        }
        for path in relative
            .ancestors()
            .take_while(|path| !path.as_os_str().is_empty())
        {
            checkpoint()?;
            if paths.insert(path.to_path_buf()) {
                path_bytes = path_bytes.saturating_add(path.to_string_lossy().len());
                if paths.len() > maximum_entries || path_bytes > maximum_path_bytes {
                    return Err(PluginRejection::at(
                        ARCHIVE_INVALID,
                        "archive",
                        "The archive has too many paths or path bytes.",
                    )
                    .into());
                }
            }
        }
    }
    Ok(())
}

fn is_plain_relative(path: &Path) -> bool {
    let components: Vec<_> = path.components().collect();
    !components.is_empty()
        && components.len() <= MAX_DEPTH
        && components.iter().all(|component| match component {
            Component::Normal(value) => safe_component(value),
            _ => false,
        })
}

fn real_directory(metadata: &fs::Metadata) -> bool {
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return false;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return false;
        }
    }
    true
}

#[cfg(windows)]
fn safe_component(value: &std::ffi::OsStr) -> bool {
    let Some(value) = value.to_str() else {
        return false;
    };
    let base = value.split('.').next().unwrap_or("").to_ascii_uppercase();
    !value.ends_with(['.', ' '])
        && !value
            .chars()
            .any(|ch| ch.is_control() || "<>:\"|?*".contains(ch))
        && !matches!(
            base.as_str(),
            "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
        )
        && !["COM", "LPT"].iter().any(|prefix| {
            base.strip_prefix(prefix).is_some_and(|n| {
                matches!(
                    n,
                    "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"
                )
            })
        })
}

#[cfg(not(windows))]
fn safe_component(_: &std::ffi::OsStr) -> bool {
    true
}

/// Creates each directory below `root` along `relative`, refusing to walk
/// through anything that is not a real directory.
fn ensure_directories(root: &Path, relative: &Path) -> io::Result<()> {
    let mut current = PathBuf::from(root);
    for component in relative.components() {
        current.push(component);
        match fs::symlink_metadata(&current) {
            Ok(metadata) if real_directory(&metadata) => {}
            Ok(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    format!("{} is not a directory", current.display()),
                ))
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => fs::create_dir(&current)?,
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

#[cfg(unix)]
fn set_executable(path: &Path, mode: Option<u32>) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    if mode.is_some_and(|mode| mode & 0o111 != 0) {
        let mut permissions = fs::metadata(path)?.permissions();
        permissions.set_mode(permissions.mode() | 0o111);
        fs::set_permissions(path, permissions)?;
    }
    Ok(())
}

#[cfg(not(unix))]
fn set_executable(_: &Path, _: Option<u32>) -> io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use zip::write::SimpleFileOptions;

    fn archive(entries: &[(&str, &[u8], Option<u32>)]) -> (tempfile_like::Dir, PathBuf) {
        let directory = tempfile_like::Dir::new();
        let path = directory.path().join("archive.zip");
        let mut writer = zip::ZipWriter::new(File::create(&path).unwrap());
        for (name, contents, mode) in entries {
            let mut options = SimpleFileOptions::default();
            if let Some(mode) = mode {
                options = options.unix_permissions(*mode);
            }
            writer.start_file(*name, options).unwrap();
            writer.write_all(contents).unwrap();
        }
        writer.finish().unwrap();
        (directory, path)
    }

    /// A self-cleaning directory under the system temporary directory.
    mod tempfile_like {
        use std::path::{Path, PathBuf};

        pub(super) struct Dir(PathBuf);

        impl Dir {
            pub(super) fn new() -> Self {
                let path = std::env::temp_dir().join(format!(
                    "lithe-generator-archive-{}-{}",
                    std::process::id(),
                    rand::random::<u64>()
                ));
                std::fs::create_dir_all(&path).unwrap();
                Self(path)
            }

            pub(super) fn path(&self) -> &Path {
                &self.0
            }
        }

        impl Drop for Dir {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
    }

    #[test]
    fn extracts_files_and_keeps_executable_bits() {
        let (directory, path) = archive(&[
            ("pom.xml", b"<project/>", None),
            ("mvnw", b"#!/bin/sh", Some(0o755)),
            ("src/main/java/App.java", b"class App {}", None),
        ]);
        let destination = directory.path().join("project");
        fs::create_dir(&destination).unwrap();
        assert_eq!(extract(&path, &destination).unwrap(), 3);
        assert_eq!(
            fs::read_to_string(destination.join("src/main/java/App.java")).unwrap(),
            "class App {}"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(destination.join("mvnw"))
                .unwrap()
                .permissions()
                .mode();
            assert_ne!(mode & 0o100, 0);
        }
    }

    #[test]
    fn refuses_entries_outside_the_destination_and_overwrites() {
        let (directory, path) = archive(&[("../escape.txt", b"x", None)]);
        let destination = directory.path().join("project");
        fs::create_dir(&destination).unwrap();
        assert!(extract(&path, &destination).is_err());
        assert!(!directory.path().join("escape.txt").exists());

        let (directory, path) = archive(&[("pom.xml", b"new", None)]);
        let destination = directory.path().join("project");
        fs::create_dir(&destination).unwrap();
        fs::write(destination.join("pom.xml"), "old").unwrap();
        assert!(extract(&path, &destination).is_err());
        assert_eq!(
            fs::read_to_string(destination.join("pom.xml")).unwrap(),
            "old"
        );
    }

    #[test]
    fn refuses_symbolic_links() {
        let directory = tempfile_like::Dir::new();
        let path = directory.path().join("archive.zip");
        let mut writer = zip::ZipWriter::new(File::create(&path).unwrap());
        writer
            .add_symlink("link", "/etc/passwd", SimpleFileOptions::default())
            .unwrap();
        writer.finish().unwrap();
        let destination = directory.path().join("project");
        fs::create_dir(&destination).unwrap();
        assert!(extract(&path, &destination).is_err());
    }

    #[test]
    fn cancellation_between_chunks_stops_before_the_next_write_or_entry() {
        let bytes = vec![b'x'; COPY_CHUNK_BYTES * 3];
        let (directory, path) =
            archive(&[("large.txt", &bytes, None), ("later.txt", b"later", None)]);
        let destination = directory.path().join("project");
        fs::create_dir(&destination).unwrap();
        let id = format!("archive-chunks-{}", rand::random::<u64>());
        let _scope = crate::protocol::cancellation::Scope::begin(Some(id.clone()), Some(3000));
        let result = extract_with_checkpoint(&path, &destination, MAX_EXTRACTED_BYTES, &mut || {
            // Observe one completed write, then cancel before another chunk.
            if fs::metadata(destination.join("large.txt"))
                .is_ok_and(|metadata| metadata.len() >= COPY_CHUNK_BYTES as u64)
            {
                assert!(crate::protocol::cancellation::cancel(&id));
            }
            checkpoint()
        });
        assert!(result.is_err());
        let written = fs::metadata(destination.join("large.txt")).unwrap().len();
        assert!(written >= COPY_CHUNK_BYTES as u64);
        assert!(written < (COPY_CHUNK_BYTES * 2) as u64);
        assert!(!destination.join("later.txt").exists());
    }

    #[test]
    fn timeout_between_chunks_preserves_its_first_error_and_closes_the_output() {
        let bytes = vec![b'x'; COPY_CHUNK_BYTES * 3];
        let (directory, path) =
            archive(&[("large.txt", &bytes, None), ("later.txt", b"later", None)]);
        let destination = directory.path().join("project");
        fs::create_dir(&destination).unwrap();
        let result = extract_with_checkpoint(&path, &destination, MAX_EXTRACTED_BYTES, &mut || {
            if fs::metadata(destination.join("large.txt"))
                .is_ok_and(|metadata| metadata.len() >= COPY_CHUNK_BYTES as u64)
            {
                // An already reached deadline controls the event order without
                // sleeping or relying on the speed of filesystem extraction.
                crate::protocol::cancellation::with_cleanup_deadline(
                    std::time::Duration::ZERO,
                    checkpoint,
                )
            } else {
                Ok(())
            }
        });
        let Err(ExtractionError::Interrupted(error)) = result else {
            panic!("chunk timeout must remain an operation interruption");
        };
        assert!(matches!(error.code, crate::protocol::ErrorCode::TimedOut));
        assert_eq!(
            fs::metadata(destination.join("large.txt")).unwrap().len(),
            COPY_CHUNK_BYTES as u64
        );
        assert!(!destination.join("later.txt").exists());
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            // An exclusive reopen proves the timed-out writer released its
            // descriptor before the host can start transaction cleanup.
            let _closed = OpenOptions::new()
                .read(true)
                .share_mode(0)
                .open(destination.join("large.txt"))
                .unwrap();
        }
    }

    #[test]
    fn rejects_excessive_archive_path_depth_before_creating_any_parent() {
        let name = format!("{}/file.txt", vec!["a"; MAX_DEPTH].join("/"));
        let (directory, path) = archive(&[(&name, b"no", None)]);
        let destination = directory.path().join("project");
        fs::create_dir(&destination).unwrap();
        assert!(extract(&path, &destination).is_err());
        assert_eq!(fs::read_dir(destination).unwrap().count(), 0);
    }

    #[test]
    fn expanded_byte_budget_counts_actual_written_bytes() {
        let bytes = vec![b'x'; COPY_CHUNK_BYTES * 2];
        let (directory, path) = archive(&[("large.txt", &bytes, None)]);
        let destination = directory.path().join("project");
        fs::create_dir(&destination).unwrap();
        assert!(extract_with_checkpoint(
            &path,
            &destination,
            COPY_CHUNK_BYTES as u64 + 16,
            &mut || Ok(())
        )
        .is_err());
        let written = fs::metadata(destination.join("large.txt")).unwrap().len();
        assert!(written > 0);
        assert!(written <= COPY_CHUNK_BYTES as u64 + 16);
    }

    #[test]
    fn implicit_parents_and_path_bytes_share_the_preflight_budget() {
        let (_directory, path) = archive(&[("parent/nested/file.txt", b"no", None)]);
        let mut zip = zip::ZipArchive::new(File::open(&path).unwrap()).unwrap();
        assert!(validate_entries(&mut zip, &mut || Ok(()), 2, usize::MAX).is_err());
        // The leaf (22 bytes) and its implicit parents (13 + 6) total 41.
        assert!(validate_entries(&mut zip, &mut || Ok(()), 3, 40).is_err());
        assert!(validate_entries(&mut zip, &mut || Ok(()), 3, 41).is_ok());
    }

    #[test]
    fn archive_paths_cannot_hide_traversal_in_normalized_components() {
        for name in [
            "nested/../file.txt",
            "nested/./file.txt",
            "nested//file.txt",
            "nested\\file.txt",
            "/file.txt",
        ] {
            let (directory, path) = archive(&[("first.txt", b"safe", None), (name, b"no", None)]);
            let destination = directory.path().join("project");
            fs::create_dir(&destination).unwrap();
            assert!(extract(&path, &destination).is_err(), "{name}");
            assert_eq!(fs::read_dir(destination).unwrap().count(), 0, "{name}");
        }
    }

    #[test]
    fn command_reports_stable_cancellation_and_timeout_before_any_write() {
        let (directory, path) = archive(&[("file.txt", b"no", None)]);
        let destination = directory.path().join("project");
        fs::create_dir(&destination).unwrap();
        let payload = serde_json::json!({"archivePath": path, "destination": destination});
        let id = format!("archive-command-{}", rand::random::<u64>());
        {
            let _scope = crate::protocol::cancellation::Scope::begin(Some(id.clone()), None);
            assert!(crate::protocol::cancellation::cancel(&id));
            let error = crate::project_generators::project_extract_archive_command(payload.clone())
                .unwrap_err();
            assert!(matches!(error.code, crate::protocol::ErrorCode::Cancelled));
        }
        crate::protocol::cancellation::with_cleanup_deadline(std::time::Duration::ZERO, || {
            let error =
                crate::project_generators::project_extract_archive_command(payload).unwrap_err();
            assert!(matches!(error.code, crate::protocol::ErrorCode::TimedOut));
        });
        assert_eq!(fs::read_dir(destination).unwrap().count(), 0);
    }

    #[test]
    fn existing_hard_link_target_is_never_truncated_or_replaced() {
        let (directory, path) = archive(&[("linked.txt", b"untrusted", None)]);
        let destination = directory.path().join("project");
        fs::create_dir(&destination).unwrap();
        let outside = directory.path().join("owned.txt");
        fs::write(&outside, b"user bytes").unwrap();
        fs::hard_link(&outside, destination.join("linked.txt")).unwrap();
        assert!(extract(&path, &destination).is_err());
        assert_eq!(fs::read(&outside).unwrap(), b"user bytes");
        assert_eq!(
            fs::read(destination.join("linked.txt")).unwrap(),
            b"user bytes"
        );
    }

    #[cfg(windows)]
    #[test]
    fn windows_archive_paths_reject_ads_device_names_and_verbatim_normalization() {
        for name in [
            "file:stream",
            "CON.txt",
            "nested/LPT1",
            "trailing.",
            "space ",
        ] {
            let (directory, path) = archive(&[(name, b"no", None)]);
            let destination = directory.path().join("project");
            fs::create_dir(&destination).unwrap();
            assert!(extract(&path, &destination).is_err(), "{name}");
            assert_eq!(fs::read_dir(destination).unwrap().count(), 0);
        }
    }

    #[cfg(unix)]
    #[test]
    fn refuses_existing_symlink_directories_without_touching_their_target() {
        let (directory, path) = archive(&[("nested/file.txt", b"no", None)]);
        let destination = directory.path().join("project");
        let outside = directory.path().join("outside");
        fs::create_dir(&destination).unwrap();
        fs::create_dir(&outside).unwrap();
        std::os::unix::fs::symlink(&outside, destination.join("nested")).unwrap();
        assert!(extract(&path, &destination).is_err());
        assert_eq!(fs::read_dir(outside).unwrap().count(), 0);
    }
}
