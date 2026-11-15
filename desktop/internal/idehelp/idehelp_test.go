package idehelp

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func withBytes(t *testing.T, data []byte) {
	t.Helper()
	original := installBytes
	installBytes = func() []byte { return data }
	t.Cleanup(func() { installBytes = original })
}

func TestInstallWritesTheHelperOnceAndReplacesAnotherVersion(t *testing.T) {
	withBytes(t, []byte("first helper"))
	dir := t.TempDir()
	path, err := Install(dir, "lithe-mcp")
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(dir, "bin", "lithe-mcp"); path != want {
		t.Fatalf("path = %q, want %q", path, want)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	// Windows has no permission bits: Go reports every writable file as 0666 there, and the
	// user's profile directory is what keeps the helper private.
	if runtime.GOOS != "windows" && (info.Mode().Perm() != 0o700 || info.Mode()&0o111 == 0) {
		t.Fatalf("mode = %v, want an executable file only the user can use", info.Mode())
	}
	first, _ := os.Stat(path)
	if _, err := Install(dir, "lithe-mcp"); err != nil {
		t.Fatal(err)
	}
	second, _ := os.Stat(path)
	if !os.SameFile(first, second) || !second.ModTime().Equal(first.ModTime()) {
		t.Fatal("installing the same helper rewrote it")
	}
	// A stale helper from another release is replaced atomically with the embedded bytes.
	withBytes(t, []byte("second helper"))
	path, err = Install(dir, "lithe-mcp")
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "second helper" {
		t.Fatalf("helper = %q, %v", data, err)
	}
}

func TestInstallRefusesABuildWithoutTheHelper(t *testing.T) {
	withBytes(t, nil)
	if _, err := Install(t.TempDir(), "lithe-mcp"); err != ErrNotBundled {
		t.Fatalf("error = %v, want ErrNotBundled", err)
	}
	withBytes(t, []byte("helper"))
	if _, err := Install(t.TempDir(), ""); err == nil || err == ErrNotBundled {
		t.Fatalf("empty name error = %v, want a name error", err)
	}
}
