package installedpackage

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestExecutableIsTheRunningProgram(t *testing.T) {
	got, err := Executable()
	if err != nil {
		t.Fatal(err)
	}
	want, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("Executable = %q, want %q", got, want)
	}
}

func TestRootIncludesEveryProductionResourceDirectory(t *testing.T) {
	base := filepath.Join(t.TempDir(), "Lithe.app")
	executable := filepath.Join(base, "Contents", "MacOS", "lithe")
	want := filepath.Dir(executable)
	if runtime.GOOS == "darwin" {
		want = base
	}
	if got := rootForExecutable(executable); got != want {
		t.Fatalf("installation root = %q; want %q", got, want)
	}
	windowsStyle := filepath.Join(t.TempDir(), "Lithe", "lithe.exe")
	if got := rootForExecutable(windowsStyle); got != filepath.Dir(windowsStyle) {
		t.Fatalf("executable resources escaped installation: %q", got)
	}
}
