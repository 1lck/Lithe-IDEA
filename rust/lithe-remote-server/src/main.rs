//! Command-line entry of the remote workspace server.
//!
//! - `--stdio`: one session on standard input and output, ending with it.
//! - `--connect <key>`: relay standard streams to the persistent session
//!   `<key>`, starting its daemon when needed. This is what transports run.
//! - `--daemon <key>`: the persistent session itself, started by `--connect`.
//! - `--identity`, `--version`, `--print-environment`: helpers for the
//!   bootstrapper and for environment resolution.
//!
//! Nothing but protocol bytes may reach standard output in `--stdio` and
//! `--connect` modes; diagnostics go to standard error.

use lithe_remote_server::PersistentOptions;
use std::io::{self, Write};
use std::path::PathBuf;
use std::process::ExitCode;

const USAGE: &str = "usage: lithe-remote-server --stdio | --connect <key> [--state-dir <dir>] | --daemon <key> [--state-dir <dir>] | --identity | --version | --print-environment";

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
    let result = match arguments.as_slice() {
        ["--stdio"] => lithe_remote_server::serve_stdio(io::stdin(), io::stdout()),
        ["--connect", key, rest @ ..] => {
            persistent(key, rest).and_then(|options| lithe_remote_server::run_proxy(&options))
        }
        ["--daemon", key, rest @ ..] => {
            persistent(key, rest).and_then(|options| lithe_remote_server::run_daemon(&options))
        }
        ["--identity"] => lithe_remote_server::identity().and_then(|identity| {
            let mut stdout = io::stdout();
            serde_json::to_writer(&mut stdout, &identity)
                .map_err(io::Error::from)
                .and_then(|()| writeln!(stdout))
        }),
        ["--version"] => writeln!(io::stdout(), "{}", env!("CARGO_PKG_VERSION")),
        ["--print-environment"] => lithe_remote_server::print_environment(),
        _ => {
            eprintln!("{USAGE}");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("lithe-remote-server: {error}");
            ExitCode::FAILURE
        }
    }
}

fn persistent(key: &str, rest: &[&str]) -> io::Result<PersistentOptions> {
    let state_directory = match rest {
        [] => None,
        ["--state-dir", directory] => Some(PathBuf::from(directory)),
        _ => return Err(io::Error::new(io::ErrorKind::InvalidInput, USAGE)),
    };
    Ok(PersistentOptions {
        key: key.into(),
        state_directory,
    })
}
