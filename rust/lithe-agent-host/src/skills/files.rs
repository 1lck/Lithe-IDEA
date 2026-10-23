//! Bounded directory inventory and non-overwriting publication in native user/project roots.

use super::*;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};

pub(super) const MAX_ENTRIES: usize = 2_000;
const MAX_FILE_BYTES: u64 = 8 * 1024 * 1024;
const MAX_DOCUMENT_BYTES: u64 = 128 * 1024;
const MAX_IMPORT_BYTES: u64 = 32 * 1024 * 1024;
const MAX_DEPTH: usize = 20;

fn failure(message: &str) -> Error {
    Error::Failed(message.into())
}

fn read(path: &Path) -> Result<Vec<u8>, Error> {
    read_limited(path, MAX_FILE_BYTES)
}

fn read_limited(path: &Path, limit: u64) -> Result<Vec<u8>, Error> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options
        .open(path)
        .map_err(|_| failure("The skill file could not be opened."))?;
    if !file
        .metadata()
        .map_err(|_| failure("The skill file could not be inspected."))?
        .is_file()
    {
        return Err(failure("Skills must contain regular files."));
    }
    let mut bytes = Vec::new();
    file.take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| failure("The skill file could not be read."))?;
    if bytes.len() as u64 > limit {
        return Err(failure(if limit == MAX_DOCUMENT_BYTES {
            "SKILL.md exceeds the 128 KiB limit."
        } else {
            "A skill file exceeds the 8 MiB limit."
        }));
    }
    Ok(bytes)
}

pub(super) fn metadata(bytes: &[u8], fallback: &str) -> Result<(String, String), Error> {
    let text = std::str::from_utf8(bytes).map_err(|_| failure("SKILL.md must use UTF-8 text."))?;
    let mut lines = text.trim_start_matches('\u{feff}').lines();
    if lines.next().map(str::trim) != Some("---") {
        return Err(failure("SKILL.md needs YAML frontmatter."));
    }
    let mut yaml = String::new();
    let mut closed = false;
    for line in lines.by_ref() {
        if line.trim() == "---" {
            closed = true;
            break;
        }
        yaml.push_str(line);
        yaml.push('\n');
    }
    if !closed {
        return Err(failure("SKILL.md frontmatter is not closed."));
    }
    if !lines.any(|line| !line.trim().is_empty()) {
        return Err(failure(
            "SKILL.md needs instructions after its frontmatter.",
        ));
    }
    let value: serde_yaml_ng::Value = serde_yaml_ng::from_str(&yaml)
        .map_err(|_| failure("SKILL.md has invalid YAML frontmatter."))?;
    let name = value["name"].as_str().unwrap_or(fallback).trim();
    let description = value["description"].as_str().unwrap_or("").trim();
    if name.is_empty() || description.is_empty() {
        return Err(failure("SKILL.md needs a name and description."));
    }
    Ok((name.into(), description.into()))
}

/// Inventory only these two explicit locations. Do not emulate Claude's policy,
/// plugin resolution, ancestor discovery or lazy nested skill loading.
pub(super) fn claude_inventory(
    workspace: Option<&Path>,
    claude: &Path,
    cancelled: &dyn Fn() -> bool,
) -> Result<Listing, Error> {
    let mut result = Listing {
        source: "directory",
        skills: vec![],
        issues: vec![],
        directories: Default::default(),
    };
    let mut roots = vec![(claude.join("skills"), "user")];
    if let Some(workspace) = workspace {
        roots.push((workspace.join(".claude/skills"), "repo"));
    }
    let mut inspected = 0usize;
    'roots: for (root, scope) in roots {
        check(cancelled)?;
        let entries = match fs::read_dir(&root) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => {
                result
                    .issues
                    .push(format!("Cannot read {}", root.display()));
                continue;
            }
        };
        for entry in entries {
            check(cancelled)?;
            inspected += 1;
            if inspected > MAX_ENTRIES {
                result
                    .issues
                    .push("Only the first 2000 directory entries were inspected.".into());
                break 'roots;
            }
            let entry = match entry {
                Ok(entry) => entry,
                Err(_) => {
                    result
                        .issues
                        .push("A skill directory could not be read.".into());
                    continue;
                }
            };
            if entry.file_name().to_string_lossy().starts_with('.') {
                continue;
            }
            let path = entry.path().join("SKILL.md");
            if !path.exists() {
                continue;
            }
            // A native skill directory may be a link. Resolve only for reading;
            // importing links or writing through linked destinations is forbidden.
            let parsed = fs::canonicalize(&path)
                .map_err(|_| failure("A skill path could not be resolved."))
                .and_then(|canonical| read_limited(&canonical, MAX_DOCUMENT_BYTES))
                .and_then(|bytes| metadata(&bytes, &entry.file_name().to_string_lossy()));
            match parsed {
                Ok((name, description)) => result.skills.push(Skill {
                    name,
                    description,
                    path,
                    scope: scope.into(),
                    enabled: None,
                    plugin_id: None,
                }),
                Err(error) => {
                    result
                        .issues
                        .push(format!("{}: {}", path.display(), error.message()))
                }
            }
        }
    }
    Ok(result)
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name.split('-').all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        })
}

/// Create native containers without following a linked intermediate directory.
fn destination(request: &Request, home: &Path, claude: &Path) -> Result<PathBuf, Error> {
    let project = request.scope.as_deref() == Some("repo");
    if !matches!(request.scope.as_deref(), Some("user" | "repo")) {
        return Err(Error::Invalid(
            "Choose Global or Project for the skill.".into(),
        ));
    }
    let (base, components) = if project {
        (
            request.workspace.as_deref().ok_or_else(|| {
                Error::Invalid("Open a project before creating project skills.".into())
            })?,
            vec![
                if request.agent_id == "codex-acp" {
                    ".agents"
                } else {
                    ".claude"
                },
                "skills",
            ],
        )
    } else if request.agent_id == "codex-acp" {
        (home, vec![".agents", "skills"])
    } else {
        // CLAUDE_CONFIG_DIR is the user's native configuration override.
        fs::create_dir_all(claude)
            .map_err(|_| failure("The Claude configuration directory could not be created."))?;
        (claude, vec!["skills"])
    };
    let mut path =
        fs::canonicalize(base).map_err(|_| failure("The skill destination is unavailable."))?;
    for component in components {
        path.push(component);
        match fs::create_dir(&path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(_) => return Err(failure("The skill destination could not be created.")),
        }
        let metadata = fs::symlink_metadata(&path)
            .map_err(|_| failure("The skill destination could not be inspected."))?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(failure("The skill destination contains a symbolic link or non-directory. Choose a regular native skill directory."));
        }
    }
    Ok(path)
}

struct Staging(PathBuf);
impl Drop for Staging {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_dir_all(&self.0) {
            if error.kind() != std::io::ErrorKind::NotFound {
                eprintln!("Skill staging cleanup failed: {error}");
            }
        }
    }
}

pub(super) fn install(
    request: &Request,
    home: &Path,
    claude: &Path,
    cancelled: &dyn Fn() -> bool,
) -> Result<PathBuf, Error> {
    let (name, content, source) = match request.action {
        Action::Create => {
            let name = request.name.as_deref().unwrap_or("");
            let description = request.description.as_deref().unwrap_or("").trim();
            let instructions = request.instructions.as_deref().unwrap_or("").trim();
            if description.is_empty() || instructions.is_empty() {
                return Err(Error::Invalid(
                    "Enter a description and instructions.".into(),
                ));
            }
            // JSON strings are valid YAML scalars, preserving quotes and newlines.
            let text = format!(
                "---\nname: {}\ndescription: {}\n---\n\n{}\n",
                json!(name),
                json!(description),
                instructions
            );
            if text.len() as u64 > MAX_DOCUMENT_BYTES {
                return Err(Error::Invalid("The skill is too large.".into()));
            }
            (name.to_owned(), Some(text.into_bytes()), None)
        }
        Action::Import => {
            let source = request
                .source
                .as_deref()
                .filter(|p| p.is_absolute())
                .ok_or_else(|| {
                    Error::Invalid("Choose a SKILL.md file or skill directory.".into())
                })?;
            let info = fs::symlink_metadata(source)
                .map_err(|_| failure("The import source is unavailable."))?;
            if info.file_type().is_symlink() {
                return Err(failure(
                    "Import a regular file or directory instead of a symbolic link.",
                ));
            }
            let file = if info.is_dir() {
                source.join("SKILL.md")
            } else {
                source.to_path_buf()
            };
            if file.file_name().and_then(|v| v.to_str()) != Some("SKILL.md") {
                return Err(Error::Invalid(
                    "Select SKILL.md or its containing directory.".into(),
                ));
            }
            let bytes = read_limited(&file, MAX_DOCUMENT_BYTES)?;
            let fallback = if info.is_dir() {
                source.file_name().and_then(|v| v.to_str()).unwrap_or("")
            } else {
                ""
            };
            let (name, _) = metadata(&bytes, fallback)?;
            if request.agent_id == "codex-acp" {
                // Codex requires an explicit frontmatter name, unlike Claude's directory fallback.
                let (explicit, _) = metadata(&bytes, "")?;
                if explicit.is_empty() {
                    return Err(failure("Codex requires a skill name."));
                }
            }
            (
                name,
                Some(bytes),
                info.is_dir().then(|| source.to_path_buf()),
            )
        }
        Action::List | Action::Read | Action::Directories | Action::SetEnabled => unreachable!(),
    };
    if !valid_name(&name) {
        return Err(Error::Invalid(
            "Use up to 64 lowercase letters, digits and single hyphens for the skill name.".into(),
        ));
    }
    if request.agent_id == "claude-acp" && matches!(name.as_str(), "synced" | "anthropic-skills") {
        return Err(Error::Invalid(
            "That skill name is reserved by Claude. Choose a different name.".into(),
        ));
    }
    check(cancelled)?;
    let root = destination(request, home, claude)?;
    if source
        .as_ref()
        .and_then(|source| fs::canonicalize(source).ok())
        .is_some_and(|source| root.starts_with(source))
    {
        return Err(Error::Invalid(
            "The import source cannot contain the destination directory.".into(),
        ));
    }
    let target = root.join(&name);
    if target.symlink_metadata().is_ok() {
        return Err(failure("A skill with this directory name already exists. Existing skills are never overwritten."));
    }
    let staging = Staging(root.join(format!(".lithe-skill-{}", uuid::Uuid::new_v4())));
    fs::create_dir(&staging.0)
        .map_err(|_| failure("The skill staging directory could not be created."))?;
    if let Some(source) = source {
        let mut budget = Budget {
            entries: 0,
            bytes: 0,
        };
        copy_directory(&source, &staging.0, 0, &mut budget, cancelled)?;
        // Validate the actual staged bytes, including concurrent source changes.
        let (staged_name, _) = metadata(
            &read_limited(&staging.0.join("SKILL.md"), MAX_DOCUMENT_BYTES)?,
            &name,
        )?;
        if staged_name != name {
            return Err(failure(
                "SKILL.md changed while it was being imported. Retry the import.",
            ));
        }
    } else if let Some(content) = content {
        let mut file = File::create(staging.0.join("SKILL.md"))
            .map_err(|_| failure("SKILL.md could not be created."))?;
        file.write_all(&content)
            .map_err(|_| failure("SKILL.md could not be saved."))?;
    }
    check(cancelled)?;
    publish(&staging.0, &target)?;
    Ok(target.join("SKILL.md"))
}

struct Budget {
    entries: usize,
    bytes: u64,
}
fn copy_directory(
    source: &Path,
    destination: &Path,
    depth: usize,
    budget: &mut Budget,
    cancelled: &dyn Fn() -> bool,
) -> Result<(), Error> {
    if depth > MAX_DEPTH {
        return Err(failure("The skill directory is too deeply nested."));
    }
    let entries =
        fs::read_dir(source).map_err(|_| failure("The skill directory could not be read."))?;
    for entry in entries {
        check(cancelled)?;
        let entry = entry.map_err(|_| failure("A skill entry could not be read."))?;
        budget.entries += 1;
        if budget.entries > MAX_ENTRIES {
            return Err(failure("The skill contains too many files."));
        }
        let kind = entry
            .file_type()
            .map_err(|_| failure("A skill entry could not be inspected."))?;
        let path = destination.join(entry.file_name());
        if kind.is_dir() {
            fs::create_dir(&path).map_err(|_| failure("A skill directory could not be copied."))?;
            copy_directory(&entry.path(), &path, depth + 1, budget, cancelled)?;
        } else if kind.is_file() {
            let bytes = read(&entry.path())?;
            budget.bytes += bytes.len() as u64;
            if budget.bytes > MAX_IMPORT_BYTES {
                return Err(failure("The skill exceeds the 32 MiB import limit."));
            }
            fs::write(&path, bytes).map_err(|_| failure("A skill file could not be copied."))?;
            let permissions = entry
                .metadata()
                .map_err(|_| failure("Skill permissions could not be read."))?
                .permissions();
            fs::set_permissions(&path, permissions)
                .map_err(|_| failure("Skill permissions could not be preserved."))?;
        } else {
            return Err(failure(
                "Skill imports cannot contain symbolic links or special files.",
            ));
        }
    }
    Ok(())
}

/// Atomic no-replace publication closes the existence-check race with another window.
pub(super) fn publish(source: &Path, target: &Path) -> Result<(), Error> {
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        let from = CString::new(source.as_os_str().as_bytes())
            .map_err(|_| failure("Invalid skill path."))?;
        let to = CString::new(target.as_os_str().as_bytes())
            .map_err(|_| failure("Invalid skill path."))?;
        #[cfg(target_os = "macos")]
        // SAFETY: both C strings remain alive for the call; flags refuse replacement.
        let result = unsafe {
            libc::renameatx_np(
                libc::AT_FDCWD,
                from.as_ptr(),
                libc::AT_FDCWD,
                to.as_ptr(),
                libc::RENAME_EXCL,
            )
        };
        #[cfg(target_os = "linux")]
        // SAFETY: both C strings remain alive for the call; flags refuse replacement.
        let result = unsafe {
            libc::renameat2(
                libc::AT_FDCWD,
                from.as_ptr(),
                libc::AT_FDCWD,
                to.as_ptr(),
                libc::RENAME_NOREPLACE,
            )
        };
        if result != 0 {
            return Err(failure(
                "The skill could not be published. Check permissions and existing skill names.",
            ));
        }
        Ok(())
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::{MoveFileExW, MOVEFILE_WRITE_THROUGH};
        let from: Vec<u16> = source.as_os_str().encode_wide().chain(Some(0)).collect();
        let to: Vec<u16> = target.as_os_str().encode_wide().chain(Some(0)).collect();
        if from[..from.len() - 1].contains(&0) || to[..to.len() - 1].contains(&0) {
            return Err(failure("Invalid skill path."));
        }
        // std::fs::rename can replace empty directories via FileRenameInfoEx.
        // Omit REPLACE_EXISTING and COPY_ALLOWED: publication must stay an
        // exclusive same-volume move, including when another writer races us.
        // SAFETY: both terminated UTF-16 buffers stay alive throughout the call.
        if unsafe { MoveFileExW(from.as_ptr(), to.as_ptr(), MOVEFILE_WRITE_THROUGH) } == 0 {
            return Err(failure(
                "The skill could not be published. Check permissions and existing skill names.",
            ));
        }
        Ok(())
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
    Err(failure(
        "Atomic skill publication is unavailable on this platform.",
    ))
}

/// Native destinations are returned as display metadata; discovery creates no directories.
pub(super) fn directories(
    request: &Request,
    home: &Path,
    claude: &Path,
) -> std::collections::BTreeMap<String, PathBuf> {
    let mut directories = std::collections::BTreeMap::new();
    directories.insert(
        "user".into(),
        if request.agent_id == "codex-acp" {
            home.join(".agents/skills")
        } else {
            claude.join("skills")
        },
    );
    if let Some(workspace) = &request.workspace {
        directories.insert(
            "repo".into(),
            workspace.join(if request.agent_id == "codex-acp" {
                ".agents/skills"
            } else {
                ".claude/skills"
            }),
        );
    }
    directories
}

pub(super) fn read_document(path: &Path) -> Result<String, Error> {
    if path.file_name().and_then(|name| name.to_str()) != Some("SKILL.md") {
        return Err(Error::Invalid(
            "Select SKILL.md or its containing directory.".into(),
        ));
    }
    let canonical = fs::canonicalize(path)
        .map_err(|_| failure("The skill document is unavailable. Refresh and retry."))?;
    String::from_utf8(read_limited(&canonical, MAX_DOCUMENT_BYTES)?)
        .map_err(|_| failure("SKILL.md must use UTF-8 text."))
}
