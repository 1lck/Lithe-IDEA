package workbench

import (
	"context"
	"runtime"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// Document-changing language operations: formatting and rename.
//
// Core owns the language-server answer. It normalises the edits, validates their
// UTF-16 ranges and applies them to text (lsp.applyTextEdits), and it decides
// which workspace-edit targets may be written and in which order
// (lsp.planWorkspaceEdit). This file only asks, hands the current text to Core
// and applies Core's resulting text to the editor as one undoable local edit, or
// writes closed files through the guarded document writer.

const (
	// semanticApplyTimeout bounds Core's edit application and the guarded writes
	// of one formatting or rename commit.
	semanticApplyTimeout = 30 * time.Second
)

// pluginEditShortcut handles the reformat chord (Option+Command+L on macOS,
// Control+Alt+L elsewhere) for the editor that owns the keyboard. It formats the
// selection when there is one and the whole document otherwise.
func (a *App) pluginEditShortcut(event gfx.KeyEvent) gfx.EventResult {
	if event.Release || !strings.EqualFold(event.Text, "l") {
		return gfx.EventResult{}
	}
	want := gfx.ModifierControl | gfx.ModifierAlt
	if runtime.GOOS == "darwin" {
		want = gfx.ModifierMeta | gfx.ModifierAlt
	}
	if event.Modifiers != want {
		return gfx.EventResult{}
	}
	p, d := a.pluginSemanticHit(event.Target)
	if d == nil || d.view.IsComposing() {
		return gfx.EventResult{}
	}
	a.startPluginFormattingAtSelection(p, d)
	return gfx.EventResult{Handled: true, Repaint: true}
}

// startPluginEdit submits a formatting or rename request. A request that would
// race the document's pending changes waits for them, like every semantic
// request. These are explicit commands, so a missing server is reported.
func (a *App) startPluginEdit(kind semanticKind, p *project, d *document, position *core.PluginDocumentPosition, newName string) {
	a.startPluginEditRequest(kind, p, d, core.PluginSemanticRequest{Position: position, NewName: newName})
}

// startPluginEditRequest is startPluginEdit with the request body prepared by the caller
// except for the operation and URI, which are filled in here.
func (a *App) startPluginEditRequest(kind semanticKind, p *project, d *document, body core.PluginSemanticRequest) {
	if a.plugins == nil || p == nil || d == nil || a.project != p || d.view.IsComposing() {
		return
	}
	a.closeSemanticHover()
	a.closeSemanticCompletion()
	a.closeSemanticDefinition()
	retry := func(a *App) { a.startPluginEditRequest(kind, p, d, body) }
	if !a.semanticDocumentReady(d) {
		a.deferSemantic(p, d, retry)
		a.startDocumentSync(p, d)
		return
	}
	server, ok := a.semanticServer(d)
	if !ok {
		a.notify(i18n.Shared(a.language(), "desktop.semantics.noServer"))
		a.renameAborted()
		return
	}
	if !server.isReady() {
		a.deferSemantic(p, d, retry)
		return
	}
	line, column := 0, 0
	if body.Position != nil {
		line, column = body.Position.Line, body.Position.UTF16Column
	}
	a.cancelSemanticKind(kind)
	// Document and selection formatting rewrite the same text, so a newer one replaces either.
	switch kind {
	case pluginSemanticFormatting:
		a.cancelSemanticKind(pluginSemanticRangeFormatting)
	case pluginSemanticRangeFormatting:
		a.cancelSemanticKind(pluginSemanticFormatting)
	}
	pending := a.newSemanticPending(kind, p, d, server, line, column, false, false)
	a.semantics.pending = append(a.semantics.pending, pending)
	body.Operation, body.URI = string(kind), d.sync.uri
	a.submitSemantic(pending, body)
}

// formattingOptions is the indentation the editor currently uses, which the server
// formats to. The editor has no indentation setting of its own yet, so this is the
// indent unit detected from the document: a tab, or four spaces when spaces lead or
// nothing is indented (tabSize 4, insertSpaces true).
func formattingOptions(d *document) *core.FormattingOptions {
	size, spaces := d.view.IndentSettings()
	return &core.FormattingOptions{TabSize: size, InsertSpaces: spaces}
}

// startPluginFormatting asks the server to format the whole document.
func (a *App) startPluginFormatting(p *project, d *document) {
	a.startPluginEditRequest(pluginSemanticFormatting, p, d, core.PluginSemanticRequest{FormattingOptions: formattingOptions(d)})
}

// startPluginFormattingAtSelection formats the selected range, or the whole document
// when nothing is selected.
func (a *App) startPluginFormattingAtSelection(p *project, d *document) {
	startLine, startColumn, endLine, endColumn, ok := d.view.SelectionUTF16()
	if !ok {
		a.startPluginFormatting(p, d)
		return
	}
	a.startPluginEditRequest(pluginSemanticRangeFormatting, p, d, core.PluginSemanticRequest{
		Range: &core.PluginDocumentRange{
			Start: core.PluginDocumentPosition{Line: startLine, UTF16Column: startColumn},
			End:   core.PluginDocumentPosition{Line: endLine, UTF16Column: endColumn},
		},
		FormattingOptions: formattingOptions(d),
	})
}

// semanticOperationFailed tells the user a document-changing request failed;
// the stable error code is already in the log.
func (a *App) semanticOperationFailed(kind semanticKind) {
	switch kind {
	case pluginSemanticFormatting, pluginSemanticRangeFormatting, pluginSemanticRename:
		a.notify(i18n.Shared(a.language(), "desktop.semantics.operationFailed"))
		if kind == pluginSemanticRename {
			a.renameAborted()
		}
	}
}

func (a *App) applySemanticFormatting(pending *semanticPending, event core.BackendEvent) {
	p, d := a.currentSemanticDocument(pending.documentID)
	if p != pending.project || d == nil || d.view.Revision() != pending.revision {
		return
	}
	edits, err := core.PluginSemanticTextEdits(event)
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_format", err))
		a.notify(i18n.Shared(a.language(), "desktop.semantics.formatFailed"))
		return
	}
	if len(edits) == 0 {
		a.notify(i18n.Shared(a.language(), "desktop.semantics.formatNothing"))
		return
	}
	a.applyEditsToDocument(p, d, edits, "plugin_format")
}

// applyEditsToDocument has Core apply edits to the document's snapshot and puts
// the result in the editor as one undoable edit spanning only the changed text.
// The result is dropped when the document changed while Core worked.
func (a *App) applyEditsToDocument(p *project, d *document, edits []core.PluginTextEdit, operation string) {
	documentID, revision := d.id, d.view.Revision()
	snapshot := d.view.TextSnapshot()
	line, column := d.view.CaretUTF16()
	caret, _ := d.view.ByteOffset(line, column)
	a.background(p, semanticApplyTimeout, func(ctx context.Context) func(*App) {
		applied, err := a.kernel.ApplyPluginTextEdits(ctx, snapshot.String(), edits)
		var change editorview.TextChange
		if err == nil {
			change = preparedTextChange(snapshot, applied, caret)
		}
		return func(a *App) {
			current, document := a.currentSemanticDocument(documentID)
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields(operation, err))
				a.notify(i18n.Shared(a.language(), "desktop.semantics.formatFailed"))
				return
			}
			if current != p || document == nil || a.project != p || document.view.Revision() != revision {
				return
			}
			document.view.ApplyTextChange(change)
		}
	})
}

// preparedTextChange is the editor change from before to text with the caret
// kept: unchanged before the changed span, shifted after it, and at the end of
// the replacement when it was inside. It may scan the document and must run off
// the window thread.
func preparedTextChange(before rope.Rope, text string, caret int) editorview.TextChange {
	start, oldEnd, newEnd := rope.Diff(before, rope.FromString(text))
	switch {
	case caret <= start:
	case caret >= oldEnd:
		caret += newEnd - oldEnd
	default:
		caret = newEnd
	}
	return editorview.PrepareTextChange(before, text, caret)
}
