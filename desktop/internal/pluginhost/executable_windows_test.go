package pluginhost

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestResolveExecutableAcceptsWindowsImageAndRejectsData(t *testing.T) {
	root := t.TempDir()
	current, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	image, err := os.ReadFile(current)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"adapter.exe", "adapter"} {
		path := filepath.Join(root, name)
		if err := os.WriteFile(path, image, 0o600); err != nil {
			t.Fatal(err)
		}
		resolved, err := ResolveExecutable(root, name)
		if err != nil || resolved != path {
			t.Fatalf("native Windows image %s: resolved=%s error=%v", name, resolved, err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "data.exe"), []byte("not a native executable"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := ResolveExecutable(root, "data.exe"); !errors.Is(err, ErrNotExecutable) {
		t.Fatalf("data file error = %v", err)
	}
}
