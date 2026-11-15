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
	if data, err := readBoundedLimit(reader, 0, maxBytes); !errors.Is(err, ErrTooLarge) || data != nil {
		t.Fatalf("growing stream returned %d bytes and %v", len(data), err)
	}
}

func TestReadFileLimitEnforcesSmallMetadataBudget(t *testing.T) {
	path := filepath.Join(t.TempDir(), "metadata")
	if err := os.WriteFile(path, []byte("1234"), 0o600); err != nil {
		t.Fatal(err)
	}
	if data, err := ReadFileLimit(path, 4); err != nil || string(data) != "1234" {
		t.Fatalf("bounded read = %q, %v", data, err)
	}
	if _, err := ReadFileLimit(path, 3); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("oversized metadata error = %v", err)
	}
	for _, tc := range []struct {
		content string
		limit   int64
	}{{"x", 0}, {"12345", 4}, {strings.Repeat("x", 4097), 4096}} {
		if data, err := readBoundedLimit(strings.NewReader(tc.content), 0, tc.limit); !errors.Is(err, ErrTooLarge) || data != nil {
			t.Fatalf("growing content of %d bytes with limit %d returned %d bytes, %v", len(tc.content), tc.limit, len(data), err)
		}
	}
}
