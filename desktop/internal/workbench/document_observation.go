package workbench

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
)

const documentChecksInFlight = 4

// A slot is closed even if native registration finishes after the project closes.
// The OS watch itself coalesces change notifications before waking the window.
type documentDirectoryWatch interface {
	Changes([]string) app.DirectoryChanges
	Close()
}

type documentWatch struct {
	mu            sync.Mutex
	watch         documentDirectoryWatch
	err           error
	ready, closed bool
}

func (w *documentWatch) finish(watch documentDirectoryWatch, err error) {
	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		if watch != nil {
			watch.Close()
		}
		return
	}
	w.watch, w.err, w.ready = watch, err, true
	w.mu.Unlock()
}

func (w *documentWatch) state() (documentDirectoryWatch, bool, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	watch, ready, err := w.watch, w.ready, w.err
	w.ready = false
	return watch, ready, err
}

func (w *documentWatch) close() {
	w.mu.Lock()
	w.closed = true
	watch := w.watch
	w.watch = nil
	w.mu.Unlock()
	if watch != nil {
		watch.Close()
	}
}

func (a *App) watchDocument(p *project, d *document) {
	if d.virtual {
		return
	}
	dir := filepath.Dir(d.path)
	if p.docs.watches == nil {
		p.docs.watches = make(map[string]*documentWatch)
	}
	if _, ok := p.docs.watches[dir]; ok {
		d.checkPending = true
		a.scheduleDocumentChecks(p)
		return
	}
	a.startDocumentWatch(p, dir)
}

func (a *App) startDocumentWatch(p *project, dir string) {
	slot := &documentWatch{}
	p.docs.watches[dir] = slot
	a.tasks.running.Add(1)
	wake := func() {
		a.post(func(a *App) { a.drainDocumentWatch(p, dir, slot) })
	}
	go func() {
		defer a.tasks.running.Done()
		watch, err := app.WatchDirectory(dir, wake)
		var observed documentDirectoryWatch
		if watch != nil {
			observed = watch
		}
		slot.finish(observed, err)
		wake()
	}()
}

func (a *App) unwatchDocument(p *project, removed *document) {
	if removed.virtual {
		return
	}
	dir := filepath.Dir(removed.path)
	for _, d := range p.docs.list {
		if filepath.Dir(d.path) == dir {
			return
		}
	}
	if slot := p.docs.watches[dir]; slot != nil {
		slot.close()
		delete(p.docs.watches, dir)
	}
}

func (a *App) drainDocumentWatch(p *project, dir string, slot *documentWatch) {
	if a.project != p || p.docs.watches[dir] != slot {
		return
	}
	watch, ready, err := slot.state()
	markDirectory := func() {
		for _, d := range p.docs.list {
			if filepath.Dir(d.path) == dir {
				d.checkPending = true
			}
		}
	}
	if ready {
		// Covers the interval between reading the file and installing its watch.
		markDirectory()
		if err != nil {
			a.emit(core.LevelWarn, "editor.document.watch_failed", map[string]any{"stage": "create"})
			a.notify(i18n.Shared(a.language(), "desktop.document.watchUnavailable"))
		}
	}
	if watch != nil {
		changes := watch.Changes(nil)
		if changes.Resync {
			markDirectory()
			slot.close()
			a.startDocumentWatch(p, dir)
		} else if len(changes.Names) > 512 {
			// An event flood has the same bounded effect as a directory rescan.
			markDirectory()
		} else if len(changes.Names) > 0 {
			names := make(map[string]struct{}, len(changes.Names))
			for _, name := range changes.Names {
				if runtime.GOOS == "windows" {
					name = strings.ToLower(name)
				}
				names[name] = struct{}{}
			}
			for _, d := range p.docs.list {
				if filepath.Dir(d.path) != dir {
					continue
				}
				name := filepath.Base(d.path)
				if runtime.GOOS == "windows" {
					name = strings.ToLower(name)
				}
				if _, ok := names[name]; ok {
					d.checkPending = true
				}
			}
		}
	}
	a.scheduleDocumentChecks(p)
}

func (a *App) scheduleDocumentChecks(p *project) {
	if a.project != p {
		return
	}
	for _, d := range p.docs.list {
		if p.docs.checking >= documentChecksInFlight {
			break
		}
		if !d.checkPending || d.checking || d.saving {
			continue
		}
		d.checkPending = false
		d.checkFailed = false
		d.checking = true
		p.docs.checking++
		baseline := d.view.SavedSnapshot()
		missing := d.recreateMissing
		read := a.documentReader
		kernel, _ := a.kernel.(editorKernel)
		encoding, hasBOM, disk := d.encoding, d.hasBOM, d.diskBytes
		a.background(p, 0, func(ctx context.Context) func(*App) {
			data, err := read(d.path)
			expected := baseline.Bytes()
			if disk != nil {
				// The file is not plain UTF-8: it is compared as bytes and decoded as it was
				// opened. Its bytes may even be invalid UTF-8, which the reader refuses.
				data, err = readRawDocument(d.path)
				expected = disk
			}
			changed := err == nil && (missing || !bytes.Equal(data, expected))
			var content editorview.Content
			prepared := changed
			if prepared {
				text, decodeErr := decodeExternal(ctx, kernel, data, encoding, hasBOM, disk != nil)
				if decodeErr != nil {
					err, changed, prepared = decodeErr, false, false
				} else {
					content = editorview.Prepare(text)
				}
			}
			return func(a *App) {
				p.docs.checking--
				d.checking = false
				if p.docs.find(d.id) == d {
					if d.recreateMissing != missing {
						d.checkPending = true
					} else {
						a.applyDocumentCheck(p, d, baseline, content, changed, prepared, err, data)
					}
					if !d.checkPending && len(d.checkWaiters) > 0 {
						waiters := d.checkWaiters
						d.checkWaiters = nil
						for _, done := range waiters {
							if d.checkFailed || d.conflicted {
								done(false)
							} else if d.dirty() || d.view.IsComposing() {
								a.saveBeforeClose(p, d, done)
							} else {
								done(true)
							}
						}
					}
				}
				a.scheduleDocumentChecks(p)
			}
		})
	}
}

func (a *App) clearDocumentConflict(d *document) {
	d.conflicted = false
	d.conflictMissing = false
	d.conflictContent = editorview.Content{}
	d.conflictBytes = nil
	d.conflictGeneration++
}

func (a *App) applyDocumentCheck(p *project, d *document, baseline rope.Rope, content editorview.Content, changed, prepared bool, err error, observed []byte) {
	if d.saving || !d.view.HasSavedSnapshot(baseline) {
		d.checkPending = true
		return
	}
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		d.checkFailed = true
		a.emit(documentFailedLevel, documentEventOpenFailed, documentOpenFields(err))
		a.notify(d.name + ": " + i18n.Shared(a.language(), "desktop.document.externalReadFailed"))
		return
	}
	if errors.Is(err, os.ErrNotExist) && d.recreateMissing && !d.conflicted {
		return
	}
	if err == nil && !changed {
		a.clearDocumentConflict(d)
		return
	}
	revision := uint64(d.view.Revision())
	state := core.DocumentState{Status: core.DocumentClean, Revision: revision}
	if d.conflicted {
		state.Status = core.DocumentConflict
		state.SavedRevision = uint64(min(d.savedRevision, d.view.Revision()))
	} else if d.dirty() || d.view.IsComposing() {
		state.Status = core.DocumentDirty
		state.SavedRevision = uint64(min(d.savedRevision, d.view.Revision()))
	}
	event := core.DocumentExternalChanged
	if errors.Is(err, os.ErrNotExist) {
		event = core.DocumentDiskConflict
	}
	ctx, cancel := context.WithTimeout(p.ctx, kernelCallTimeout)
	decision, decisionErr := a.kernel.ReduceDocument(ctx, state, core.DocumentEvent{Type: event})
	cancel()
	if decisionErr != nil {
		d.checkFailed = true
		a.emit(documentFailedLevel, documentEventOpenFailed, documentOpenFields(decisionErr))
		a.notify(d.name + ": " + i18n.Shared(a.language(), "desktop.document.externalReadFailed"))
		return
	}
	switch decision.Action {
	case core.DocumentReloadFromDisk:
		if !prepared {
			d.checkPending = true
			return
		}
		if d.view.Reload(content) {
			if d.needsCodec() {
				d.diskBytes = observed
			}
			d.savedRevision = d.view.Revision()
			a.clearDocumentConflict(d)
		} else {
			d.checkFailed = true
			fields := documentOpenFields(errors.New("document reload was not accepted"))
			a.emit(documentFailedLevel, documentEventOpenFailed, fields)
			a.notify(d.name + ": " + i18n.Shared(a.language(), "desktop.document.externalReadFailed"))
		}
	case core.DocumentShowConflict:
		d.conflictMissing = errors.Is(err, os.ErrNotExist)
		d.conflictContent = content
		d.conflictBytes = observed
		d.conflictGeneration++
		if !d.conflicted {
			d.conflicted = true
			a.emit(core.LevelWarn, "app.notification.operation_rejected", map[string]any{"operation": "document_external_change", "reason": "disk_conflict"})
		}
	default:
		d.checkFailed = true
		fields := documentOpenFields(errors.New("unexpected document lifecycle action"))
		a.emit(documentFailedLevel, documentEventOpenFailed, fields)
		a.notify(d.name + ": " + i18n.Shared(a.language(), "desktop.document.externalReadFailed"))
	}
}
