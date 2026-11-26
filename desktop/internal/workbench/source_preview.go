package workbench

import (
	"context"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// sourcePreview is a view of one file that follows a selection in a list (Search Everywhere,
// Problems, References). It shows an open document's current text, so unsaved edits show.
//
// A read-only preview never writes the file. An editable one (the Problems preview) is a second
// editor of the file's document, as the right side of a working-copy Diff tab is: an edit made in
// either view reaches the other at once, the document keeps the undo and saves the file, and a
// file that has no tab opens as a document without one (documents_tabless.go), which is released
// when the preview moves on and nothing of it is unsaved. The language features follow the
// preview's caret while the user works there (document.lens).
type sourcePreview struct {
	// path is the file shown and line the one-based line revealed. A load replaces
	// view when its answer arrives for the same generation.
	path       string
	line       int
	generation uint64
	failure    error
	view       *editorview.View
	hit        gfx.ID
	input      ui.Handlers
	draw       func(*ui.DrawContext)
	// tint colors line tintLine under its text, as the Problems preview marks its diagnostic's
	// line in the color of the diagnostic's severity; a transparent tint marks nothing. tinted is
	// the mark the view was last given, so a rebuild that asks for the same mark does not set it
	// again.
	tint     gfx.Color
	tintLine int
	tinted   lineTint
	// doc is the document an editable preview (editablePreviews) edits and project its project,
	// once the preview shows it.
	doc     *document
	project *project
}

// lineTint is a one-based line and the color it is marked with; the zero value marks nothing.
type lineTint struct {
	line  int
	color gfx.Color
}

// close releases the view's highlighter and forgets the file. The document an editable preview
// showed stays; closeSourcePreview also releases it when only the preview kept it.
func (sp *sourcePreview) close() {
	if sp.view != nil {
		sp.view.Close()
	}
	if sp.doc != nil && sp.doc.lens == sp.view {
		sp.doc.lens = nil
	}
	sp.view = nil
	sp.doc, sp.project = nil, nil
	sp.path = ""
	sp.failure = nil
	sp.tinted = lineTint{}
	sp.generation++
}

// markLine colors one-based line with tint, or marks nothing when tint is transparent. A view that
// is still loading gets the mark when it arrives.
func (sp *sourcePreview) markLine(line int, tint gfx.Color) {
	sp.tintLine, sp.tint = line, tint
	sp.applyTint()
}

// applyTint gives the view the mark of the tinted line when it has a different one.
func (sp *sourcePreview) applyTint() {
	if sp.view == nil {
		return
	}
	want := lineTint{line: sp.tintLine, color: sp.tint}
	if want.line <= 0 || want.color.Alpha == 0 {
		want = lineTint{}
	}
	if want == sp.tinted {
		return
	}
	sp.tinted = want
	if want.line == 0 {
		sp.view.SetLineHighlights(nil)
		return
	}
	sp.view.SetLineHighlights([]editorview.LineHighlight{{StartLine: want.line - 1, EndLine: want.line - 1, Color: want.color}})
}

// editablePreviews are the previews that edit their file's document.
func (a *App) editablePreviews() [1]*sourcePreview {
	return [1]*sourcePreview{&a.problems.preview}
}

// previewEditable reports whether sp edits its file's document.
func (a *App) previewEditable(sp *sourcePreview) bool {
	for _, e := range a.editablePreviews() {
		if e == sp {
			return true
		}
	}
	return false
}

// closeSourcePreview closes sp and releases the document without a tab that only it kept.
func (a *App) closeSourcePreview(sp *sourcePreview) {
	d, p := sp.doc, sp.project
	sp.close()
	if d != nil && p != nil && a.project == p && d.tabless {
		a.releaseIdleTablessDocument(p, d.path)
	}
}

// previewShowsDocument reports whether an editable preview edits document d, which keeps a
// document without a tab from being released under it.
func (a *App) previewShowsDocument(d *document) bool {
	for _, sp := range a.editablePreviews() {
		if sp.doc == d {
			return true
		}
	}
	return false
}

// documentPreviewView is the view of the editable preview that edits document d, or nil.
func (a *App) documentPreviewView(d *document) *editorview.View {
	for _, sp := range a.editablePreviews() {
		if sp.doc == d && sp.view != nil {
			return sp.view
		}
	}
	return nil
}

// syncSourcePreviewDecorations copies already prepared colors when both views still share their
// snapshot. Independently mirrored ropes receive the worker's separately prepared answer instead.
func (a *App) syncSourcePreviewDecorations(d *document) {
	if preview := a.documentPreviewView(d); preview != nil {
		preview.CopyDocumentDecorationsFrom(d.view)
	}
}

// clearSourcePreviewDecorations withdraws a document's overlays from its editable preview too.
func (a *App) clearSourcePreviewDecorations(d *document) {
	a.clearSourcePreviewColors(d)
	a.clearSourcePreviewScopes(d)
}

func (a *App) clearSourcePreviewScopes(d *document) {
	if preview := a.documentPreviewView(d); preview != nil {
		preview.SetBracketMatches(nil)
		preview.SetIndentGuideScopes(editorview.PreparedIndentGuideScopes{})
	}
}

func (a *App) clearSourcePreviewColors(d *document) {
	if preview := a.documentPreviewView(d); preview != nil {
		preview.ClearColorDecorations()
	}
}

// closePreviewsOfDocument closes every editable preview that edits document d, which is going
// away; the next frame shows the file again from what is left.
func (a *App) closePreviewsOfDocument(d *document) {
	for _, sp := range a.editablePreviews() {
		if sp.doc == d {
			sp.close()
		}
	}
}

// show makes the preview follow path and line: a new file starts a load, the same
// file only moves the reveal. alive reports whether the preview is still wanted when
// a load finishes.
func (a *App) showSourcePreview(p *project, sp *sourcePreview, path string, line int, alive func(*App) bool) {
	if path == "" {
		return
	}
	if sp.path == path {
		if sp.line != line {
			sp.line = line
			if sp.view != nil && line > 0 {
				sp.view.GoToLine(line)
			}
		}
		return
	}
	if a.previewEditable(sp) {
		a.showEditablePreview(p, sp, path, line, alive)
		return
	}
	sp.close()
	sp.path, sp.line = path, line
	generation := sp.generation
	var openText []byte
	var openGrammar *syntax.Syntax
	open := false
	if d := p.docs.byPath(path); d != nil {
		openText, _ = d.view.Text()
		openGrammar = d.grammar
		open = true
	}
	registry := a.syntaxRegistry()
	kernel, _ := a.kernel.(editorKernel)
	budget := int64(a.searchPreferences.MaxFileBytes)
	bytesOf := a.documentBytesOf(p)
	a.background(p, 0, func(ctx context.Context) func(*App) {
		data, err := openText, error(nil)
		if !open {
			var read documentRead
			read, err = readDocumentEncodedLimit(ctx, kernel, bytesOf, path, budget)
			data = read.text
		}
		var content editorview.Content
		grammar := openGrammar
		if err == nil {
			content = editorview.Prepare(data)
			if !open {
				_, grammar = a.resolveDocumentLanguage(ctx, registry, path, content.Snapshot())
			}
		}
		return func(a *App) {
			if sp.generation != generation || a.project != p || !alive(a) {
				return
			}
			if err != nil {
				sp.failure = err
				return
			}
			a.installSourcePreview(sp, content, grammar)
		}
	})
}

// showEditablePreview makes the editable preview show the document of path: the open one, or
// one without a tab read in the background. The document the preview showed before is released
// when only the preview kept it.
func (a *App) showEditablePreview(p *project, sp *sourcePreview, path string, line int, alive func(*App) bool) {
	a.closeSourcePreview(sp)
	sp.path, sp.line = path, line
	if d := p.docs.byPath(path); d != nil {
		a.bindSourcePreview(p, sp, d)
		return
	}
	generation := sp.generation
	registry := a.syntaxRegistry()
	kernel, _ := a.kernel.(editorKernel)
	bytesOf := a.documentBytesOf(p)
	a.background(p, 0, func(ctx context.Context) func(*App) {
		file := a.readTablessFile(ctx, kernel, bytesOf, registry, path)
		return func(a *App) {
			if sp.generation != generation || a.project != p || !alive(a) {
				return
			}
			// A document opened meanwhile, by a tab or a Diff tab, is the one to edit.
			d := p.docs.byPath(path)
			if d == nil {
				if file.err != nil {
					sp.failure = file.err
					return
				}
				d = a.addTablessDocument(p, path, file)
			}
			a.bindSourcePreview(p, sp, d)
		}
	})
}

// bindSourcePreview makes the editable view of document d, which shares the document's text,
// and reveals the line.
func (a *App) bindSourcePreview(p *project, sp *sourcePreview, d *document) {
	var view *editorview.View
	view = editorview.New(editorview.Config{
		Label:   d.name,
		Content: d.view.CopyContent(),
		Syntax:  d.grammar,
		Notify:  a.invalidator.Invalidate,
		Save:    func() { a.saveDocument(p, d.id) },
		OnEdit:  func(edit editorview.Edit) { a.previewEdited(p, sp, view, edit) },
	})
	view.SetReadOnly(d.view.ReadOnly())
	view.SetWrap(false)
	view.SetMinimap(false)
	if sp.line > 0 {
		view.GoToLine(sp.line)
	}
	sp.view, sp.doc, sp.project = view, d, p
	a.syncSourcePreviewDecorations(d)
	sp.applyTint()
	sp.input = a.editablePreviewInput(p, d, view)
	sp.draw = a.sourcePreviewDraw(sp)
	// The preview underlines the document's diagnostics too.
	a.projectDocumentMarkers(d)
}

// previewEdited gives the document an edit the user made in its preview, as one undo step of the
// document. A mirrored edit is not given back.
func (a *App) previewEdited(p *project, sp *sourcePreview, view *editorview.View, edit editorview.Edit) {
	if p.diffs.mirroring > 0 {
		return
	}
	d := sp.doc
	if d == nil || sp.view != view || a.project != p {
		return
	}
	if !a.editDocumentFrom(p, d, view, edit) {
		// The preview and its document disagree on the text; the preview shows the document again.
		view.ShowContent(d.view.CopyContent())
		a.syncSourcePreviewDecorations(d)
	}
}

// mirrorPreviewEdit mirrors an edit of document d into the editable preview that shows it, unless
// the edit came from there. The document's undo already holds it, so the preview does not record it.
func (a *App) mirrorPreviewEdit(p *project, d *document, edit editorview.Edit) {
	for _, sp := range a.editablePreviews() {
		if sp.doc != d || sp.view == nil || sp.view == p.diffs.origin {
			continue
		}
		p.diffs.mirroring++
		if !sp.view.ApplyEdit(edit, false) {
			sp.view.ShowContent(d.view.CopyContent())
			a.syncSourcePreviewDecorations(d)
		}
		p.diffs.mirroring--
	}
}

// editablePreviewInput makes the handlers of the editable preview view of document d. They are
// the document's own: a key, a press or typing there points the language features at the
// preview, and an undo or redo chord takes back or does again the document's edits.
func (a *App) editablePreviewInput(p *project, d *document, view *editorview.View) ui.Handlers {
	return ui.Handlers{
		Role: gfx.RoleTerminal,
		Key: func(event gfx.KeyEvent) gfx.EventResult {
			d.lens = view
			if documentUndoChord(d, event) {
				return gfx.EventResult{Handled: true, Repaint: true}
			}
			return a.documentViewKey(p, d, view, event)
		},
		Pointer: func(event gfx.PointerEvent) gfx.EventResult {
			if event.Kind == gfx.PointerDown {
				d.lens = view
			}
			defer a.pluginSemanticsCaretSync()
			if result, handled := a.pluginSemanticsPointer(event, p, d, view); handled {
				return result
			}
			result, _ := view.Pointer(event)
			return result
		},
		Scroll: func(event gfx.ScrollEvent) gfx.EventResult {
			a.pluginSemanticsScrolled(d)
			result, _ := view.Scroll(event)
			return result
		},
		Text: func(ctx app.TextInputContext) *app.TextInput {
			d.lens = view
			return view.TextInput(ctx)
		},
	}
}

// sourcePreviewShortcut handles a chord pressed while an editable preview has the keyboard: undo
// and redo go to its document, the other editor chords (copy, cut, paste, select all, save) to
// the preview.
func (a *App) sourcePreviewShortcut(event gfx.KeyEvent) (gfx.EventResult, bool) {
	for _, sp := range a.editablePreviews() {
		if sp.doc == nil || sp.view == nil || !sp.view.Owns(event.Target) {
			continue
		}
		if documentUndoChord(sp.doc, event) {
			return gfx.EventResult{Handled: true, Repaint: true}, true
		}
		return sp.view.Shortcut(event)
	}
	return gfx.EventResult{}, false
}

// followKeyboardView points the language features of the document whose editor or editable
// preview has the keyboard (id) at that view, before a chord acts on its caret.
func (a *App) followKeyboardView(id gfx.ID) {
	p := a.project
	if p == nil || id.IsZero() {
		return
	}
	for _, sp := range a.editablePreviews() {
		if sp.doc != nil && sp.view != nil && sp.view.Owns(id) {
			sp.doc.lens = sp.view
			return
		}
	}
	for _, d := range p.docs.list {
		if d.view.Owns(id) {
			d.lens = nil
			return
		}
	}
}

// previewDocumentHit is the project and document of the editable preview whose text is id.
func (a *App) previewDocumentHit(id gfx.ID) (*project, *document) {
	for _, sp := range a.editablePreviews() {
		if sp.doc != nil && sp.view != nil && sp.hit == id && sp.project == a.project {
			return sp.project, sp.doc
		}
	}
	return nil, nil
}

// installSourcePreview makes the read-only view of the loaded text and reveals the line.
func (a *App) installSourcePreview(sp *sourcePreview, content editorview.Content, grammar *syntax.Syntax) {
	view := editorview.New(editorview.Config{
		Label:   filepath.Base(sp.path),
		Content: content,
		Syntax:  grammar,
		Notify:  a.invalidator.Invalidate,
	})
	view.SetReadOnly(true)
	view.SetWrap(false)
	view.SetMinimap(false)
	if sp.line > 0 {
		view.GoToLine(sp.line)
	}
	sp.view = view
	sp.applyTint()
	sp.input = ui.Handlers{
		Role: gfx.RoleTerminal,
		Key: func(event gfx.KeyEvent) gfx.EventResult {
			result, _ := view.Key(event)
			return result
		},
		Pointer: func(event gfx.PointerEvent) gfx.EventResult {
			result, _ := view.Pointer(event)
			return result
		},
		Scroll: func(event gfx.ScrollEvent) gfx.EventResult {
			result, _ := view.Scroll(event)
			return result
		},
	}
	sp.draw = a.sourcePreviewDraw(sp)
}

// sourcePreviewDraw is the painter of the preview's view: without a minimap, a vertical bar or
// soft wrap, in the editor's font and look.
func (a *App) sourcePreviewDraw(sp *sourcePreview) func(*ui.DrawContext) {
	return func(dc *ui.DrawContext) {
		v := sp.view
		if v == nil {
			return
		}
		v.BindWithoutMinimap(sp.hit, sp.input.Parts())
		v.HideVerticalBar()
		v.SetFont(a.editorFont())
		v.SetWrap(false)
		v.SetMessages(a.editorMessages())
		v.SetPresentation(a.editorPresentation())
		v.Paint(dc.Canvas, dc.Rect, a.editorLook())
	}
}

// sourcePreviewPane declares the preview, or empty when nothing is shown yet.
func (a *App) sourcePreviewPane(c ui.C, sp *sourcePreview, part, empty string) {
	switch {
	case sp.failure != nil:
		a.panelMessage(c, a.text.Errors.Core(sp.failure.Error()), a.theme.Danger)
	case sp.view == nil:
		a.panelMessage(c, empty, a.colors.Subtle)
	default:
		sp.hit = ui.ID(c.Part(part))
		ui.Control(c.Part(part), filepath.Base(sp.path), &sp.input).Grow(1).Basis(0).FillHeight().MinHeight(0).Draw(sp.draw)
	}
}
