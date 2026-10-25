use std::env;
use std::fs;
use std::path::{Path, PathBuf};

/// Directories expected next to `lithe-windows.exe`.
///
/// `portable-pty` loads `conpty.dll` by bare name, so Windows resolves it from
/// the executable's own directory first. The pair must therefore sit beside the
/// binary rather than inside a resource subdirectory:
///
/// - `conpty.dll` exports `CreatePseudoConsole` and friends.
/// - `OpenConsole.exe` is the console host that `conpty.dll` launches, and the
///   pair does not work without it.
/// - `ConPTY-LICENSE.txt` is the MIT text for that upstream code. The license
///   requires the notice to accompany every distributed copy, so it ships beside
///   the binaries instead of staying behind in the repository.
///
/// See `third_party/conpty/manifest.json` for the pinned upstream package and
/// `scripts/prepare-conpty.ps1` for the download that fills `.artifacts`.
const CONPTY_FILES: [&str; 3] = ["conpty.dll", "OpenConsole.exe", "ConPTY-LICENSE.txt"];

fn main() {
    // Keep the page bridge in its own ACL namespace. Defining an app ACL for
    // one command would also change authorization for every product command.
    tauri_build::try_build(
        tauri_build::Attributes::new().plugin("declarative-web", tauri_build::InlinedPlugin::new()),
    )
    .expect("Tauri build failed");

    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }

    let target = env::var("TARGET").unwrap_or_default();
    let platform = match target.as_str() {
        "x86_64-pc-windows-msvc" => "windows-x86_64",
        "aarch64-pc-windows-msvc" => "windows-aarch64",
        other => {
            println!(
                "cargo:warning=ConPTY staging skipped: no bundled console host for target {other}"
            );
            return;
        }
    };

    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let repo_root = manifest_dir
        .ancestors()
        .nth(3)
        .expect("crate must live inside the repository")
        .to_path_buf();
    // Architecture independent on purpose: the same directory is declared in
    // tauri.conf.json so the installer ships the same pair the build staged.
    let source_dir = repo_root.join(".artifacts").join("conpty");

    // `OUT_DIR` is <target-dir>/<triple?>/<profile>/build/<pkg>-<hash>/out, so the
    // profile directory that receives the executable is three levels up.
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is set for build scripts"));
    let profile_dir = out_dir
        .ancestors()
        .nth(3)
        .expect("OUT_DIR must sit inside a Cargo profile directory")
        .to_path_buf();

    println!("cargo:rerun-if-changed=../../third_party/conpty/manifest.json");
    for name in CONPTY_FILES {
        println!("cargo:rerun-if-changed={}", source_dir.join(name).display());
    }

    if !source_dir.is_dir() {
        let message = format!(
            "ConPTY runtime is not staged for {platform}. Run \
             `powershell -ExecutionPolicy Bypass -File scripts/prepare-conpty.ps1` to \
             download it. Without those files the terminal falls back to the \
             system console host, which drops extended keyboard sequences such as \
             Shift+Enter."
        );
        // Packaged builds must not silently ship a degraded terminal, while a
        // plain `cargo check` on an unrelated change should still work.
        if env::var("LITHE_REQUIRE_CONPTY").as_deref() == Ok("1") {
            panic!("{message}");
        }
        println!("cargo:warning={message}");
        return;
    }

    if let Err(error) = stage(&source_dir, &profile_dir, &platform) {
        if env::var("LITHE_REQUIRE_CONPTY").as_deref() == Ok("1") {
            panic!("ConPTY staging failed: {error}");
        }
        println!("cargo:warning=ConPTY staging failed: {error}");
    }
}

fn stage(source_dir: &Path, profile_dir: &Path, platform: &str) -> Result<(), String> {
    for name in CONPTY_FILES {
        let source = source_dir.join(name);
        if !source.is_file() {
            return Err(format!("missing {} for {platform}", source.display()));
        }
        let destination = profile_dir.join(name);
        // Copy only when the bytes differ so an incremental build does not rewrite
        // files that a running terminal session may hold open.
        if fs::read(&source).ok() == fs::read(&destination).ok() {
            continue;
        }
        fs::copy(&source, &destination).map_err(|error| {
            format!(
                "cannot copy {} to {}: {error}",
                source.display(),
                destination.display()
            )
        })?;
    }
    Ok(())
}
