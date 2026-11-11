package workbench

import (
	"context"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// sourcePreview is a read-only view of one file that follows a selection in a list
// (Search Everywhere). It never takes the window's keyboard focus or writes the file,
// and an open document lends it its current text, so unsaved edits show.
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
}

// close releases the view's highlighter and forgets the file.
func (sp *sourcePreview) close() {
	if sp.view != nil {
		sp.view.Close()
	}
	sp.view = nil
	sp.path = ""
	sp.failure = nil
	sp.generation++
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
	sp.close()
	sp.path, sp.line = path, line
	generation := sp.generation
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
			if language, ok := registry.ForPath(path); ok {
				grammar = registry.Syntax(language.ID)
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
	sp.draw = func(dc *ui.DrawContext) {
		v := sp.view
		if v == nil {
			return
		}
		v.BindWithoutMinimap(sp.hit, sp.input.Parts())
		v.HideVerticalBar()
		v.SetFont(a.editorFont())
		v.SetWrap(false)
		v.SetMessages(a.editorMessages())
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
