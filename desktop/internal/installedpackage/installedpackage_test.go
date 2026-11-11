package installedpackage

import (
	"os"
	"path/filepath"
	"testing"
)

// fakeBundle lays out a macOS app bundle with an executable and one resource folder, and returns
// the bundle root and the executable path.
func fakeBundle(t *testing.T) (string, string) {
	t.Helper()
	root := filepath.Join(t.TempDir(), "Lithe.app")
	executable := filepath.Join(root, "Contents", "MacOS", "lithe")
	for _, directory := range []string{filepath.Dir(executable), filepath.Join(root, "Contents", "Resources", "Fonts")} {
		if err := os.MkdirAll(directory, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(executable, []byte("binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	return root, executable
}

func TestResourceFolderFindsOnlyAnExistingFolderInsideAnAppBundle(t *testing.T) {
	root, executable := fakeBundle(t)
	if got, want := resourceFolder(executable, "Fonts"), filepath.Join(root, "Contents", "Resources", "Fonts"); got != want {
		t.Fatalf("resourceFolder = %q, want %q", got, want)
	}
	if got := resourceFolder(executable, "Missing"); got != "" {
		t.Fatalf("a folder the bundle lacks = %q, want empty", got)
	}
	if got := resourceFolder(executable, ""); got != "" {
		t.Fatalf("an empty name = %q, want empty", got)
	}
	loose := filepath.Join(t.TempDir(), "lithe")
	if got := resourceFolder(loose, "Fonts"); got != "" {
		t.Fatalf("an executable outside a bundle = %q, want empty", got)
	}
}

func TestResourceFolderIsEmptyForTheTestExecutable(t *testing.T) {
	// go test runs a binary from a temporary build folder, never from an app bundle, so the
	// public lookup must report no bundle rather than guess a folder next to it.
	if got := ResourceFolder("Fonts"); got != "" {
		t.Fatalf("ResourceFolder outside a bundle = %q, want empty", got)
	}
	if _, err := Executable(); err != nil {
		t.Fatal(err)
	}
}
