package workbench

import (
	"io"
	"os"
	"testing"
)

// copyTestBinary makes the running test executable available at dest so a fixture can
// start it as an external process with a -test.run helper. A hard link is preferred: the
// fixture is never written, and linking keeps one file instead of writing the test binary's
// full size for every fixture (the platform then validates one code identity, not a new one
// per test). A filesystem without hard links falls back to a copy.
func copyTestBinary(t *testing.T, dest string) {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Link(executable, dest); err == nil {
		return
	}
	source, err := os.Open(executable)
	if err != nil {
		t.Fatal(err)
	}
	target, err := os.OpenFile(dest, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		source.Close()
		t.Fatal(err)
	}
	_, copyErr := io.Copy(target, source)
	closeTargetErr := target.Close()
	closeSourceErr := source.Close()
	if copyErr != nil || closeTargetErr != nil || closeSourceErr != nil {
		t.Fatalf("copy test binary: %v, close: %v, %v", copyErr, closeTargetErr, closeSourceErr)
	}
}
