package marketplace

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRemoteArchiveCacheKeepsRecentlyUsedArchivesWithinItsBudget(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	root := t.TempDir()
	cache := RemoteArchiveCache{directory: filepath.Join(root, "cache"), maxBytes: 8}
	download := func(body string) string {
		t.Helper()
		selection := archiveSelection(body)
		archive, err := newArchiveDownloader(archiveClient(body, int64(len(body))), root).Download(ctx, selection)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			if err := archive.Discard(); err != nil {
				t.Error(err)
			}
		})
		if err := cache.Store(ctx, selection.SHA256, archive); err != nil {
			t.Fatal(err)
		}
		return selection.SHA256
	}
	read := func(digest, want string) error {
		t.Helper()
		used, err := cache.Read(ctx, digest, func(path string) error {
			bytes, err := os.ReadFile(path)
			if err == nil && string(bytes) != want {
				t.Errorf("cached bytes = %q, want %q", bytes, want)
			}
			return err
		})
		if err == nil && !used {
			return os.ErrNotExist
		}
		return err
	}
	first, second := download("old!"), download("two!")
	for _, digest := range []string{first, second} {
		past := time.Unix(1, 0)
		if err := os.Chtimes(filepath.Join(cache.directory, digest), past, past); err != nil {
			t.Fatal(err)
		}
	}
	if err := read(first, "old!"); err != nil {
		t.Fatal(err)
	}
	// Simulate the private staging file left by a process that was killed.
	if err := os.WriteFile(filepath.Join(cache.directory, remoteCachePending), []byte("partial"), 0o600); err != nil {
		t.Fatal(err)
	}
	third := download("new!")
	if err := read(second, "two!"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("least recently used archive survives: %v", err)
	}
	if err := read(first, "old!"); err != nil {
		t.Fatal(err)
	}
	if err := read(third, "new!"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(cache.directory, remoteCachePending)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("abandoned archive survives: %v", err)
	}
}
