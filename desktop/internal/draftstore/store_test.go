package draftstore

import (
	"errors"
	"io"
	"os"
	"path/filepath"
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

func TestMigrateRootMovesLegacyDraftsWithoutOverwritingTarget(t *testing.T) {
	dir := t.TempDir()
	limits := core.EditorRecoveryDecision{MaxDocumentBytes: 1024, MaxStorageBytes: 8192, MaxDocuments: 16}
	s := New(dir, limits)
	legacyRoot := filepath.Join(dir, "anchor", "legacy", "project")
	targetRoot := filepath.Join(dir, "anchor", "fingerprinted", "project")
	otherRoot := filepath.Join(dir, "anchor", "other", "project")

	if err := s.Save(Entry{
		Root:     legacyRoot,
		Path:     filepath.Join(legacyRoot, "src", "main.go"),
		Name:     "main.go",
		BaseHash: Hash([]byte("base")),
		Text:     "legacy nested draft",
		Line:     3,
		Column:   7,
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.Save(Entry{
		Root:     legacyRoot,
		Path:     filepath.Join(legacyRoot, "README.md"),
		Name:     "README.md",
		BaseHash: Hash([]byte("base-readme")),
		Text:     "stale legacy readme",
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.Save(Entry{
		Root:     targetRoot,
		Path:     filepath.Join(targetRoot, "README.md"),
		Name:     "README.md",
		BaseHash: Hash([]byte("base-readme")),
		Text:     "newer target readme",
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.Save(Entry{
		Root:    legacyRoot,
		Path:    "scratch-1",
		Name:    "Scratch",
		Scratch: true,
		Text:    "scratch",
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.Save(Entry{
		Root: otherRoot,
		Path: filepath.Join(otherRoot, "keep.txt"),
		Name: "keep.txt",
		Text: "other",
	}); err != nil {
		t.Fatal(err)
	}

	if err := s.MigrateRoot(legacyRoot, targetRoot); err != nil {
		t.Fatal(err)
	}

	migrated, found, err := s.Load(targetRoot, filepath.Join(targetRoot, "src", "main.go"))
	if err != nil || !found || migrated.Text != "legacy nested draft" || migrated.Line != 3 || migrated.Column != 7 {
		t.Fatalf("migrated draft = %+v, found=%v, err=%v", migrated, found, err)
	}
	if _, stillLegacy, err := s.Load(legacyRoot, filepath.Join(legacyRoot, "src", "main.go")); err != nil || stillLegacy {
		t.Fatalf("legacy draft still present after migration: stillLegacy=%v err=%v", stillLegacy, err)
	}

	keptTarget, found, err := s.Load(targetRoot, filepath.Join(targetRoot, "README.md"))
	if err != nil || !found || keptTarget.Text != "newer target readme" {
		t.Fatalf("existing target draft overwritten: %+v, found=%v, err=%v", keptTarget, found, err)
	}

	if _, found, err := s.Load(otherRoot, filepath.Join(otherRoot, "keep.txt")); err != nil || !found {
		t.Fatalf("unrelated draft affected: found=%v err=%v", found, err)
	}
	scratch, err := s.List(legacyRoot, true)
	if err != nil || len(scratch) != 1 || scratch[0].Path != "scratch-1" {
		t.Fatalf("scratch draft affected: %+v err=%v", scratch, err)
	}
}
