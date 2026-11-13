package workbench

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"github.com/1lck/Lithe-IDEA/desktop/internal/draftstore"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

type draftListState struct {
	list          ui.ListState
	open, loading bool
	entries       []draftstore.Entry
	generation    uint64
}

func (a *App) newScratch(p *project) {
	if p == nil {
		return
	}
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		a.recoveryFailed(err)
		return
	}
	path := "scratch:" + hex.EncodeToString(random[:])
	name := i18n.SharedFormat(a.language(), "desktop.drafts.untitled", map[string]string{"number": strconv.Itoa(p.docs.next + 1)})
	a.placeScratch(p, draftstore.Entry{Path: path, Name: name, Scratch: true}, editorview.Prepare(nil))
}
func (a *App) placeScratch(p *project, entry draftstore.Entry, content editorview.Content) {
	if d := p.docs.byPath(entry.Path); d != nil {
		a.selectDocument(p, d.id)
		return
	}
	a.placeDocumentAs(p, entry.Path, entry.Name, content, nil, "", true)
	if d := p.docs.byPath(entry.Path); d != nil {
		d.scratch, d.virtual = true, false
		d.view.SetReadOnly(false)
		d.view.GoToNavigation(entry.Line, entry.Column, false)
		a.flushCheckpoint(p, d, false)
	}
}
func (a *App) openScratchList() {
	if a.project == nil || a.recovery == nil {
		return
	}
	v := &a.drafts
	v.open, v.loading = true, true
	v.generation++
	gen := v.generation
	storage := a.recovery.store
	a.background(a.project, kernelCallTimeout, func(context.Context) func(*App) {
		entries, err := storage.List("", true)
		return func(a *App) {
			if !v.open || v.generation != gen {
				return
			}
			v.loading = false
			if err != nil {
				a.recoveryFailed(err)
				return
			}
			v.entries = entries
		}
	})
}
func (a *App) openScratch(p *project, path string) {
	storage := a.recovery.store
	a.background(p, kernelCallTimeout, func(context.Context) func(*App) {
		entry, found, err := storage.Load("", path)
		var content editorview.Content
		if found && err == nil {
			content = editorview.Prepare([]byte(entry.Text))
		}
		return func(a *App) {
			if err != nil {
				a.recoveryFailed(err)
				return
			}
			if found {
				a.placeScratch(p, entry, content)
			}
		}
	})
}
func (a *App) discardScratch(p *project, d *document) {
	if !d.scratch {
		return
	}
	a.flushCheckpoint(p, d, true)
	// Removing the tab normally keeps a scratch. The empty checkpoint is queued last.
	a.removeDocument(p, d)
	a.flushCheckpoint(p, d, true)
}
func (a *App) saveScratchAs(p *project, d *document) {
	if d.saving || d.view.IsComposing() {
		return
	}
	d.saving = true
	before := d.view.TextSnapshot()
	name := d.name
	title := i18n.Shared(a.language(), "desktop.drafts.saveAs")
	a.background(p, 0, func(ctx context.Context) func(*App) {
		choose := a.chooseScratchPath
		if choose == nil {
			choose = func(title, name string) (string, error) {
				return app.SaveFile(app.SaveFileOptions{Title: title, SuggestedName: name})
			}
		}
		path, err := choose(title, name)
		if err == nil {
			err = ctx.Err()
		}
		if err == nil && path != "" {
			err = writeScratchFile(path, before.Bytes())
		}
		return func(a *App) {
			d.saving = false
			waiters := d.closeWaiters
			d.closeWaiters = nil
			defer func() {
				for _, done := range waiters {
					done(err == nil && path != "")
				}
			}()
			if err != nil {
				a.saveFailed(d.id, d.view.Revision(), d.name, err)
				return
			}
			if path == "" {
				return
			}
			if d.view.TextSnapshot().Same(before) {
				a.removeDocument(p, d)
				a.flushCheckpoint(p, d, true)
			}
			a.openFile(p, path)
			a.notifyInfo(i18n.Shared(a.language(), "desktop.drafts.saved"))
		}
	})
}
func writeScratchFile(path string, data []byte) error {
	expected, err := documentio.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return documentio.WriteMissing(path, data)
	}
	if err != nil {
		return err
	}
	return documentio.WriteGuarded(path, data, expected)
}
func (a *App) scratchPopup(c ui.C) {
	v, p := &a.drafts, a.project
	if !v.open || p == nil {
		return
	}
	ui.ModalWith(c.Part("scratch-files"), &v.open, i18n.Shared(a.language(), "desktop.drafts.list"), ui.ModalSpec{Width: 620}, func() {
		if !v.loading && len(v.entries) == 0 {
			ui.Text(c, i18n.Shared(a.language(), "desktop.drafts.empty")).Color(a.colors.Subtle)
		}
		ui.List(c.Part("entries"), &v.list, len(v.entries), func(item ui.ListRow) {
			row, index := item.C, item.Index
			entry := v.entries[index]
			ui.Row(row).FillWidth().Items(ui.Center).Gap(8).Children(func() {
				if ui.Button(row, entry.Name).Ghost().Grow(1).Clicked() {
					c.After(func() { v.open = false; a.openScratch(p, entry.Path) })
				}
				if ui.Button(row, i18n.Shared(a.language(), "desktop.drafts.discard")).Outline().Small().Clicked() {
					c.After(func() { a.enqueueCheckpoint(checkpoint{entry: entry, remove: true}); a.openScratchList() })
				}
			})
		}).Height(300)
	}, func() {
		if ui.Button(c, i18n.Shared(a.language(), "desktop.drafts.new")).Clicked() {
			c.After(func() { v.open = false; a.newScratch(p) })
		}
	})
}
