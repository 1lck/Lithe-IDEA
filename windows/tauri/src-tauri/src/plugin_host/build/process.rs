//! Bounded native process adapter. Job Object ownership, pipe draining and
//! tree termination stay in lithe_git_host, shared with the launch path.

use super::operation::{
    BuildProcessExecutor, BuildProcessOutput, BuildProcessPlan, ModelExecutionGuard,
    MODEL_OUTPUT_LIMIT,
};
use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::time::Instant;

const FAILURE_STREAM_BYTES: usize = 4096;

/// Preserve actionable process diagnostics using the existing shared secret
/// redaction policy. Input, retained text and regex work are independently
/// bounded; a failure never returns an environment snapshot or raw output.
pub(super) fn process_failure(reason: &str, stdout: &[u8], stderr: &[u8]) -> String {
    fn detail(bytes: &[u8]) -> String {
        // Keep lookahead for a quoted secret spanning the display boundary.
        let captured = String::from_utf8_lossy(&bytes[..bytes.len().min(16 * 1024)]);
        let redacted = lithe_core::diagnostics::logging::sanitize_log_text(&captured);
        let mut end = redacted.len().min(FAILURE_STREAM_BYTES);
        while !redacted.is_char_boundary(end) {
            end -= 1;
        }
        let mut value = redacted[..end].to_string();
        if end < redacted.len() || bytes.len() > 16 * 1024 {
            value.push_str("…[truncated]");
        }
        value
    }
    let mut message = format!("plugin.build.processFailed: {}", detail(reason.as_bytes()));
    for (name, bytes) in [("stderr", stderr), ("stdout", stdout)] {
        if !bytes.is_empty() {
            message.push_str(&format!("\n{name}: {}", detail(bytes)));
        }
    }
    message
}

pub(super) struct NativeBuildExecutor;
impl BuildProcessExecutor for NativeBuildExecutor {
    fn run(
        &self,
        plan: &BuildProcessPlan,
        guard: &dyn ModelExecutionGuard,
    ) -> Result<BuildProcessOutput, String> {
        guard.checkpoint()?;
        if !plan.executable.is_absolute() || !plan.directory.is_absolute() {
            return Err("plugin.build.invalidPlan: executable and cwd must be absolute".into());
        }
        let mut command = std::process::Command::new(&plan.executable);
        command
            .args(&plan.arguments)
            .current_dir(&plan.directory)
            .env_clear()
            .envs(&plan.environment);
        let deadline = Instant::now() + plan.timeout;
        let stdout_bytes = Cell::new(0usize);
        let stderr_bytes = Cell::new(0usize);
        let output_file_invalid = Cell::new(false);
        let exceeded =
            || stdout_bytes.get() > plan.output_limit || stderr_bytes.get() > plan.output_limit;
        let start_permit = RefCell::new(Some(guard.start_permit()?));
        let outcome = lithe_git_host::run(
            &mut command,
            None,
            || {
                if let Some(path) = &plan.output_file {
                    output_file_invalid.set(validate_output_file(path).is_err());
                }
                exceeded()
                    || output_file_invalid.get()
                    || Instant::now() >= deadline
                    || guard.cancelled()
            },
            || {
                drop(start_permit.borrow_mut().take());
            },
            |stream, bytes| {
                let count = match stream {
                    lithe_git_host::Stream::Stdout => &stdout_bytes,
                    lithe_git_host::Stream::Stderr => &stderr_bytes,
                };
                count.set(count.get().saturating_add(bytes.len()));
            },
        );
        drop(start_permit); // spawn failure has no started hook
                            // The shared executor returns only after bounded process-tree cleanup.
                            // Never publish success merely because the parent process exited.
        if matches!(
            outcome.failure.as_ref(),
            Some(lithe_git_host::Failure::Cleanup)
        ) {
            return Err("plugin.build.cleanupFailed: process tree did not drain".into());
        }
        guard.checkpoint()?;
        if exceeded()
            || output_file_invalid.get()
            || matches!(
                outcome.failure.as_ref(),
                Some(lithe_git_host::Failure::OutputLimit)
            )
        {
            return Err("plugin.build.outputLimit".into());
        }
        if Instant::now() >= deadline {
            return Err("plugin.build.timeout".into());
        }
        if let Some(failure) = outcome.failure {
            return Err(process_failure(
                &format!("{failure:?}"),
                &outcome.stdout,
                &outcome.stderr,
            ));
        }
        if outcome.status.is_none_or(|status| !status.success()) {
            return Err(process_failure(
                &format!("unsuccessful exit ({:?})", outcome.status),
                &outcome.stdout,
                &outcome.stderr,
            ));
        }
        if let Some(path) = &plan.output_file {
            validate_output_file(path)?;
        }
        Ok(BuildProcessOutput {
            stdout: outcome.stdout,
            stderr: outcome.stderr,
        })
    }
}

pub(super) fn validate_output_file(path: &Path) -> Result<(), String> {
    let metadata = std::fs::symlink_metadata(path)
        .map_err(|_| "plugin.build.invalidOutput: output file is missing")?;
    #[cfg(windows)]
    let linked = {
        use std::os::windows::fs::MetadataExt;
        metadata.file_attributes() & 0x0400 != 0
    };
    #[cfg(not(windows))]
    let linked = metadata.file_type().is_symlink();
    if linked || !metadata.is_file() {
        return Err("plugin.build.invalidOutput: output must be a regular file".into());
    }
    if metadata.len() > MODEL_OUTPUT_LIMIT as u64 {
        return Err("plugin.build.outputLimit".into());
    }
    Ok(())
}

fn validate_output_parent(path: &Path) -> Result<(), String> {
    if !path.is_absolute() {
        return Err("plugin.build.invalidOutput: output path must be absolute".into());
    }
    for directory in path
        .parent()
        .ok_or("invalid model output path")?
        .ancestors()
    {
        let metadata = std::fs::symlink_metadata(directory).map_err(|error| error.to_string())?;
        #[cfg(windows)]
        let linked = {
            use std::os::windows::fs::MetadataExt;
            metadata.file_attributes() & 0x0400 != 0
        };
        #[cfg(not(windows))]
        let linked = metadata.file_type().is_symlink();
        if linked || !metadata.is_dir() {
            return Err("plugin.build.invalidOutput: output directory crosses a link".into());
        }
    }
    Ok(())
}

/// A fresh file inside the already-owned plugin state directory, never in a
/// package or installation. There is no reusable cache or new resource root.
/// One operation removes its own file after tree cleanup, including failures;
/// a crash leaves only per-user plugin state, removed with plugin uninstall.
pub(super) struct ModelOutputFile {
    path: PathBuf,
}
impl ModelOutputFile {
    pub fn create(path: &Path) -> Result<Self, String> {
        if !path.is_absolute() {
            return Err("plugin.build.invalidOutput: output path must be absolute".into());
        }
        let parent = path.parent().ok_or("invalid model output path")?;
        // Validate existing ancestors before create_dir_all can traverse a
        // redirected plugin-state path, then verify the newly made chain.
        for directory in parent.ancestors() {
            match std::fs::symlink_metadata(directory) {
                Ok(_) => {
                    validate_output_parent(&directory.join("model-output"))?;
                    break;
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => return Err(error.to_string()),
            }
        }
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        // The storage adapter supplies this path. Reject redirected state
        // before creating a file so no write can enter distribution resources.
        validate_output_parent(path)?;
        let file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)
            .map_err(|error| format!("model output allocation failed: {error}"))?;
        drop(file);
        Ok(Self { path: path.into() })
    }
}
impl Drop for ModelOutputFile {
    fn drop(&mut self) {
        if let Err(error) = std::fs::remove_file(&self.path) {
            if error.kind() != std::io::ErrorKind::NotFound {
                eprintln!("model output cleanup failed: {error}");
            }
        }
    }
}
