package workbench

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugininstall"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
)

// TestOfficialCargoReleasePluginBuildsAWorkspace is an opt-in end-to-end check
// of the published official Cargo 0.1.0 release archive. The archive keeps the
// contract's <plugin-id>/ layout, so this test covers downloading the release as
// published: install, enable, detect the Cargo instance, load its provider model
// and run a real cargo build. It needs Node and Cargo on PATH and does not run
// in normal suites.
func TestOfficialCargoReleasePluginBuildsAWorkspace(t *testing.T) {
	archive := os.Getenv("LITHE_RAW_CARGO_PLUGIN_ARCHIVE")
	if archive == "" {
		t.Skip("set LITHE_RAW_CARGO_PLUGIN_ARCHIVE to the unmodified official cargo-build-0.1.0-darwin.zip")
	}
	runOfficialCargoPluginWorkspace(t, archive)
}

// TestRepackedOfficialCargoPluginBuildsAWorkspace covers the flat archive layout
// this host accepted before the contract layout was wired: the same official
// Cargo 0.1.0 contents with plugin.json at the ZIP root. Both layouts must keep
// producing the same package, so the test prevents a layout fix from dropping
// flat archives that were already installable.
func TestRepackedOfficialCargoPluginBuildsAWorkspace(t *testing.T) {
	archive := os.Getenv("LITHE_REPACKED_CARGO_PLUGIN_ARCHIVE")
	if archive == "" {
		t.Skip("set LITHE_REPACKED_CARGO_PLUGIN_ARCHIVE to the official Cargo 0.1.0 contents repacked with plugin.json at the archive root")
	}
	runOfficialCargoPluginWorkspace(t, archive)
}

// runOfficialCargoPluginWorkspace installs the official Cargo 0.1.0 archive,
// enables it, detects a workspace and runs its build task.
func runOfficialCargoPluginWorkspace(t *testing.T, archive string) {
	t.Helper()
	workspace := t.TempDir()
	if err := os.MkdirAll(filepath.Join(workspace, "src"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspace, "Cargo.toml"), []byte("[package]\nname = \"build_run_e2e\"\nversion = \"0.1.0\"\nedition = \"2021\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspace, "src", "main.rs"), []byte("fn main() {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	service, err := pluginservice.Open(core.NewClient(), h.store, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h.app.plugins = service
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	plan, err := service.Installer.Prepare(ctx, plugininstall.Request{
		ArchivePath: archive,
		Root:        service.Root,
		Source:      plugintrust.Disk,
	})
	if err != nil {
		t.Fatalf("prepare the official plugin: %v", err)
	}
	if plan.ID != "io.github.lithe-idea.cargo-build" || plan.Version != "0.1.0" {
		_ = service.Installer.Discard(plan)
		t.Fatalf("unexpected official plugin identity: %s %s", plan.ID, plan.Version)
	}
	// The published package carries no publisher signature, so a disk install
	// must still ask the user; the layout fix may not turn that into trust.
	if !plan.NeedsApproval() {
		_ = service.Installer.Discard(plan)
		t.Fatal("an unsigned package from disk reused an approval")
	}
	installed, err := service.Installer.Commit(plan)
	if err != nil {
		_ = service.Installer.Discard(plan)
		t.Fatalf("install the official plugin: %v", err)
	}
	// The contract's <plugin-id>/ directory is the package's content root, not a
	// second directory below the installed package.
	if _, err := os.Stat(filepath.Join(installed.Path, pluginpkg.ManifestFile)); err != nil {
		t.Fatalf("the installed package has no plugin.json at its root: %v", err)
	}
	if _, err := os.Stat(filepath.Join(installed.Path, plan.ID)); !os.IsNotExist(err) {
		t.Fatalf("the installed package kept its archive directory: %v", err)
	}
	if err := service.Manager.SetEnabled("io.github.lithe-idea.cargo-build", true); err != nil {
		t.Fatal(err)
	}
	h.open(workspace)
	p := h.app.project
	if p == nil {
		t.Fatal("the workspace did not open")
	}
	a := h.app
	a.loadBuildSystems(p)
	h.settle()
	h.settle()
	if len(p.build.instances) == 0 {
		t.Fatalf("no Cargo instance was detected: status=%q failed=%q", p.build.status, p.build.failed)
	}
	instance := &p.build.instances[0]
	if instance.modelError != "" {
		t.Fatalf("the official provider did not load its model: %v", instance.modelError)
	}
	if !instance.modelLoaded {
		t.Fatal("the Cargo model was not loaded")
	}
	p.build.taskID = "build"
	a.runSelectedBuildTask(p)
	h.settle()
	output := strings.Join(p.build.output, "")
	if p.build.status != a.text.Build.Succeeded {
		t.Fatalf("cargo build did not succeed: status=%q output=%q", p.build.status, output)
	}
	if !strings.Contains(output, "Finished") && !strings.Contains(output, "Compiling") {
		t.Fatalf("cargo build produced no build output: %q", output)
	}
}
