//go:build !windows

package toolchain

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// runtimeManifestLinkingOutside is the fixture runtime whose definition lets
// its program link outside the home.
func runtimeManifestLinkingOutside(t *testing.T) json.RawMessage {
	t.Helper()
	var manifest map[string]any
	if err := json.Unmarshal(readManifest(t, "runtime.plugin.json"), &manifest); err != nil {
		t.Fatal(err)
	}
	definition := manifest["toolDefinitions"].([]any)[0].(map[string]any)
	definition["executableLinksOutsideHome"] = true
	encoded, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

// A virtual environment's program links to its base installation outside the
// environment. Core accepts it only for a definition that allows it and only
// when the host recorded every directory on the layout path, here jre and
// jre/bin. The program is probed and started from the environment's layout
// path, never its target, so it still finds the environment it belongs to.
func TestAnEnvironmentProgramLinkedOutsideItsHomeStartsFromItsLayoutPath(t *testing.T) {
	for _, allowed := range []bool{true, false} {
		name := "definition-allows-it"
		if !allowed {
			name = "definition-keeps-the-program-inside"
		}
		t.Run(name, func(t *testing.T) {
			root, home, base, environment := t.TempDir(), t.TempDir(), t.TempDir(), t.TempDir()
			baseProgram := filepath.Join(base, "jre", "bin", "vm")
			writeExecutable(t, baseProgram)
			bin := filepath.Join(environment, "jre", "bin")
			if err := os.MkdirAll(bin, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(baseProgram, filepath.Join(bin, "vm")); err != nil {
				t.Fatal(err)
			}
			canonicalEnvironment := canonical(t, environment)
			program := filepath.Join(canonicalEnvironment, "jre", "bin", "vm")
			// Only the layout path answers: probing the base program would
			// leave the environment.
			options := fixtureOptions(home, environment, map[string]string{program: "vm 7.1\n"})
			manifest := readManifest(t, "runtime.plugin.json")
			if allowed {
				manifest = runtimeManifestLinkingOutside(t)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			snapshot, err := Load(ctx, core.NewClient(), root, ".", []json.RawMessage{manifest}, options)
			if err != nil {
				t.Fatal(err)
			}
			if len(snapshot.Tools) != 1 {
				t.Fatalf("tools = %+v", snapshot.Tools)
			}
			effective := snapshot.Tools[0].Effective
			if !allowed {
				if effective != nil {
					t.Fatalf("selected %s although the definition keeps its program inside the home", effective.Executable)
				}
				return
			}
			if effective == nil {
				for _, trace := range snapshot.Tools[0].Trace {
					if trace.Reason != nil {
						t.Logf("trace reason = %s", trace.Reason.Code)
					}
				}
				t.Fatal("the environment was not selected")
			}
			if filepath.Clean(effective.Executable) != program || effective.Version != "7.1" {
				t.Fatalf("selection = %s %s, want %s 7.1", effective.Executable, effective.Version, program)
			}
			if effective.Home == nil || filepath.Clean(*effective.Home) != canonicalEnvironment {
				t.Fatalf("home = %v, want %s", effective.Home, canonicalEnvironment)
			}
			if got := effective.Environment["FICTIONAL_VM_HOME"]; filepath.Clean(got) != canonicalEnvironment {
				t.Fatalf("FICTIONAL_VM_HOME = %s, want %s", got, canonicalEnvironment)
			}
		})
	}
}
