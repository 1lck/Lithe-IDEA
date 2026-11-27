package pluginpkg

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestReadFileEnforcesTheLimit(t *testing.T) {
	dir := t.TempDir()
	const manifest = `{"displayName":"Fixture"}`
	if err := os.WriteFile(filepath.Join(dir, ManifestFile), []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadFile(dir, []string{ManifestFile}, int64(len(manifest)-1)); !errors.Is(err, ErrReadTooLarge) {
		t.Fatalf("a file over the limit was read: %v", err)
	}
	if data, err := ReadFile(dir, []string{ManifestFile}, int64(len(manifest))); err != nil || string(data) != manifest {
		t.Fatalf("read = %q %v", data, err)
	}
}

func TestReadFileReadsOnlyRegularPackageFiles(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "icons", "nested"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "icons", "a.svg"), []byte("<svg/>"), 0o644); err != nil {
		t.Fatal(err)
	}
	if data, err := ReadFile(dir, []string{"icons", "a.svg"}, 1<<10); err != nil || string(data) != "<svg/>" {
		t.Fatalf("read = %q %v", data, err)
	}
	if _, err := ReadFile(dir, nil, 1<<20); !errors.Is(err, ErrNotPackageFile) {
		t.Fatalf("the package directory itself was read: %v", err)
	}
	if _, err := ReadFile(dir, []string{"icons", "nested"}, 1<<20); !errors.Is(err, ErrNotPackageFile) {
		t.Fatalf("a directory was read: %v", err)
	}
	if _, err := ReadFile(dir, []string{"icons", "missing.svg"}, 1<<20); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("missing file = %v", err)
	}
	if err := os.Symlink(filepath.Join(dir, "icons"), filepath.Join(dir, "linked")); err != nil {
		t.Skipf("symbolic links are unavailable: %v", err)
	}
	if err := os.Symlink(filepath.Join(dir, "icons", "a.svg"), filepath.Join(dir, "icons", "b.svg")); err != nil {
		t.Fatal(err)
	}
	for _, segments := range [][]string{{"linked", "a.svg"}, {"icons", "b.svg"}} {
		if _, err := ReadFile(dir, segments, 1<<20); !errors.Is(err, ErrNotPackageFile) {
			t.Fatalf("%v was read through a link: %v", segments, err)
		}
	}
}
