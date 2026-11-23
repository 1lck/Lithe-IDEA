package atomicfile

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestInstallKeepsSameBytesAndAtomicallyReplacesStaleOnes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "binary")
	if err := Install(path, []byte("first"), 0o700); err != nil {
		t.Fatal(err)
	}
	initial, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && initial.Mode().Perm() != 0o700 {
		t.Fatalf("mode = %v", initial.Mode())
	}
	if err := Install(path, []byte("first"), 0o700); err != nil {
		t.Fatal(err)
	}
	same, err := os.Stat(path)
	if err != nil || !os.SameFile(initial, same) {
		t.Fatalf("same bytes rewritten: %v", err)
	}
	if err := Install(path, []byte("second"), 0o600); err != nil {
		t.Fatal(err)
	}
	changed, err := os.ReadFile(path)
	if err != nil || string(changed) != "second" {
		t.Fatalf("%q, %v", changed, err)
	}
	if runtime.GOOS != "windows" {
		info, err := os.Stat(path)
		if err != nil || info.Mode().Perm() != 0o600 {
			t.Fatalf("mode = %v, %v", info.Mode(), err)
		}
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil || len(entries) != 1 {
		t.Fatalf("leftover temporary files: %v %v", entries, err)
	}
}

func TestInstallReplacesSymlinkRatherThanAcceptMatchingTarget(t *testing.T) {
	dir := t.TempDir()
	outside := filepath.Join(dir, "outside")
	if err := os.WriteFile(outside, []byte("expected"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "inside")
	if err := os.Symlink(outside, link); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	if err := Install(link, []byte("expected"), 0o600); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(link)
	if err != nil || !info.Mode().IsRegular() {
		t.Fatalf("did not replace symlink: %v %v", info, err)
	}
}

func TestWriteFailureLeavesNoTemporaryFile(t *testing.T) {
	dir := t.TempDir()
	blocker := filepath.Join(dir, "blocker")
	if err := os.WriteFile(blocker, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := Write(filepath.Join(blocker, "child"), []byte("x"), 0o600); err == nil {
		t.Fatal("write inside regular file succeeded")
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 1 {
		t.Fatalf("unexpected files: %v %v", entries, err)
	}
}
