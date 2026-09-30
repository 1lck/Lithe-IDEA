use anyhow::{Context as _, Result};
use rgitui_settings::{current_git_auth_runtime, GitAuthRuntime, GitProviderRuntime};

use super::argsafe::sh_quote;
use std::path::Path;
use std::process::Command;

/// Run a git network command via system git.
///
/// If the command fails with an SSH auth error and HTTPS credentials are
/// available (provider token, system credential helper like `gh`), the
/// command is automatically retried with SSH-to-HTTPS URL rewriting.
pub(crate) fn run_git_network_command(repo_path: &Path, args: &[&str]) -> Result<Option<String>> {
    let auth = current_git_auth_runtime();
    let remote_url = resolve_remote_url(repo_path, args);

    // --- First attempt: run as-is (with SSH key / HTTPS token if configured) ---
    let result = run_git_command(repo_path, args, &auth, &remote_url, false);

    // --- If SSH auth failed, retry with HTTPS rewriting ---
    if let Err(ref e) = result {
        let err_msg = e.to_string();
        if is_ssh_auth_error(&err_msg) {
            if let Some(ref url) = remote_url {
                if is_ssh_url(url) && can_use_https(repo_path, &auth, url) {
                    log::info!("SSH auth failed, retrying with HTTPS rewriting for {}", url);
                    return run_git_command(repo_path, args, &auth, &remote_url, true);
                }
            }
        }
    }

    result
}

/// The stock pack program to pin for a subcommand, if it accepts one.
///
/// A repository's own config can name the program git runs on the far side of a
/// transport (`remote.<name>.uploadpack`, `remote.<name>.receivepack`, and the
/// `pack.*` equivalents). For a local-path or SSH remote that program runs on
/// this machine, so cloning an untrusted repository and pressing Fetch is enough
/// to execute whatever its `.git/config` names. The command-line flags outrank
/// repository config, so pin them to the stock programs everywhere they exist.
fn pack_program_pin(subcommand: &str) -> Option<&'static str> {
    match subcommand {
        "fetch" | "pull" => Some("--upload-pack=git-upload-pack"),
        "push" => Some("--receive-pack=git-receive-pack"),
        _ => None,
    }
}

/// Build and execute a single git command.
/// When `force_https` is true, SSH URLs are rewritten to HTTPS.
fn run_git_command(
    repo_path: &Path,
    args: &[&str],
    auth: &GitAuthRuntime,
    remote_url: &Option<String>,
    force_https: bool,
) -> Result<Option<String>> {
    // Bound network inactivity for both HTTP and SSH transports. Git still owns
    // the child process, but these limits prevent a dead peer from hanging an
    // operation indefinitely when no explicit UI cancellation token exists.
    let mut config_args: Vec<String> =
        vec!["http.lowSpeedLimit=1".into(), "http.lowSpeedTime=30".into()];
    let mut cmd = super::git_command();
    cmd.current_dir(repo_path).env("GIT_TERMINAL_PROMPT", "0");

    if let Some(ref url) = remote_url {
        if force_https && is_ssh_url(url) {
            // Rewrite SSH to HTTPS.
            if let Some((ssh_prefix, https_prefix)) = insteadof_pair(url) {
                config_args.push(format!("url.{https_prefix}.insteadOf={ssh_prefix}"));
            }
            // Inject HTTPS credentials if we have our own.
            if let Some(https_url) = ssh_to_https(url) {
                inject_https_credentials(&mut cmd, auth, &https_url);
            }
        } else if !force_https {
            // Normal mode: use SSH key or HTTPS credentials as appropriate.
            if is_ssh_url(url) {
                cmd.env("GIT_SSH_COMMAND", ssh_command(auth.ssh_key_path.as_deref()));
            } else {
                // HTTPS remote - inject credentials.
                inject_https_credentials(&mut cmd, auth, url);
            }
        }
    }

    // -c flags MUST come before the subcommand.
    for cfg in &config_args {
        cmd.arg("-c").arg(cfg);
    }
    // The pack-program pin has to land after the subcommand, so split rather
    // than appending `args` wholesale.
    if let Some((subcommand, rest)) = args.split_first() {
        cmd.arg(subcommand);
        if let Some(pin) = pack_program_pin(subcommand) {
            cmd.arg(pin);
        }
        cmd.args(rest);
    }

    let output = cmd
        .output()
        .with_context(|| format!("Failed to run system git command: git {}", args.join(" ")))?;

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let detail = if stderr.is_empty() {
        stdout
    } else if stdout.is_empty() {
        stderr
    } else {
        format!("{stderr}\n{stdout}")
    };

    if output.status.success() {
        let detail = detail.trim().to_string();
        Ok((!detail.is_empty()).then_some(detail))
    } else {
        anyhow::bail!(
            "{}",
            if detail.is_empty() {
                format!(
                    "git {} failed with exit status {}",
                    args.join(" "),
                    output.status
                )
            } else {
                detail
            }
        );
    }
}

fn ssh_command(key_path: Option<&Path>) -> String {
    let mut command =
        String::from("ssh -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=2");
    if let Some(key_path) = key_path.filter(|path| path.exists()) {
        command.push_str(&format!(
            " -i {} -o IdentitiesOnly=yes",
            sh_quote(key_path.to_string_lossy().as_ref())
        ));
    }
    command
}

/// Check if an error message indicates SSH authentication failure.
fn is_ssh_auth_error(msg: &str) -> bool {
    msg.contains("Permission denied (publickey)")
        || msg.contains("Host key verification failed")
        || msg.contains("Could not read from remote repository")
}

/// Check if we have HTTPS credentials available for this SSH URL.
fn can_use_https(repo_path: &Path, auth: &GitAuthRuntime, ssh_url: &str) -> bool {
    let Some(https_url) = ssh_to_https(ssh_url) else {
        return false;
    };
    find_https_credentials(auth, &https_url).is_some()
        || has_credential_helper_for_host(repo_path, &https_url)
}

pub(crate) fn inject_https_credentials(cmd: &mut Command, auth: &GitAuthRuntime, remote_url: &str) {
    let (username, token) = match find_https_credentials(auth, remote_url) {
        Some(creds) => creds,
        None => return,
    };

    let askpass_path = match ensure_askpass_script() {
        Ok(p) => p,
        Err(e) => {
            log::warn!("Could not create HTTPS askpass helper: {e}");
            return;
        }
    };

    cmd.env("GIT_ASKPASS", &askpass_path);
    cmd.env("RGITUI_GIT_USER", username);
    cmd.env("RGITUI_GIT_TOKEN", token);
}

/// Extract the bare host from an HTTP(S) URL for credential matching.
///
/// Strips the scheme, any `user@` userinfo prefix, and any `:port` suffix so
/// that URLs like `https://user@host:443/owner/repo.git` resolve to `host`.
/// Userinfo is removed before the port so a `:` inside `user:pass@` is not
/// mistaken for the port separator. IPv6 literals are not handled.
fn extract_host(url: &str) -> &str {
    let authority = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .and_then(|rest| rest.split('/').next())
        .unwrap_or("");

    let host = authority
        .rsplit_once('@')
        .map(|(_, host)| host)
        .unwrap_or(authority);

    host.split(':').next().unwrap_or(host)
}

fn find_https_credentials(auth: &GitAuthRuntime, remote_url: &str) -> Option<(String, String)> {
    let host = extract_host(remote_url);

    let matching_provider: Option<&GitProviderRuntime> = auth
        .providers
        .iter()
        .find(|p| p.use_for_https && p.token.is_some() && host_matches(&p.host, host));

    if let Some(provider) = matching_provider {
        if let Some(ref token) = provider.token {
            let username = if provider.username.is_empty() {
                "x-access-token".to_string()
            } else {
                provider.username.clone()
            };
            return Some((username, token.clone()));
        }
    }

    if let Some(ref token) = auth.default_https_token {
        return Some(("x-access-token".to_string(), token.clone()));
    }

    None
}

fn host_matches(provider_host: &str, remote_host: &str) -> bool {
    let ph = provider_host.trim().to_lowercase();
    let rh = remote_host.trim().to_lowercase();
    ph == rh || rh.ends_with(&format!(".{ph}")) || ph.ends_with(&format!(".{rh}"))
}

fn resolve_remote_url(repo_path: &Path, args: &[&str]) -> Option<String> {
    let remote_name = extract_remote_name(args)?;
    let repo = git2::Repository::open(repo_path).ok()?;
    let remote = repo.find_remote(&remote_name).ok()?;
    remote.url().map(|s| s.to_string())
}

fn extract_remote_name(args: &[&str]) -> Option<String> {
    let mut iter = args.iter();
    let subcmd = iter.next()?;
    match *subcmd {
        "fetch" | "pull" | "push" => {
            for arg in iter {
                if !arg.starts_with('-') {
                    return Some(arg.to_string());
                }
            }
            None
        }
        _ => None,
    }
}

fn ensure_askpass_script() -> Result<std::path::PathBuf> {
    let dir = rgitui_settings::config_dir();
    std::fs::create_dir_all(&dir)?;

    #[cfg(windows)]
    let script_path = dir.join("askpass.cmd");
    #[cfg(not(windows))]
    let script_path = dir.join("askpass.sh");

    let needs_write = match std::fs::metadata(&script_path) {
        Ok(m) => m.len() == 0,
        Err(_) => true,
    };

    if needs_write {
        #[cfg(windows)]
        {
            // Batch helper invoked by git as `askpass.cmd "<prompt>"`. Delayed
            // expansion (`!VAR!`) avoids re-parsing token characters such as
            // `& | < > ^`, and CRLF line endings keep cmd.exe happy.
            let script = "@echo off\r\n\
                setlocal enabledelayedexpansion\r\n\
                echo %~1 | findstr /B /I \"Username\" >nul\r\n\
                if not errorlevel 1 (\r\n\
                \x20   echo !RGITUI_GIT_USER!\r\n\
                ) else (\r\n\
                \x20   echo !RGITUI_GIT_TOKEN!\r\n\
                )\r\n";
            std::fs::write(&script_path, script)?;
        }
        #[cfg(not(windows))]
        {
            let script = "#!/usr/bin/env bash\n\
                case \"$1\" in\n\
                \x20   Username*|username*) echo \"$RGITUI_GIT_USER\" ;;\n\
                \x20   *) echo \"$RGITUI_GIT_TOKEN\" ;;\n\
                esac\n";
            std::fs::write(&script_path, script)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&script_path, std::fs::Permissions::from_mode(0o755))?;
            }
        }
    }

    Ok(script_path)
}

fn is_ssh_url(url: &str) -> bool {
    url.starts_with("git@") || url.starts_with("ssh://")
}

fn ssh_to_https(url: &str) -> Option<String> {
    if let Some(rest) = url.strip_prefix("git@") {
        let (host, path) = rest.split_once(':')?;
        Some(format!("https://{host}/{path}"))
    } else if let Some(rest) = url.strip_prefix("ssh://") {
        let rest = rest.strip_prefix("git@").unwrap_or(rest);
        Some(format!("https://{rest}"))
    } else {
        None
    }
}

fn insteadof_pair(ssh_url: &str) -> Option<(String, String)> {
    if let Some(rest) = ssh_url.strip_prefix("git@") {
        let host = rest.split_once(':')?.0;
        Some((format!("git@{host}:"), format!("https://{host}/")))
    } else if let Some(rest) = ssh_url.strip_prefix("ssh://") {
        let rest = rest.strip_prefix("git@").unwrap_or(rest);
        let host = rest.split_once('/')?.0;
        Some((format!("ssh://git@{host}/"), format!("https://{host}/")))
    } else {
        None
    }
}

fn has_credential_helper_for_host(repo_path: &Path, https_url: &str) -> bool {
    let host = extract_host(https_url);
    if host.is_empty() {
        return false;
    }

    let output = super::git_command()
        .args(["config", "--get-regexp", "credential"])
        .current_dir(repo_path)
        .output();

    match output {
        Ok(out) => {
            let config = String::from_utf8_lossy(&out.stdout);
            config.contains(&format!("credential.https://{host}"))
                || config.contains("credential.helper")
        }
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ─── is_ssh_auth_error ───────────────────────────────────────────────────

    #[test]
    fn is_ssh_auth_error_detects_publickey() {
        assert!(is_ssh_auth_error("Permission denied (publickey)"));
        assert!(is_ssh_auth_error(
            "Permission denied (publickey) for github.com"
        ));
    }

    #[test]
    fn is_ssh_auth_error_detects_host_key() {
        assert!(is_ssh_auth_error("Host key verification failed"));
        assert!(is_ssh_auth_error(
            "Host key verification failed for github.com"
        ));
    }

    #[test]
    fn is_ssh_auth_error_detects_remote_read() {
        assert!(is_ssh_auth_error("Could not read from remote repository"));
    }

    #[test]
    fn is_ssh_auth_error_false_for_other_errors() {
        assert!(!is_ssh_auth_error("object not found"));
        assert!(!is_ssh_auth_error("Connection timed out"));
        assert!(!is_ssh_auth_error("Permission denied (password)"));
    }

    // ─── host_matches ──────────────────────────────────────────────────────

    #[test]
    fn host_matches_exact() {
        assert!(host_matches("github.com", "github.com"));
        assert!(host_matches("gitlab.com", "gitlab.com"));
    }

    #[test]
    fn host_matches_case_insensitive() {
        assert!(host_matches("GitHub.COM", "github.com"));
        assert!(host_matches("github.com", "GITHUB.COM"));
    }

    #[test]
    fn host_matches_subdomain() {
        // Provider is the bare domain, remote has a subdomain
        assert!(host_matches("github.com", "github.com"));
        assert!(host_matches("github.com", "foo.github.com"));
        // Remote is the bare domain, provider has a subdomain
        assert!(host_matches("foo.github.com", "github.com"));
    }

    #[test]
    fn host_matches_no_match() {
        assert!(!host_matches("github.com", "gitlab.com"));
        assert!(!host_matches("github.com", "notgithub.com"));
        assert!(!host_matches("githu.com", "github.com"));
    }

    #[test]
    fn host_matches_trims_whitespace() {
        assert!(host_matches(" github.com ", "github.com"));
        assert!(host_matches("github.com", " github.com "));
    }

    // ─── extract_remote_name ─────────────────────────────────────────────────

    #[test]
    fn extract_remote_name_fetch() {
        assert_eq!(
            extract_remote_name(&["fetch", "origin"]),
            Some("origin".to_string())
        );
    }

    #[test]
    fn extract_remote_name_pull() {
        assert_eq!(
            extract_remote_name(&["pull", "upstream", "main"]),
            Some("upstream".to_string())
        );
    }

    #[test]
    fn extract_remote_name_push() {
        assert_eq!(
            extract_remote_name(&["push", "github"]),
            Some("github".to_string())
        );
    }

    #[test]
    fn extract_remote_name_skips_flags() {
        assert_eq!(
            extract_remote_name(&["push", "--force", "origin"]),
            Some("origin".to_string())
        );
        assert_eq!(
            extract_remote_name(&["fetch", "-v", "--thin", "origin"]),
            Some("origin".to_string())
        );
    }

    #[test]
    fn extract_remote_name_empty_args() {
        assert_eq!(extract_remote_name(&[]), None);
    }

    #[test]
    fn extract_remote_name_unknown_subcommand() {
        assert_eq!(extract_remote_name(&["clone"]), None);
        assert_eq!(extract_remote_name(&["remote", "add"]), None);
    }

    #[test]
    fn extract_remote_name_only_flags() {
        assert_eq!(extract_remote_name(&["fetch", "--all"]), None);
    }

    // ─── is_ssh_url ────────────────────────────────────────────────────────

    #[test]
    fn is_ssh_url_git_at() {
        assert!(is_ssh_url("git@github.com:user/repo.git"));
        assert!(is_ssh_url("git@gitlab.com:foo/bar.git"));
    }

    #[test]
    fn is_ssh_url_ssh_protocol() {
        assert!(is_ssh_url("ssh://git@github.com/user/repo.git"));
        assert!(is_ssh_url("ssh://user@github.com/user/repo.git"));
    }

    #[test]
    fn is_ssh_url_not_https() {
        assert!(!is_ssh_url("https://github.com/user/repo.git"));
        assert!(!is_ssh_url("http://github.com/user/repo.git"));
    }

    #[test]
    fn is_ssh_url_not_file() {
        assert!(!is_ssh_url("file:///path/to/repo"));
    }

    // ─── ssh_to_https ──────────────────────────────────────────────────────

    #[test]
    fn ssh_to_https_git_at() {
        assert_eq!(
            ssh_to_https("git@github.com:user/repo.git"),
            Some("https://github.com/user/repo.git".to_string())
        );
        assert_eq!(
            ssh_to_https("git@gitlab.com:foo/bar.git"),
            Some("https://gitlab.com/foo/bar.git".to_string())
        );
    }

    #[test]
    fn ssh_to_https_ssh_protocol() {
        assert_eq!(
            ssh_to_https("ssh://git@github.com/user/repo.git"),
            Some("https://github.com/user/repo.git".to_string())
        );
        // ssh://user@host/path — user@ prefix is preserved as-is in the HTTPS URL
        assert_eq!(
            ssh_to_https("ssh://user@github.com/user/repo.git"),
            Some("https://user@github.com/user/repo.git".to_string())
        );
    }

    #[test]
    fn ssh_to_https_no_op_for_https() {
        assert_eq!(ssh_to_https("https://github.com/user/repo.git"), None);
        assert_eq!(ssh_to_https("http://github.com/user/repo.git"), None);
    }

    #[test]
    fn ssh_to_https_no_op_for_scp_style_without_host() {
        // "user@host:path" — the split_once on ':' won't find a valid host/path split
        assert_eq!(ssh_to_https("git@github.comuser/repo.git"), None);
    }

    // ─── insteadof_pair ────────────────────────────────────────────────────

    #[test]
    fn insteadof_pair_git_at() {
        assert_eq!(
            insteadof_pair("git@github.com:user/repo.git"),
            Some((
                "git@github.com:".to_string(),
                "https://github.com/".to_string()
            ))
        );
    }

    #[test]
    fn insteadof_pair_ssh_protocol() {
        assert_eq!(
            insteadof_pair("ssh://git@github.com/user/repo.git"),
            Some((
                "ssh://git@github.com/".to_string(),
                "https://github.com/".to_string()
            ))
        );
    }

    #[test]
    fn insteadof_pair_no_op_for_https() {
        assert_eq!(insteadof_pair("https://github.com/user/repo.git"), None);
    }

    #[test]
    fn ssh_transport_has_bounded_connect_and_idle_timeouts() {
        let command = ssh_command(None);
        assert!(command.contains("ConnectTimeout=15"));
        assert!(command.contains("ServerAliveInterval=15"));
        assert!(command.contains("ServerAliveCountMax=2"));
    }
}
