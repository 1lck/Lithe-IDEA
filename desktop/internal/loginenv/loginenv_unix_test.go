//go:build !windows

package loginenv

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWriteCachePreservesAnotherWritersStagedPath(t *testing.T) {
	path := filepath.Join(t.TempDir(), "login-path")
	// A second instance has finished writing its PATH but has not renamed it yet.
	staged := path + ".tmp"
	if err := os.WriteFile(staged, []byte("/other/bin\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writeCache(path, "/current/bin"); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil || string(got) != "/current/bin\n" {
		t.Fatalf("published PATH = %q, %v", got, err)
	}
	got, err = os.ReadFile(staged)
	if err != nil || string(got) != "/other/bin\n" {
		t.Fatalf("other writer's staged PATH = %q, %v", got, err)
	}
}

func TestFailedCacheReplacementReturnsErrorAndCleansUpStaging(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "login-path")
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := writeCache(path, "/current/bin"); err == nil {
		t.Fatal("replaced a directory with a PATH cache")
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 1 || entries[0].Name() != "login-path" || !entries[0].IsDir() {
		t.Fatalf("unexpected files after failed replacement: %v, %v", entries, err)
	}
}
