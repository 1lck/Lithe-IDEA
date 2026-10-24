//! Command-line entry of the remote workspace server.
//!
//! `--stdio` speaks the protocol on standard input and output. Nothing else may
//! be written to standard output in that mode; diagnostics go to standard error.

use std::io::{self, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match arguments
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .as_slice()
    {
        ["--stdio"] => match lithe_remote_server::serve(io::stdin(), io::stdout()) {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("lithe-remote-server: {error}");
                ExitCode::FAILURE
            }
        },
        ["--identity"] => match lithe_remote_server::identity() {
            Ok(identity) => {
                let mut stdout = io::stdout();
                let printed = serde_json::to_writer(&mut stdout, &identity)
                    .map_err(io::Error::from)
                    .and_then(|()| writeln!(stdout));
                if let Err(error) = printed {
                    eprintln!("lithe-remote-server: {error}");
                    return ExitCode::FAILURE;
                }
                ExitCode::SUCCESS
            }
            Err(error) => {
                eprintln!("lithe-remote-server: cannot hash own executable: {error}");
                ExitCode::FAILURE
            }
        },
        ["--version"] => {
            println!("{}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        _ => {
            eprintln!("usage: lithe-remote-server --stdio | --identity | --version");
            ExitCode::from(2)
        }
    }
}
