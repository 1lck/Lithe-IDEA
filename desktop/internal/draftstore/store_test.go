package draftstore

import (
	"errors"
	"io"
	"os"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestRecoveryStoreAtomicOverwriteAndQuotaPreservePriorContents(t *testing.T) {
	dir := t.TempDir()
	limits := core.EditorRecoveryDecision{MaxDocumentBytes: 32, MaxStorageBytes: 4096, MaxDocuments: 1}
	s := New(dir, limits)
	entry := Entry{Root: "workspace", Path: "a.txt", Text: "first"}
	if err := s.Save(entry); err != nil {
		t.Fatal(err)
	}
	entry.Text = "updated 😀"
	if err := s.Save(entry); err != nil {
		t.Fatal(err)
	}
	if err := s.Save(Entry{Root: "workspace", Path: "b.txt", Text: "full"}); err == nil {
		t.Fatal("document cap ignored")
	}
	fresh := New(dir, limits)
	got, found, err := fresh.Load("workspace", "a.txt")
	if err != nil || !found || got.Text != "updated 😀" {
		t.Fatalf("reopened checkpoint: %+v %v %v", got, found, err)
	}
	entry.Text = "012345678901234567890123456789012"
	if err := s.Save(entry); err == nil {
		t.Fatal("source cap ignored")
	}
	got, _, err = fresh.Load("workspace", "a.txt")
	if err != nil || got.Text != "updated 😀" {
		t.Fatal("rejected save destroyed prior checkpoint")
	}
	if err = s.Remove("workspace", "a.txt"); err != nil {
		t.Fatal(err)
	}
	if err = s.Remove("workspace", "a.txt"); err != nil {
		t.Fatal(err)
	}
}

func TestSaveSourceStreamingFailurePreservesPriorCheckpointAndLeavesNoTemp(t *testing.T) {
	dir := t.TempDir()
	limits := core.EditorRecoveryDecision{MaxDocumentBytes: 64, MaxStorageBytes: 4096, MaxDocuments: 2}
	s := New(dir, limits)
	if err := s.Save(Entry{Root: "workspace", Path: "a.txt", Text: "committed"}); err != nil {
		t.Fatal(err)
	}
	streamErr := errors.New("stream aborted")
	err := s.SaveSource(Entry{Root: "workspace", Path: "a.txt"}, 7, func(w io.Writer) error {
		if _, err := w.Write([]byte("partial")); err != nil {
			return err
		}
		return streamErr
	})
	if !errors.Is(err, streamErr) {
		t.Fatalf("SaveSource error = %v, want %v", err, streamErr)
	}
	got, found, err := s.Load("workspace", "a.txt")
	if err != nil || !found || got.Text != "committed" {
		t.Fatalf("checkpoint after failed SaveSource = %+v, %v, %v", got, found, err)
	}
	entries, err := os.ReadDir(s.dir)
	if err != nil || len(entries) != 1 {
		t.Fatalf("unexpected files in recovery dir: %v, %v", entries, err)
	}
}
