package core

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// Exercise the real desktop wrapper against a tiny Cargo output fixture. This
// checks what the Go linker receives without compiling a second Rust Core.
func TestDesktopGoFindsWindowsCargoImportLibraries(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("the desktop wrapper requires bash")
	}
	fixture := filepath.Join(t.TempDir(), "workspace with spaces")
	write := func(path, value string, mode os.FileMode) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(value), mode); err != nil {
			t.Fatal(err)
		}
	}
	read, err := os.ReadFile("../../../scripts/desktop/desktop-go.sh")
	if err != nil {
		t.Fatal(err)
	}
	write(filepath.Join(fixture, "scripts/desktop/desktop-go.sh"), string(read), 0o700)
	write(filepath.Join(fixture, "scripts/desktop/build-desktop-core.sh"), "#!/usr/bin/env bash\nprintf '%s/.artifacts/desktop/lithe-core/x86_64-pc-windows-gnu/debug\\n' \"$(cd \"$(dirname \"$0\")/../..\" && pwd -P)\"\n", 0o700)
	write(filepath.Join(fixture, ".artifacts/desktop/lithe-core/x86_64-pc-windows-gnu/debug/native-static-libs.txt"), "-lsystem -lwindows.0.52.0 -lwinapi_kernel32\n", 0o600)
	write(filepath.Join(fixture, ".artifacts/desktop/lithe-core/x86_64-pc-windows-gnu/debug/lib/liblithe_core.a"), "core fixture", 0o600)
	write(filepath.Join(fixture, ".artifacts/desktop/lithe-core/x86_64-pc-windows-gnu/debug/include/lithe_core.h"), "header fixture", 0o600)
	write(filepath.Join(fixture, "bin/go"), "#!/usr/bin/env bash\ncase \"$1:$2\" in env:GOOS|env:GOHOSTOS) echo windows;; env:GOARCH) echo amd64;; *) printf 'CFLAGS=%s\\nLDFLAGS=%s\\n' \"$CGO_CFLAGS\" \"$CGO_LDFLAGS\";; esac\n", 0o700)
	write(filepath.Join(fixture, "bin/rustc"), "#!/usr/bin/env bash\nprintf 'host: x86_64-pc-windows-msvc\\n'\n", 0o700)
	if runtime.GOOS != "windows" {
		write(filepath.Join(fixture, "bin/cygpath"), "#!/usr/bin/env bash\nprintf '%s\\n' \"$2\"\n", 0o700)
	}
	if err := os.MkdirAll(filepath.Join(fixture, "desktop"), 0o700); err != nil {
		t.Fatal(err)
	}
	build := filepath.Join(fixture, ".artifacts/desktop/lithe-core-rust/target/x86_64-pc-windows-gnu/debug/build")
	winlibs := filepath.Join(fixture, "cargo registry", "windows", "lib")
	winapi := filepath.Join(fixture, "cargo registry", "winapi", "lib")
	write(filepath.Join(winlibs, "libwindows.0.52.0.a"), "windows fixture", 0o600)
	write(filepath.Join(winapi, "libwinapi_kernel32.a"), "winapi fixture", 0o600)
	write(filepath.Join(build, "windows-hash/output"), "cargo:rustc-link-search=native="+filepath.ToSlash(winlibs)+"\n", 0o600)
	write(filepath.Join(build, "winapi-hash/output"), "cargo::rustc-link-search=native="+filepath.ToSlash(winapi)+"\n", 0o600)
	run := func() (string, error) {
		t.Helper()
		// Each wrapper run starts dozens of short processes (hashing, sed, cut). Under a loaded
		// suite that takes far longer than the 30s of an in-process test, and a deadline that
		// kills it reports a hang that is only slowness. The bound is for a stuck script.
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
		defer cancel()
		cmd := exec.CommandContext(ctx, bash, filepath.Join(fixture, "scripts/desktop/desktop-go.sh"), "test")
		for _, entry := range os.Environ() {
			upper := strings.ToUpper(entry)
			if !strings.HasPrefix(upper, "PATH=") && !strings.HasPrefix(upper, "GOARCH=") && !strings.HasPrefix(upper, "LITHE_CORE_TARGET=") && !strings.HasPrefix(upper, "CGO_CFLAGS=") && !strings.HasPrefix(upper, "CGO_LDFLAGS=") {
				cmd.Env = append(cmd.Env, entry)
			}
		}
		cmd.Env = append(cmd.Env, "PATH="+filepath.Join(fixture, "bin")+string(os.PathListSeparator)+os.Getenv("PATH"))
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	out, err := run()
	if err != nil {
		t.Fatalf("desktop wrapper: %v\n%s", err, out)
	}
	for _, path := range []string{winlibs, winapi} {
		if !strings.Contains(out, `"-L`+filepath.ToSlash(path)+`"`) {
			t.Fatalf("missing quoted Cargo library directory %q: %s", path, out)
		}
	}
	if !strings.Contains(out, `"-I`) || !strings.Contains(out, "-llithe_core") {
		t.Fatalf("missing core include or library: %s", out)
	}
	// Changing a Cargo import archive at the same path must also invalidate cgo.
	write(filepath.Join(winlibs, "libwindows.0.52.0.a"), "updated windows fixture", 0o600)
	updated, err := run()
	if err != nil {
		t.Fatalf("updated import archive: %v\n%s", err, updated)
	}
	if strings.SplitN(updated, "\n", 2)[0] == strings.SplitN(out, "\n", 2)[0] {
		t.Fatal("changed Windows import archive retained the old cgo action identity")
	}
	conflict := filepath.Join(fixture, "another cargo registry", "lib")
	write(filepath.Join(conflict, "libwindows.0.52.0.a"), "different bytes", 0o600)
	write(filepath.Join(build, "old-windows-hash/output"), "cargo:rustc-link-search=native="+filepath.ToSlash(conflict)+"\n", 0o600)
	out, err = run()
	if err == nil || !strings.Contains(out, "Conflicting Cargo import libraries") {
		t.Fatalf("conflicting archives were not refused: %v\n%s", err, out)
	}
}

// Integration: a no-checkout clone can already have the pinned HEAD while it
// has no worktree or index. Fake the compiler, not Git, to reproduce that state.
func TestBuildDesktopCoreChecksOutFreshPinnedRevision(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("the desktop build requires bash")
	}
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("this checkout integration test requires git")
	}
	write := func(path, value string, mode os.FileMode) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(value), mode); err != nil {
			t.Fatal(err)
		}
	}
	source := filepath.Join(t.TempDir(), "core-source")
	if err := os.Mkdir(source, 0o700); err != nil {
		t.Fatal(err)
	}
	runGit(t, source, "init", "-q")
	write(filepath.Join(source, "rust/Cargo.toml"), "fixture manifest\n", 0o600)
	write(filepath.Join(source, "rust/crates/core/include/lithe_core.h"), "fixture header\n", 0o600)
	runGit(t, source, "add", ".")
	runGit(t, source, "commit", "-qm", "fixture")
	revision := runGit(t, source, "rev-parse", "HEAD")
	fixture := filepath.Join(t.TempDir(), "workspace with spaces")
	if err := os.Mkdir(fixture, 0o700); err != nil {
		t.Fatal(err)
	}
	checkout := filepath.Join(fixture, ".artifacts/desktop/lithe-core-rust/source")
	if err := os.MkdirAll(filepath.Dir(checkout), 0o700); err != nil {
		t.Fatal(err)
	}
	runGit(t, fixture, "clone", "--no-checkout", source, checkout)
	if _, err := os.Stat(filepath.Join(checkout, ".git/index")); !os.IsNotExist(err) {
		t.Fatalf("fixture unexpectedly has an index: %v", err)
	}
	build, err := os.ReadFile("../../../scripts/desktop/build-desktop-core.sh")
	if err != nil {
		t.Fatal(err)
	}
	const pinPrefix = `PINNED_CORE_REVISION="`
	_, afterPin, found := strings.Cut(string(build), pinPrefix)
	pin, _, closed := strings.Cut(afterPin, `"`)
	if !found || !closed || len(pin) != 40 {
		t.Fatal("the test fixture could not locate the pinned revision")
	}
	script := filepath.Join(fixture, "scripts/desktop/build-desktop-core.sh")
	write(script, strings.Replace(string(build), pinPrefix+pin+`"`, pinPrefix+revision+`"`, 1), 0o700)
	write(filepath.Join(fixture, "bin/rustc"), "#!/usr/bin/env bash\nif [[ \"$1\" == -vV ]]; then echo 'host: x86_64-unknown-linux-gnu'; else echo 'rustc fixture'; fi\n", 0o700)
	write(filepath.Join(fixture, "bin/cargo"), `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == clean ]]; then exit 0; fi
out="$CARGO_TARGET_DIR/debug"
helper=lithe-mcp
libs=-lm
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == --target ]]; then
        j=$((i+1))
        out="$CARGO_TARGET_DIR/${!j}/debug"
        if [[ "${!j}" == *-windows-gnu ]]; then
            [[ "${WINAPI_NO_BUNDLED_LIBRARIES:-}" == 1 ]] || { echo 'winapi still requires Cargo-private import libraries' >&2; exit 1; }
            helper=lithe-mcp.exe
            libs=-lkernel32
        fi
    fi
done
mkdir -p "$out"
printf fixture > "$out/liblithe_core.a"
printf helper > "$out/$helper"
for arg in "$@"; do case "$arg" in native-static-libs=*) printf '%s\n' "$libs" > "${arg#native-static-libs=}";; esac; done
`, 0o700)
	target := "x86_64-unknown-linux-gnu"
	runBuild := func() ([]byte, error) {
		t.Helper()
		cmd := exec.CommandContext(testContext(t), bash, script)
		for _, entry := range os.Environ() {
			upper := strings.ToUpper(entry)
			if !strings.HasPrefix(upper, "PATH=") && !strings.HasPrefix(upper, "LITHE_CORE_RUST_DIR=") && !strings.HasPrefix(upper, "LITHE_CORE_TARGET=") && !strings.HasPrefix(upper, "WINAPI_NO_BUNDLED_LIBRARIES=") {
				cmd.Env = append(cmd.Env, entry)
			}
		}
		cmd.Env = append(cmd.Env, "PATH="+filepath.Join(fixture, "bin")+string(os.PathListSeparator)+os.Getenv("PATH"), "LITHE_CORE_TARGET="+target)
		return cmd.CombinedOutput()
	}
	// A no-index directory may still contain untracked user files. Recovery
	// must refuse a conflicting file rather than force-check it out.
	manifest := filepath.Join(checkout, "rust/Cargo.toml")
	write(manifest, "preserve this file\n", 0o600)
	output, err := runBuild()
	if err == nil {
		t.Fatalf("checkout overwrote a conflicting untracked file: %s", output)
	}
	if content, err := os.ReadFile(manifest); err != nil || string(content) != "preserve this file\n" {
		t.Fatalf("untracked file was changed: %q, %v", content, err)
	}
	if err := os.Remove(manifest); err != nil {
		t.Fatal(err)
	}
	output, err = runBuild()
	if err != nil {
		t.Fatalf("building a fresh pinned checkout: %v\n%s", err, output)
	}
	if _, err := os.Stat(filepath.Join(checkout, "rust/Cargo.toml")); err != nil {
		t.Fatalf("pinned worktree was not checked out: %v", err)
	}
	// The GNU cgo lane must ask winapi to use MinGW's system import libraries,
	// not private libwinapi_* archives from a transient Cargo registry path.
	target = "x86_64-pc-windows-gnu"
	output, err = runBuild()
	if err != nil {
		t.Fatalf("building Windows Core with system import libraries: %v\n%s", err, output)
	}
	stage := filepath.Join(fixture, ".artifacts/desktop/lithe-core", target, "debug")
	if libs, err := os.ReadFile(filepath.Join(stage, "native-static-libs.txt")); err != nil || string(libs) != "-lkernel32\n" {
		t.Fatalf("unexpected Windows linker inputs: %q, %v", libs, err)
	}
	if identity, err := os.ReadFile(filepath.Join(stage, "identity.txt")); err != nil || !strings.Contains(string(identity), "winapi-import-libraries=mingw-system\n") {
		t.Fatalf("Windows import library identity missing: %q, %v", identity, err)
	}
	target = "x86_64-unknown-linux-gnu"
	// Once a worktree has an index, a deliberate deletion must not be repaired
	// by checkout behind the user's back, even if the build cannot proceed.
	if err := os.Remove(manifest); err != nil {
		t.Fatal(err)
	}
	output, err = runBuild()
	if err == nil || !strings.Contains(string(output), "No Lithe-core-rust workspace") {
		t.Fatalf("deleted manifest did not stop the build: %v\n%s", err, output)
	}
	if _, err := os.Stat(manifest); !os.IsNotExist(err) {
		t.Fatalf("the existing worktree's deletion was overwritten: %v", err)
	}
}
