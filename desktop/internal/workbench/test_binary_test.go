package workbench

import (
	"io"
	"os"
	"testing"
)

// copyTestBinary copies the running test executable to dest so a fixture can
// start it as an external process with a -test.run helper.
func copyTestBinary(t *testing.T, dest string) {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
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
