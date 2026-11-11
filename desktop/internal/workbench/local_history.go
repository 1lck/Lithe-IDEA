package workbench

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/vivaui/viva/ui"
)

// Local history keeps versioned snapshots of the project's files. Core stores and
// prunes them and decides which snapshots an event takes (history.planEvent); the
// host names the event, supplies the text and chooses where the snapshots live:
// the platform's per-user application data, one folder per project, never the
// project or the installed application.

// localHistoryKernel is the part of Core local history uses.
type localHistoryKernel interface {
	PlanHistoryEvent(context.Context, string) ([]core.HistorySnapshotPlan, error)
	RecordHistory(ctx context.Context, workspaceRoot, storageRoot, path, reason, content string) (*core.HistoryEntry, error)
	HistoryEntries(ctx context.Context, workspaceRoot, storageRoot, path string) ([]core.HistoryEntry, error)
	HistoryContent(ctx context.Context, storageRoot, contentPath string) (string, error)
	RenameHistory(ctx context.Context, storageRoot, path, id, label string) error
	DeleteHistory(ctx context.Context, storageRoot, path, id string) error
	RelocateHistory(ctx context.Context, storageRoot, source, destination string) error
}

// localHistoryStorage is where a project's snapshots are stored:
// <user config>/Lithe/LocalHistory/<hash of the project path>.
func localHistoryStorage(root string) (string, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256([]byte(filepath.Clean(root)))
	return filepath.Join(base, "Lithe", "LocalHistory", hex.EncodeToString(sum[:8])), nil
}

// historyTexts is the text an event supplies for each snapshot source.
type historyTexts struct {
	before, after, buffer []byte
}

// recordLocalHistory records the snapshots Core plans for event on the file at path,
// in the background. A text that is absent or not UTF-8 is not recorded. Failures are
// logged and never interrupt the edit that caused them.
func (a *App) recordLocalHistory(p *project, path, event string, texts historyTexts) {
	a.localHistoryJob(p, func(ctx context.Context, kernel localHistoryKernel, root, storage string) error {
		rel, inside := projectRelative(root, path)
		if !inside {
			return nil
		}
		return recordPlannedHistory(ctx, kernel, root, storage, rel, event, texts)
	})
}

// renamedLocalHistory records the text a rename moves away from, then moves the
// file's or folder's snapshots to its new path, in that order. before is nil for a
// folder or a file whose text was not read.
func (a *App) renamedLocalHistory(p *project, oldPath, newPath string, before []byte) {
	a.localHistoryJob(p, func(ctx context.Context, kernel localHistoryKernel, root, storage string) error {
		oldRel, inside := projectRelative(root, oldPath)
		newRel, insideToo := projectRelative(root, newPath)
		if !inside || !insideToo {
			return nil
		}
		if before != nil {
			if err := recordPlannedHistory(ctx, kernel, root, storage, oldRel, "beforeRename", historyTexts{before: before}); err != nil {
				return err
			}
		}
		return kernel.RelocateHistory(ctx, storage, oldRel, newRel)
	})
}

// localHistoryJob runs one local history step for the project in the background and
// logs its failure.
func (a *App) localHistoryJob(p *project, work func(ctx context.Context, kernel localHistoryKernel, root, storage string) error) {
	kernel, ok := a.kernel.(localHistoryKernel)
	if !ok || p == nil {
		return
	}
	root := p.root
	a.background(p, 10*time.Second, func(ctx context.Context) func(*App) {
		storage, err := localHistoryStorage(root)
		if err == nil {
			err = work(ctx, kernel, root, storage)
		}
		return func(a *App) {
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("local_history_record", err))
			}
		}
	})
}

// recordPlannedHistory records, under rel, each snapshot Core plans for event.
func recordPlannedHistory(ctx context.Context, kernel localHistoryKernel, root, storage, rel, event string, texts historyTexts) error {
	plan, err := kernel.PlanHistoryEvent(ctx, event)
	if err != nil {
		return err
	}
	for _, snapshot := range plan {
		var text []byte
		switch snapshot.Source {
		case "beforeChange":
			text = texts.before
		case "afterChange":
			text = texts.after
		case "editorBuffer":
			text = texts.buffer
		}
		if text == nil || !utf8.Valid(text) {
			continue
		}
		if _, err := kernel.RecordHistory(ctx, root, storage, rel, snapshot.Reason, string(text)); err != nil {
			return err
		}
	}
	return nil
}

// localHistoryReadLimit is the largest file a rename snapshots from disk.
const localHistoryReadLimit = 8 << 20

// readForLocalHistory is the text of the regular file at path for a snapshot, or nil
// for a folder, a large file or one that cannot be read.
func readForLocalHistory(path string) []byte {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > localHistoryReadLimit {
		return nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	return data
}

// localHistoryState is the Local History dialog of one file.
type localHistoryState struct {
	open, loading bool
	// path is the file's absolute path, rel its project-relative path.
	path, rel string
	entries   []core.HistoryEntry
	list      ui.ListState
	selected  int
	// preview is the selected snapshot's text, previewID the entry it belongs to.
	preview, previewID string
	// previewReady is true once preview holds the selected snapshot's text.
	previewReady bool
	label        ui.Field
	failure      string
	busy         bool
}

// openLocalHistory shows the snapshots of the file at path.
func (a *App) openLocalHistory(p *project, path string) {
	kernel, ok := a.kernel.(localHistoryKernel)
	if !ok || p == nil {
		return
	}
	rel, inside := projectRelative(p.root, path)
	if !inside {
		return
	}
	h := &p.history
	*h = localHistoryState{open: true, loading: true, path: path, rel: rel, selected: -1}
	root := p.root
	a.background(p, 10*time.Second, func(ctx context.Context) func(*App) {
		storage, err := localHistoryStorage(root)
		var entries []core.HistoryEntry
		if err == nil {
			entries, err = kernel.HistoryEntries(ctx, root, storage, rel)
		}
		return func(a *App) {
			if !h.open || h.path != path {
				return
			}
			h.loading = false
			if err != nil {
				h.failure = a.text.History.Failed(err.Error())
				return
			}
			h.entries = entries
			if len(entries) > 0 {
				a.selectLocalHistory(p, 0)
			}
		}
	})
	a.performed("localHistory.open", surfaceMenu)
}

// selectLocalHistory selects one snapshot and reads its text for the preview.
func (a *App) selectLocalHistory(p *project, index int) {
	kernel, ok := a.kernel.(localHistoryKernel)
	h := &p.history
	if !ok || index < 0 || index >= len(h.entries) {
		return
	}
	h.selected = index
	entry := h.entries[index]
	h.label.SetText(entry.Label)
	if h.previewID == entry.ID {
		return
	}
	h.preview, h.previewID, h.previewReady = "", entry.ID, false
	root := p.root
	a.background(p, 10*time.Second, func(ctx context.Context) func(*App) {
		storage, err := localHistoryStorage(root)
		var text string
		if err == nil {
			text, err = kernel.HistoryContent(ctx, storage, entry.ContentPath)
		}
		return func(a *App) {
			if h.previewID != entry.ID {
				return
			}
			if err != nil {
				h.failure = a.text.History.Failed(err.Error())
				return
			}
			h.preview, h.previewReady = text, true
		}
	})
}

// restoreLocalHistory puts the selected snapshot's text in the file's editor as one
// undoable edit, opening the file first when needed. The text it replaces is recorded
// as a restore snapshot first, so a restore can itself be undone from history.
func (a *App) restoreLocalHistory(p *project) {
	h := &p.history
	if h.selected < 0 || h.selected >= len(h.entries) || !h.previewReady || h.previewID != h.entries[h.selected].ID {
		return
	}
	text, path := h.preview, h.path
	apply := func(d *document) {
		if d == nil || d.view.IsComposing() {
			return
		}
		data, _ := d.view.Text()
		a.recordLocalHistory(p, path, "restore", historyTexts{before: append([]byte(nil), data...)})
		if err := d.view.ApplyEdits([]editorview.TextEdit{{Range: editorview.Range{Start: 0, End: len(data)}, Text: text}}); err != nil {
			a.notify(a.text.History.Failed(err.Error()))
			return
		}
		a.performed("localHistory.restore", surfaceButton)
		h.open = false
	}
	if d := p.docs.byPath(path); d != nil {
		apply(d)
		return
	}
	if p.docs.openWaiters == nil {
		p.docs.openWaiters = make(map[string][]func(*document, error))
	}
	p.docs.openWaiters[path] = append(p.docs.openWaiters[path], func(d *document, err error) {
		if err == nil {
			apply(d)
		}
	})
	a.openFile(p, path)
}

// renameLocalHistory saves the label field on the selected snapshot.
func (a *App) renameLocalHistory(p *project) {
	a.changeLocalHistory(p, func(ctx context.Context, kernel localHistoryKernel, storage string, entry core.HistoryEntry, label string) error {
		return kernel.RenameHistory(ctx, storage, entry.RelativePath, entry.ID, label)
	})
}

// deleteLocalHistory deletes the selected snapshot.
func (a *App) deleteLocalHistory(p *project) {
	a.changeLocalHistory(p, func(ctx context.Context, kernel localHistoryKernel, storage string, entry core.HistoryEntry, _ string) error {
		return kernel.DeleteHistory(ctx, storage, entry.RelativePath, entry.ID)
	})
}

// changeLocalHistory runs one change to the selected snapshot and lists the file's
// snapshots again.
func (a *App) changeLocalHistory(p *project, change func(context.Context, localHistoryKernel, string, core.HistoryEntry, string) error) {
	kernel, ok := a.kernel.(localHistoryKernel)
	h := &p.history
	if !ok || h.busy || h.selected < 0 || h.selected >= len(h.entries) {
		return
	}
	entry, label, path := h.entries[h.selected], h.label.Text(), h.path
	h.busy = true
	root := p.root
	a.background(p, 10*time.Second, func(ctx context.Context) func(*App) {
		storage, err := localHistoryStorage(root)
		if err == nil {
			err = change(ctx, kernel, storage, entry, label)
		}
		return func(a *App) {
			h.busy = false
			if err != nil {
				h.failure = a.text.History.Failed(err.Error())
				return
			}
			if h.open && h.path == path {
				a.openLocalHistory(p, path)
			}
		}
	})
}
