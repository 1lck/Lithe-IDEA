package sysinfo

import (
	"runtime"
	"testing"
)

// TestCurrentReadsTheSystem checks that the facts the system always has are read on the
// systems the client ships on.
func TestCurrentReadsTheSystem(t *testing.T) {
	snapshot := Current(t.TempDir())
	if snapshot.OSName == "" || snapshot.CPUCores == 0 {
		t.Fatalf("snapshot = %+v", snapshot)
	}
	switch runtime.GOOS {
	case "darwin", "linux", "windows":
		if snapshot.OSVersion == "" || snapshot.ResidentBytes == 0 || snapshot.DiskFreeBytes == 0 {
			t.Fatalf("snapshot = %+v", snapshot)
		}
	}
	if Current("").DiskFreeBytes != 0 {
		t.Fatal("a snapshot for no volume has room on a disk")
	}
}
