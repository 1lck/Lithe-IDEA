package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync/atomic"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
	pluginSemanticCodeActions       semanticKind = "codeActions"
	pluginSemanticResolveCodeAction semanticKind = "resolveCodeAction"
	pluginSemanticExecuteCommand    semanticKind = "executeCommand"

	pluginMethodCodeActions       = "textDocument/codeAction"
	pluginMethodResolveCodeAction = "codeAction/resolve"
	pluginMethodExecuteCommand    = "workspace/executeCommand"

	pluginWorkspaceApplyEdit          = "workspaceApplyEdit"
	pluginWorkspaceApplyEditCancelled = "workspaceApplyEditCancelled"

	featureCodeActions       = "codeActions"
	featureCodeActionResolve = "codeActionResolve"

	codeActionPopupWidth = float32(420)
	codeActionRowHeight  = float32(28)
)

type workspaceApplyEditKernel interface {
	RespondWorkspaceApplyEdit(ctx context.Context, session, applyEditID string, applied bool, failureReason string) error
}

// codeActionsState holds the open Code Actions popup and its virtualized list state.
type codeActionsState struct {
	open       bool
	resolving  bool
	actions    []core.PluginSemanticCodeAction
	selected   int
	list       ui.ListState
	documentID int
	revision   int
	anchor     gfx.Rect
}

// storeRawPluginDiagnostics retains Core's normalized LSP diagnostics per plugin and file
// so codeAction requests forward nullable severity, tags and relatedInformation intact.
func (a *App) storeRawPluginDiagnostics(pluginID, fileKey string, diagnostics []core.PluginDiagnostic) {
	if pluginID == "" || fileKey == "" {
		return
	}
	if len(diagnostics) == 0 {
		if byFile := a.rawPluginDiagnostics[pluginID]; byFile != nil {
			delete(byFile, fileKey)
			if len(byFile) == 0 {
				delete(a.rawPluginDiagnostics, pluginID)
			}
		}
		return
	}
	if a.rawPluginDiagnostics == nil {
		a.rawPluginDiagnostics = make(map[string]map[string][]core.PluginDiagnostic)
	}
	byFile := a.rawPluginDiagnostics[pluginID]
	if byFile == nil {
		byFile = make(map[string][]core.PluginDiagnostic)
		a.rawPluginDiagnostics[pluginID] = byFile
	}
	copied := make([]core.PluginDiagnostic, len(diagnostics))
	copy(copied, diagnostics)
	byFile[fileKey] = copied
}

func (a *App) clearRawPluginDiagnostics(pluginID string) {
	if a.rawPluginDiagnostics != nil {
		delete(a.rawPluginDiagnostics, pluginID)
		if len(a.rawPluginDiagnostics) == 0 {
			a.rawPluginDiagnostics = nil
		}
	}
}

func (a *App) clearRawPluginFileDiagnostics(pluginID, fileKey string) {
	if byFile := a.rawPluginDiagnostics[pluginID]; byFile != nil {
		delete(byFile, fileKey)
		if len(byFile) == 0 {
			delete(a.rawPluginDiagnostics, pluginID)
		}
	}
}

func (a *App) clearAllRawPluginDiagnostics() {
	a.rawPluginDiagnostics = nil
}

// diagnosticsOverlapping forwards only diagnostics from the server
// receiving the request, keeping the server's original publication order.
func (a *App) diagnosticsOverlapping(owner, path string, target core.PluginDocumentRange) []core.PluginDiagnostic {
	var out []core.PluginDiagnostic
	for _, diag := range a.rawPluginDiagnostics[owner][path] {
		if diagnosticOverlapsRange(diag.Range, target) {
			out = append(out, diag)
		}
	}
	return out
}

func (a *App) diagnosticsOnLine(owner, path string, line int) []core.PluginDiagnostic {
	var out []core.PluginDiagnostic
	for _, diag := range a.rawPluginDiagnostics[owner][path] {
		if diag.Range.Start.Line <= line && line <= diag.Range.End.Line {
			out = append(out, diag)
		}
	}
	return out
}

func diagnosticOverlapsRange(d core.PluginDiagnosticRange, r core.PluginDocumentRange) bool {
	if comparePos(d.End.Line, d.End.UTF16Column, r.Start.Line, r.Start.UTF16Column) < 0 {
		return false
	}
	if comparePos(r.End.Line, r.End.UTF16Column, d.Start.Line, d.Start.UTF16Column) < 0 {
		return false
	}
	return true
}

func comparePos(lineA, colA, lineB, colB int) int {
	if lineA != lineB {
		if lineA < lineB {
			return -1
		}
		return 1
	}
	if colA < colB {
		return -1
	}
	if colA > colB {
		return 1
	}
	return 0
}

func (a *App) diagnosticAt(d *document, line, column int) (core.PluginDiagnostic, bool) {
	server, offered := a.editorServer(d, featureCodeActions)
	if !offered {
		return core.PluginDiagnostic{}, false
	}
	pos := core.PluginDocumentPosition{Line: line, UTF16Column: column}
	target := core.PluginDocumentRange{Start: pos, End: pos}
	for _, diag := range a.rawPluginDiagnostics[server.session.PluginID][d.path] {
		if diag.Message != "" && diagnosticOverlapsRange(diag.Range, target) {
			return diag, true
		}
	}
	return core.PluginDiagnostic{}, false
}

// codeActionsShortcut handles Option+Enter on macOS and Alt+Enter on Windows/Linux.
func (a *App) codeActionsShortcut(event gfx.KeyEvent) gfx.EventResult {
	if event.Release || event.Modifiers != gfx.ModifierAlt {
		return gfx.EventResult{}
	}
	if event.Key != gfx.KeyEnter && event.Text != "\r" && event.Text != "\n" {
		return gfx.EventResult{}
	}
	p, d := a.pluginSemanticHit(event.Target)
	if d == nil || d.caretView().IsComposing() || d.view.ReadOnly() {
		return gfx.EventResult{}
	}
	if _, offered := a.editorServer(d, featureCodeActions); !offered {
		return gfx.EventResult{}
	}
	a.startPluginCodeActions(p, d, nil, surfaceShortcut)
	return gfx.EventResult{Handled: true, Repaint: true}
}

// startPluginCodeActions requests code actions for the current selection or caret position.
func (a *App) startPluginCodeActions(p *project, d *document, only []string, surface actionSurface) {
	if a.plugins == nil || p == nil || d == nil || a.project != p || d.caretView().IsComposing() || d.view.ReadOnly() {
		return
	}
	var target core.PluginDocumentRange
	if sLine, sCol, eLine, eCol, ok := d.caretView().SelectionUTF16(); ok {
		target = core.PluginDocumentRange{
			Start: core.PluginDocumentPosition{Line: sLine, UTF16Column: sCol},
			End:   core.PluginDocumentPosition{Line: eLine, UTF16Column: eCol},
		}
	} else {
		line, col := d.caretView().CaretUTF16()
		pos := core.PluginDocumentPosition{Line: line, UTF16Column: col}
		target = core.PluginDocumentRange{Start: pos, End: pos}
	}
	anchor, _ := d.caretView().CaretRect()
	a.startPluginCodeActionsAtRange(p, d, target, anchor, only, surface)
}

// startPluginCodeActionsAtRange requests code actions over an explicit UTF-16 range and anchor.
func (a *App) startPluginCodeActionsAtRange(p *project, d *document, target core.PluginDocumentRange, anchor gfx.Rect, only []string, surface actionSurface) {
	if a.plugins == nil || p == nil || d == nil || a.project != p || d.caretView().IsComposing() || d.view.ReadOnly() {
		return
	}
	a.closeSemanticHover()
	a.closeSemanticCompletion()
	a.closeSemanticDefinition()
	a.closeSemanticCodeActions()
	revision := d.view.Revision()
	retry := func(a *App) {
		if p.docs.find(d.id) == d && d.view.Revision() == revision {
			a.startPluginCodeActionsAtRange(p, d, target, anchor, only, surface)
		}
	}
	if !a.semanticDocumentReady(d) {
		a.deferSemantic(p, d, retry)
		a.startDocumentSync(p, d)
		return
	}
	server, ok := a.semanticServer(d)
	if !ok {
		a.notify(i18n.Shared(a.language(), "desktop.semantics.noServer"))
		return
	}
	if !server.isReady() {
		a.deferSemantic(p, d, retry)
		return
	}
	if !server.features[featureCodeActions] {
		a.notifyInfo(i18n.Shared(a.language(), "desktop.semantics.noCodeActions"))
		return
	}
	diags := a.diagnosticsOverlapping(server.session.PluginID, d.path, target)
	if len(diags) == 0 && target.Start == target.End {
		diags = a.diagnosticsOnLine(server.session.PluginID, d.path, target.Start.Line)
	}
	ctxPayload := map[string]any{"triggerKind": 1}
	if len(only) > 0 {
		ctxPayload["only"] = only
	}
	rawCtx, _ := json.Marshal(ctxPayload)

	a.cancelSemanticKind(pluginSemanticCodeActions)
	a.cancelSemanticKind(pluginSemanticResolveCodeAction)
	pending := a.newSemanticPending(pluginSemanticCodeActions, p, d, server, target.Start.Line, target.Start.UTF16Column, false, false)
	pending.anchor = anchor
	a.semantics.pending = append(a.semantics.pending, pending)
	if surface != "" {
		a.performed("editor.semantics.codeActions", surface)
	}
	request := core.PluginSemanticRequest{
		Operation:         string(pluginSemanticCodeActions),
		URI:               d.sync.uri,
		Range:             &target,
		Diagnostics:       diags,
		CodeActionContext: rawCtx,
	}
	a.background(pending.project, semanticStartTimeout, func(ctx context.Context) func(*App) {
		operation, err := a.plugins.RequestLanguageSession(ctx, pending.server.session, request)
		return func(a *App) { a.semanticRequestStarted(pending, operation, err, ctx.Err()) }
	})
}

func (a *App) applySemanticCodeActions(pending *semanticPending, event core.BackendEvent) {
	p, d := a.currentSemanticDocument(pending.documentID)
	if p != pending.project || d == nil || d.view.Revision() != pending.revision || d.caretView().IsComposing() {
		return
	}
	actions, err := core.PluginSemanticCodeActions(event)
	if err != nil {
		a.operationFailed("plugin_code_actions", err)
		a.notifyError(i18n.Shared(a.language(), "desktop.semantics.operationFailed"))
		return
	}
	if len(actions) == 0 {
		a.closeSemanticCodeActions()
		a.notifyInfo(i18n.Shared(a.language(), "desktop.semantics.noCodeActions"))
		return
	}
	anchor := pending.anchor
	if anchor.Height <= 0 {
		anchor, _ = d.caretView().CaretRect()
	}
	state := &a.semantics.codeActions
	*state = codeActionsState{
		open:       true,
		actions:    actions,
		selected:   0,
		documentID: d.id,
		revision:   pending.revision,
		anchor:     anchor,
	}
	state.list.Select(0)
}

func (a *App) closeSemanticCodeActions() {
	a.semantics.codeActions = codeActionsState{}
}

func (a *App) codeActionsKey(event gfx.KeyEvent) gfx.EventResult {
	state := &a.semantics.codeActions
	if state.resolving {
		if event.Key == gfx.KeyEscape {
			a.cancelSemanticKind(pluginSemanticResolveCodeAction)
			a.closeSemanticCodeActions()
			return gfx.EventResult{Handled: true, Repaint: true}
		}
		return gfx.EventResult{Handled: true}
	}
	switch event.Key {
	case gfx.KeyEscape:
		a.closeSemanticCodeActions()
		return gfx.EventResult{Handled: true, Repaint: true}
	case gfx.KeyUp:
		if state.selected > 0 {
			state.selected--
			state.list.Select(state.selected)
		}
		return gfx.EventResult{Handled: true, Repaint: true}
	case gfx.KeyDown:
		if state.selected+1 < len(state.actions) {
			state.selected++
			state.list.Select(state.selected)
		}
		return gfx.EventResult{Handled: true, Repaint: true}
	case gfx.KeyPageUp:
		state.selected = max(state.selected-visibleSemanticRows, 0)
		state.list.Select(state.selected)
		return gfx.EventResult{Handled: true, Repaint: true}
	case gfx.KeyPageDown:
		state.selected = min(state.selected+visibleSemanticRows, max(len(state.actions)-1, 0))
		state.list.Select(state.selected)
		return gfx.EventResult{Handled: true, Repaint: true}
	case gfx.KeyEnter:
		if len(state.actions) > 0 {
			a.choosePluginCodeAction(state.selected)
			return gfx.EventResult{Handled: true, Repaint: true}
		}
		a.closeSemanticCodeActions()
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	return gfx.EventResult{}
}

func (a *App) choosePluginCodeAction(index int) {
	state := &a.semantics.codeActions
	if index < 0 || index >= len(state.actions) || state.resolving {
		a.closeSemanticCodeActions()
		return
	}
	p, d := a.currentSemanticDocument(state.documentID)
	if d == nil || p != a.project || d.view.Revision() != state.revision || d.caretView().IsComposing() || d.view.ReadOnly() {
		a.closeSemanticCodeActions()
		return
	}
	action := state.actions[index]
	revision := state.revision
	server, ok := a.semanticServer(d)
	if !ok || !server.isReady() {
		a.closeSemanticCodeActions()
		a.notify(i18n.Shared(a.language(), "desktop.semantics.noServer"))
		return
	}
	if action.Edit == nil && action.Command == nil && len(action.Raw) > 0 && server.features[featureCodeActionResolve] {
		state.resolving = true
		a.cancelSemanticKind(pluginSemanticResolveCodeAction)
		pending := a.newSemanticPending(pluginSemanticResolveCodeAction, p, d, server, 0, 0, false, false)
		a.semantics.pending = append(a.semantics.pending, pending)
		request := core.PluginSemanticRequest{
			Operation:  string(pluginSemanticResolveCodeAction),
			URI:        d.sync.uri,
			CodeAction: action.Raw,
		}
		a.background(p, semanticStartTimeout, func(ctx context.Context) func(*App) {
			operation, err := a.plugins.RequestLanguageSession(ctx, server.session, request)
			return func(a *App) { a.semanticRequestStarted(pending, operation, err, ctx.Err()) }
		})
		return
	}
	a.closeSemanticCodeActions()
	a.executeResolvedCodeAction(p, d, server, revision, action)
}

func (a *App) applySemanticResolveCodeAction(pending *semanticPending, event core.BackendEvent) {
	p, d := a.currentSemanticDocument(pending.documentID)
	a.closeSemanticCodeActions()
	if p != pending.project || d == nil || d.view.Revision() != pending.revision || d.caretView().IsComposing() || d.view.ReadOnly() {
		return
	}
	resolved, err := core.PluginSemanticResolvedCodeAction(event)
	if err != nil || resolved == nil {
		if err != nil {
			a.operationFailed("plugin_code_action_resolve", err)
		}
		a.notifyError(i18n.Shared(a.language(), "desktop.semantics.codeActionFailed"))
		return
	}
	a.executeResolvedCodeAction(p, d, pending.server, pending.revision, *resolved)
}

func (a *App) executeResolvedCodeAction(p *project, d *document, server *pluginServer, revision int, action core.PluginSemanticCodeAction) {
	if p != a.project || d == nil || d.view.Revision() != revision || d.caretView().IsComposing() || d.view.ReadOnly() {
		return
	}
	a.performed("editor.codeAction.apply", surfaceButton)
	runCommand := func() {
		if action.Command == nil || action.Command.Command == "" {
			return
		}
		if server == nil || !server.isReady() || !server.features[featureExecuteCommand] {
			return
		}
		cmdBytes, err := json.Marshal(action.Command)
		if err != nil {
			return
		}
		pending := a.newSemanticPending(pluginSemanticExecuteCommand, p, d, server, 0, 0, false, false)
		a.semantics.pending = append(a.semantics.pending, pending)
		request := core.PluginSemanticRequest{
			Operation: string(pluginSemanticExecuteCommand),
			Command:   cmdBytes,
		}
		a.background(p, semanticStartTimeout, func(ctx context.Context) func(*App) {
			operation, reqErr := a.plugins.RequestLanguageSession(ctx, server.session, request)
			return func(a *App) { a.semanticRequestStarted(pending, operation, reqErr, ctx.Err()) }
		})
	}
	if action.Edit != nil && len(action.Edit.Changes) > 0 {
		if !a.workspaceEditVersionsCurrent(p, server, action.Edit.DocumentVersions) {
			a.operationRejected("plugin_code_action", "stale_document_revision")
			a.notifyError(i18n.Shared(a.language(), "desktop.semantics.codeActionFailed"))
			return
		}
		a.applyLanguageWorkspaceEdit(p, server, p.ctx, action.Edit.Changes, func(err error) {
			if err == nil {
				runCommand()
				return
			}
			if errors.Is(err, context.Canceled) || a.project != p {
				return
			}
			if errors.Is(err, errRenameRejected) {
				a.operationRejected("plugin_code_action", "outside_or_readonly")
				a.notifyError(i18n.Shared(a.language(), "desktop.semantics.codeActionRejected"))
			} else {
				a.operationFailed("plugin_code_action", err)
				a.notifyError(i18n.Shared(a.language(), "desktop.semantics.codeActionFailed"))
			}
		})
		return
	}
	runCommand()
}

func (a *App) captureWorkspaceOpenDocuments(p *project) map[string]renameOpenDocument {
	open := make(map[string]renameOpenDocument, len(p.docs.list))
	for _, d := range p.docs.list {
		line, column := d.view.CaretUTF16()
		caret, _ := d.view.ByteOffset(line, column)
		open[d.path] = renameOpenDocument{
			id: d.id, revision: d.view.Revision(),
			text: d.view.TextSnapshot(), caret: caret,
			isReadOnly: d.view.ReadOnly(), isComposing: d.caretView().IsComposing(),
		}
	}
	return open
}

func (a *App) workspaceEditVersionsCurrent(p *project, server *pluginServer, versions map[string]int64) bool {
	if len(versions) == 0 {
		return true
	}
	if server.session.Documents == nil {
		return false
	}
	for path, version := range versions {
		d := p.docs.byPath(path)
		if d == nil || !a.semanticDocumentReady(d) {
			return false
		}
		owner, _ := a.documentSyncServer(d)
		current, tracked := server.session.Documents.Version(d.sync.uri)
		if owner != server || !tracked || current != version {
			return false
		}
	}
	return true
}

var errStaleWorkspaceEdit = errors.New("open document changed before workspace edit could be applied")

// applyLanguageWorkspaceEdit keeps disk I/O off the window thread. If a target
// changes before the open-document edits are installed, it restores any disk
// edits using the exact bytes written, preserving concurrent external edits.
func (a *App) applyLanguageWorkspaceEdit(p *project, server *pluginServer, parent context.Context, changes map[string][]core.PluginTextEdit, done func(error)) {
	open := a.captureWorkspaceOpenDocuments(p)
	write := a.documentWriter
	session := server.session
	// The final callback also runs if the project closes, so it can restore disk writes.
	ctx, cancel := context.WithTimeout(parent, semanticApplyTimeout)
	a.background(nil, 0, func(context.Context) func(*App) {
		defer cancel()
		writes, updates, err := a.prepareWorkspaceEdit(ctx, p.root, changes, open)
		if err == nil {
			err = writeWorkspaceEdit(ctx, writes, write)
		}
		if err != nil {
			return func(*App) { done(err) }
		}

		// The worker owns the disk transaction until the window claims
		// the result. Closing the window may prevent a queued callback
		// from ever running, so cleanup cannot rely on that callback.
		var claimed atomic.Bool
		settled := make(chan struct{})
		var reject error
		a.post(func(a *App) {
			if !claimed.CompareAndSwap(false, true) {
				return
			}
			defer close(settled)
			reject = ctx.Err()
			if reject == nil && (a.project != p || !a.isCurrentPluginServer(session.PluginID, server)) {
				reject = context.Canceled
			}
			if reject != nil {
				return
			}
			for path := range changes {
				if d := p.docs.byPath(path); d != nil && open[path].id != d.id {
					reject = errStaleWorkspaceEdit
					return
				}
			}
			for _, update := range updates {
				d := p.docs.find(update.id)
				if d == nil || d.view.ReadOnly() || d.caretView().IsComposing() || d.view.Revision() != update.revision {
					reject = errStaleWorkspaceEdit
					return
				}
			}
			for _, update := range updates {
				p.docs.find(update.id).view.ApplyTextChange(update.change)
			}
		})
		select {
		case <-settled:
		case <-ctx.Done():
			if claimed.CompareAndSwap(false, true) {
				reject = ctx.Err()
			} else {
				// The window owns the result. This callback only checks
				// snapshots and applies already prepared editor changes.
				<-settled
			}
		}
		var rollbackErr error
		if reject != nil {
			rollbackErr = restoreWorkspaceEdit(writes, write)
		}
		return func(a *App) {
			if rollbackErr != nil {
				a.operationFailed("plugin_workspace_apply_edit_rollback", rollbackErr)
			}
			done(errors.Join(reject, rollbackErr))
		}
	})
}

// applyServerWorkspaceEdit validates a server request and returns the final
// result through Core's bounded, session-scoped request lifecycle.
func (a *App) applyServerWorkspaceEdit(server *pluginServer, event core.BackendEvent) {
	if server == nil || server.session == nil {
		return
	}
	req, err := core.PluginWorkspaceApplyEditFromEvent(event)
	if err != nil {
		a.backgroundFailed("plugin_workspace_apply_edit", err)
		return
	}
	responder, ok := a.kernel.(workspaceApplyEditKernel)
	if !ok {
		return
	}
	respond := func(applied bool, reason string) {
		sessionID := server.session.Session.ID
		a.background(nil, semanticStartTimeout, func(ctx context.Context) func(*App) {
			if err := responder.RespondWorkspaceApplyEdit(ctx, sessionID, req.ApplyEditID, applied, reason); err != nil && !errors.Is(err, context.Canceled) {
				return func(a *App) { a.backgroundFailed("plugin_workspace_apply_edit_response", err) }
			}
			return nil
		})
	}
	p := a.project
	if p == nil || p != server.project || !a.isCurrentPluginServer(server.session.PluginID, server) {
		respond(false, "Workspace session is no longer active.")
		return
	}
	if !a.workspaceEditVersionsCurrent(p, server, req.DocumentVersions) {
		a.operationRejected("plugin_workspace_apply_edit", "stale_document_revision")
		respond(false, "Open document changed before workspace edit could be applied.")
		return
	}
	if len(req.Changes) == 0 {
		respond(true, "")
		return
	}
	if server.workspaceEdits == nil {
		server.workspaceEdits = make(map[string]context.CancelFunc)
	}
	ctx, cancel := context.WithCancel(p.ctx)
	server.workspaceEdits[req.ApplyEditID] = cancel
	a.applyLanguageWorkspaceEdit(p, server, ctx, req.Changes, func(err error) {
		delete(server.workspaceEdits, req.ApplyEditID)
		defer cancel()
		switch {
		case ctx.Err() != nil:
			// log-exempt: 用户取消：Core 已结束这条工作区编辑请求。
		case err == nil:
			respond(true, "")
		case errors.Is(err, errStaleWorkspaceEdit):
			a.operationRejected("plugin_workspace_apply_edit", "stale_document_revision")
			respond(false, "Open document changed before workspace edit could be applied.")
		case errors.Is(err, errRenameRejected):
			a.operationRejected("plugin_workspace_apply_edit", "outside_or_readonly")
			respond(false, "Workspace edit touches outside-workspace or read-only documents.")
		default:
			a.operationFailed("plugin_workspace_apply_edit", err)
			respond(false, "Workspace edit validation or disk write failed.")
		}
	})
}

func (a *App) cancelServerWorkspaceEdit(server *pluginServer, event core.BackendEvent) {
	if server == nil {
		return
	}
	var req struct {
		ID string `json:"applyEditId"`
	}
	if err := json.Unmarshal(event.Result, &req); err != nil {
		a.backgroundFailed("plugin_workspace_apply_edit_cancel", err)
		return
	}
	if cancel := server.workspaceEdits[req.ID]; cancel != nil {
		cancel()
	}
}

func (a *App) codeActionGroupLabel(group string) string {
	lang := a.language()
	switch group {
	case "quickfix":
		return i18n.Shared(lang, "desktop.semantics.codeActionQuickFix")
	case "refactor":
		return i18n.Shared(lang, "desktop.semantics.codeActionRefactor")
	case "source":
		return i18n.Shared(lang, "desktop.semantics.codeActionSource")
	default:
		return i18n.Shared(lang, "desktop.semantics.codeActionOther")
	}
}

func (a *App) codeActionsPopup(c ui.C) {
	state := &a.semantics.codeActions
	p, d := a.currentSemanticDocument(state.documentID)
	if d == nil || p != a.project || d.view.Revision() != state.revision || len(state.actions) == 0 {
		a.closeSemanticCodeActions()
		return
	}
	anchor := state.anchor
	if anchor.Height <= 0 {
		var ok bool
		anchor, ok = d.caretView().CaretRect()
		if !ok {
			a.closeSemanticCodeActions()
			return
		}
	}
	bounds := c.Bounds()
	rows := min(len(state.actions), visibleSemanticRows)
	listHeight := float32(rows) * codeActionRowHeight
	totalHeight := listHeight + 2*semanticPopupPad
	y := anchor.Y + anchor.Height + 2
	if y+totalHeight > bounds.Y+bounds.Height-4 && anchor.Y-totalHeight-2 >= bounds.Y+4 {
		y = anchor.Y - totalHeight - 2
	}
	x, y := popupOrigin(anchor.X, y, codeActionPopupWidth, bounds)
	title := i18n.Shared(a.language(), "desktop.semantics.codeActions")
	state.list.Label = func(i int) string {
		if i >= 0 && i < len(state.actions) {
			return state.actions[i].Title
		}
		return ""
	}
	if state.selected >= 0 && state.selected < len(state.actions) && state.list.Selected() != state.selected {
		state.list.Select(state.selected)
	}
	chosen := -1
	a.semanticPopup(c, x, y, codeActionPopupWidth, totalHeight, title, semanticPopupPad, func() {
		ui.List(c.Part("code-actions-list"), &state.list, len(state.actions), func(row ui.ListRow) {
			action := state.actions[row.Index]
			selected := row.Index == state.selected
			el := row.Element.FillWidth().Height(codeActionRowHeight).PadX(8).Gap(8).Items(ui.Center).
				Radius(a.theme.Metrics.RadiusItem()).
				HitWith(ui.ID(row.C), action.Title, gfx.HitOptions{Role: gfx.RoleOption, SkipFocus: true, Cursor: gfx.PointerCursorHand}).
				Hover(ui.Look{}.Background(a.colors.Hover)).
				Pressed(ui.Look{}.Background(a.colors.Active))
			if selected {
				el = el.Background(a.colors.Active)
			}
			iconColor := a.colors.Subtle
			if action.Group == "quickfix" || action.IsPreferred {
				iconColor = gfx.RGB24(0xD99B26)
			}
			el.Children(func() {
				ui.Icon(row.C, icons.Sparkles).Size(13, 13).Color(iconColor).Shrink(0)
				ui.Text(row.C, action.Title).FontSize(12).Color(a.colors.Text).Grow(1).Shrink(1).Ellipsis()
				if action.IsPreferred {
					ui.Text(row.C, i18n.Shared(a.language(), "desktop.semantics.codeActionPreferred")).
						FontSize(10.5).Color(a.theme.Primary).Shrink(0)
				}
				ui.Text(row.C, a.codeActionGroupLabel(action.Group)).
					FontSize(10.5).Color(a.colors.Subtle).Shrink(0)
			})
			if el.Clicked() {
				chosen = row.Index
			}
		}).Scrollbars().Label(title).FillWidth().Height(listHeight)
	})
	if chosen >= 0 {
		state.selected = chosen
		c.After(func() { a.choosePluginCodeAction(chosen) })
	}
}

// codeActionLightbulb renders a non-focus-stealing clickable lightbulb indicator on the
// active line's left gutter margin without shifting textLeft horizontally.
func (a *App) codeActionLightbulb(c ui.C, p *project, d *document) {
	if p == nil || d == nil || d.virtual || d.view.ReadOnly() || d.caretView().IsComposing() {
		return
	}
	server, offered := a.editorServer(d, featureCodeActions)
	if server == nil || !offered || d.lastArea.Width <= 0 {
		return
	}
	caretRect, ok := d.caretView().CaretRect()
	if !ok || caretRect.Y < d.lastArea.Y || caretRect.Y+caretRect.Height > d.lastArea.Y+d.lastArea.Height {
		return
	}
	caretLine, _ := d.caretView().CaretUTF16()
	hasDiagnostics := false
	for _, diag := range a.rawPluginDiagnostics[server.session.PluginID][d.path] {
		if diag.Range.Start.Line <= caretLine && caretLine <= diag.Range.End.Line {
			hasDiagnostics = true
			break
		}
	}
	start, end := d.caretView().Selection()
	if !hasDiagnostics && start == end {
		return
	}
	bulbColor := a.colors.Subtle
	if hasDiagnostics {
		bulbColor = gfx.RGB24(0xD99B26)
	}
	label := i18n.Shared(a.language(), "desktop.semantics.codeActions")
	bx := d.lastArea.X + 2
	by := caretRect.Y + (caretRect.Height-16)/2
	ui.Stack(c.Part("lightbulb-layer")).Fill().Children(func() {
		kc := c.Part("code-action-bulb")
		btn := ui.Row(kc).Absolute().Left(bx).Top(by).Size(16, 16).Center().
			Radius(4).
			HitWith(ui.ID(kc), label, gfx.HitOptions{Role: gfx.RoleButton, SkipFocus: true, Cursor: gfx.PointerCursorHand}).
			Hover(ui.Look{}.Background(a.colors.Hover)).
			Pressed(ui.Look{}.Background(a.colors.Active)).
			Tooltip(label)
		btn.Children(func() {
			ui.Icon(kc, icons.Sparkles).Size(12, 12).Color(bulbColor)
		})
		if btn.Clicked() {
			anchor := gfx.Rect{X: max(caretRect.X, d.lastArea.X+28), Y: caretRect.Y, Width: 16, Height: caretRect.Height}
			c.After(func() {
				var target core.PluginDocumentRange
				if sLine, sCol, eLine, eCol, selOK := d.caretView().SelectionUTF16(); selOK {
					target = core.PluginDocumentRange{
						Start: core.PluginDocumentPosition{Line: sLine, UTF16Column: sCol},
						End:   core.PluginDocumentPosition{Line: eLine, UTF16Column: eCol},
					}
				} else {
					l, col := d.caretView().CaretUTF16()
					pos := core.PluginDocumentPosition{Line: l, UTF16Column: col}
					target = core.PluginDocumentRange{Start: pos, End: pos}
				}
				a.startPluginCodeActionsAtRange(p, d, target, anchor, nil, surfaceButton)
			})
		}
	})
}

func truncateDisplayText(s string, maxRunes int) string {
	s = strings.TrimSpace(strings.ReplaceAll(strings.ReplaceAll(s, "\r\n", " "), "\n", " "))
	if utf8.RuneCountInString(s) <= maxRunes {
		return s
	}
	var b strings.Builder
	count := 0
	for _, r := range s {
		if count >= maxRunes-1 {
			break
		}
		b.WriteRune(r)
		count++
	}
	b.WriteRune('…')
	return b.String()
}
