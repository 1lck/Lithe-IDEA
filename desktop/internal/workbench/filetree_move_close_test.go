package workbench

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// All three operations use real Core. Hold exactly one boundary per run, so
// waiting for history does not require directory rules to run before or after it.
type closeDuringTreeMoveKernel struct {
	*testKernel
	hold    string
	entered chan struct{}
	release chan struct{}
}

func (k *closeDuringTreeMoveKernel) pause(ctx context.Context, phase string) error {
	if k.hold != phase {
		return nil
	}
	close(k.entered)
	wait, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	select {
	case <-k.release:
		return nil
	case <-wait.Done():
		return wait.Err()
	}
}

func (k *closeDuringTreeMoveKernel) RenameWorkspaceEntry(ctx context.Context, root, from, to string) (core.WorkspaceEntry, error) {
	entry, err := k.Client.RenameWorkspaceEntry(ctx, root, from, to)
	if waitErr := k.pause(ctx, "rename receipt"); waitErr != nil {
		return entry, waitErr
	}
	return entry, err
}

func (k *closeDuringTreeMoveKernel) RelocateHistory(ctx context.Context, storage, from, to string) error {
	if err := k.pause(ctx, "history write"); err != nil {
		return err
	}
	return k.Client.RelocateHistory(ctx, storage, from, to)
}

func (k *closeDuringTreeMoveKernel) RelocateDirectoryRules(ctx context.Context, from, to string, insensitive bool, rules json.RawMessage) (json.RawMessage, error) {
	if err := k.pause(ctx, "directory rules write"); err != nil {
		return nil, err
	}
	return k.Client.RelocateDirectoryRules(ctx, from, to, insensitive, rules)
}

// The rename result runs on the window before the derived jobs can enter their
// gates. Pump wakes, not the whole task group (which includes the held job).
func (k *closeDuringTreeMoveKernel) awaitGate(t *testing.T, h *harness) {
	t.Helper()
	deadline := time.NewTimer(8 * time.Second)
	defer deadline.Stop()
	for {
		select {
		case <-k.entered:
			return
		case <-h.driver.Wakes():
			if err := h.driver.Pump(); err != nil {
				t.Fatal(err)
			}
		case <-deadline.C:
			t.Fatalf("never reached %s (%s)", k.hold, h.taskState())
		}
	}
}

func TestProjectCloseWaitsForTreeMove(t *testing.T) {
	const from, to = "before", "after"
	const oldFile, newFile = from + "/note.txt", to + "/note.txt"
	const snapshot = "an earlier revision, not the bytes on disk"
	for _, tc := range []struct {
		name, hold string
		conflict   bool
	}{
		{"CommittedRenameReceipt", "rename receipt", false},
		{"RelocateHistory", "history write", false},
		{"RelocateDirectoryRules", "directory rules write", false},
		{"RefusedRenameReceipt", "rename receipt", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			writeTreeFiles(t, root, oldFile)
			if tc.conflict {
				writeTreeFiles(t, root, newFile)
			}
			k := &closeDuringTreeMoveKernel{
				testKernel: &testKernel{Client: core.NewClient()},
				hold:       tc.hold, entered: make(chan struct{}), release: make(chan struct{}),
			}
			h := newHarness(t, k)
			unblock := sync.OnceFunc(func() { close(k.release) })
			defer unblock() // runs before harness cleanup even when an assertion fails
			p := h.openTree(t, root)
			h.await("loaded directory rules", func() bool { return p.indexing.loaded })
			h.app.setDirectoryRole(p, from, "sources")
			h.await("the saved source mark", func() bool { return core.ParseDirectoryRules(p.indexing.rules).Marks[from] == "sources" })

			storage, ok := h.app.localHistoryDirectory(root)
			if !ok {
				t.Fatal("the harness has no local history directory")
			}
			ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
			defer cancel()
			entry, err := k.RecordHistory(ctx, root, storage, oldFile, "saved", snapshot, core.HistoryPolicy{})
			if err != nil || entry == nil {
				t.Fatalf("recording the pre-existing snapshot: entry=%v err=%v", entry, err)
			}

			// Enter the shared rename/drag commit path, past the dialog's
			// advisory preflight: in the conflict case Core itself refuses.
			h.app.commitTreeMove(p, from, to)
			k.awaitGate(t, h)
			wantDir, absentDir := to, from
			if tc.conflict {
				wantDir, absentDir = from, to
				expectTreeFileBytes(t, root, newFile, newFile+"\n")
			} else if _, err := os.Stat(filepath.Join(root, from)); !os.IsNotExist(err) {
				t.Fatalf("at %s Core has not removed the old directory: %v", k.hold, err)
			}
			expectTreeFileBytes(t, root, wantDir+"/note.txt", oldFile+"\n")

			closed := false
			h.app.requestCloseProject(func() { closed = true })
			if closed || h.app.project != p || p.ctx.Err() != nil {
				t.Errorf("project closed before releasing %s: close callback=%v project retained=%v context=%v", k.hold, closed, h.app.project == p, p.ctx.Err())
			}
			unblock()
			h.await("close after releasing "+k.hold, func() bool { return closed })
			if h.app.project != nil {
				t.Fatal("close callback ran but the project is still open")
			}

			// Read immediately after close, not after settling other jobs. The
			// new project must see the original mark and the exact old snapshot.
			var saved directoryRulesFile
			if ok, err := h.store.Load(directoryRulesName(root), &saved); err != nil || !ok {
				t.Fatalf("reading persisted directory rules: found=%v err=%v", ok, err)
			}
			marks := core.ParseDirectoryRules(saved.Rules).Marks
			if _, stale := marks[absentDir]; stale || marks[wantDir] != "sources" {
				t.Errorf("persisted marks=%v, want sources at %q only", marks, wantDir)
			}
			entries, err := k.HistoryEntries(ctx, root, storage, "")
			if err != nil || len(entries) != 1 || entries[0].RelativePath != wantDir+"/note.txt" || entries[0].ID != entry.ID {
				t.Fatalf("persisted history=%+v err=%v, want original snapshot at %s/note.txt", entries, err, wantDir)
			}
			if got, err := k.HistoryContent(ctx, storage, entries[0].ContentPath); err != nil || got != snapshot {
				t.Errorf("relocated history content=%q err=%v, want %q", got, err, snapshot)
			}
		})
	}
}
