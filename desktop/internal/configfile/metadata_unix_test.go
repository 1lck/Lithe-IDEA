//go:build darwin || linux

package configfile

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

func TestNativeConfigPublicationPreservesUnixModeAndAttributes(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "settings.json")
	if err := os.WriteFile(path, []byte("original"), 0o640); err != nil {
		t.Fatal(err)
	}
	for _, value := range [][]byte{[]byte("fixture-value"), {}} {
		func() {
			file, err := os.OpenFile(path, os.O_RDWR, 0)
			if err != nil {
				t.Fatal(err)
			}
			defer func() {
				if err := file.Close(); err != nil {
					t.Error(err)
				}
			}()
			const attribute = "user.lithe.fixture"
			if err := unix.Fsetxattr(int(file.Fd()), attribute, value, 0); err != nil {
				t.Fatal(err)
			}
			snapshot, err := Capture(context.Background(), root, "settings.json", 4096)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := snapshot.Replace(context.Background(), []byte("replacement"+string(value)), nil); err != nil {
				t.Fatal(err)
			}
			published, err := os.Open(path)
			if err != nil {
				t.Fatal(err)
			}
			defer func() {
				if err := published.Close(); err != nil {
					t.Error(err)
				}
			}()
			info, err := published.Stat()
			if err != nil {
				t.Fatal(err)
			}
			if info.Mode().Perm() != 0o640 {
				t.Fatalf("mode changed to %v", info.Mode())
			}
			buffer := make([]byte, 256)
			count, err := unix.Fgetxattr(int(published.Fd()), attribute, buffer)
			if err != nil {
				t.Fatal(err)
			}
			if string(buffer[:count]) != string(value) {
				t.Fatalf("attribute changed: %q", buffer[:count])
			}
		}()
	}
	assertNoTemporaryFiles(t, root)
}
