package workbench

import (
	"context"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
)

// This file keeps the documents that have no tab (matrix id git-diff-review). The right side of a
// working-copy Diff tab and the Problems preview edit the file's text, and an unopened file has no
// document to edit. Such a document is read in the background and joins the project's documents: it
// is saved, autosaved and checked on close like any other, but no group holds it and it takes no
// focus. The editor attaches a tab to it when the file is opened (selectDocument), and it is released
// when no Diff tab and no editable preview shows it and it is saved (releaseIdleTablessDocument).

// ensureTablessDocument makes sure the working-copy file of tab t has a document, opening it in the
// background when none is open, and lays the tab out again when it has one.
func (a *App) ensureTablessDocument(t *diffTab) {
	p := a.project
	if p == nil || !diffWritable(t) {
		return
	}
	path := diffTabPath(t)
	if p.docs.byPath(path) != nil {
		return
	}
	a.openTablessDocument(p, path)
}

// openTablessDocument reads path in the background and makes it a document without a tab. The Diff
// tabs of the file are laid out again once it is there, so their right sides become editable.
func (a *App) openTablessDocument(p *project, path string) {
	if p.docs.opening[path] {
		return
	}
	if p.docs.opening == nil {
		p.docs.opening = map[string]bool{}
	}
	p.docs.opening[path] = true
	registry := a.syntaxRegistry()
	kernel, _ := a.kernel.(editorKernel)
	a.background(p, 0, func(ctx context.Context) func(*App) {
		file := readTablessFile(ctx, kernel, registry, path)
		return func(a *App) {
			delete(p.docs.opening, path)
			// A file that is not text, or that cannot be read, has no document; its Diff stays read only.
			if file.err != nil || a.project != p || p.docs.byPath(path) != nil {
				return
			}
			a.addTablessDocument(p, path, file)
		}
	})
}

// tablessFile is what a worker read of a file that becomes a document without a tab.
type tablessFile struct {
	read       documentRead
	content    editorview.Content
	grammar    *syntax.Syntax
	languageID string
	err        error
}

// readTablessFile reads path and prepares its text and grammar; it runs on a worker.
func readTablessFile(ctx context.Context, kernel editorKernel, registry *syntax.Registry, path string) tablessFile {
	read, err := readDocumentEncoded(ctx, kernel, path)
	file := tablessFile{read: read, err: err}
	if err != nil {
		return file
	}
	file.content = editorview.Prepare(read.text)
	file.grammar = registry.SyntaxForPath(path)
	if language, ok := registry.ForPath(path); ok {
		file.languageID = language.ID
	}
	return file
}

// addTablessDocument makes file the document of path without a tab and lays the Diff tabs of the
// file out again, so their right sides become editable.
func (a *App) addTablessDocument(p *project, path string, file tablessFile) *document {
	p.docs.next++
	d := a.newTablessDocument(p, p.docs.next, path, filepath.Base(path), file.content, file.grammar, file.languageID)
	d.encoding, d.hasBOM, d.diskBytes = file.read.encoding, file.read.hasBOM, file.read.disk
	d.tabless = true
	p.docs.list = append(p.docs.list, d)
	for _, t := range p.diffs.list {
		if diffWritable(t) && diffTabPath(t) == path {
			a.rebuildDiff(t)
		}
	}
	return d
}

// newTablessDocument makes the document of path with its editor, wired the way a tab's document is,
// except for its tab, its input and its watch, which attachDocumentTab adds.
func (a *App) newTablessDocument(p *project, id int, path, name string, content editorview.Content, grammar *syntax.Syntax, languageID string) *document {
	d := &document{id: id, path: path, name: name, languageID: languageID}
	d.view = editorview.New(editorview.Config{
		Label:   name,
		Content: content,
		Syntax:  grammar,
		Notify:  a.invalidator.Invalidate,
		Save:    func() { a.saveDocument(p, id) },
		OnEdit: func(edit editorview.Edit) {
			a.documentEdited(p, d, edit)
			a.mirrorDocumentEdit(p, d, edit)
		},
	})
	d.view.SetVimExit(func(cmd string) bool { return a.vimExit(p, d, cmd) })
	setupFolding(d)
	d.breakpointText = d.view.TextSnapshot()
	return d
}

// attachDocumentTab gives the tabless document d a tab in the editor, in the group a new file would
// open in, and reports whether the tab was made.
func (a *App) attachDocumentTab(p *project, d *document) bool {
	group, ok := a.placeEditorMember(p, documentMember(d.id))
	if !ok {
		return false
	}
	d.tabless = false
	p.docs.group = group
	a.documentInput(p, d)
	a.refreshGitGutter(p, d)
	a.refreshInlineBlame(p, d)
	a.watchDocument(p, d)
	a.startDocumentSync(p, d)
	a.scheduleEditorActions(p, d)
	a.enforceTabLimit(p, d)
	return true
}

// releaseIdleTablessDocument releases the tabless document of path once no Diff tab and no editable
// preview shows the file and the document has nothing unsaved.
func (a *App) releaseIdleTablessDocument(p *project, path string) {
	d := p.docs.byPath(path)
	if d == nil || !d.tabless || a.previewShowsDocument(d) {
		return
	}
	for _, t := range p.diffs.list {
		if diffWritable(t) && diffTabPath(t) == path {
			return
		}
	}
	if !d.dirty() {
		a.removeDocument(p, d)
	}
}
