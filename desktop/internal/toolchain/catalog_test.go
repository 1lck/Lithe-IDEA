package toolchain

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestGlobalCatalogWithoutProjectPersistsSDKsAndAllowsProjectOverrides(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	kernel := core.NewClient()
	settings := filepath.Join(t.TempDir(), "user-settings")
	home := t.TempDir()
	first, second := filepath.Join(t.TempDir(), "sdk8"), filepath.Join(t.TempDir(), "sdk21")
	outputs := map[string]string{}
	for _, sdk := range []string{first, second} {
		exe := filepath.Join(sdk, "bin", "cc")
		writeExecutable(t, exe)
		outputs[canonical(t, exe)] = "Compiler 3.2.1\n"
	}
	first, second = canonical(t, first), canonical(t, second)
	options := fixtureOptions(home, "", outputs)
	options.Global, options.GlobalRoot = true, settings
	manifests := []json.RawMessage{readManifest(t, "compiler.plugin.json")}
	snapshot, err := Load(ctx, kernel, "", ".", manifests, options)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(settings); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("reading global settings created the root: %v", err)
	}
	const tool = "dev.example.toolsmith:compiler"
	snapshot.Tools[0].CustomHomes = []string{first, second}
	edits := []Edit{{Tool: tool, Pin: &core.ToolchainPin{Home: second, Version: "3.2.1", Provider: "host:manual"}}}
	if changed, err := snapshot.SaveCatalog(ctx, kernel, edits); err != nil || !changed {
		t.Fatalf("save global catalog = %v, %v", changed, err)
	}
	loaded, err := Load(ctx, kernel, "", ".", manifests, options)
	if err != nil {
		t.Fatal(err)
	}
	if len(loaded.Tools) != 1 || len(loaded.Tools[0].CustomHomes) != 2 || loaded.Tools[0].Effective == nil || loaded.Tools[0].Effective.Home == nil || *loaded.Tools[0].Effective.Home != second {
		t.Fatalf("global SDK readback = %+v", loaded.Tools)
	}
	if _, err := snapshot.SaveCatalog(ctx, kernel, edits); !errors.Is(err, ErrPinConflict) {
		t.Fatalf("stale global source was reused: %v", err)
	}
	options.Global = false
	for range 2 {
		root := t.TempDir()
		selected, err := Resolve(ctx, kernel, root, ".", tool, "", nil, manifests, options)
		if err != nil || selected.Home == nil || *selected.Home != second {
			t.Fatalf("a different project did not inherit the global default: %+v, %v", selected, err)
		}
		if _, err := os.Stat(filepath.Join(root, ".lithe")); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("inheriting a global SDK wrote project state: %v", err)
		}
		project, err := Load(ctx, kernel, root, ".", manifests, options)
		if err != nil {
			t.Fatal(err)
		}
		if _, _, err := project.SavePins(ctx, kernel, []Edit{{Tool: tool, Pin: &core.ToolchainPin{Home: first, Version: "3.2.1", Provider: "host:manual"}}}); err != nil {
			t.Fatal(err)
		}
		selected, err = Resolve(ctx, kernel, root, ".", tool, "", nil, manifests, options)
		if err != nil || selected.Home == nil || *selected.Home != first || selected.Layer != "pinned" {
			t.Fatalf("the explicit project SDK did not override the default: %+v, %v", selected, err)
		}
	}
}
