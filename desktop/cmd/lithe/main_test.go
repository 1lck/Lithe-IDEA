package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestCLIClassifiesActualFileAndFolder(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "-中文 file.txt")
	if err := os.WriteFile(path, []byte("text"), 0600); err != nil {
		t.Fatal(err)
	}
	client := core.NewClient()
	for _, test := range []struct {
		path string
		file bool
	}{{root, false}, {path, true}} {
		actual, file, err := commandLineTarget(client, test.path)
		expected, resolveErr := filepath.EvalSymlinks(test.path)
		if err != nil || resolveErr != nil || actual != expected || file != test.file {
			t.Fatalf("classify %q: %q %v %v", test.path, actual, file, err)
		}
	}
	if _, _, err := commandLineTarget(client, filepath.Join(root, "missing")); err == nil {
		t.Fatal("missing target accepted")
	}
}
