//! Extracting a downloaded project archive into the staging directory.
//!
//! The archive comes from a server the user can change, so it is untrusted:
//! every entry must stay inside the destination, symbolic links are refused,
//! existing files are never replaced, and the bytes actually written are
//! bounded regardless of what the headers claim.

use crate::plugins::declarative::{PluginRejection, Validation};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Component, Path, PathBuf};

const MAX_ENTRIES: usize = 20_000;
const MAX_EXTRACTED_BYTES: u64 = 512 * 1024 * 1024;
const ARCHIVE_INVALID: &str = "plugin.project.archiveInvalid";

/// `S_IFMT` and `S_IFLNK` of a Unix mode stored in a zip entry.
const FILE_TYPE_MASK: u32 = 0o170000;
const SYMLINK_TYPE: u32 = 0o120000;

/// Extracts `archive` into `destination`, which must be an existing
/// directory. Returns the number of files written.
pub(crate) fn extract(archive: &Path, destination: &Path) -> Validation<usize> {
    let rejected = |message: String| PluginRejection::at(ARCHIVE_INVALID, "archive", message);
    let destination_metadata = fs::symlink_metadata(destination)
        .map_err(|error| rejected(format!("The destination cannot be read: {error}")))?;
    if !destination_metadata.is_dir() {
        return Err(rejected("The destination is not a directory.".into()));
    }
    let file = File::open(archive)
        .map_err(|error| rejected(format!("The archive cannot be read: {error}")))?;
    let mut zip = zip::ZipArchive::new(file)
        .map_err(|error| rejected(format!("The download is not a zip archive: {error}")))?;
    if zip.len() > MAX_ENTRIES {
        return Err(rejected("The archive has too many entries.".into()));
    }

    let mut written: u64 = 0;
    let mut files = 0;
    for index in 0..zip.len() {
        let mut entry = zip
            .by_index(index)
            .map_err(|error| rejected(format!("Entry {index} cannot be read: {error}")))?;
        let name = entry.name().to_string();
        let relative = entry
            .enclosed_name()
            .filter(|path| is_plain_relative(path))
            .ok_or_else(|| rejected(format!("{name} leaves the project directory.")))?;
        let mode = entry.unix_mode();
        if mode.is_some_and(|mode| mode & FILE_TYPE_MASK == SYMLINK_TYPE) {
            return Err(rejected(format!("{name} is a symbolic link.")));
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
        let remaining = MAX_EXTRACTED_BYTES - written;
        let copied = io::copy(&mut (&mut entry).take(remaining + 1), &mut output)
            .map_err(|error| rejected(format!("{name} cannot be extracted: {error}")))?;
        if copied > remaining {
            return Err(rejected(
                "The archive expands beyond the size limit.".into(),
            ));
        }
        output
            .flush()
            .map_err(|error| rejected(format!("{name}: {error}")))?;
        written += copied;
        files += 1;
        set_executable(&target, mode).map_err(|error| rejected(format!("{name}: {error}")))?;
    }
    Ok(files)
}

fn is_plain_relative(path: &Path) -> bool {
    path.components().next().is_some()
        && path
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
}

/// Creates each directory below `root` along `relative`, refusing to walk
/// through anything that is not a real directory.
fn ensure_directories(root: &Path, relative: &Path) -> io::Result<()> {
    let mut current = PathBuf::from(root);
    for component in relative.components() {
        current.push(component);
        match fs::symlink_metadata(&current) {
            Ok(metadata) if metadata.is_dir() => {}
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
}
