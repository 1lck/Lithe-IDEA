//! Windows-owned filesystem transaction for an already validated Core plan.
use serde_json::Value;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Component, Path, PathBuf};
use std::time::Instant;

use super::{Error, Result};

const MAX_ENTRIES: usize = 20_000;
const MAX_BYTES: u64 = 512 * 1024 * 1024;
const MAX_DEPTH: usize = 64;

pub(super) fn component(value: &str) -> Result<()> {
    let base = value.split('.').next().unwrap_or("").to_ascii_uppercase();
    if value.is_empty()
        || value == "."
        || value == ".."
        || value.ends_with(['.', ' '])
        || value
            .chars()
            .any(|ch| ch.is_control() || "<>:\"/\\|?*".contains(ch))
        || matches!(
            base.as_str(),
            "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
        )
        || ["COM", "LPT"].iter().any(|prefix| {
            base.strip_prefix(prefix).is_some_and(|n| {
                matches!(
                    n,
                    "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"
                )
            })
        })
    {
        return Err(Error::new("generator.invalidPath"));
    }
    Ok(())
}

pub(super) fn relative(value: &str) -> Result<PathBuf> {
    if value.is_empty() || value.contains('\\') {
        return Err(Error::new("generator.invalidPath"));
    }
    let mut path = PathBuf::new();
    for part in value.split('/') {
        component(part)?;
        path.push(part);
    }
    Ok(path)
}

fn metadata(path: &Path) -> Result<std::fs::Metadata> {
    let info = fs::symlink_metadata(path).map_err(Error::io)?;
    if info.file_type().is_symlink() {
        return Err(Error::new("generator.linkRejected"));
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if info.file_attributes() & 0x400 != 0 {
            return Err(Error::new("generator.linkRejected"));
        }
        if info.is_file() {
            use std::os::windows::io::AsRawHandle;
            use windows_sys::Win32::Storage::FileSystem::{
                GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION,
            };
            let file = File::open(path).map_err(Error::io)?;
            let mut information = std::mem::MaybeUninit::<BY_HANDLE_FILE_INFORMATION>::uninit();
            if unsafe { GetFileInformationByHandle(file.as_raw_handle(), information.as_mut_ptr()) }
                == 0
            {
                return Err(Error::io(std::io::Error::last_os_error()));
            }
            if unsafe { information.assume_init() }.nNumberOfLinks != 1 {
                return Err(Error::new("generator.linkRejected"));
            }
        }
    }
    Ok(info)
}

pub(super) struct Parent {
    pub path: PathBuf,
    identity: same_file::Handle,
}
impl Parent {
    pub fn open(path: &Path) -> Result<Self> {
        if !path.is_absolute() {
            return Err(Error::new("generator.invalidPath"));
        }
        let mut current = PathBuf::new();
        for part in path.components() {
            match part {
                Component::Prefix(_) | Component::RootDir => current.push(part.as_os_str()),
                Component::Normal(_) => {
                    current.push(part);
                    metadata(&current)?;
                }
                _ => return Err(Error::new("generator.invalidPath")),
            }
        }
        if !metadata(path)?.is_dir() {
            return Err(Error::new("generator.invalidPath"));
        }
        let path = fs::canonicalize(path).map_err(Error::io)?;
        let identity = same_file::Handle::from_path(&path).map_err(Error::io)?;
        Ok(Self { path, identity })
    }
    pub fn check(&self) -> Result<()> {
        self.reopen().map(|_| ())
    }
    pub fn reopen(&self) -> Result<Self> {
        let parent = Self::open(&self.path)?;
        if parent.identity != self.identity {
            return Err(Error::new("generator.stale"));
        }
        Ok(parent)
    }
}

pub(super) fn absent(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(Error::io(error)),
        Ok(_) => Err(Error::new("generator.destinationExists")),
    }
}

pub(super) struct Transaction {
    pub stage: PathBuf,
    target: PathBuf,
    parent: Parent,
    identity: same_file::Handle,
    published: bool,
}
impl Transaction {
    pub fn create(parent: Parent, name: &str, token: &str) -> Result<Self> {
        component(name)?;
        component(token)?;
        parent.check()?;
        let target = parent.path.join(name);
        absent(&target)?;
        let stage = parent.path.join(format!(".{name}.lithe-creating-{token}"));
        fs::create_dir(&stage).map_err(Error::io)?;
        let identity = match same_file::Handle::from_path(&stage) {
            Ok(identity) => identity,
            Err(error) => {
                fs::remove_dir(&stage).map_err(|_| Error::new("generator.cleanupFailed"))?;
                return Err(Error::io(error));
            }
        };
        Ok(Self {
            stage,
            target,
            parent,
            identity,
            published: false,
        })
    }
    pub fn check(&self) -> Result<()> {
        self.parent.check()?;
        if !metadata(&self.stage)?.is_dir()
            || same_file::Handle::from_path(&self.stage).map_err(Error::io)? != self.identity
        {
            return Err(Error::new("generator.stale"));
        }
        Ok(())
    }
    pub fn write(&self, path: &str, bytes: &[u8]) -> Result<()> {
        self.check()?;
        let relative = relative(path)?;
        let mut current = self.stage.clone();
        let parts: Vec<_> = relative.components().collect();
        for part in &parts[..parts.len() - 1] {
            current.push(part);
            match fs::create_dir(&current) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    if !metadata(&current)?.is_dir() {
                        return Err(Error::new("generator.invalidPath"));
                    }
                }
                Err(error) => return Err(Error::io(error)),
            }
        }
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(self.stage.join(relative))
            .map_err(Error::io)?;
        file.write_all(bytes).map_err(Error::io)?;
        file.sync_all().map_err(Error::io)
    }
    pub fn validate(&self, checkpoint: &dyn Fn() -> Result<()>) -> Result<()> {
        self.check()?;
        let mut pending = vec![(self.stage.clone(), 0)];
        let (mut count, mut bytes) = (0usize, 0u64);
        while let Some((directory, depth)) = pending.pop() {
            checkpoint()?;
            if depth > MAX_DEPTH {
                return Err(Error::new("generator.outputLimit"));
            }
            for entry in fs::read_dir(directory).map_err(Error::io)? {
                checkpoint()?;
                let entry = entry.map_err(Error::io)?;
                component(
                    entry
                        .file_name()
                        .to_str()
                        .ok_or_else(|| Error::new("generator.invalidPath"))?,
                )?;
                count += 1;
                let info = metadata(&entry.path())?;
                bytes = bytes
                    .checked_add(info.len())
                    .ok_or_else(|| Error::new("generator.outputLimit"))?;
                if count > MAX_ENTRIES || bytes > MAX_BYTES {
                    return Err(Error::new("generator.outputLimit"));
                }
                if info.is_dir() {
                    pending.push((entry.path(), depth + 1));
                } else if !info.is_file() {
                    return Err(Error::new("generator.linkRejected"));
                }
            }
        }
        Ok(())
    }
    pub fn collect(&self, path: &str, checkpoint: &dyn Fn() -> Result<()>) -> Result<()> {
        self.validate(checkpoint)?;
        let source = self.stage.join(relative(path)?);
        if !metadata(&source)?.is_dir() {
            return Err(Error::new("generator.invalidPath"));
        }
        for entry in fs::read_dir(&source).map_err(Error::io)? {
            checkpoint()?;
            let entry = entry.map_err(Error::io)?;
            let destination = self.stage.join(entry.file_name());
            // Windows' existing no-replace primitive also handles directories.
            crate::file_publication::publish_new_record(&entry.path(), &destination)
                .map_err(Error::io)?;
        }
        fs::remove_dir(source).map_err(Error::io)
    }
    pub fn publish(&mut self, checkpoint: &dyn Fn() -> Result<()>) -> Result<PathBuf> {
        // All writers must have exited and the caller must validate their tree
        // before taking the short cancellation/publication ordering lock.
        self.check()?;
        checkpoint()?;
        absent(&self.target)?;
        crate::file_publication::publish_new_record(&self.stage, &self.target)
            .map_err(Error::io)?;
        self.published = true;
        Ok(self.target.clone())
    }
    pub fn cleanup(&self) -> Result<()> {
        if self.published {
            return Ok(());
        }
        self.check()
            .map_err(|_| Error::new("generator.cleanupFailed"))?;
        fs::remove_dir_all(&self.stage).map_err(|_| Error::new("generator.cleanupFailed"))?;
        absent(&self.stage).map_err(|_| Error::new("generator.cleanupFailed"))
    }
}

pub(super) trait Executor {
    fn command(
        &self,
        index: usize,
        step: &Value,
        stage: &Path,
        deadline: Instant,
        checkpoint: &dyn Fn() -> Result<()>,
    ) -> Result<()>;
}

pub(super) fn execute(
    transaction: &mut Transaction,
    plan: &Value,
    executor: &dyn Executor,
    deadline: Instant,
    checkpoint: &dyn Fn() -> Result<()>,
) -> Result<PathBuf> {
    let steps = plan["steps"]
        .as_array()
        .ok_or_else(|| Error::new("generator.invalidPlan"))?;
    // Unsupported downloads must fail before creating or running any step.
    if steps.iter().any(|step| step["kind"] == "archive") {
        return Err(Error::new("generator.archiveUnavailable"));
    }
    for (index, step) in steps.iter().enumerate() {
        checkpoint()?;
        transaction.check()?;
        match step["kind"].as_str() {
            Some("writeFiles") => {
                for file in step["files"]
                    .as_array()
                    .ok_or_else(|| Error::new("generator.invalidPlan"))?
                {
                    checkpoint()?;
                    transaction.write(
                        file["path"]
                            .as_str()
                            .ok_or_else(|| Error::new("generator.invalidPlan"))?,
                        file["contents"]
                            .as_str()
                            .ok_or_else(|| Error::new("generator.invalidPlan"))?
                            .as_bytes(),
                    )?;
                }
            }
            Some("command") => {
                executor.command(index, step, &transaction.stage, deadline, checkpoint)?;
                transaction.validate(checkpoint)?;
                if let Some(collect) = step["collect"].as_str() {
                    transaction.collect(collect, checkpoint)?;
                }
            }
            _ => return Err(Error::new("generator.invalidPlan")),
        }
    }
    transaction.validate(checkpoint)?;
    Ok(transaction.stage.clone())
}
