//go:build !windows

package toolchain

import (
	"os"
	"testing"
)

func linkToolchainDirectory(t *testing.T, target, link string) {
	t.Helper()
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
}
