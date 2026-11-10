package workbench

import (
	"context"
	"errors"
	"strconv"
	"unicode"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// Rename: the logic of one rename. The dialog in pluginrename_view.go only
// shows renameState and reports the user's confirm or cancel, so the same logic
// can be drawn by another view layer.
//
// Flow: open (prefilled with the identifier at the caret) -> confirm sends
// textDocument/rename -> Core normalises the WorkspaceEdit -> Core plans the
// targets (workspace scope, read-only documents, commit order) -> edits are
// computed by Core for every target before anything is written -> closed files
// are written through the guarded document writer in Core's order and restored
// in reverse when one fails -> open documents get one undoable local edit each.

// renameState is the rename dialog's state.
type renameState struct {
	open bool
	// busy is set from confirm until the server answers or the dialog closes.
	busy       bool
	documentID int
	revision   int
	line       int
	column     int
	initial    string
	name       ui.Field
}

// renameOpenDocument is one open editor document captured on the window thread
// for a workspace edit.
type renameOpenDocument struct {
	id       int
	revision int
	text     rope.Rope
	caret    int
}

// renameClosedWrite is one closed file's before and after bytes.
type renameClosedWrite struct {
	path          string
	before, after []byte
}

// renameDocumentUpdate is one open document's prepared edit.
type renameDocumentUpdate struct {
	id       int
	revision int
	change   editorview.TextChange
}

// openPluginRename opens the rename dialog for the symbol at the caret.
func (a *App) openPluginRename(p *project, d *document) {
	if a.plugins == nil || p == nil || d == nil || a.project != p || d.view.IsComposing() {
		return
	}
	if _, ok := a.semanticServer(d); !ok {
		a.notify(i18n.Shared(a.language(), "desktop.semantics.noServer"))
		return
	}
	a.closePluginSemantics()
	line, column := d.view.CaretUTF16()
	initial := identifierAt(d.view.TextSnapshot(), d.view, line, column)
	state := &a.semantics.rename
	*state = renameState{open: true, documentID: d.id, revision: d.view.Revision(), line: line, column: column, initial: initial}
	state.name.SetText(initial)
	a.semantics.project = p
	a.semantics.documentID = d.id
}

// identifierAt is the identifier under the caret, used only to prefill the
// rename field; the server decides what the rename actually covers.
func identifierAt(text rope.Rope, view *editorview.View, line, column int) string {
	at, ok := view.ByteOffset(line, column)
	if !ok {
		return ""
	}
	start, end := text.LineStart(line), text.LineEnd(line)
	lineText, _ := text.Substring(start, end)
	value := lineText
	i := at - start
	if i < 0 || i > len(value) {
		return ""
	}
	isWord := func(r rune) bool { return r == '_' || unicode.IsLetter(r) || unicode.IsDigit(r) }
	from, to := i, i
	for from > 0 {
		r, size := utf8.DecodeLastRuneInString(value[:from])
		if !isWord(r) {
			break
		}
		from -= size
	}
	for to < len(value) {
		r, size := utf8.DecodeRuneInString(value[to:])
		if !isWord(r) {
			break
		}
		to += size
	}
	return value[from:to]
}

// renameReady says the typed name can be sent.
func (a *App) renameReady() bool {
	state := &a.semantics.rename
	name := state.name.Text()
	return state.open && !state.busy && name != "" && name != state.initial
}

// confirmPluginRename sends the rename request for the typed name.
func (a *App) confirmPluginRename() {
	state := &a.semantics.rename
	if !a.renameReady() {
		return
	}
	p, d := a.currentSemanticDocument(state.documentID)
	if d == nil || p != a.project || d.view.Revision() != state.revision {
		a.closePluginRename()
		return
	}
	state.busy = true
	position := core.PluginDocumentPosition{Line: state.line, UTF16Column: state.column}
	a.startPluginEdit(pluginSemanticRename, p, d, &position, state.name.Text())
}

// cancelPluginRename closes the dialog and cancels a request in flight.
func (a *App) cancelPluginRename() {
	a.cancelSemanticKind(pluginSemanticRename)
	a.closePluginRename()
}

func (a *App) closePluginRename() {
	state := &a.semantics.rename
	documentID := state.documentID
	wasOpen := state.open
	*state = renameState{}
	if wasOpen {
		a.focusDocument(documentID)
	}
}

// renameAborted ends the dialog after a failed or unavailable request.
func (a *App) renameAborted() {
	if a.semantics.rename.busy {
		a.closePluginRename()
	}
}

func (a *App) applySemanticRename(pending *semanticPending, event core.BackendEvent) {
	p, d := a.currentSemanticDocument(pending.documentID)
	if p != pending.project || d == nil || d.view.Revision() != pending.revision {
		a.closePluginRename()
		return
	}
	changes, err := core.PluginSemanticWorkspaceChanges(event)
	a.closePluginRename()
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_rename", err))
		a.notify(i18n.Shared(a.language(), "desktop.semantics.operationFailed"))
		return
	}
	if len(changes) == 0 {
		a.notify(i18n.Shared(a.language(), "desktop.semantics.renameNothing"))
		return
	}
	a.applyWorkspaceChanges(p, changes)
}

// errRenameRejected marks a plan Core refused; nothing was written.
var errRenameRejected = errors.New("workspace edit rejected by Core")

// applyWorkspaceChanges plans and commits a normalised workspace edit.
func (a *App) applyWorkspaceChanges(p *project, changes map[string][]core.PluginTextEdit) {
	open := make(map[string]renameOpenDocument, len(p.docs.list))
	list := make([]core.PluginOpenDocument, 0, len(p.docs.list))
	for _, d := range p.docs.list {
		line, column := d.view.CaretUTF16()
		caret, _ := d.view.ByteOffset(line, column)
		open[d.path] = renameOpenDocument{id: d.id, revision: d.view.Revision(), text: d.view.TextSnapshot(), caret: caret}
		list = append(list, core.PluginOpenDocument{Path: d.path})
	}
	write := a.documentWriter
	root := p.root
	a.background(p, semanticApplyTimeout, func(ctx context.Context) func(*App) {
		files, updates, err := a.commitWorkspaceEdit(ctx, root, changes, list, open, write)
		return func(a *App) {
			if a.project != p {
				return
			}
			if err != nil {
				if errors.Is(err, errRenameRejected) {
					a.notify(i18n.Shared(a.language(), "desktop.semantics.renameRejected"))
				} else {
					a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_rename", err))
					a.notify(i18n.Shared(a.language(), "desktop.semantics.renameFailed"))
				}
				return
			}
			stale := 0
			for _, update := range updates {
				document := p.docs.find(update.id)
				if document == nil || document.view.Revision() != update.revision || !document.view.ApplyTextChange(update.change) {
					stale++
				}
			}
			if stale > 0 {
				a.notify(i18n.Shared(a.language(), "desktop.semantics.renamePartial"))
				return
			}
			a.notify(i18n.SharedFormat(a.language(), "desktop.semantics.renameApplied", map[string]string{"count": strconv.Itoa(files + len(updates))}))
		}
	})
}

// commitWorkspaceEdit runs off the window thread. It asks Core to plan, has Core
// compute every target's new text first, then writes closed files in Core's
// order. A failed write restores the files already written in reverse order and
// returns the failure, leaving open documents untouched.
func (a *App) commitWorkspaceEdit(ctx context.Context, root string, changes map[string][]core.PluginTextEdit, list []core.PluginOpenDocument, open map[string]renameOpenDocument, write func(string, []byte, []byte) error) (int, []renameDocumentUpdate, error) {
	plan, err := a.kernel.PlanPluginWorkspaceEdit(ctx, root, changes, list)
	if err != nil {
		return 0, nil, err
	}
	if plan.Rejection != nil {
		return 0, nil, errRenameRejected
	}
	var writes []renameClosedWrite
	var updates []renameDocumentUpdate
	for _, target := range plan.Targets {
		switch target.Effect {
		case "writeFile":
			data, err := readDocument(target.Path)
			if err != nil {
				return 0, nil, err
			}
			text, err := a.kernel.ApplyPluginTextEdits(ctx, string(data), target.Edits)
			if err != nil {
				return 0, nil, err
			}
			writes = append(writes, renameClosedWrite{path: target.Path, before: data, after: []byte(text)})
		case "updateDocument":
			snapshot, ok := open[target.Path]
			if !ok {
				return 0, nil, errors.New("workspace edit names an open document the editor does not hold")
			}
			text, err := a.kernel.ApplyPluginTextEdits(ctx, snapshot.text.String(), target.Edits)
			if err != nil {
				return 0, nil, err
			}
			updates = append(updates, renameDocumentUpdate{
				id: snapshot.id, revision: snapshot.revision,
				change: preparedTextChange(snapshot.text, text, snapshot.caret),
			})
		default:
			return 0, nil, errors.New("workspace edit plan has an unknown effect")
		}
	}
	for i, w := range writes {
		if err := write(w.path, w.after, w.before); err != nil {
			failure := err
			for j := i - 1; j >= 0; j-- {
				if restoreErr := write(writes[j].path, writes[j].before, writes[j].after); restoreErr != nil {
					failure = errors.Join(failure, restoreErr)
				}
			}
			return 0, nil, failure
		}
	}
	return len(writes), updates, nil
}
