package workbench

import (
	"context"
	"errors"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/draftstore"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/ui"
	"path/filepath"
	"sync"
)

var recentFilesIO sync.Mutex

type recentRequest struct {
	project    *project
	event      *core.EditorRecentEvent
	text       rope.Rope
	caret      int
	query      string
	edited     bool
	generation uint64
	search     bool
}
type recentFileState struct {
	mu           sync.Mutex
	pending      []recentRequest
	running      bool
	open, edited bool
	query        ui.Field
	list         []core.EditorRecentEntry
	listState    ui.ListState
	computed     string
	generation   uint64
	lastEdited   int
}

func recentFilesName(root string) string { return "editor-recent-" + draftstore.Key(root) + ".json" }
func (a *App) noteRecentFile(p *project, d *document, kind string) {
	if d.virtual || d.scratch {
		return
	}
	relative, err := filepath.Rel(p.root, d.path)
	if err != nil {
		a.recentFailed(err)
		return
	}
	_, caret := d.view.SelectionOffsets()
	event := core.EditorRecentEvent{Kind: kind, Path: filepath.ToSlash(relative), Name: d.name}
	a.enqueueRecent(recentRequest{project: p, event: &event, text: d.view.TextSnapshot(), caret: caret})
}
func (a *App) markRecentlyEdited(p *project, d *document) {
	if a.recentFiles.lastEdited != d.id {
		a.recentFiles.lastEdited = d.id
		a.noteRecentFile(p, d, "edited")
	}
}
func (a *App) recentFailed(err error) {
	a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("editor_recent", documentLogError(err)))
	a.notifyError(i18n.Shared(a.language(), "desktop.recentFiles.failed"))
}
func (a *App) openRecentFiles(edited bool) {
	p := a.project
	if p == nil {
		return
	}
	v := &a.recentFiles
	v.open, v.edited = true, edited
	v.query.SetText("")
	v.computed = "\x00"
	v.lastEdited = 0
	if d := p.selectedDocument(p.docs.group); d != nil && d.dirty() {
		a.noteRecentFile(p, d, "edited")
	}
	a.queryRecentFiles(p)
}
func (a *App) queryRecentFiles(p *project) {
	v := &a.recentFiles
	v.computed = v.query.Text()
	v.generation++
	a.enqueueRecent(recentRequest{project: p, query: v.query.Text(), edited: v.edited, generation: v.generation, search: true})
}
func (a *App) enqueueRecent(request recentRequest) {
	v := &a.recentFiles
	v.mu.Lock()
	// Core bounds persisted history; this separate native work queue bounds pending I/O.
	if len(v.pending) >= 128 {
		v.mu.Unlock()
		a.recentFailed(context.DeadlineExceeded)
		return
	}
	v.pending = append(v.pending, request)
	if v.running {
		v.mu.Unlock()
		return
	}
	v.running = true
	v.mu.Unlock()
	a.background(nil, 0, func(context.Context) func(*App) {
		for {
			v.mu.Lock()
			if len(v.pending) == 0 {
				v.running = false
				v.mu.Unlock()
				return nil
			}
			job := v.pending[0]
			v.pending = v.pending[1:]
			v.mu.Unlock()
			p := job.project
			if job.event != nil {
				job.event.Line, job.event.Column = editorview.SnapshotUTF16(job.text, job.caret)
			}
			recentFilesIO.Lock()
			var entries []core.EditorRecentEntry
			_, err := a.store.Load(recentFilesName(p.root), &entries)
			ctx, cancel := context.WithTimeout(p.ctx, kernelCallTimeout)
			var result core.EditorRecentResult
			if err == nil {
				result, err = core.NewClient().ReduceEditorRecent(ctx, core.EditorRecentRequest{Entries: entries, Event: job.event, Query: job.query, OnlyEdited: job.edited})
			}
			cancel()
			if err == nil {
				entries = result.Entries
				if job.event != nil {
					err = a.store.Save(recentFilesName(p.root), entries)
				}
			}
			recentFilesIO.Unlock()
			a.post(func(a *App) {
				if err != nil {
					// log-exempt: 生命周期清理：关闭项目取消所属的历史读取，结果不再投递。
					if !errors.Is(err, context.Canceled) {
						a.recentFailed(err)
					}
					return
				}
				if job.search && a.project == p && v.open && v.generation == job.generation {
					v.list = result.Results
				}
			})
		}
	})
}
func (a *App) recentFilesPopup(c ui.C) {
	v, p := &a.recentFiles, a.project
	if !v.open || p == nil {
		return
	}
	if v.computed != v.query.Text() {
		a.queryRecentFiles(p)
	}
	title := i18n.Shared(a.language(), "desktop.recentFiles.title")
	if v.edited {
		title = i18n.Shared(a.language(), "desktop.recentFiles.edited")
	}
	ui.ModalWith(c.Part("recent-files"), &v.open, title, ui.ModalSpec{Width: 660}, func() {
		submitted := ui.TextField(c.Part("query"), &v.query, i18n.Shared(a.language(), "desktop.recentFiles.query"), "").Icon(icons.Search).FillWidth().Submitted()
		open := func(entry core.EditorRecentEntry) {
			v.open = false
			a.openFileAtPosition(p, filepath.Join(p.root, filepath.FromSlash(entry.Path)), entry.Line, entry.Column)
		}
		if submitted && len(v.list) > 0 && v.computed == v.query.Text() {
			entry := v.list[0]
			c.After(func() { open(entry) })
		}
		if len(v.list) == 0 {
			ui.Text(c, i18n.Shared(a.language(), "desktop.recentFiles.empty")).Color(a.colors.Subtle)
		}
		ui.List(c.Part("entries"), &v.listState, len(v.list), func(item ui.ListRow) {
			row, index := item.C, item.Index
			entry := v.list[index]
			box := item.Element.FillWidth().Height(42).PadX(8).Radius(4).Hover(ui.Look{}.Background(a.colors.Hover))
			if item.Selected() {
				box = box.Background(a.colors.Selection)
			}
			if box.Children(func() {
				ui.Column(row).FillWidth().Children(func() {
					ui.Text(row, entry.Name).FontSize(13).Color(a.colors.Text)
					ui.Text(row, entry.Path).FontSize(11).Color(a.colors.Subtle).Ellipsis()
				})
			}).Clicked() {
				c.After(func() { open(entry) })
			}
		}).Height(336)
		if index, ok := v.listState.Submitted(); ok && index >= 0 && index < len(v.list) {
			entry := v.list[index]
			c.After(func() { open(entry) })
		}
	}, nil)
}
