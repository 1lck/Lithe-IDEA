//go:build darwin || linux

package documentio

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

func TestGuardedWriteKeepsExtendedAttributes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(path, []byte("original"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := unix.Setxattr(path, "user.lithe.test", []byte("attribute"), 0); err != nil {
		t.Fatal(err)
	}
	if err := WriteGuarded(path, []byte("new"), []byte("original")); err != nil {
		t.Fatal(err)
	}
	data := make([]byte, 64)
	n, err := unix.Getxattr(path, "user.lithe.test", data)
	if err != nil || string(data[:n]) != "attribute" {
		t.Fatalf("attribute = %q, error = %v", data[:max(n, 0)], err)
	}
}

func TestGuardedWriteRejectsHardLinks(t *testing.T) {
	dir := t.TempDir()
	path, alias := filepath.Join(dir, "file"), filepath.Join(dir, "alias")
	if err := os.WriteFile(path, []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(path, alias); err != nil {
		t.Fatal(err)
	}
	if err := WriteGuarded(path, []byte("new"), []byte("original")); !errors.Is(err, ErrHardLink) {
		t.Fatalf("error = %v", err)
	}
	for _, p := range []string{path, alias} {
		data, err := os.ReadFile(p)
		if err != nil || string(data) != "original" {
			t.Fatalf("%s = %q, error = %v", p, data, err)
		}
	}
}
