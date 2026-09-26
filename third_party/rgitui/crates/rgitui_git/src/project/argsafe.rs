//! Validation for values interpolated into `git` command lines.
//!
//! Remote and branch names reach the CLI as positional arguments. Git treats
//! any argument beginning with `-` as an option regardless of the position it
//! appears in, and it does not validate remote names when reading them back out
//! of `.git/config`. A repository carrying
//! `[remote "--upload-pack=<command>"]` therefore turns an ordinary fetch into
//! arbitrary command execution. `--` does not help: `git fetch -- <name>` is
//! rejected because git parses the trailing operand as a pathname.
//!
//! These checks run on every value that is about to become a positional
//! argument, both where the value is read out of the repository and where it
//! arrives from the UI.

use anyhow::Result;

/// What a rejected value was being used for, so the error names it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ArgKind {
    Remote,
    Branch,
}

impl ArgKind {
    fn noun(self) -> &'static str {
        match self {
            ArgKind::Remote => "Remote name",
            ArgKind::Branch => "Branch name",
        }
    }
}

/// Reject values that git would parse as an option or that would corrupt the
/// command line.
///
/// Only a leading `-` can turn a positional argument into an option, so that is
/// the check that closes the injection. Control characters are rejected as well
/// because they cannot appear in a valid ref name and would otherwise produce
/// unreadable errors.
pub(crate) fn validate_cli_arg(value: &str, kind: ArgKind) -> Result<()> {
    let noun = kind.noun();

    if value.is_empty() {
        anyhow::bail!("{noun} is empty. Check the repository's remote configuration.");
    }

    if value.starts_with('-') {
        anyhow::bail!(
            "{noun} '{value}' starts with '-', which git would interpret as a command-line \
             option. Rename it with: git remote rename '{value}' <new-name>"
        );
    }

    if let Some(bad) = value.chars().find(|c| c.is_control()) {
        anyhow::bail!(
            "{noun} '{}' contains the control character {:?}, which is not valid in a git ref.",
            value.escape_debug(),
            bad
        );
    }

    Ok(())
}

/// Convenience wrapper for remote names.
pub(crate) fn validate_remote_name(name: &str) -> Result<()> {
    validate_cli_arg(name, ArgKind::Remote)
}

/// Convenience wrapper for branch names.
pub(crate) fn validate_branch_name(name: &str) -> Result<()> {
    validate_cli_arg(name, ArgKind::Branch)
}

/// Quote a value for use inside a POSIX `sh` command line.
///
/// Git runs `GIT_SSH_COMMAND` and rebase-todo `exec` lines through a shell — on
/// Windows that is the `sh` bundled with Git for Windows — so both need POSIX
/// quoting rules. The value is always quoted rather than only when it looks
/// dangerous, which keeps the guarantee independent of the caller's input.
pub(crate) fn sh_quote(value: &str) -> String {
    // Inside single quotes every character is literal except `'` itself, which
    // is closed, escaped, and reopened.
    format!("'{}'", value.replace('\'', r"'\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_ordinary_names() {
        for name in ["origin", "upstream", "my-fork", "remote.with.dots", "a"] {
            assert!(validate_remote_name(name).is_ok(), "rejected {name}");
        }
    }

    #[test]
    fn accepts_branch_names_with_slashes_and_equals() {
        // `=` is legal in a ref name and is only dangerous behind a leading `-`,
        // which is rejected separately.
        for name in ["main", "feat/thing", "release/1.2", "odd=name"] {
            assert!(validate_branch_name(name).is_ok(), "rejected {name}");
        }
    }

    #[test]
    fn rejects_option_lookalikes() {
        // The reproduced injection: a remote named so that `git fetch <name>`
        // runs an arbitrary program.
        assert!(validate_remote_name("--upload-pack=touch /tmp/pwned").is_err());
        assert!(validate_remote_name("--exec=whoami").is_err());
        assert!(validate_remote_name("-o").is_err());
        assert!(validate_branch_name("--force").is_err());
    }

    #[test]
    fn rejects_empty_and_control_characters() {
        assert!(validate_remote_name("").is_err());
        assert!(validate_remote_name("origin\nfetch").is_err());
        assert!(validate_branch_name("main\0").is_err());
        assert!(validate_branch_name("main\ttab").is_err());
    }

    #[test]
    fn sh_quote_wraps_and_neutralizes_metacharacters() {
        assert_eq!(
            sh_quote("/home/u/.ssh/id_ed25519"),
            "'/home/u/.ssh/id_ed25519'"
        );
        assert_eq!(sh_quote("/tmp/with space/x"), "'/tmp/with space/x'");
        // The reproduced reword injection: backticks and $() must stay literal.
        assert_eq!(sh_quote("pwn `whoami`"), "'pwn `whoami`'");
        assert_eq!(sh_quote("$(id)"), "'$(id)'");
        assert_eq!(sh_quote("a;b&c|d"), "'a;b&c|d'");
    }

    #[test]
    fn sh_quote_escapes_embedded_single_quotes() {
        assert_eq!(sh_quote("it's"), r"'it'\''s'");
        assert_eq!(sh_quote("'"), r"''\'''");
    }

    #[test]
    fn error_message_names_the_offending_value() {
        let err = validate_remote_name("--upload-pack=id")
            .unwrap_err()
            .to_string();
        assert!(err.contains("--upload-pack=id"), "unhelpful error: {err}");
        assert!(err.contains("Remote name"), "unhelpful error: {err}");
    }
}
