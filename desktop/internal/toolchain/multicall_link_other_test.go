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

// A version manager can install every tool as a link to one multi-call
// executable that picks the tool by the name it was started under (rustup's
// cargo and rust-analyzer). The probe and the launch must start the layout
// name; the link target answers for itself, so its output never matches the
// tool's version pattern and the installation would never be found.
func TestALayoutLinkedToAMultiCallExecutableIsStartedByItsLayoutName(t *testing.T) {
	root, home, vmHome := t.TempDir(), t.TempDir(), t.TempDir()
	bin := filepath.Join(vmHome, "jre", "bin")
	multiplexer := filepath.Join(bin, "multiplexer")
	writeExecutable(t, multiplexer)
	if err := os.Symlink("multiplexer", filepath.Join(bin, "vm")); err != nil {
		t.Fatal(err)
	}
	canonicalHome := canonical(t, vmHome)
	vm := filepath.Join(canonicalHome, "jre", "bin", "vm")
	options := fixtureOptions(home, vmHome, map[string]string{
		vm: "vm 7.1\n",
		filepath.Join(canonicalHome, "jre", "bin", "multiplexer"): "multiplexer 1.0\n",
	})
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	snapshot, err := Load(ctx, core.NewClient(), root, ".", []json.RawMessage{readManifest(t, "runtime.plugin.json")}, options)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Tools) != 1 {
		t.Fatalf("tools = %+v", snapshot.Tools)
	}
	effective := snapshot.Tools[0].Effective
	if effective == nil {
		for _, trace := range snapshot.Tools[0].Trace {
			if trace.Reason != nil {
				t.Logf("trace reason = %s", trace.Reason.Code)
			}
		}
		t.Fatal("the linked installation was not selected")
	}
	if filepath.Clean(effective.Executable) != vm || effective.Version != "7.1" {
		t.Fatalf("selection = %s %s, want %s 7.1", effective.Executable, effective.Version, vm)
	}
}
