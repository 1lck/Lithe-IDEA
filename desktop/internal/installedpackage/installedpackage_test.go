package installedpackage

import (
	"os"
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
