package documentio

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadFilePreservesContentAndEnforcesSize(t *testing.T) {
	path := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(path, []byte("hello\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	data, err := ReadFile(path)
	if err != nil || string(data) != "hello\n" {
		t.Fatalf("read = %q, %v", data, err)
	}
	file, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Truncate(maxBytes + 1); err != nil {
		file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadFile(path); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("large file error = %v", err)
	}
}

func TestReadBoundsBytesWhenSizeChanges(t *testing.T) {
	reader := strings.NewReader(strings.Repeat("x", maxBytes+1))
	if data, err := readBounded(reader, 0); !errors.Is(err, ErrTooLarge) || data != nil {
		t.Fatalf("growing stream returned %d bytes and %v", len(data), err)
	}
}
