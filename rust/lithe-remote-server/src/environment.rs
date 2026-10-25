//! The remote user's login environment.
//!
//! A command run over SSH or `docker exec` gets a minimal environment: login
//! profiles, and the files where nvm, SDKMAN, pyenv or Homebrew add
//! themselves to `PATH`, are often not read. Builds started from the IDE
//! would then fail with "command not found" although the same command works
//! in the user's terminal. The server therefore asks the user's own shell,
//! started as an interactive login shell, for the environment it ends up
//! with, and caches the answer for the session.

use crate::platform::{self, ChildKind};
use crate::session::Session;
use crate::{parse, to_value};
use lithe_remote_protocol::methods::{
    EnvironmentResolveParams, EnvironmentResolveResult, ResolvedEnvironmentSource,
};
use lithe_remote_protocol::RemoteError;
use serde_json::Value;
use std::collections::BTreeMap;
use std::io::{self, Write};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const BEGIN_MARKER: &str = "LITHE-ENVIRONMENT-BEGIN";
const END_MARKER: &str = "LITHE-ENVIRONMENT-END";

/// Bound for one shell start-up. Profiles that start `tmux`, wait for input
/// or run slow network checks hit it instead of hanging the server.
const SHELL_TIMEOUT: Duration = Duration::from_secs(10);

/// Variables that describe the resolving shell itself, not the user's
/// environment, and would be wrong in any other process.
const SHELL_LOCAL_VARIABLES: &[&str] = &["PWD", "OLDPWD", "SHLVL", "_", "TERM", "PS1", "PS2"];

#[derive(Default)]
pub(crate) struct EnvironmentCache {
    resolved: Mutex<Option<EnvironmentResolveResult>>,
    /// Serializes resolutions so concurrent spawns start one shell, not many.
    resolving: Mutex<()>,
}

impl EnvironmentCache {
    pub(crate) fn resolve(
        &self,
        session: &Arc<Session>,
        refresh: bool,
    ) -> EnvironmentResolveResult {
        let _resolving = crate::lock(&self.resolving);
        if !refresh {
            if let Some(cached) = crate::lock(&self.resolved).clone() {
                return cached;
            }
        }
        let result = resolve_uncached(session);
        *crate::lock(&self.resolved) = Some(result.clone());
        result
    }
}

pub(crate) fn handle(session: &Arc<Session>, params: Value) -> Result<Value, RemoteError> {
    let params: EnvironmentResolveParams = if params.is_null() {
        EnvironmentResolveParams::default()
    } else {
        parse(params)?
    };
    to_value(session.environment.resolve(session, params.refresh))
}

fn resolve_uncached(session: &Arc<Session>) -> EnvironmentResolveResult {
    let server_environment = || std::env::vars().collect::<BTreeMap<_, _>>();
    let account = platform::current_account();
    let Some(shell) = account.shell else {
        return EnvironmentResolveResult {
            environment: server_environment(),
            source: ResolvedEnvironmentSource::Server,
            diagnostics: Some("the account has no login shell".into()),
        };
    };
    let executable = match std::env::current_exe() {
        Ok(executable) => executable,
        Err(error) => {
            return EnvironmentResolveResult {
                environment: server_environment(),
                source: ResolvedEnvironmentSource::Server,
                diagnostics: Some(format!("cannot locate the server executable: {error}")),
            }
        }
    };
    // The shell runs our own binary to print the environment, so the result
    // does not depend on `env` flags that differ between GNU and BSD.
    let Some(script) = executable
        .to_str()
        .filter(|path| !path.contains('\''))
        .map(|path| format!("'{path}' --print-environment"))
    else {
        return EnvironmentResolveResult {
            environment: server_environment(),
            source: ResolvedEnvironmentSource::Server,
            diagnostics: Some("the server path cannot be quoted for the shell".into()),
        };
    };

    let mut diagnostics = Vec::new();
    for (flags, source) in [
        (
            &["-l", "-i", "-c"][..],
            ResolvedEnvironmentSource::InteractiveLoginShell,
        ),
        (&["-l", "-c"][..], ResolvedEnvironmentSource::LoginShell),
    ] {
        match run_shell(session, &shell, flags, &script) {
            Ok(environment) => {
                return EnvironmentResolveResult {
                    environment,
                    source,
                    diagnostics: (!diagnostics.is_empty()).then(|| diagnostics.join("; ")),
                }
            }
            Err(error) => diagnostics.push(format!("{shell} {}: {error}", flags.join(" "))),
        }
    }
    EnvironmentResolveResult {
        environment: server_environment(),
        source: ResolvedEnvironmentSource::Server,
        diagnostics: Some(diagnostics.join("; ")),
    }
}

fn run_shell(
    session: &Arc<Session>,
    shell: &str,
    flags: &[&str],
    script: &str,
) -> io::Result<BTreeMap<String, String>> {
    let mut command = Command::new(shell);
    command
        .args(flags)
        .arg(script)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    // A new session without a controlling terminal: an interactive shell
    // cannot steal the user's terminal or stop on job-control signals.
    platform::prepare_child(&mut command, ChildKind::Plain);
    let child = session.spawner.run(move || command.spawn())?;
    let (_status, stdout) = platform::collect_output(child, SHELL_TIMEOUT)?;
    parse_environment(&stdout)
        .ok_or_else(|| io::Error::other("the shell did not print an environment"))
}

/// Extracts the JSON object printed between the markers; everything else
/// the profiles printed is ignored.
fn parse_environment(output: &[u8]) -> Option<BTreeMap<String, String>> {
    let text = String::from_utf8_lossy(output);
    let (_, rest) = text.split_once(BEGIN_MARKER)?;
    let (json, _) = rest.split_once(END_MARKER)?;
    let mut environment: BTreeMap<String, String> = serde_json::from_str(json.trim()).ok()?;
    for name in SHELL_LOCAL_VARIABLES {
        environment.remove(*name);
    }
    Some(environment)
}

/// Implements `--print-environment`: the server's own environment between
/// markers, as one JSON object. Variables that are not valid UTF-8 are left
/// out because the protocol cannot carry them.
pub fn print_environment() -> io::Result<()> {
    let environment: BTreeMap<String, String> = std::env::vars_os()
        .filter_map(|(name, value)| Some((name.into_string().ok()?, value.into_string().ok()?)))
        .collect();
    let mut stdout = io::stdout().lock();
    writeln!(stdout, "{BEGIN_MARKER}")?;
    serde_json::to_writer(&mut stdout, &environment).map_err(io::Error::from)?;
    writeln!(stdout, "\n{END_MARKER}")?;
    stdout.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    // Profiles print greetings, version-manager notices and prompts around
    // the payload; only the marked object counts, minus shell-local state.
    #[test]
    fn environment_is_read_between_markers() {
        let output = b"Welcome!\nnvm: using node 20\nLITHE-ENVIRONMENT-BEGIN\n{\"PATH\":\"/home/dev/.nvm/bin:/usr/bin\",\"SHLVL\":\"2\",\"LANG\":\"C.UTF-8\"}\nLITHE-ENVIRONMENT-END\nbye\n";
        let environment = parse_environment(output).unwrap();
        assert_eq!(
            environment.get("PATH").map(String::as_str),
            Some("/home/dev/.nvm/bin:/usr/bin")
        );
        assert!(!environment.contains_key("SHLVL"));
        assert_eq!(environment.len(), 2);
        assert!(parse_environment(b"zsh: command not found").is_none());
    }
}
