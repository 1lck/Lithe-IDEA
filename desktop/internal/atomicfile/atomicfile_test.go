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

func TestWriteWithCheckCancellationBeforeRenameKeepsOriginal(t *testing.T) {
	path := filepath.Join(t.TempDir(), "archive")
	if err := os.WriteFile(path, []byte("old archive"), 0o600); err != nil {
		t.Fatal(err)
	}
	canceled := errors.New("canceled before commit")
	err := WriteWithCheck(path, 0o600, func(w io.Writer) error {
		_, err := w.Write([]byte("new archive"))
		return err
	}, func() error { return canceled })
	if !errors.Is(err, canceled) {
		t.Fatalf("cancellation = %v, want %v", err, canceled)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "old archive" {
		t.Fatalf("canceled write replaced original: %q, %v", data, err)
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil || len(entries) != 1 {
		t.Fatalf("temporary file remained: %v, %v", entries, err)
	}
}

func TestInstallDoesNotSwallowNonRenameErrorsEvenWhenTargetMatches(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "binary")
	wantErr := errors.New("disk write error")
	err := writeWithRename(path, 0o600, func(w io.Writer) error {
		if err := os.WriteFile(path, []byte("right"), 0o600); err != nil {
			return err
		}
		return wantErr
	}, os.Rename, nil, func() bool {
		return holds(path, []byte("right"))
	})
	if !errors.Is(err, wantErr) {
		t.Fatalf("non-rename error swallowed or replaced: %v, want %v", err, wantErr)
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 1 {
		t.Fatalf("temporary file remained: %v, %v", entries, err)
	}
}

func TestWriteAndInstallRejectInvalidPaths(t *testing.T) {
	for _, invalid := range []string{"", ".", ".."} {
		if err := Write(invalid, []byte("x"), 0o600); err == nil {
			t.Fatalf("Write(%q) succeeded", invalid)
		}
		if err := Install(invalid, []byte("x"), 0o600); err == nil {
			t.Fatalf("Install(%q) succeeded", invalid)
		}
	}
	if err := WriteWith(filepath.Join(t.TempDir(), "file"), 0o600, nil); err == nil {
		t.Fatal("WriteWith(nil) succeeded")
	}
}

func TestWriteWithStreamsToFileDirectly(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "streamed.bin")
	err := WriteWith(path, 0o600, func(w io.Writer) error {
		f, ok := w.(*os.File)
		if !ok {
			return fmt.Errorf("writer is %T, want *os.File", w)
		}
		if _, err := w.Write([]byte("chunk-1-")); err != nil {
			return err
		}
		info, err := f.Stat()
		if err != nil {
			return err
		}
		if info.Size() != int64(len("chunk-1-")) {
			return fmt.Errorf("size after first write = %d, want incremental write without buffering", info.Size())
		}
		_, err = w.Write([]byte("chunk-2"))
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil || string(got) != "chunk-1-chunk-2" {
		t.Fatalf("streamed file = %q, %v", got, err)
	}
}
