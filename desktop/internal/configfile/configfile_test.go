package configfile

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func assertNoTemporaryFiles(t *testing.T, root string) {
	t.Helper()
	if err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if strings.HasPrefix(entry.Name(), ".lithe-config-") && strings.HasSuffix(entry.Name(), ".tmp") {
			t.Errorf("temporary file remains: %s", path)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

func TestCaptureMissingSourceDoesNotCreateDirectories(t *testing.T) {
	root := filepath.Join(t.TempDir(), "preferences")
	snapshot, err := Capture(context.Background(), root, "plugin-settings.json", 4096)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Exists() {
		t.Fatal("missing source was reported as existing")
	}
	text, err := snapshot.Text()
	if err != nil || text != nil {
		t.Fatalf("missing text = %v, %v", text, err)
	}
	if _, err := os.Stat(root); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("capture created a root: %v", err)
	}
}

func TestReplacementAndRemovalHonorCapturedBytes(t *testing.T) {
	root := t.TempDir()
	name := ".lithe/plugin-settings.json"
	before, err := Capture(context.Background(), root, name, 4096)
	if err != nil {
		t.Fatal(err)
	}
	committed, err := before.Replace(context.Background(), []byte("first\n"), nil)
	if err != nil || !committed {
		t.Fatalf("first publication: %v, %v", committed, err)
	}
	if _, err := before.Replace(context.Background(), []byte("stale\n"), nil); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale publication: %v", err)
	}
	current, err := Capture(context.Background(), root, name, 4096)
	if err != nil {
		t.Fatal(err)
	}
	bytes := current.Bytes()
	bytes[0] = 'X'
	if text, _ := current.Text(); text == nil || *text != "first\n" {
		t.Fatal("a caller mutated the captured baseline")
	}
	if committed, err := current.Replace(context.Background(), []byte("first\n"), nil); err != nil || committed {
		t.Fatalf("no-op: %v, %v", committed, err)
	}
	if err := os.WriteFile(filepath.Join(root, name), []byte("external\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := current.Remove(context.Background(), nil); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale deletion: %v", err)
	}
	current, err = Capture(context.Background(), root, name, 4096)
	if err != nil {
		t.Fatal(err)
	}
	if committed, err := current.Remove(context.Background(), nil); err != nil || !committed {
		t.Fatalf("deletion: %v, %v", committed, err)
	}
	if _, err := os.Stat(filepath.Join(root, name)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("source remains: %v", err)
	}
	assertNoTemporaryFiles(t, root)
}

func TestFinalCheckAndCancellationKeepOriginalAndCleanTemporary(t *testing.T) {
	for _, cancelOperation := range []bool{false, true} {
		name := "conflict"
		if cancelOperation {
			name = "cancel"
		}
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, "settings.json")
			if err := os.WriteFile(path, []byte("original"), 0o600); err != nil {
				t.Fatal(err)
			}
			snapshot, err := Capture(context.Background(), root, "settings.json", 4096)
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			checks := 0
			committed, err := snapshot.Replace(ctx, []byte("replacement"), func() error {
				checks++
				if checks == 2 {
					if cancelOperation {
						cancel()
						return ctx.Err()
					}
					return ErrConflict
				}
				return nil
			})
			want := ErrConflict
			if cancelOperation {
				want = context.Canceled
			}
			if committed || !errors.Is(err, want) || checks != 2 {
				t.Fatalf("publication = %v, %v, checks %d", committed, err, checks)
			}
			data, readErr := os.ReadFile(path)
			if readErr != nil || string(data) != "original" {
				t.Fatalf("original changed: %q, %v", data, readErr)
			}
			assertNoTemporaryFiles(t, root)
		})
	}
}

func TestCaptureRejectsNonFilesInvalidEncodingAndOversizedSources(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "directory"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := Capture(context.Background(), root, "directory", 8); !errors.Is(err, ErrTarget) {
		t.Fatalf("directory accepted: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "large"), []byte("123456789"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Capture(context.Background(), root, "large", 8); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("oversized source: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "encoding"), []byte{0xff}, 0o600); err != nil {
		t.Fatal(err)
	}
	file, err := Capture(context.Background(), root, "encoding", 8)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.Text(); !errors.Is(err, ErrEncoding) {
		t.Fatalf("invalid UTF-8 repaired: %v", err)
	}
}

func TestCaptureAndPublicationStayWithinNativeRoot(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	if _, err := Capture(context.Background(), root, "../outside", 4096); !errors.Is(err, ErrTarget) {
		t.Fatalf("parent escape: %v", err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "link")); err != nil {
		if runtime.GOOS == "windows" && errors.Is(err, os.ErrPermission) {
			t.Skipf("Windows symbolic-link privilege unavailable: %v", err)
		}
		t.Fatal(err)
	}
	if _, err := Capture(context.Background(), root, "link/settings.json", 4096); err == nil {
		t.Fatal("root escape accepted")
	}
	captured, err := Capture(context.Background(), root, "settings.json", 4096)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(outside, "settings.json"), filepath.Join(root, "settings.json")); err != nil {
		t.Fatal(err)
	}
	if _, err := captured.Replace(context.Background(), []byte("wrong"), nil); err == nil {
		t.Fatal("a newly linked target was accepted")
	}
	if _, err := os.Stat(filepath.Join(outside, "settings.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("outside source changed: %v", err)
	}
}
