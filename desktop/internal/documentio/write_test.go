package documentio

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestWriteReplacesFileAndKeepsPermissions(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "document.txt")
	if err := os.WriteFile(path, []byte("old content"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := WriteGuarded(path, []byte("new"), []byte("old content")); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "new" {
		t.Fatalf("content = %q, error = %v", data, err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm() != 0o640 {
		t.Fatalf("permissions = %o", info.Mode().Perm())
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 1 {
		t.Fatalf("directory entries = %v, error = %v", entries, err)
	}
}

func TestWriteRejectsSymbolicLink(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("creating symbolic links can require Windows privileges")
	}
	dir := t.TempDir()
	target, link := filepath.Join(dir, "target"), filepath.Join(dir, "link")
	if err := os.WriteFile(target, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("target", link); err != nil {
		t.Fatal(err)
	}
	if err := WriteGuarded(link, []byte("new"), []byte("old")); err == nil {
		t.Fatal("a symbolic link was silently overwritten")
	}
	data, err := os.ReadFile(target)
	if err != nil || string(data) != "old" {
		t.Fatalf("target = %q, error = %v", data, err)
	}
}

func TestWriteRejectsMissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing")
	if err := WriteGuarded(path, []byte("data"), []byte("old")); !errors.Is(err, ErrConflict) {
		t.Fatalf("missing file error = %v", err)
	}
}

func TestWriteMissingCreatesWithoutReplacingAnEntry(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "document.txt")
	if err := WriteMissing(path, []byte("recovered")); err != nil {
		t.Fatal(err)
	}
	if err := WriteMissing(path, []byte("other")); !errors.Is(err, ErrConflict) {
		t.Fatalf("existing target error = %v, want conflict", err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "recovered" {
		t.Fatalf("content = %q, error = %v", data, err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 1 {
		t.Fatalf("staging files remained: %v, error = %v", entries, err)
	}
}

func TestWriteMissingDoesNotReplaceSymlink(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("creating symbolic links can require Windows privileges")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "document.txt")
	if err := os.Symlink("absent-target", path); err != nil {
		t.Fatal(err)
	}
	if err := WriteMissing(path, []byte("editor")); !errors.Is(err, ErrConflict) {
		t.Fatalf("symlink error = %v, want conflict", err)
	}
	if target, err := os.Readlink(path); err != nil || target != "absent-target" {
		t.Fatalf("symlink changed: %q, %v", target, err)
	}
}
