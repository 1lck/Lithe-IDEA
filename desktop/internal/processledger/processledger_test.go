package processledger

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func TestWritePreservesAnotherWritersStagedLedger(t *testing.T) {
	l := Open(t.TempDir())
	// Model a different instance between writing its snapshot and publishing it.
	staged := l.path + ".tmp"
	if err := os.WriteFile(staged, []byte("[]"), 0o600); err != nil {
		t.Fatal(err)
	}
	records := []Record{{PID: 42, Started: "first", Command: "tool"}}
	if err := l.write(records); err != nil {
		t.Fatal(err)
	}
	if got, err := l.read(); err != nil || !slices.Equal(got, records) {
		t.Fatalf("published ledger = %v, %v", got, err)
	}
	if got, err := os.ReadFile(staged); err != nil || string(got) != "[]" {
		t.Fatalf("other writer's staged ledger = %q, %v", got, err)
	}
}

func TestFailedLedgerReplacementCleansUpStaging(t *testing.T) {
	dir := t.TempDir()
	l := Open(dir)
	// A directory at the destination forces rename to fail on every platform.
	if err := os.Mkdir(l.path, 0o700); err != nil {
		t.Fatal(err)
	}
	previous := filepath.Join(l.path, "existing")
	if err := os.WriteFile(previous, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := l.write(nil); err == nil {
		t.Fatal("replaced a directory with a ledger")
	}
	if got, err := os.ReadFile(previous); err != nil || string(got) != "keep" {
		t.Fatalf("previous contents = %q, %v", got, err)
	}
	if entries, err := os.ReadDir(dir); err != nil || len(entries) != 1 {
		t.Fatalf("unexpected files after failed replacement: %v, %v", entries, err)
	}
}
