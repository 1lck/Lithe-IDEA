//! Executes the existing Git engine's invocations on its request-scoped host.

use super::{execution_events, execution_policy, GitProcessOutput};
use crate::protocol::{CoreError, ErrorCode};
use crate::remote::{workspace, workspace_host};
use lithe_remote_protocol::methods::{self, EnvironmentSource, OutputStream, SpawnParams};
use std::collections::BTreeMap;
use std::path::Path;
use std::time::Duration;

const MAX_CAPTURE_BYTES: usize = 32 * 1024 * 1024;

/// Returns `None` only for a local workspace; remote failures never run local Git.
pub(super) fn capture(
    root: &str,
    arguments: &[String],
    input: Option<&str>,
    disable_optional_locks: bool,
    environment: &[(String, String)],
    visible: bool,
) -> Option<Result<GitProcessOutput, CoreError>> {
    workspace::current().map(|host| {
        let session = &host.connection.session;
        let params = parameters(
            &host,
            root,
            arguments,
            input.is_some(),
            disable_optional_locks,
            environment,
        )?;
        let executable = params.argv.first().cloned();
        let mut invocation = visible
            .then(execution_events::Invocation::current)
            .flatten();
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        let result = workspace_host::process_observing(
            session,
            params,
            input.map(str::as_bytes),
            &mut |event| {
                match event.event.as_str() {
                    "process.started" => {
                        if let Some(invocation) = &invocation {
                            invocation.started_on_host(root, arguments, executable.clone());
                        }
                    }
                    methods::EVENT_PROCESS_OUTPUT => {
                        let event: methods::ProcessOutputEvent =
                            event.decode().map_err(|error| {
                                CoreError::new(ErrorCode::ParseFailed, "Invalid remote Git output")
                                    .with_details(error.to_string())
                            })?;
                        let bytes = methods::decode_bytes(&event.data).map_err(|error| {
                            CoreError::new(
                                ErrorCode::ParseFailed,
                                "Invalid remote Git output bytes",
                            )
                            .with_details(error.to_string())
                        })?;
                        let target = if event.stream == OutputStream::Stdout {
                            &mut stdout
                        } else {
                            &mut stderr
                        };
                        if target.len() + bytes.len() > MAX_CAPTURE_BYTES {
                            return Err(CoreError::new(
                                ErrorCode::ProcessFailed,
                                "Git output exceeded the capture limit",
                            ));
                        }
                        target.extend_from_slice(&bytes);
                        if let Some(invocation) = &mut invocation {
                            invocation.output(
                                if event.stream == OutputStream::Stdout {
                                    lithe_git_host::Stream::Stdout
                                } else {
                                    lithe_git_host::Stream::Stderr
                                },
                                &bytes,
                            );
                        }
                    }
                    _ => {}
                }
                Ok(())
            },
        );
        let exit = result
            .as_ref()
            .ok()
            .and_then(|value| value["exitCode"].as_i64())
            .and_then(|code| i32::try_from(code).ok());
        if let Some(invocation) = invocation {
            let expected = !visible
                && exit == Some(1)
                && result.is_ok()
                && execution_policy::command_index(arguments)
                    .is_some_and(|index| arguments[index] == "config");
            invocation.finished_with_expected_exit(exit, result.as_ref().err(), expected);
        }
        result?;
        Ok(GitProcessOutput {
            stdout,
            stderr,
            exit_code: exit.unwrap_or(1),
        })
    })
}

/// Builds host-native argv and environment without exporting client executable paths.
pub(super) fn parameters(
    host: &workspace::Host,
    root: &str,
    arguments: &[String],
    pipe_stdin: bool,
    disable_optional_locks: bool,
    environment: &[(String, String)],
) -> Result<SpawnParams, CoreError> {
    let result = workspace_host::request_cancellable(
        &host.connection.session,
        methods::ENVIRONMENT_RESOLVE,
        serde_json::json!({}),
        Duration::from_secs(60),
    );
    crate::protocol::cancellation::check()?;
    let resolved: methods::EnvironmentResolveResult =
        serde_json::from_value(result.map_err(|error| {
            CoreError::new(
                ErrorCode::ProcessStartFailed,
                "Could not resolve the remote login environment",
            )
            .with_details(error.to_string())
        })?)
        .map_err(|error| {
            CoreError::new(ErrorCode::ParseFailed, "Invalid remote login environment")
                .with_details(error.to_string())
        })?;
    let mut env = BTreeMap::new();
    if disable_optional_locks {
        env.insert("GIT_OPTIONAL_LOCKS".into(), "0".into());
    }
    for (key, value) in environment {
        // These paths are generated by the Git engine in workspace URL identity.
        let value = if matches!(
            key.as_str(),
            "GIT_DIR"
                | "GIT_COMMON_DIR"
                | "GIT_WORK_TREE"
                | "GIT_INDEX_FILE"
                | "LITHE_REBASE_DIR"
                | "LITHE_REBASE_TODO"
                | "LITHE_REBASE_MESSAGES"
        ) {
            host.remote_path(Path::new(value))
                .to_string_lossy()
                .into_owned()
        } else {
            value.clone()
        };
        env.insert(key.clone(), value);
    }
    if execution_policy::command_index(arguments).is_some_and(|index| arguments[index] != "config")
    {
        let inherited = resolved
            .environment
            .get("GIT_CONFIG_COUNT")
            .map(String::as_str)
            .unwrap_or("0")
            .parse::<usize>()
            .ok()
            .filter(|count| *count <= 4096)
            .ok_or_else(|| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid remote Git configuration count",
                )
            })?;
        let values = execution_policy::temporary_config();
        for (offset, (key, value)) in values.iter().enumerate() {
            env.insert(
                format!("GIT_CONFIG_KEY_{}", inherited + offset),
                key.clone(),
            );
            env.insert(
                format!("GIT_CONFIG_VALUE_{}", inherited + offset),
                value.clone(),
            );
        }
        env.insert(
            "GIT_CONFIG_COUNT".into(),
            (inherited + values.len()).to_string(),
        );
    }
    env.insert("GIT_PAGER".into(), "cat".into());
    env.insert("LC_ALL".into(), "C".into());
    env.insert("GIT_TERMINAL_PROMPT".into(), "0".into());
    // The remote credential helper/SSH agent owns authentication until the
    // host AskPass relay is installed; never export the local helper path.
    let executable = remote_git_executable(host, &resolved)?;
    let mut argv = vec![executable];
    argv.extend_from_slice(arguments);
    Ok(SpawnParams {
        process_id: 0,
        argv,
        cwd: Some(
            host.remote_path(Path::new(root))
                .to_string_lossy()
                .into_owned(),
        ),
        environment: EnvironmentSource::Login,
        env,
        pipe_stdin,
    })
}

fn remote_git_executable(
    host: &workspace::Host,
    environment: &methods::EnvironmentResolveResult,
) -> Result<String, CoreError> {
    if let Some((executable, _)) = host
        .connection
        .git_tool
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .as_ref()
    {
        return Ok(executable.clone());
    }
    let path = environment
        .environment
        .get("PATH")
        .map(String::as_str)
        .unwrap_or("");
    for directory in path
        .split(':')
        .filter(|directory| directory.starts_with('/'))
    {
        let candidate = format!("{}/git", directory.trim_end_matches('/'));
        let result = workspace_host::request_cancellable(
            &host.connection.session,
            methods::FS_STAT,
            serde_json::json!({"path": candidate}),
            Duration::from_secs(30),
        );
        crate::protocol::cancellation::check()?;
        let metadata = match result {
            Ok(value) => {
                serde_json::from_value::<methods::FileMetadata>(value).map_err(|error| {
                    CoreError::new(ErrorCode::ParseFailed, "Invalid remote Git metadata")
                        .with_details(error.to_string())
                })?
            }
            Err(lithe_remote_client::session::ClientError::Remote(error))
                if error.code == lithe_remote_protocol::ErrorCode::NotFound =>
            {
                continue
            }
            Err(error) => {
                return Err(CoreError::new(
                    ErrorCode::ProcessStartFailed,
                    "Could not resolve remote Git",
                )
                .with_details(error.to_string()))
            }
        };
        let regular = metadata.kind == methods::FileKind::File
            || metadata.symlink_target_kind == Some(methods::FileKind::File);
        if regular && (metadata.kind == methods::FileKind::Symlink || metadata.mode & 0o111 != 0) {
            let mut version = Vec::new();
            let result = workspace_host::process_observing(
                &host.connection.session,
                SpawnParams {
                    process_id: 0,
                    argv: vec![candidate.clone(), "--version".into()],
                    cwd: None,
                    environment: EnvironmentSource::Login,
                    env: BTreeMap::new(),
                    pipe_stdin: false,
                },
                None,
                &mut |event| {
                    if event.event == methods::EVENT_PROCESS_OUTPUT {
                        let output: methods::ProcessOutputEvent =
                            event.decode().map_err(|error| {
                                CoreError::new(ErrorCode::ParseFailed, "Invalid remote Git version")
                                    .with_details(error.to_string())
                            })?;
                        let bytes = methods::decode_bytes(&output.data).map_err(|error| {
                            CoreError::new(
                                ErrorCode::ParseFailed,
                                "Invalid remote Git version bytes",
                            )
                            .with_details(error.to_string())
                        })?;
                        if version.len() + bytes.len() > 4096 {
                            return Err(CoreError::new(
                                ErrorCode::ProcessFailed,
                                "Remote Git version output exceeded its limit",
                            ));
                        }
                        if output.stream == OutputStream::Stdout {
                            version.extend(bytes);
                        }
                    }
                    Ok(())
                },
            )?;
            if result["exitCode"] != 0 {
                return Err(CoreError::new(
                    ErrorCode::ProcessStartFailed,
                    "Could not inspect remote Git version",
                ));
            }
            let version = String::from_utf8_lossy(&version).trim().to_owned();
            execution_policy::validate_version(&version)?;
            *host
                .connection
                .git_tool
                .lock()
                .unwrap_or_else(|error| error.into_inner()) = Some((candidate.clone(), version));
            return Ok(candidate);
        }
    }
    Err(CoreError::new(
        ErrorCode::ProcessStartFailed,
        "Git is not available on the remote login PATH",
    ))
}
