package workbench

import (
	"context"
	"runtime"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// Line operations: toggle comment, delete, move and copy lines.
//
// Core owns every rule (what a comment is for a language, how a selection that ends at the
// start of a line is treated, CRLF, UTF-16 offsets). This file only takes the lines an
// operation can touch from the editor, asks Core off the window thread and puts the answer
// back as one undoable edit while the document is still at the revision the window was
// taken at. A no-op answer (moving the first line up) leaves the document alone.

// editorKernel is what the editor features of this package need beyond the common Kernel. The
// application's kernel (core.Client) has all of it; keeping the list here keeps the editor
// features out of the shared interface.
type editorKernel interface {
	LineEdit(context.Context, core.LineEditRequest) (core.LineEditOutcome, error)
	LineCommentToken(context.Context, string) (*string, error)
	DecodeFileBytes(context.Context, []byte, string) (core.DecodedFile, error)
	EncodeFileText(context.Context, string, string, *bool) (core.EncodedText, error)
	ReduceNavigationHistory(context.Context, core.NavigationHistory, core.NavigationHistoryEvent) (core.NavigationHistory, *core.NavigationLocation, error)
	DeclarationOrUsages(context.Context, string, core.PluginDocumentPosition, []core.PluginSemanticLocation) (bool, error)
}

// lineOperationFor maps a chord to its line operation. Alt-Up and Alt-Down move, adding Shift
// copies, Primary-Shift-K deletes and Primary-slash toggles the comment, as the previous
// clients did.
func lineOperationFor(event gfx.KeyEvent, primary gfx.Modifiers) (core.LineEditOperation, bool) {
	if event.Release {
		return "", false
	}
	switch event.Key {
	case gfx.KeyUp, gfx.KeyDown:
		up := event.Key == gfx.KeyUp
		switch event.Modifiers {
		case gfx.ModifierAlt:
			if up {
				return core.MoveLineUp, true
			}
			return core.MoveLineDown, true
		case gfx.ModifierAlt | gfx.ModifierShift:
			if up {
				return core.CopyLineUp, true
			}
			return core.CopyLineDown, true
		}
	case gfx.KeyUnknown:
		switch {
		case event.Modifiers == primary && event.Text == "/":
			return core.ToggleLineComment, true
		case event.Modifiers == primary|gfx.ModifierShift && strings.EqualFold(event.Text, "k"):
			return core.DeleteLine, true
		}
	}
	return "", false
}

// lineEditKey handles a line-operation key of the focused document, or reports it unhandled.
func (a *App) lineEditKey(p *project, d *document, event gfx.KeyEvent) (gfx.EventResult, bool) {
	if event.Target != d.hit {
		return gfx.EventResult{}, false
	}
	if result := a.navigationHistoryShortcut(event); result.Handled {
		return result, true
	}
	op, ok := lineOperationFor(event, primaryModifier())
	if !ok {
		return gfx.EventResult{}, false
	}
	a.runLineOperation(p, d, op)
	return gfx.EventResult{Handled: true, Repaint: true}, true
}

// lineEditShortcut handles a line-operation chord for the editor that owns the keyboard.
func (a *App) lineEditShortcut(event gfx.KeyEvent) gfx.EventResult {
	op, ok := lineOperationFor(event, primaryModifier())
	if !ok {
		return gfx.EventResult{}
	}
	p, d := a.pluginSemanticHit(event.Target)
	if d == nil {
		return gfx.EventResult{}
	}
	a.runLineOperation(p, d, op)
	return gfx.EventResult{Handled: true, Repaint: true}
}

// runLineOperation applies op to the document's selected lines.
func (a *App) runLineOperation(p *project, d *document, op core.LineEditOperation) {
	kernel, ok := a.kernel.(editorKernel)
	if !ok || p == nil || d == nil || d.virtual || d.view.ReadOnly() {
		return
	}
	in, ok := d.view.LineEditInput()
	if !ok {
		return
	}
	a.performed("editor.lineEdit."+string(op), surfaceShortcut)
	documentID, name := d.id, d.name
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		request := core.LineEditRequest{
			Operation: op, Source: in.Source,
			SelectionStart: in.SelectionStart, SelectionLength: in.SelectionLength,
		}
		if op == core.ToggleLineComment {
			token, err := kernel.LineCommentToken(ctx, name)
			if err != nil {
				return func(a *App) { a.lineEditFailed(err) }
			}
			if token == nil {
				return func(a *App) { a.notifyInfo(i18n.Shared(a.language(), "desktop.editor.noLineComment")) }
			}
			request.CommentToken = token
		}
		outcome, err := kernel.LineEdit(ctx, request)
		return func(a *App) {
			if err != nil {
				a.lineEditFailed(err)
				return
			}
			if !outcome.Applied {
				return
			}
			current := p.docs.find(documentID)
			if current == nil || a.project != p {
				return
			}
			// A document that changed while Core worked keeps its newer text.
			current.view.ApplyLineEdit(in, outcome.ReplacedStart, outcome.ReplacedLength, outcome.Text, outcome.SelectionStart, outcome.SelectionLength)
		}
	})
}

func (a *App) lineEditFailed(err error) {
	a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("editor_line_edit", err))
	a.notifyError(i18n.Shared(a.language(), "desktop.editor.lineEditFailed"))
}

// primaryModifier is the modifier of the platform's primary chords: Command on a Mac,
// Control elsewhere.
func primaryModifier() gfx.Modifiers {
	if runtime.GOOS == "darwin" {
		return gfx.ModifierMeta
	}
	return gfx.ModifierControl
}
