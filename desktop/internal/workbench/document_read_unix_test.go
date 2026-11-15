//go:build darwin || linux

package workbench

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"golang.org/x/sys/unix"
)

// A subprocess makes a regression that blocks opening a FIFO bounded and reclaimable.
func TestDocumentReadRejectsFIFO(t *testing.T) {
	const helper = "LITHE_TEST_DOCUMENT_FIFO"
	if path := os.Getenv(helper); path != "" {
		_, err := readDocument(path)
		if !errors.Is(err, documentio.ErrNotRegular) {
			t.Fatalf("opening FIFO returned %v, want non-regular-file error", err)
		}
		return
	}
	path := filepath.Join(t.TempDir(), "pipe")
	if err := unix.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestDocumentReadRejectsFIFO$")
	command.Env = append(os.Environ(), helper+"="+path)
	output, err := command.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("opening FIFO did not finish within deadline: %v", ctx.Err())
	}
	if err != nil {
		t.Fatalf("FIFO read check failed: %v: %s", err, output)
	}
}

func TestDocumentReadRejectsSymlinkAndAllowsHardLink(t *testing.T) {
	dir := t.TempDir()
	original := filepath.Join(dir, "original")
	if err := os.WriteFile(original, []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}
	symlink := filepath.Join(dir, "symlink")
	if err := os.Symlink(original, symlink); err != nil {
		t.Fatal(err)
	}
	if _, err := readDocument(symlink); !errors.Is(err, documentio.ErrSymbolicLink) {
		t.Fatalf("opening symlink returned %v, want symlink error", err)
	}
	hardlink := filepath.Join(dir, "hardlink")
	if err := os.Link(original, hardlink); err != nil {
		t.Fatal(err)
	}
	data, err := readDocument(hardlink)
	if err != nil || string(data) != "hello" {
		t.Fatalf("opening hardlink returned %q, %v", data, err)
	}
}
