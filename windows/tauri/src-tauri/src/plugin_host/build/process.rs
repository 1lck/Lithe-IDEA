//! Bounded native process adapter. Job Object ownership, pipe draining and
//! tree termination stay in lithe_git_host, shared with the launch path.

use super::operation::{
    BuildProcessExecutor, BuildProcessOutput, BuildProcessPlan, BuildRunProcessOutput,
    ModelExecutionGuard, MODEL_OUTPUT_LIMIT,
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

/// `lithe_git_host` invokes its started hook after the child is resumed.
/// Freeze report freshness before entering that runner, so even an immediate
/// child report belongs to this run. The hook only records successful spawn.
pub(super) struct ProcessStart {
    before_spawn_millis: Option<u64>,
    started: Cell<bool>,
}
impl ProcessStart {
    pub fn capture(clock: impl FnOnce() -> Option<u64>) -> Self {
        Self {
            before_spawn_millis: clock(),
            started: Cell::new(false),
        }
    }
    pub fn mark_started(&self) {
        self.started.set(true);
    }
    pub fn started(&self) -> bool {
        self.started.get()
    }
    pub fn started_at_millis(&self) -> Option<u64> {
        self.started().then_some(self.before_spawn_millis).flatten()
    }
}

impl BuildProcessExecutor for NativeBuildExecutor {
    fn run(
        &self,
        plan: &BuildProcessPlan,
        guard: &dyn ModelExecutionGuard,
    ) -> Result<BuildProcessOutput, String> {
        let (output, result) = capture_process(plan, guard, &mut |_, _| Ok(()));
        if let Some(error) = result.failure {
            return Err(error);
        }
        if result.exit_code != Some(0) {
            return Err(process_failure(
                "unsuccessful exit",
                &output.stdout,
                &output.stderr,
            ));
        }
        Ok(output)
    }

    fn run_command(
        &self,
        plan: &BuildProcessPlan,
        guard: &dyn ModelExecutionGuard,
        output: &mut dyn FnMut(lithe_git_host::Stream, &[u8]) -> Result<(), String>,
    ) -> BuildRunProcessOutput {
        capture_process(plan, guard, output).1
    }
}

/// Both model probes and explicit runs use the same frozen argv/environment,
/// budgets, native Job Object and cleanup/error precedence.
fn capture_process(
    plan: &BuildProcessPlan,
    guard: &dyn ModelExecutionGuard,
    output: &mut dyn FnMut(lithe_git_host::Stream, &[u8]) -> Result<(), String>,
) -> (BuildProcessOutput, BuildRunProcessOutput) {
    let empty = |error: String| {
        (
            BuildProcessOutput {
                stdout: vec![],
                stderr: vec![],
            },
            BuildRunProcessOutput {
                exit_code: None,
                started: false,
                failure: Some(error),
                started_at_millis: None,
            },
        )
    };
    if let Err(error) = guard.checkpoint() {
        return empty(error);
    }
    if !plan.executable.is_absolute() || !plan.directory.is_absolute() {
        return empty("plugin.build.invalidPlan".into());
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
    let start_permit = match guard.start_permit() {
        Ok(permit) => RefCell::new(Some(permit)),
        Err(error) => return empty(error),
    };
    let start = ProcessStart::capture(|| {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .ok()
            .and_then(|time| u64::try_from(time.as_millis()).ok())
    });
    let stream_failure = RefCell::new(None::<String>);
    let outcome = lithe_git_host::run(
        &mut command,
        None,
        || {
            if let Some(path) = &plan.output_file {
                output_file_invalid.set(validate_output_file(path).is_err());
            }
            exceeded()
                || stream_failure.borrow().is_some()
                || output_file_invalid.get()
                || Instant::now() >= deadline
                || guard.cancelled()
        },
        || {
            start.mark_started();
            drop(start_permit.borrow_mut().take());
        },
        |stream, bytes| {
            let count = match stream {
                lithe_git_host::Stream::Stdout => &stdout_bytes,
                lithe_git_host::Stream::Stderr => &stderr_bytes,
            };
            count.set(count.get().saturating_add(bytes.len()));
            if !exceeded() && stream_failure.borrow().is_none() {
                if let Err(error) = output(stream, bytes) {
                    *stream_failure.borrow_mut() = Some(error);
                }
            }
        },
    );
    // Spawn failure has no started hook. Never publish success merely because
    // the parent process exited.
    drop(start_permit);
    let failure = if matches!(
        outcome.failure.as_ref(),
        Some(lithe_git_host::Failure::Cleanup)
    ) {
        Some("plugin.build.cleanupFailed".into())
    } else if let Some(error) = stream_failure.into_inner() {
        Some(error)
    } else if exceeded()
        || output_file_invalid.get()
        || matches!(
            outcome.failure.as_ref(),
            Some(lithe_git_host::Failure::OutputLimit)
        )
    {
        Some("plugin.build.outputLimit".into())
    } else if Instant::now() >= deadline {
        Some("plugin.build.timeout".into())
    } else if let Err(error) = guard.checkpoint() {
        Some(error)
    } else if let Some(failure) = outcome.failure {
        Some(process_failure(
            &format!("{failure:?}"),
            &outcome.stdout,
            &outcome.stderr,
        ))
    } else if let Some(path) = &plan.output_file {
        validate_output_file(path).err()
    } else {
        None
    };
    let result = BuildRunProcessOutput {
        exit_code: outcome.status.and_then(|status| status.code()),
        started: start.started(),
        failure,
        started_at_millis: start.started_at_millis(),
    };
    (
        BuildProcessOutput {
            stdout: outcome.stdout,
            stderr: outcome.stderr,
        },
        result,
    )
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
