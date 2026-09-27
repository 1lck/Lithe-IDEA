use super::*;
use std::os::unix::fs::{symlink, PermissionsExt};

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("lithe-cli-owner-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        Self(root)
    }
    fn file(&self, relative: &str, contents: &str) -> PathBuf {
        let path = self.0.join(relative);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, contents).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }
    fn link(&self, relative: &str, target: &Path) -> PathBuf {
        let path = self.0.join(relative);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        symlink(target, &path).unwrap();
        path
    }
    fn npm_cli(&self) -> PathBuf {
        let target = self.file(
            "npm space/node_modules/@openai/codex/bin/codex.js",
            "#!/bin/sh\n",
        );
        self.file(
            "npm space/node_modules/@openai/codex/package.json",
            r#"{"name":"@openai/codex","bin":{"codex":"bin/codex.js"}}"#,
        );
        self.link("npm space/bin/codex", &target)
    }
    fn npm_probe(&self, _: &Path, args: &[&str]) -> Result<String, RunError> {
        match args {
            ["prefix", "--global"] => Ok(self.0.join("npm space").display().to_string()),
            ["root", "--global"] => Ok(self.0.join("npm space/node_modules").display().to_string()),
            _ => panic!("unexpected probe: {args:?}"),
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn codex() -> &'static AgentCli {
    crate::catalog::find("codex-acp")
        .unwrap()
        .cli
        .as_ref()
        .unwrap()
}
fn claude() -> &'static AgentCli {
    crate::catalog::find("claude-acp")
        .unwrap()
        .cli
        .as_ref()
        .unwrap()
}

#[test]
fn homebrew_receipt_and_actual_target_win_over_an_unrelated_npm_install() {
    // Preserve cask/formula ownership and Claude's chosen release channel.
    for (kind, directory, package, cli) in [
        ("--cask", "Caskroom", "codex", codex()),
        ("--formula", "Cellar", "codex", codex()),
        ("--cask", "Caskroom", "claude-code@latest", claude()),
    ] {
        let fixture = Fixture::new();
        let npm = fixture.file("npm space/bin/npm", "#!/bin/sh\n");
        fixture.npm_cli();
        let brew = fixture.file("brew prefix/bin/brew", "#!/bin/sh\n");
        let target = fixture.file(
            &format!("brew prefix/{directory}/{package}/1/cli"),
            "#!/bin/sh\n",
        );
        let executable = fixture.link(&format!("brew prefix/bin/{}", cli.command), &target);
        std::fs::create_dir_all(fixture.0.join("brew prefix/Cellar")).unwrap();
        std::fs::create_dir_all(fixture.0.join("brew prefix/Caskroom")).unwrap();
        let plan = resolve(
            cli,
            Some(&executable),
            Some(&npm),
            Some(&brew),
            None,
            &|program, args| {
                assert_eq!(
                    program, brew,
                    "npm must not be consulted for a verified Homebrew CLI"
                );
                match args {
                    ["--caskroom"] => {
                        Ok(fixture.0.join("brew prefix/Caskroom").display().to_string())
                    }
                    ["--cellar"] => Ok(fixture.0.join("brew prefix/Cellar").display().to_string()),
                    ["list", flag, "--versions", name] if *flag == kind && *name == package => {
                        Ok(format!("{package} 1"))
                    }
                    _ => panic!("unexpected probe: {args:?}"),
                }
            },
        )
        .unwrap();
        assert_eq!(plan.installation.source, CliSource::Homebrew);
        assert!(plan.installation.can_update);
        let command = plan.command.unwrap();
        assert_eq!(command.program, brew);
        assert_eq!(command.arguments, ["upgrade", kind, package]);
        assert!(!command.observes_npm);
    }
}

#[test]
fn npm_requires_its_global_package_manifest_bin_and_active_link_to_agree() {
    let fixture = Fixture::new();
    let executable = fixture.npm_cli();
    let npm = fixture.file("npm space/bin/npm", "#!/bin/sh\n");
    let plan = resolve(
        codex(),
        Some(&executable),
        Some(&npm),
        None,
        None,
        &|program, args| fixture.npm_probe(program, args),
    )
    .unwrap();
    assert_eq!(plan.installation.source, CliSource::Npm);
    assert!(plan.installation.can_update);
    assert_eq!(plan.command.unwrap().program, npm);

    fixture.file(
        "npm space/node_modules/@openai/codex/package.json",
        r#"{"name":"different-package","bin":{"codex":"bin/codex.js"}}"#,
    );
    let plan = resolve(
        codex(),
        Some(&executable),
        Some(&npm),
        None,
        None,
        &|_, _| panic!("unverified packages must not be updated"),
    )
    .unwrap();
    assert_eq!(plan.installation.source, CliSource::Unknown);
    assert!(plan.command.is_none());
}

#[test]
fn another_node_environment_cannot_update_the_active_npm_install() {
    let fixture = Fixture::new();
    let executable = fixture.npm_cli();
    let npm = fixture.file("other-node/bin/npm", "#!/bin/sh\n");
    std::fs::create_dir_all(fixture.0.join("other-node/node_modules")).unwrap();
    let plan = resolve(
        codex(),
        Some(&executable),
        Some(&npm),
        None,
        None,
        &|_, args| {
            Ok(fixture
                .0
                .join(if args[0] == "prefix" {
                    "other-node"
                } else {
                    "other-node/node_modules"
                })
                .display()
                .to_string())
        },
    )
    .unwrap();
    assert_eq!(plan.installation.source, CliSource::Npm);
    assert!(!plan.installation.can_update);
    assert!(plan.command.is_none());
    assert!(plan
        .installation
        .update_hint
        .contains("Node.js/npm environment"));
}

#[test]
fn native_claude_launcher_uses_self_update_without_requiring_npm() {
    let fixture = Fixture::new();
    let target = fixture.file("home/.local/share/claude/versions/2.1.280", "#!/bin/sh\n");
    let executable = fixture.link("home/.local/bin/claude", &target);
    let plan = resolve(
        claude(),
        Some(&executable),
        None,
        None,
        Some(&fixture.0.join("home")),
        &|_, _| panic!("native installation does not need package manager probes"),
    )
    .unwrap();
    assert_eq!(plan.installation.source, CliSource::Native);
    let command = plan.command.unwrap();
    assert_eq!(command.program, executable);
    assert_eq!(command.arguments, ["update"]);
}

#[test]
fn missing_cli_can_use_npm_but_existing_or_broken_commands_are_never_overwritten() {
    let fixture = Fixture::new();
    let npm = fixture.file("npm space/bin/npm", "#!/bin/sh\n");
    let plan = resolve(codex(), None, Some(&npm), None, None, &|p, a| {
        fixture.npm_probe(p, a)
    })
    .unwrap();
    assert_eq!(plan.installation.source, CliSource::Missing);
    assert!(plan.installation.can_update);

    let broken = fixture.link("npm space/bin/codex", &fixture.0.join("missing-target"));
    for executable in [None, Some(broken.as_path())] {
        let plan = resolve(codex(), executable, Some(&npm), None, None, &|p, a| {
            fixture.npm_probe(p, a)
        })
        .unwrap();
        assert!(!plan.installation.can_update);
        assert!(plan.command.is_none());
    }
    let manual = fixture.file("manual/codex", "#!/bin/sh\n");
    let plan = resolve(codex(), Some(&manual), Some(&npm), None, None, &|_, _| {
        panic!("do not probe/update unknown owners")
    })
    .unwrap();
    assert_eq!(plan.installation.source, CliSource::Unknown);
    assert!(plan.command.is_none());
}

#[test]
fn unrecorded_homebrew_target_cannot_fall_back_to_npm_and_cancel_is_preserved() {
    let fixture = Fixture::new();
    let target = fixture.file("Caskroom/codex/1/cli", "#!/bin/sh\n");
    let brew = fixture.file("bin/brew", "#!/bin/sh\n");
    let plan = resolve(
        codex(),
        Some(&target),
        Some(Path::new("unused-npm")),
        Some(&brew),
        None,
        &|_, args| {
            if args[0] == "--caskroom" {
                Ok(fixture.0.join("Caskroom").display().to_string())
            } else {
                Err(RunError::Start("no installed receipt".into()))
            }
        },
    )
    .unwrap();
    assert_eq!(plan.installation.source, CliSource::Homebrew);
    assert!(plan.command.is_none());
    for (failure, expected) in [
        (RunError::Cancelled, ManagementError::Cancelled),
        (RunError::TimedOut, ManagementError::TimedOut),
    ] {
        let result = resolve(codex(), Some(&target), None, Some(&brew), None, &|_, _| {
            Err(if failure == RunError::Cancelled {
                RunError::Cancelled
            } else {
                RunError::TimedOut
            })
        });
        assert_eq!(result.unwrap_err(), expected);
    }
}
