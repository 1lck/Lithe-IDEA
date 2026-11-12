package toolchain

import (
	"context"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestProbeAllCoalescesWindowsNativePathAliases(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	path := filepath.Join(t.TempDir(), "bin", "compiler.exe")
	var calls atomic.Int32
	workspace := workspace{caseSensitive: false, probe: func(context.Context, string, []string) (string, int, error) {
		calls.Add(1)
		return "Compiler 3.2.1", 0, nil
	}}
	probes := workspace.probeAll(ctx, core.ToolchainToolDefinition{
		Version: core.ToolchainVersionRule{Arguments: []string{"--version"}},
	}, []string{path, filepath.ToSlash(path), strings.ToUpper(path)})
	if calls.Load() != 1 || len(probes) != 1 {
		t.Fatalf("one native executable was probed %d times: %+v", calls.Load(), probes)
	}
	if filepath.Clean(probes[0].Executable) != probes[0].Executable {
		t.Fatalf("probe path was not adapted for native execution: %q", probes[0].Executable)
	}
}
