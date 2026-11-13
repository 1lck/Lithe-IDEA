package workbench

import (
	"context"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// problemsPreview is the read-only source view beside the Problems list. It shows the file of the
// selected diagnostic and reveals its line; it never takes the keyboard focus of the window or
// writes the file. Its text is the open document's when the file is open, so unsaved edits show.
type problemsPreview struct {
	// path and line are the file and zero-based line the preview was asked for. A load replaces
	// view when its answer arrives for the same generation.
	path       string
	line       int
	generation uint64
	failure    error
	view       *editorview.View
	hit        gfx.ID
	input      ui.Handlers
	draw       func(*ui.DrawContext)
}

// close releases the view's highlighter and forgets the file.
func (pv *problemsPreview) close() {
	if pv.view != nil {
		pv.view.Close()
	}
	pv.view = nil
	pv.path = ""
	pv.failure = nil
	pv.generation++
}

// selectedProblemLocation is the file and zero-based line of the selected diagnostic, and false
// when no diagnostic row is selected.
func (v *problemsView) selectedProblemLocation() (string, int, bool) {
	row := v.list.Selected()
	if row < 0 {
		return "", 0, false
	}
	group, index, header := v.rowAt(row)
	if header {
		return "", 0, false
	}
	item, ok := v.diagnostic(group, index)
	if !ok || item.FileKey == "" {
		return "", 0, false
	}
	return item.FileKey, item.Line, true
}

// syncProblemsPreview follows the selection while the preview is on. A new file starts a load; the
// same file only moves the reveal. A selection that is not a diagnostic keeps the last preview.
func (a *App) syncProblemsPreview(p *project) {
	v := &a.problems
	if !v.show {
		return
	}
	path, line, ok := v.selectedProblemLocation()
	if !ok {
		return
	}
	pv := &v.preview
	if pv.path != path {
		a.loadProblemsPreview(p, path, line)
		return
	}
	if pv.line != line {
		pv.line = line
		if pv.view != nil {
			pv.view.GoToLine(line + 1)
		}
	}
}

// loadProblemsPreview reads the file's text off the window thread. An open document contributes its
// current text, so the preview shows what the editor shows.
func (a *App) loadProblemsPreview(p *project, path string, line int) {
	pv := &a.problems.preview
	if pv.view != nil {
		pv.view.Close()
	}
	pv.view = nil
	pv.failure = nil
	pv.path, pv.line = path, line
	pv.generation++
	generation := pv.generation
	var openText []byte
	open := false
	if d := p.docs.byPath(path); d != nil {
		data, _ := d.view.Text()
		openText = append([]byte(nil), data...)
		open = true
	}
	registry := a.syntaxRegistry()
	kernel, _ := a.kernel.(editorKernel)
	a.background(p, 0, func(ctx context.Context) func(*App) {
		data, err := openText, error(nil)
		if !open {
			var read documentRead
			read, err = readDocumentEncoded(ctx, kernel, path)
			data = read.text
		}
		var content editorview.Content
		var grammar *syntax.Syntax
		if err == nil {
			content = editorview.Prepare(data)
			grammar = registry.SyntaxForPath(path)
		}
		return func(a *App) {
			pv := &a.problems.preview
			if pv.generation != generation || a.project != p || !a.problems.show {
				return
			}
			if err != nil {
				pv.failure = err
				return
			}
			a.installProblemsPreview(path, content, grammar)
		}
	})
}

// installProblemsPreview makes the read-only view of the loaded text and reveals the requested line.
func (a *App) installProblemsPreview(path string, content editorview.Content, grammar *syntax.Syntax) {
	pv := &a.problems.preview
	view := editorview.New(editorview.Config{
		Label:   filepath.Base(path),
		Content: content,
		Syntax:  grammar,
		Notify:  a.invalidator.Invalidate,
	})
	view.SetReadOnly(true)
	view.SetWrap(false)
	view.SetMinimap(false)
	view.GoToLine(pv.line + 1)
	pv.view = view
	pv.input = ui.Handlers{
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
	pv.draw = func(dc *ui.DrawContext) { a.drawProblemsPreview(dc, pv) }
}

// problemsPreviewPane declares the preview beside the list, or the reason there is none.
func (a *App) problemsPreviewPane(c ui.C, p *project) {
	lang := a.language()
	pv := &a.problems.preview
	switch {
	case pv.failure != nil:
		a.panelMessage(c, a.text.Errors.Core(pv.failure.Error()), a.theme.Danger)
	case pv.view == nil:
		a.panelMessage(c, i18n.Shared(lang, "desktop.problems.previewEmpty"), a.colors.Subtle)
	default:
		pv.hit = ui.ID(c.Part("problemsPreview"))
		ui.Control(c.Part("problemsPreview"), filepath.Base(pv.path), &pv.input).Grow(1).Basis(0).FillHeight().Draw(pv.draw)
	}
}

// drawProblemsPreview paints the preview into its control.
func (a *App) drawProblemsPreview(dc *ui.DrawContext, pv *problemsPreview) {
	v := pv.view
	if v == nil {
		return
	}
	v.BindWithoutMinimap(pv.hit, pv.input.Parts())
	v.HideVerticalBar()
	v.SetFont(a.editorFont())
	v.SetWrap(false)
	v.SetMessages(a.editorMessages())
	v.Paint(dc.Canvas, dc.Rect, a.editorLook())
}
