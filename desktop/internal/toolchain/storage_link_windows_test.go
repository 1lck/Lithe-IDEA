package toolchain

import (
	"context"
	"os/exec"
	"testing"
	"time"
)

// A junction exercises the same escaping reparse-point boundary without
// requiring a machine-wide developer-mode or symbolic-link privilege change.
func linkToolchainDirectory(t *testing.T, target, link string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "cmd.exe", "/d", "/c", "mklink", "/J", link, target).CombinedOutput()
	if err != nil {
		t.Fatalf("create owned directory junction: %v\n%s", err, output)
	}
}
