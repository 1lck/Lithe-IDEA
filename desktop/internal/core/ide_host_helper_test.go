package core

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestResolveIDEHelperPath(t *testing.T) {
	dir := t.TempDir()
	artifact := filepath.Join(t.TempDir(), "bin")
	if _, err := ResolveIDEHelperPath(dir, artifact); !errors.Is(err, ErrIDEHelperMissing) {
		t.Fatalf("missing helper error = %v", err)
	}
	writeFile(t, filepath.Join(artifact, IDEHelperName()), "")
	got, err := ResolveIDEHelperPath(dir, artifact)
	if err != nil || got != filepath.Join(artifact, IDEHelperName()) {
		t.Fatalf("artifact helper = %q, %v", got, err)
	}
	// A directory with the same name is not a helper.
	if err := os.MkdirAll(filepath.Join(dir, IDEHelperName()), 0o755); err != nil {
		t.Fatal(err)
	}
	if got, err := ResolveIDEHelperPath(dir, artifact); err != nil || got != filepath.Join(artifact, IDEHelperName()) {
		t.Fatalf("directory candidate = %q, %v", got, err)
	}
}
