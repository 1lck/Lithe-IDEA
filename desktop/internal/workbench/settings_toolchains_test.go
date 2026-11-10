package workbench

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

func TestToolchainSettingsRejectSaveForAnotherOrClosedProject(t *testing.T) {
	for _, closed := range []bool{false, true} {
		name := "another-project"
		if closed {
			name = "closed-project"
		}
		t.Run(name, func(t *testing.T) {
			original, current := t.TempDir(), t.TempDir()
			app := &App{kernel: &testKernel{Client: core.NewClient()}}
			if !closed {
				app.toolchainRoot.Store(&current)
			}
			snapshot := toolchain.Snapshot{Root: original, Directory: "."}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_, err := (settingsToolchains{app: app}).Save(ctx, snapshot, []toolchain.Edit{{Tool: "dev.example:compiler"}})
			if !errors.Is(err, toolchain.ErrPinConflict) {
				t.Errorf("save error = %v, want a stale-source conflict", err)
			}
			for _, root := range []string{original, current} {
				if _, err := os.Stat(filepath.Join(root, ".lithe")); !errors.Is(err, os.ErrNotExist) {
					t.Errorf("stale draft created workspace state: %v", err)
				}
			}
		})
	}
}

type settingsScopeKernel struct {
	*testKernel
	onEdit func()
}

func (k *settingsScopeKernel) EditToolchainPinSources(ctx context.Context, request core.ToolchainPinSourcesRequest) (core.ToolchainPinSourcesEdit, error) {
	k.onEdit()
	return k.Client.EditToolchainPinSources(ctx, request)
}

// Switching projects after confirmation cannot retarget either publication or
// the reread. The result must describe the source the user actually saved.
func TestToolchainSettingsSaveRereadsItsCapturedProject(t *testing.T) {
	original, current := t.TempDir(), t.TempDir()
	kernel := &settingsScopeKernel{testKernel: &testKernel{Client: core.NewClient()}}
	app := &App{kernel: kernel}
	app.toolchainRoot.Store(&original)
	kernel.onEdit = func() { app.toolchainRoot.Store(&current) }
	plugins, err := pluginservice.Open(core.NewClient(), store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	app.plugins = plugins
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	snapshot, err := (settingsToolchains{app: app}).Load(ctx)
	if err != nil {
		t.Fatal(err)
	}
	updated, err := (settingsToolchains{app: app}).Save(ctx, snapshot, []toolchain.Edit{{Tool: "dev.example:compiler", Pin: &core.ToolchainPin{Home: "/fixture/tool", Version: "1.0", Provider: "host:system"}}})
	if err != nil {
		t.Fatal(err)
	}
	if updated.Root != snapshot.Root {
		t.Errorf("saved source = %q, want captured source %q", updated.Root, snapshot.Root)
	}
	data, err := os.ReadFile(filepath.Join(original, ".lithe", "toolchains", "local.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(updated.Baseline, data) {
		t.Error("save returned another project's baseline")
	}
	if _, err := os.Stat(filepath.Join(current, ".lithe")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("save created state in the newly selected project: %v", err)
	}
}

func TestToolchainSettingsRejectsReplacedWorkspaceAtTheSamePath(t *testing.T) {
	testToolchainSettingsWorkspaceReplacement(t, false)
}

func TestToolchainSettingsRejectsWorkspaceReplacementDuringCoreEdit(t *testing.T) {
	testToolchainSettingsWorkspaceReplacement(t, true)
}

func testToolchainSettingsWorkspaceReplacement(t *testing.T, duringEdit bool) {
	t.Helper()
	original := filepath.Join(t.TempDir(), "workspace")
	if err := os.Mkdir(original, 0o700); err != nil {
		t.Fatal(err)
	}
	kernel := &settingsScopeKernel{testKernel: &testKernel{Client: core.NewClient()}, onEdit: func() {}}
	app := &App{kernel: kernel}
	app.toolchainRoot.Store(&original)
	plugins, err := pluginservice.Open(core.NewClient(), store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	app.plugins = plugins
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	snapshot, err := (settingsToolchains{app: app}).Load(ctx)
	if err != nil {
		t.Fatal(err)
	}
	retired := original + "-retired"
	replace := func() {
		if err := os.Rename(original, retired); err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(original, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if duringEdit {
		kernel.onEdit = replace
	} else {
		replace()
	}
	_, err = (settingsToolchains{app: app}).Save(ctx, snapshot, []toolchain.Edit{{Tool: "dev.example:compiler"}})
	if !errors.Is(err, toolchain.ErrPinConflict) {
		t.Fatalf("replaced workspace save = %v, want conflict", err)
	}
	for _, root := range []string{original, retired} {
		if _, err := os.Stat(filepath.Join(root, ".lithe")); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("replaced workspace was written: %s: %v", root, err)
		}
	}
}

type pinReadbackFailureKernel struct {
	*testKernel
	failReadback bool
}

func (k *pinReadbackFailureKernel) EditToolchainPinSources(ctx context.Context, request core.ToolchainPinSourcesRequest) (core.ToolchainPinSourcesEdit, error) {
	edit, err := k.Client.EditToolchainPinSources(ctx, request)
	if err == nil {
		k.failReadback = true
	}
	return edit, err
}

func (k *pinReadbackFailureKernel) DecodeToolchainPinDocument(ctx context.Context, document *string) (json.RawMessage, error) {
	if k.failReadback {
		return nil, errors.New("fixture source became unreadable after publication")
	}
	return k.Client.DecodeToolchainPinDocument(ctx, document)
}

func TestToolchainSettingsReadbackFailureReportsCommittedSource(t *testing.T) {
	root := t.TempDir()
	kernel := &pinReadbackFailureKernel{testKernel: &testKernel{Client: core.NewClient()}}
	app := &App{kernel: kernel}
	app.toolchainRoot.Store(&root)
	plugins, err := pluginservice.Open(core.NewClient(), store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	app.plugins = plugins
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	adapter := settingsToolchains{app: app}
	snapshot, err := adapter.Load(ctx)
	if err != nil {
		t.Fatal(err)
	}
	_, err = adapter.Save(ctx, snapshot, []toolchain.Edit{{Tool: "dev.example:compiler", Pin: &core.ToolchainPin{Home: "/fixture/tool", Version: "1.0", Provider: "host:system"}}})
	if !errors.Is(err, toolchain.ErrPinCommitted) {
		t.Fatalf("readback failure did not invalidate the baseline: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(root, ".lithe", "toolchains", "local.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(data, []byte("dev.example:compiler")) {
		t.Fatalf("test did not exercise a committed pin: %s", data)
	}
}
