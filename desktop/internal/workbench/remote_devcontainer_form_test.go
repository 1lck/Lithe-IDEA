package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackage"
	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackagetest"
)

// Creating in an empty workspace publishes standard JSON and rereads it through Core.
// Opening, editing a draft and cancelling never create a file or start the CLI.
func TestRemoteDevcontainerFormCreatesAndRereadsConfiguration(t *testing.T) {
	folder := t.TempDir()
	h, k, _ := remoteDevcontainerHarness(t, folder, false)
	d, language := h.app.remote.devcontainer, h.app.language()
	path := filepath.Join(folder, filepath.FromSlash(remoteTestConfig))
	d.name.SetText("API")
	d.image.SetText("debian:bookworm-slim")
	d.ports.SetText("3000, 8080")
	h.redraw()
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("draft wrote a configuration: %v", err)
	}
	h.clickFront(i18n.Shared(language, "desktop.remote.devcontainer.createConfig"))
	awaitStateWithin(t, h, 10*time.Second, "the published configuration reread", func() bool {
		return !d.creating && !d.reading && (len(d.configs) == 1 || d.err != "")
	})
	if d.err != "" || d.create || d.config != remoteTestConfig || !d.buildable() {
		t.Fatalf("configuration not ready: %q, %+v", d.err, d.configs)
	}
	ready := d.runtimes
	d.runtimes = core.ContainerRuntimes{}
	if d.buildable() {
		t.Fatal("a configured folder can build without a discovered usable runtime")
	}
	d.runtimes = ready
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var config struct {
		Name, Image string
		AppPort     []string
	}
	if err := json.Unmarshal(data, &config); err != nil {
		t.Fatal(err)
	}
	if config.Name != "API" || config.Image != "debian:bookworm-slim" || len(config.AppPort) != 2 || config.AppPort[0] != "127.0.0.1:3000:3000" {
		t.Fatalf("unexpected saved configuration: %s", data)
	}
	k.set(func(k *remoteHostKernel) {
		if len(k.devcontainers.requests) != 0 {
			t.Error("creating JSON started a container")
		}
	})

	h.app.leaveRemoteDevcontainer()
	another := t.TempDir()
	h.app.openRemoteDevcontainer()
	h.app.remote.devcontainer.folder.SetText(another)
	h.app.readRemoteDevcontainer()
	awaitRemoteDevcontainerRead(t, h)
	h.app.remote.devcontainer.image.SetText("alpine:3")
	h.app.leaveRemoteDevcontainer()
	if _, err := os.Stat(filepath.Join(another, filepath.FromSlash(remoteTestConfig))); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("cancel wrote configuration: %v", err)
	}
}

func TestRemoteDevcontainerConfigurationLeavesInstalledPackageUnchanged(t *testing.T) {
	if !installedpackagetest.Run(t) {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	directory, err := os.UserConfigDir()
	if err != nil {
		t.Fatal(err)
	}
	folder := filepath.Join(directory, "devcontainer-workspace")
	if err := os.MkdirAll(folder, 0o700); err != nil {
		t.Fatal(err)
	}
	prepared, err := core.NewClient().RemoteDevcontainerPrepare(ctx, core.DevcontainerForm{Image: "debian:bookworm-slim"})
	if err != nil {
		t.Fatal(err)
	}
	if err := writeRemoteDevcontainerConfig(ctx, folder, prepared); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(folder, filepath.FromSlash(prepared.Path))
	installedpackagetest.Outside(t, path)
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeRemoteDevcontainerConfig(ctx, folder, prepared); !errors.Is(err, configfile.ErrConflict) {
		t.Fatalf("existing file should conflict: %v", err)
	}
	after, err := os.ReadFile(path)
	if err != nil || string(before) != string(after) {
		t.Fatalf("existing configuration changed: %v", err)
	}
	installation, err := installedpackage.Root()
	if err != nil {
		t.Fatal(err)
	}
	if err := writeRemoteDevcontainerConfig(ctx, installation, prepared); !errors.Is(err, configfile.ErrTarget) {
		t.Fatalf("installation should be read-only: %v", err)
	}
}

// Selection refresh must discard earlier folder/trust results even when the folder is unchanged.
func TestRemoteDevcontainerRuntimeRefreshInvalidatesReadAndPreservesDraft(t *testing.T) {
	folder := t.TempDir()
	h, _, _ := remoteDevcontainerHarness(t, folder, false)
	d := h.app.remote.devcontainer
	oldRead := d.reads
	d.image.SetText("debian:bookworm-slim")
	target := core.ContainerRuntimeTarget{Engine: core.ContainerEngineDocker, Context: "test-context"}
	h.app.applyRemoteDevcontainerRuntimes(d, core.ContainerRuntimes{SelectedRuntime: "new", Runtimes: []core.ContainerRuntime{{ID: "new", ContainerRuntimeTarget: target, Available: false}}})
	if d.reads <= oldRead || d.trusted || d.read != "" || d.buildable() {
		t.Fatal("refresh retained earlier trust or a buildable folder")
	}
	awaitRemoteDevcontainerRead(t, h)
	if d.image.Text() != "debian:bookworm-slim" || d.runtimeTarget() == nil || *d.runtimeTarget() != target {
		t.Fatal("refresh lost the draft or selected runtime")
	}
}
