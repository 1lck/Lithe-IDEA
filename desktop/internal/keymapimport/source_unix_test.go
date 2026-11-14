//go:build !windows

package keymapimport

import (
	"os"
	"path/filepath"
	"testing"
)

// A selected file can be readable even when listing/opening its parent is not.
// macOS file-picker grants have this same boundary in protected directories.
func TestImportSelectedSourceNeedsNoParentDirectoryRead(t *testing.T) {
	root := filepath.Join(t.TempDir(), "selected-only")
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "keys.json")
	if err := os.WriteFile(path, []byte(`[]`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(root, 0111); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.Chmod(root, 0700); err != nil {
			t.Error(err)
		}
	})
	snapshot, err := Read(t.Context(), path)
	if err != nil || snapshot.Content() != `[]` {
		t.Fatalf("selected file required parent access: %v", err)
	}
	if err = snapshot.Revalidate(t.Context()); err != nil {
		t.Fatal(err)
	}
}
