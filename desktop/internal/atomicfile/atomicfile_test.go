package atomicfile

import (
	"errors"
	"fmt"
	"io"
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

func TestWriteWithFailureKeepsPreviousBytes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	if err := os.WriteFile(path, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	cause := errors.New("write interrupted")
	err := WriteWith(path, 0o600, func(w io.Writer) error {
		if _, err := w.Write([]byte("partial")); err != nil {
			return err
		}
		return cause
	})
	if !errors.Is(err, cause) {
		t.Fatalf("write failed with %v, want %v", err, cause)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "old" {
		t.Fatalf("previous content lost: %q, %v", data, err)
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil || len(entries) != 1 {
		t.Fatalf("temporary files left behind: %v, %v", entries, err)
	}
}

func TestInstallOnlyAcceptsIdenticalConcurrentWriter(t *testing.T) {
	for _, same := range []bool{true, false} {
		t.Run(fmt.Sprint(same), func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "binary")
			err := InstallWithRename(path, []byte("right"), 0o600, func(_, target string) error {
				value := []byte("wrong")
				if same {
					value = []byte("right")
				}
				if err := os.WriteFile(target, value, 0o600); err != nil {
					return err
				}
				return errors.New("rename denied by another client")
			})
			if same && err != nil {
				t.Fatalf("matching installation rejected: %v", err)
			}
			if !same && err == nil {
				t.Fatal("mismatched installation accepted")
			}
			entries, err := os.ReadDir(filepath.Dir(path))
			if err != nil || len(entries) != 1 {
				t.Fatalf("temporary file remains: %v, %v", entries, err)
			}
		})
	}
}
