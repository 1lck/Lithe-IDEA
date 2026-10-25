//! Native visibility settings. Never move skill packages or keep a Lithe enabled flag.

use super::*;
use fs2::FileExt;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};

const MAX_SETTINGS_BYTES: u64 = 1024 * 1024;

fn failed() -> Error {
    Error::Failed(
        "Skill settings could not be updated. Check the settings file and refresh.".into(),
    )
}

/// These are configured states, not a reconstruction of Claude's effective
/// managed/ancestor/session policy. Project-local overrides take precedence.
pub(super) fn annotate(listing: &mut Listing, workspace: Option<&Path>, claude: &Path) {
    let user = load(&claude.join("settings.json"));
    let project = workspace
        .map(|root| {
            Ok::<_, Error>((
                load(&root.join(".claude/settings.json"))?,
                load(&root.join(".claude/settings.local.json"))?,
            ))
        })
        .transpose();
    for skill in &mut listing.skills {
        skill.enabled = user.as_ref().ok().and_then(|user| {
            let mut state = visibility(user, &skill.name)?;
            if skill.scope == "repo" {
                if let Some((shared, local)) = project.as_ref().ok()?.as_ref() {
                    state = override_visibility(shared, &skill.name)?.unwrap_or(state);
                    state = override_visibility(local, &skill.name)?.unwrap_or(state);
                }
            }
            Some(state)
        });
    }
    if user.is_err() || project.is_err() {
        listing.issues.push("Claude skill settings could not be read. Fix invalid settings and refresh before toggling.".into());
    }
}

fn override_visibility(value: &Value, name: &str) -> Option<Option<bool>> {
    match value
        .get("skillOverrides")
        .and_then(|values| values.get(name))
        .and_then(Value::as_str)
    {
        None => Some(None),
        Some("off") => Some(Some(false)),
        Some("on" | "name-only" | "user-invocable-only") => Some(Some(true)),
        Some(_) => None,
    }
}

fn visibility(value: &Value, name: &str) -> Option<bool> {
    Some(override_visibility(value, name)?.unwrap_or(true))
}

pub(super) fn set_enabled(
    request: &Request,
    home: &Path,
    claude: &Path,
    cancelled: &dyn Fn() -> bool,
) -> Result<Value, Error> {
    let enabled = request
        .enabled
        .ok_or_else(|| Error::Invalid("Choose whether to enable the skill.".into()))?;
    let path = request
        .source
        .as_deref()
        .filter(|path| path.is_absolute())
        .ok_or_else(|| Error::Invalid("Choose a skill document.".into()))?;
    if request.agent_id == "codex-acp" {
        let cli = environment::detect_tool("codex", cancelled).ok_or(Error::MissingCLI)?;
        check(cancelled)?;
        let cwd = request.workspace.as_deref().unwrap_or(home);
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|_| failed())?;
        let value = runtime.block_on(CodexHistory::set_skill_enabled(
            cli.path,
            cwd.to_owned(),
            path.to_owned(),
            enabled,
            request.codex_home.clone(),
            cancelled,
        ));
        check(cancelled)?;
        let listing = parse_codex(&value.map_err(|_| Error::Failed("Codex skill settings could not be confirmed. Refresh to check the current state.".into()))?, cwd)?;
        if !listing
            .skills
            .iter()
            .any(|skill| same_path(&skill.path, path) && skill.enabled == Some(enabled))
        {
            return Err(Error::Failed("The Agent did not apply the skill setting. Refresh and check project or managed configuration.".into()));
        }
        return listing_value(listing, request, home, claude);
    }
    let mut listing = files::claude_inventory(request.workspace.as_deref(), claude, cancelled)?;
    let discovery_issue_count = listing.issues.len();
    annotate(&mut listing, request.workspace.as_deref(), claude);
    let skill = listing
        .skills
        .iter()
        .find(|skill| {
            same_path(&skill.path, path) && Some(skill.scope.as_str()) == request.scope.as_deref()
        })
        .ok_or_else(|| {
            Error::Invalid(
                "The skill is no longer available in this scope. Refresh and retry.".into(),
            )
        })?;
    if skill.enabled.is_none() {
        return Err(failed());
    }
    // SkillOverrides keys are names. Duplicate names in the same scope share one setting.
    if skill.name.contains(':') {
        return Err(Error::Invalid(
            "Claude plugin skills must be managed through Claude's plugin settings.".into(),
        ));
    }
    let target = if skill.scope == "repo" {
        request
            .workspace
            .as_ref()
            .ok_or_else(failed)?
            .join(".claude/settings.local.json")
    } else {
        claude.join("settings.json")
    };
    write_override(&target, &skill.name, enabled, cancelled)?;
    listing.issues.truncate(discovery_issue_count);
    annotate(&mut listing, request.workspace.as_deref(), claude);
    if !listing
        .skills
        .iter()
        .any(|skill| same_path(&skill.path, path) && skill.enabled == Some(enabled))
    {
        return Err(Error::Failed("The Agent did not apply the skill setting. Refresh and check project or managed configuration.".into()));
    }
    listing_value(listing, request, home, claude)
}

fn options() -> OpenOptions {
    let mut options = OpenOptions::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .mode(0o600);
    }
    options
}

fn snapshot(path: &Path) -> Result<Option<Vec<u8>>, Error> {
    let file = match options().read(true).open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(failed()),
    };
    if !file.metadata().map_err(|_| failed())?.is_file()
        || fs::symlink_metadata(path)
            .map_err(|_| failed())?
            .file_type()
            .is_symlink()
    {
        return Err(failed());
    }
    let mut bytes = vec![];
    file.take(MAX_SETTINGS_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| failed())?;
    if bytes.len() as u64 > MAX_SETTINGS_BYTES {
        return Err(failed());
    }
    Ok(Some(bytes))
}

fn parse(bytes: Option<&[u8]>) -> Result<Value, Error> {
    let value: Value = match bytes {
        Some(bytes) => serde_json::from_slice(bytes).map_err(|_| failed())?,
        None => json!({}),
    };
    if !value.is_object() {
        return Err(failed());
    }
    if let Some(overrides) = value.get("skillOverrides") {
        if !overrides.is_object()
            || !overrides.as_object().unwrap().values().all(|value| {
                matches!(
                    value.as_str(),
                    Some("on" | "off" | "name-only" | "user-invocable-only")
                )
            })
        {
            return Err(failed());
        }
    }
    Ok(value)
}

fn load(path: &Path) -> Result<Value, Error> {
    parse(snapshot(path)?.as_deref())
}

struct Temporary(PathBuf);
impl Drop for Temporary {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_file(&self.0) {
            if error.kind() != std::io::ErrorKind::NotFound {
                eprintln!("Skill settings staging cleanup failed: {error}");
            }
        }
    }
}

pub(super) fn write_override(
    path: &Path,
    name: &str,
    enabled: bool,
    cancelled: &dyn Fn() -> bool,
) -> Result<(), Error> {
    let parent = path.parent().ok_or_else(failed)?;
    // Reject linked parents before writing, including a linked .claude directory.
    let mut ancestors: Vec<_> = parent.ancestors().collect();
    ancestors.reverse();
    for ancestor in ancestors {
        if !ancestor.exists() {
            fs::create_dir(ancestor).map_err(|_| failed())?;
        }
        let metadata = fs::symlink_metadata(ancestor).map_err(|_| failed())?;
        // macOS /var is a system link; resolve existing ancestors, but the actual
        // settings directory itself must remain a regular native directory.
        if !ancestor.is_dir() || (ancestor == parent && metadata.file_type().is_symlink()) {
            return Err(failed());
        }
    }
    let lock_path = parent.join(".lithe-skill-settings.lock");
    let lock = options()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&lock_path)
        .map_err(|_| failed())?;
    if !lock.metadata().map_err(|_| failed())?.is_file()
        || fs::symlink_metadata(&lock_path)
            .map_err(|_| failed())?
            .file_type()
            .is_symlink()
    {
        return Err(failed());
    }
    // Nonblocking lock serializes Lithe windows; native/editor changes are
    // checked against the exact input snapshot before atomic publication.
    lock.try_lock_exclusive().map_err(|_| {
        Error::Failed("Skill settings are busy. Retry after the other change finishes.".into())
    })?;
    let before = snapshot(path)?;
    let mut value = parse(before.as_deref())?;
    value
        .as_object_mut()
        .ok_or_else(failed)?
        .entry("skillOverrides")
        .or_insert_with(|| json!({}))[name] = json!(if enabled { "on" } else { "off" });
    let mut bytes = serde_json::to_vec_pretty(&value).map_err(|_| failed())?;
    bytes.push(b'\n');
    if bytes.len() as u64 > MAX_SETTINGS_BYTES {
        return Err(failed());
    }
    check(cancelled)?;
    let staging = Temporary(parent.join(format!(".lithe-skill-settings-{}", uuid::Uuid::new_v4())));
    let mut file = options()
        .write(true)
        .create_new(true)
        .open(&staging.0)
        .map_err(|_| failed())?;
    if let Ok(metadata) = fs::metadata(path) {
        file.set_permissions(metadata.permissions())
            .map_err(|_| failed())?;
    }
    file.write_all(&bytes)
        .and_then(|_| file.sync_all())
        .map_err(|_| failed())?;
    drop(file);
    check(cancelled)?;
    if snapshot(path)? != before {
        return Err(Error::Failed(
            "Skill settings changed elsewhere. Refresh and retry.".into(),
        ));
    }
    fs::rename(&staging.0, path).map_err(|_| failed())?;
    Ok(())
}
