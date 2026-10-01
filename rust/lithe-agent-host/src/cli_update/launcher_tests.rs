//! npm's Windows `.cmd` launchers. The layout is plain files, so the launcher
//! mapping runs on every platform; ownership resolution needs Windows paths.

use super::*;

struct Prefix(PathBuf);

impl Prefix {
    /// An npm global prefix holding `<command>.cmd` and the package that owns it.
    fn new(cli: &AgentCli, package_name: &str, bin: &str) -> Self {
        let root =
            std::env::temp_dir().join(format!("lithe-cli-launcher-{}", uuid::Uuid::new_v4()));
        let package = root.join("node_modules").join(cli.package);
        std::fs::create_dir_all(package.join("bin")).unwrap();
        std::fs::write(
            package.join("package.json"),
            serde_json::json!({ "name": package_name, "bin": { cli.command: bin } }).to_string(),
        )
        .unwrap();
        std::fs::write(package.join(bin), "binary").unwrap();
        std::fs::write(root.join(format!("{}.cmd", cli.command)), "@ECHO off\r\n").unwrap();
        Self(root)
    }

    fn launcher(&self, cli: &AgentCli) -> PathBuf {
        self.0.join(format!("{}.cmd", cli.command))
    }
}

impl Drop for Prefix {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn cli(agent: &str) -> &'static AgentCli {
    crate::catalog::find(agent).unwrap().cli.as_ref().unwrap()
}

#[test]
fn native_npm_bin_replaces_its_launcher_so_adapters_can_spawn_it() {
    // Claude Code ships `bin/claude.exe`; Node.js cannot spawn `claude.cmd`
    // without a shell, which surfaced as `spawn EINVAL` on the first session.
    let claude = cli("claude-acp");
    let prefix = Prefix::new(claude, claude.package, "bin/claude.exe");
    assert_eq!(
        launch_executable(claude, &prefix.launcher(claude)),
        prefix
            .0
            .join("node_modules")
            .join(claude.package)
            .join("bin/claude.exe")
    );
}

#[test]
fn script_bins_and_foreign_packages_keep_the_detected_launcher() {
    // Codex ships `bin/codex.js`, which still needs the launcher to find Node.js.
    let codex = cli("codex-acp");
    let script = Prefix::new(codex, codex.package, "bin/codex.js");
    assert_eq!(
        launch_executable(codex, &script.launcher(codex)),
        script.launcher(codex)
    );

    // A package that is not the CLI's own never redirects the launch.
    let claude = cli("claude-acp");
    let foreign = Prefix::new(claude, "unrelated-package", "bin/claude.exe");
    assert_eq!(
        launch_executable(claude, &foreign.launcher(claude)),
        foreign.launcher(claude)
    );

    // Paths that are not npm launchers are passed through unchanged.
    let plain = PathBuf::from("/usr/local/bin/claude");
    assert_eq!(launch_executable(claude, &plain), plain);
}

#[cfg(windows)]
#[test]
fn npm_cmd_launcher_is_recognised_as_an_updatable_npm_install() {
    for (agent, bin) in [
        ("codex-acp", "bin/codex.js"),
        ("claude-acp", "bin/claude.exe"),
    ] {
        let cli = cli(agent);
        let prefix = Prefix::new(cli, cli.package, bin);
        let npm = prefix.0.join("npm.cmd");
        std::fs::write(&npm, "@ECHO off\r\n").unwrap();
        let plan = resolve(
            cli,
            Some(&prefix.launcher(cli)),
            Some(&npm),
            None,
            None,
            &|_, args| match args {
                ["prefix", "--global"] => Ok(prefix.0.display().to_string()),
                ["root", "--global"] => Ok(prefix.0.join("node_modules").display().to_string()),
                _ => panic!("unexpected probe: {args:?}"),
            },
        )
        .unwrap();
        assert_eq!(plan.installation.source, CliSource::Npm, "{agent}");
        assert!(plan.installation.can_update, "{agent}");
        assert_eq!(plan.command.unwrap().program, npm);
    }
}

#[cfg(windows)]
#[test]
fn a_launcher_from_another_npm_prefix_is_never_updated_by_the_active_npm() {
    let codex = cli("codex-acp");
    let active = Prefix::new(codex, codex.package, "bin/codex.js");
    let other = Prefix::new(codex, codex.package, "bin/codex.js");
    let npm = active.0.join("npm.cmd");
    std::fs::write(&npm, "@ECHO off\r\n").unwrap();
    let plan = resolve(
        codex,
        Some(&other.launcher(codex)),
        Some(&npm),
        None,
        None,
        &|_, args| match args {
            ["prefix", "--global"] => Ok(active.0.display().to_string()),
            ["root", "--global"] => Ok(active.0.join("node_modules").display().to_string()),
            _ => panic!("unexpected probe: {args:?}"),
        },
    )
    .unwrap();
    assert_eq!(plan.installation.source, CliSource::Npm);
    assert!(!plan.installation.can_update);
    assert!(plan.command.is_none());
}
