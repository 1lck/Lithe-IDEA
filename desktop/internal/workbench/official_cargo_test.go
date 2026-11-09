package workbench

import (
	"context"
	"errors"
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

// TestRepackedOfficialCargoPluginBuildsAWorkspace is an opt-in end-to-end check
// of the official Cargo 0.1.0 plugin contents. The test uses a copy repacked so
// plugin.json is at the ZIP root; the raw GitHub release has a top-level
// directory and is covered by the separate layout test instead. It needs Node
// and Cargo on PATH and does not run in normal suites.
func TestRepackedOfficialCargoPluginBuildsAWorkspace(t *testing.T) {
	archive := os.Getenv("LITHE_REPACKED_CARGO_PLUGIN_ARCHIVE")
	if archive == "" {
		t.Skip("set LITHE_REPACKED_CARGO_PLUGIN_ARCHIVE to the official Cargo 0.1.0 contents repacked with plugin.json at the archive root")
	}
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
		t.Fatalf("prepare the repacked official plugin: %v", err)
	}
	if plan.ID != "io.github.lithe-idea.cargo-build" || plan.Version != "0.1.0" {
		_ = service.Installer.Discard(plan)
		t.Fatalf("unexpected official plugin identity: %s %s", plan.ID, plan.Version)
	}
	if _, err := service.Installer.Commit(plan); err != nil {
		_ = service.Installer.Discard(plan)
		t.Fatalf("install the repacked official plugin: %v", err)
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

// TestRawOfficialCargoReleaseLayoutIsRejected preserves the exact published
// archive behaviour: the GitHub release ZIP places the package under its
// <plugin-id>/ directory (the contract's package layout), while the current
// pluginpkg extractor only looks for plugin.json at the extracted root. This
// test is opt-in and must fail with the layout error, not be masked by installer
// code.
func TestRawOfficialCargoReleaseLayoutIsRejected(t *testing.T) {
	archive := os.Getenv("LITHE_RAW_CARGO_PLUGIN_ARCHIVE")
	if archive == "" {
		t.Skip("set LITHE_RAW_CARGO_PLUGIN_ARCHIVE to the unmodified official cargo-build-0.1.0-darwin.zip")
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	service, err := pluginservice.Open(core.NewClient(), h.store, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	_, err = service.Installer.Prepare(ctx, plugininstall.Request{
		ArchivePath: archive,
		Root:        service.Root,
		Source:      plugintrust.Disk,
	})
	if !errors.Is(err, pluginpkg.ErrManifestMissing) {
		t.Fatalf("raw release layout = %v, want ErrManifestMissing", err)
	}
}
