package workbench

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/draftstore"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"io"
	"os"
	"sync"
	"time"
)

type checkpoint struct {
	entry      draftstore.Entry
	text, base rope.Rope
	remove     bool
	caret      int
}

// A single native worker drains coalesced immutable snapshots. Its queue and storage share
// Core's document limit. The UI lock never spans filesystem work or source flattening.
type recoveryWriter struct {
	mu      sync.Mutex
	pending map[string]checkpoint
	running bool
	store   *draftstore.Store
	limit   int
}

func (a *App) initRecovery() {
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	limits, err := core.NewClient().DecideEditorRecovery(ctx, core.EditorRecoveryRequest{})
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("editor_recovery", err))
		return
	}
	a.recovery = &recoveryWriter{pending: map[string]checkpoint{}, store: draftstore.New(a.store.Dir(), limits), limit: limits.MaxDocuments}
}
func (a *App) checkpointDocument(p *project, d *document) {
	if d.virtual || a.recovery == nil {
		return
	}
	if d.recoveryTimer != nil {
		d.recoveryTimer.Stop()
	}
	// The timer retains only the document identity. Snapshot capture stays on the UI thread.
	d.recoveryTimer = time.AfterFunc(200*time.Millisecond, func() {
		a.post(func(a *App) {
			if a.project == p && p.docs.find(d.id) == d {
				d.recoveryTimer = nil
				a.flushCheckpoint(p, d, false)
			}
		})
	})
}
func (a *App) flushCheckpoint(p *project, d *document, remove bool) {
	if d.virtual || a.recovery == nil {
		return
	}
	if d.recoveryTimer != nil {
		d.recoveryTimer.Stop()
		d.recoveryTimer = nil
	}
	_, caret := d.view.SelectionOffsets()
	root := p.root
	if d.scratch {
		root = ""
	}
	job := checkpoint{caret: caret, entry: draftstore.Entry{Root: root, Path: d.path, Name: d.name, Scratch: d.scratch}, text: d.view.TextSnapshot(), base: d.view.SavedSnapshot(), remove: remove || (!d.scratch && !d.dirty())}
	a.enqueueCheckpoint(job)
}
func (a *App) enqueueCheckpoint(job checkpoint) {
	writer := a.recovery
	if writer == nil {
		return
	}
	key := job.entry.Root + "\x00" + job.entry.Path
	writer.mu.Lock()
	if _, exists := writer.pending[key]; !exists && len(writer.pending) >= writer.limit {
		writer.mu.Unlock()
		a.recoveryFailed(context.DeadlineExceeded)
		return
	}
	writer.pending[key] = job
	if writer.running {
		writer.mu.Unlock()
		return
	}
	writer.running = true
	writer.mu.Unlock()
	a.background(nil, 0, func(context.Context) func(*App) {
		for {
			writer.mu.Lock()
			var next checkpoint
			var key string
			for k, v := range writer.pending {
				key, next = k, v
				break
			}
			if key == "" {
				writer.running = false
				writer.mu.Unlock()
				return nil
			}
			delete(writer.pending, key)
			writer.mu.Unlock()
			var err error
			if next.remove {
				err = writer.store.Remove(next.entry.Root, next.entry.Path)
			} else {
				next.entry.Line, next.entry.Column = editorview.SnapshotUTF16(next.text, next.caret)
				digest := sha256.New()
				next.base.Chunks(0, next.base.Len(), func(chunk string) bool { _, err = io.WriteString(digest, chunk); return err == nil })
				next.entry.BaseHash = hex.EncodeToString(digest.Sum(nil))
				if err == nil {
					err = writer.store.SaveSource(next.entry, int64(next.text.Len()), func(w io.Writer) error {
						var failure error
						next.text.Chunks(0, next.text.Len(), func(chunk string) bool { _, failure = io.WriteString(w, chunk); return failure == nil })
						return failure
					})
				}
			}
			if err != nil {
				a.post(func(a *App) { a.recoveryFailed(err) })
			}
		}
	})
}
func (a *App) recoveryFailed(err error) {
	a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("editor_recovery", documentLogError(err)))
	a.notifyError(i18n.Shared(a.language(), "desktop.drafts.failed"))
}

type recoveredDocument struct {
	found, missing, conflict bool
	prepared                 editorview.PreparedEdit
	disk                     editorview.Content
	line, column             int
	err                      error
}

func (a *App) prepareRecoveredDocument(ctx context.Context, p *project, path string, data []byte, readErr error) recoveredDocument {
	var result recoveredDocument
	if a.recovery == nil {
		return result
	}
	entry, found, err := a.recovery.store.Load(p.root, path)
	if err != nil {
		result.err = err
		return result
	}
	if !found {
		return result
	}
	if readErr != nil && !errors.Is(readErr, os.ErrNotExist) {
		return result
	}
	hash := draftstore.Hash(data)
	var diskHash *string
	if readErr == nil {
		diskHash = &hash
	}
	decision, err := core.NewClient().DecideEditorRecovery(ctx, core.EditorRecoveryRequest{BaseHash: entry.BaseHash, DiskHash: diskHash, Bytes: uint64(len(entry.Text))})
	if err != nil {
		result.err = err
		return result
	}
	result.disk = editorview.Prepare(data)
	result.prepared, err = editorview.PrepareEdits(result.disk.Snapshot(), result.disk.Snapshot(), []editorview.TextEdit{{Range: editorview.Range{Start: 0, End: len(data)}, Text: entry.Text}})
	result.err = err
	result.found = err == nil
	result.missing = readErr != nil
	result.conflict = decision.Action == "restoreConflict"
	result.line, result.column = entry.Line, entry.Column
	return result
}
func (a *App) applyRecoveredDocument(p *project, d *document, restored recoveredDocument) {
	if restored.err != nil {
		a.recoveryFailed(restored.err)
		return
	}
	if !restored.found {
		return
	}
	// Reuse the exact native baseline captured by the prepared edit, not an equivalent rope.
	if restored.conflict {
		d.conflicted, d.conflictMissing = true, restored.missing
		d.recoveredConflict = true
		d.conflictBytes = d.diskBytes
		d.conflictContent = restored.disk
	}
	d.view.ApplyPreparedEdit(restored.prepared)
	d.view.GoToNavigation(restored.line, restored.column, false)
	message := i18n.Shared(a.language(), "desktop.drafts.recovered")
	if restored.conflict {
		message = i18n.Shared(a.language(), "desktop.drafts.conflict")
	}
	a.performed("editor.recovery.restored", surfaceMenu)
	a.notifyInfo(message)
}
func (a *App) restoreCheckpoints(p *project) {
	if a.recovery == nil {
		return
	}
	storage := a.recovery.store
	a.background(p, kernelCallTimeout, func(context.Context) func(*App) {
		entries, err := storage.List(p.root, false)
		return func(a *App) {
			if err != nil {
				a.recoveryFailed(err)
				return
			}
			for _, entry := range entries {
				a.openFile(p, entry.Path)
			}
		}
	})
}
