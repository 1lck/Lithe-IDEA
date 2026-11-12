package documentio

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestGuardedWriteRejectsExternalChanges(t *testing.T) {
	path := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(path, []byte("external"), 0o600); err != nil {
		t.Fatal(err)
	}
	err := WriteGuarded(path, []byte("local"), []byte("original"))
	if !errors.Is(err, ErrConflict) {
		t.Fatalf("error = %v; want conflict", err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "external" {
		t.Fatalf("content = %q, error = %v", data, err)
	}
}

func TestGuardedWriteDoesNotRecreateDeletedFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "removed")
	err := WriteGuarded(path, []byte("new"), []byte("original"))
	if !errors.Is(err, ErrConflict) {
		t.Fatalf("error = %v; want conflict", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("removed file recreated: %v", err)
	}
}

func TestGuardedWritePreservesEmptyBaseline(t *testing.T) {
	path := filepath.Join(t.TempDir(), "empty")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := WriteGuarded(path, []byte("new"), []byte{}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "new" {
		t.Fatalf("content = %q, error = %v", data, err)
	}
}
