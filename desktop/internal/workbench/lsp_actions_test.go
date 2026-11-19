package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginlsp"
	"github.com/vivaui/viva/gfx"
)

type codeActionSyncKernel struct {
	closeRecordKernel
	changeStarted chan core.PluginDocumentSyncRequest
	releaseChange <-chan struct{}
	version       int64
}

func (k *codeActionSyncKernel) SyncPluginDocument(ctx context.Context, request core.PluginDocumentSyncRequest) (core.PluginDocumentSync, error) {
	if len(request.ContentChanges) == 0 {
		return k.closeRecordKernel.SyncPluginDocument(ctx, request)
	}
	select {
	case k.changeStarted <- request:
	case <-ctx.Done():
		return core.PluginDocumentSync{}, ctx.Err()
	}
	select {
	case <-k.releaseChange:
		k.version++
		return core.PluginDocumentSync{URI: request.URI, DocumentVersion: k.version, Changed: true}, nil
	case <-ctx.Done():
		return core.PluginDocumentSync{}, ctx.Err()
	}
}

func TestLSPCodeActionsApplyEditAndWaitForSynchronizationBeforeCommand(t *testing.T) {
	f := newSemanticFixture(t)
	release := make(chan struct{})
	releaseChange := sync.OnceFunc(func() { close(release) })
	defer releaseChange()
	syncKernel := &codeActionSyncKernel{changeStarted: make(chan core.PluginDocumentSyncRequest, 2), releaseChange: release, version: 1}
	tracker := pluginlsp.New(syncKernel, f.server.session.Session.ID)
	if _, err := tracker.Open(t.Context(), pluginlsp.Document{URI: f.d.sync.uri, LanguageID: f.d.languageID, Text: "one\n"}); err != nil {
		t.Fatal(err)
	}
	f.server.session.Documents = tracker
	f.server.features = map[string]bool{featureCodeActions: true, featureExecuteCommand: true}
	f.d.view.GoToNavigation(0, 1, false)
	f.h.app.storeRawPluginDiagnostics("test", f.d.path, []core.PluginDiagnostic{{Message: "active diagnostic"}})
	f.h.app.storeRawPluginDiagnostics("dev.lithe.test.other", f.d.path, []core.PluginDiagnostic{{Message: "other diagnostic"}})
	if err := f.h.driver.Key(gfx.KeyEnter, gfx.ModifierAlt); err != nil {
		t.Fatal(err)
	}
	f.waitForRequests(t, 1)
	request := f.kernel.request(0)
	if request.Operation != string(pluginSemanticCodeActions) || request.Range == nil || request.Range.Start.UTF16Column != 1 {
		t.Fatalf("code action request = %+v", request)
	}
	if len(request.Diagnostics) != 1 || request.Diagnostics[0].Message != "active diagnostic" {
		t.Fatalf("diagnostic context = %+v", request.Diagnostics)
	}

	version, ok := f.server.session.Documents.Version(f.d.sync.uri)
	if !ok {
		t.Fatal("fixture lacks a synchronized document version")
	}
	response, err := json.Marshal(map[string]any{"actions": []core.PluginSemanticCodeAction{{
		Title: "Replace one with two",
		Group: "quickfix",
		Edit: &core.PluginSemanticWorkspaceEdit{
			Changes:          map[string][]core.PluginTextEdit{f.d.path: wordEdit(0, 0, 3, "two")},
			DocumentVersions: map[string]int64{f.d.path: version},
		},
		Command: &core.PluginSemanticCommand{Title: "Finish edit", Command: "test.finishEdit"},
	}}})
	if err != nil {
		t.Fatal(err)
	}
	f.deliver(t, "op-1", pluginMethodCodeActions, response)
	if !f.h.app.semantics.codeActions.open {
		t.Fatal("code action list did not open")
	}
	if err := f.h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	f.h.await("code action edit and deferred command", func() bool {
		return f.server.codeActionCommand != nil || f.kernel.requestCount() > 1
	})
	if got := f.d.view.TextSnapshot().String(); got != "two\n" {
		t.Fatalf("code action produced %q", got)
	}
	syncDeadline, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	select {
	case change := <-syncKernel.changeStarted:
		if change.URI != f.d.sync.uri || len(change.ContentChanges) != 1 || change.ContentChanges[0].Text != "two" {
			t.Fatalf("wrong code action didChange: %+v", change)
		}
	case <-syncDeadline.Done():
		t.Fatal("the code action did not send its edit to the server")
	}
	if f.server.codeActionCommand == nil || f.kernel.requestCount() != 1 {
		t.Fatal("the command was submitted before the didChange acknowledgement")
	}
	releaseChange()
	f.waitForRequests(t, 2)
	request = f.kernel.request(1)
	var command core.PluginSemanticCommand
	if err := json.Unmarshal(request.Command, &command); err != nil || request.Operation != string(pluginSemanticExecuteCommand) || command.Command != "test.finishEdit" {
		t.Fatalf("execute command request = %+v (%v)", request, err)
	}
	f.deliver(t, "op-2", pluginMethodExecuteCommand, json.RawMessage(`{}`))
	if _, err := f.h.driver.ShortcutChord(primaryModifier(), 'z'); err != nil {
		t.Fatal(err)
	}
	if got := f.d.view.TextSnapshot().String(); got != "one\n" {
		t.Fatalf("undo produced %q", got)
	}
}

func TestLSPSignatureHelpShortcutPresentsAndDismisses(t *testing.T) {
	f := newSemanticFixture(t)
	f.server.features = map[string]bool{featureSignatureHelp: true}
	key := gfx.KeyEvent{Text: "p", Modifiers: primaryModifier(), Target: f.d.hit}
	if !f.h.app.pluginSemanticsShortcut(key).Handled {
		t.Fatal("signature help shortcut was not handled")
	}
	f.waitForRequests(t, 1)
	if request := f.kernel.request(0); request.Operation != string(pluginSemanticSignatureHelp) || request.Position == nil {
		t.Fatalf("signature request = %+v", request)
	}
	f.deliver(t, "op-1", pluginMethodSignatureHelp, json.RawMessage(`{"signatureHelp":{"signatures":[{"label":"greet(name: string)"}],"activeSignature":0}}`))
	if state := f.h.app.semantics.signatureHelp; !state.open || state.help.Signatures[0].Label != "greet(name: string)" {
		t.Fatalf("signature help state = %+v", state)
	}
	if err := f.h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	if f.h.app.semantics.signatureHelp.open {
		t.Fatal("Escape left the signature popup open")
	}
}

func TestLSPSignatureHelpKeepsCompletionPreviewVisible(t *testing.T) {
	f := newSemanticFixture(t)
	if err := f.h.driver.Resize(350, 600); err != nil {
		t.Fatal(err)
	}
	f.openFunctionCompletions(t)
	f.server.features = map[string]bool{featureSignatureHelp: true}
	f.h.app.startPluginSignatureHelp(f.p, f.d, 0, 0, "")
	f.waitForRequests(t, 2)
	f.deliver(t, "op-2", pluginMethodSignatureHelp, json.RawMessage(`{
		"signatureHelp": {
			"signatures": [{"label":"call(arg: string)", "documentation":"Active call.",
				"parameters": [{"documentation":"Active argument.", "byteStart":5, "byteEnd":8}]}],
			"activeSignature":0, "activeParameter":0
		}
	}`))
	completion := f.h.hitLabeled(f.h.shared("desktop.semantics.completion"))
	parameters := f.h.hitLabeled(f.h.shared("desktop.semantics.signatureHelp"))
	if completion.X < parameters.Right() && parameters.X < completion.Right() &&
		completion.Y < parameters.Bottom() && parameters.Y < completion.Bottom() {
		t.Fatalf("completion %v and parameter information %v overlap", completion, parameters)
	}
	if !f.h.showsWrapped(completionTimeoutDetail) || !f.h.shows("Active argument.") {
		t.Fatal("the selected completion and current parameter details should both be visible")
	}
}

func TestLSPInlayHintsReleaseWhenDisabled(t *testing.T) {
	f := newSemanticFixture(t)
	f.h.app.editorPreferences.InlayHints = true
	f.server.features = map[string]bool{featureInlayHints: true}
	f.h.app.invalidator.Invalidate()
	if err := f.h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	f.waitForRequests(t, 1)
	request := f.kernel.request(0)
	if request.Operation != string(pluginSemanticInlayHints) || request.Range == nil || request.Range.Start.Line != 0 {
		t.Fatalf("inlay request = %+v", request)
	}
	f.deliver(t, "op-1", pluginMethodInlayHints, json.RawMessage(`{"hints":[{"position":{"line":0,"utf16Column":1},"label":": string"}]}`))
	f.h.settleChain()
	if !f.d.view.HasInlayHints() {
		t.Fatal("inlay result did not reach the editor")
	}
	f.h.app.editorPreferences.InlayHints = false
	f.h.app.applyInlayHintsPreference(false)
	if f.d.view.HasInlayHints() || f.d.inlay.prepareCancel != nil {
		t.Fatal("disabling inlay hints kept decorations or background preparation")
	}
}

func TestLSPInlayHintsRetryAndStopAfterFailure(t *testing.T) {
	f := newSemanticFixture(t)
	a := f.h.app
	clock := time.Date(2026, time.January, 1, 0, 0, 0, 0, time.UTC)
	a.now = func() time.Time { return clock }
	a.editorPreferences.InlayHints = true
	f.server.features = map[string]bool{featureInlayHints: true}
	a.invalidator.Invalidate()
	f.h.settle()
	f.waitForRequests(t, 1)

	advance := func() {
		t.Helper()
		clock = clock.Add(time.Second)
		if err := f.h.driver.Advance(time.Second); err != nil {
			t.Fatal(err)
		}
	}
	serverError := func(operation string) {
		t.Helper()
		f.h.settle()
		a.applyPluginSemanticEvent(f.server, core.BackendEvent{
			Type: pluginSemanticCompleted, OperationID: operation, Method: pluginMethodInlayHints,
			Error: json.RawMessage(`{"code":-32801,"message":"Content modified"}`),
		})
		// Directly injected events bypass App.post's wakeup.
		a.invalidator.Invalidate()
		f.h.settle()
	}

	serverError("op-1")
	if got := f.kernel.requestCount(); got != 1 {
		t.Fatalf("requests before retry delay = %d, want 1", got)
	}
	advance()
	f.waitForRequests(t, 2)
	f.deliver(t, "op-2", pluginMethodInlayHints, json.RawMessage(`{"hints":[{"position":{"line":0,"utf16Column":1},"label":": string"}]}`))
	f.h.settleChain()
	if !f.d.view.HasInlayHints() {
		t.Fatal("the retry did not paint hints in the same viewport")
	}

	a.inlayHintsRefresh(f.server)
	f.h.settle()
	advance()
	f.waitForRequests(t, 3)
	serverError("op-3")
	advance()
	f.waitForRequests(t, 4)
	f.deliver(t, "op-4", pluginMethodInlayHints, json.RawMessage(`{"hints":true}`))
	f.h.settle()
	if !f.d.view.HasInlayHints() {
		t.Fatal("a failed refresh discarded the last successful hints")
	}
	advance()
	a.invalidator.Invalidate()
	f.h.settleChain()
	if got := f.kernel.requestCount(); got != 4 {
		t.Fatalf("requests after the retry failed = %d, want 4", got)
	}

	a.inlayHintsRefresh(f.server)
	f.h.settle()
	advance()
	f.waitForRequests(t, 5)
	f.deliver(t, "op-5", pluginMethodInlayHints, json.RawMessage(`{"hints":[]}`))
	f.h.settleChain()
	if f.d.view.HasInlayHints() {
		t.Fatal("a successful empty refresh left stale hints visible")
	}
}

func TestLSPWorkspaceEditWriteRollsBackGuardedDiskWrites(t *testing.T) {
	for _, scenario := range []struct {
		name           string
		cancel         bool
		externalTarget string
	}{
		{name: "cancel after first write", cancel: true},
		{name: "second file changed externally", externalTarget: "second.txt"},
		{name: "first file changed before rollback", cancel: true, externalTarget: "first.txt"},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			dir := t.TempDir()
			writes := []renameClosedWrite{
				{path: filepath.Join(dir, "first.txt"), before: []byte("old first"), after: []byte("new first")},
				{path: filepath.Join(dir, "second.txt"), before: []byte("old second"), after: []byte("new second")},
			}
			for _, write := range writes {
				if err := os.WriteFile(write.path, write.before, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			external := []byte("external edit")
			err := writeWorkspaceEdit(ctx, writes, func(path string, next, expected []byte) error {
				if err := documentio.WriteGuarded(path, next, expected); err != nil {
					return err
				}
				if path == writes[0].path && string(next) == string(writes[0].after) {
					if scenario.externalTarget != "" {
						if err := os.WriteFile(filepath.Join(dir, scenario.externalTarget), external, 0o600); err != nil {
							t.Fatal(err)
						}
					}
					if scenario.cancel {
						cancel()
					}
				}
				return nil
			})
			if scenario.cancel && !errors.Is(err, context.Canceled) {
				t.Fatalf("workspace edit error = %v, want cancellation", err)
			}
			if scenario.externalTarget != "" && !errors.Is(err, documentio.ErrConflict) {
				t.Fatalf("workspace edit error = %v, want the writer to detect changed bytes", err)
			}
			for _, write := range writes {
				want := write.before
				if filepath.Base(write.path) == scenario.externalTarget {
					want = external
				}
				data, err := os.ReadFile(write.path)
				if err != nil || string(data) != string(want) {
					t.Fatalf("%s = %q, %v, want %q", write.path, data, err, want)
				}
			}
		})
	}
}

type workspaceEditResponse struct {
	session, id string
	applied     bool
	reason      string
}

type workspaceEditResponseKernel struct {
	*semanticTestKernel
	reply chan workspaceEditResponse
}

func (k *workspaceEditResponseKernel) RespondWorkspaceApplyEdit(ctx context.Context, session, id string, applied bool, reason string) error {
	select {
	case k.reply <- workspaceEditResponse{session: session, id: id, applied: applied, reason: reason}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func TestLSPServerWorkspaceEditAppliesDiskAndEditorChangesBeforeResponding(t *testing.T) {
	f := newSemanticFixture(t)
	a := f.h.app
	responder := &workspaceEditResponseKernel{semanticTestKernel: f.kernel, reply: make(chan workspaceEditResponse, 1)}
	a.kernel = responder
	closed := filepath.Join(f.p.root, "B.java")
	if err := os.WriteFile(closed, []byte("one\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	version, ok := f.server.session.Documents.Version(f.d.sync.uri)
	if !ok {
		t.Fatal("fixture lacks a synchronized document version")
	}
	const requestID = "apply-1"
	result, err := json.Marshal(core.PluginWorkspaceApplyEdit{
		ApplyEditID: requestID,
		Changes: map[string][]core.PluginTextEdit{
			f.d.path: wordEdit(0, 0, 3, "two"),
			closed:   wordEdit(0, 0, 3, "two"),
		},
		DocumentVersions: map[string]int64{f.d.path: version},
	})
	if err != nil {
		t.Fatal(err)
	}
	a.applyServerWorkspaceEdit(f.server, core.BackendEvent{Type: pluginWorkspaceApplyEdit, Result: result})
	awaitDocumentState(t, f.h, func() bool { return len(responder.reply) > 0 })
	response := <-responder.reply
	if response.session != f.server.session.Session.ID || response.id != requestID || !response.applied || response.reason != "" {
		t.Fatalf("workspace edit response = %+v", response)
	}
	if got := f.d.view.TextSnapshot().String(); got != "two\n" {
		t.Fatalf("editor text at acknowledgement = %q, want two", got)
	}
	data, err := os.ReadFile(closed)
	if err != nil || string(data) != "two\n" {
		t.Fatalf("disk text at acknowledgement = %q, %v, want two", data, err)
	}
}

func TestLSPCodeActionsMatchEarlyResultsByOperationID(t *testing.T) {
	f := newSemanticFixture(t)
	a := f.h.app
	pending := a.newSemanticPending(pluginSemanticCodeActions, f.p, f.d, f.server, 0, 0, false, false)
	a.semantics.pending = append(a.semantics.pending, pending)
	f.deliver(t, "replaced", pluginMethodCodeActions, json.RawMessage(`{"actions":[{"title":"Old edits","group":"quickfix"}]}`))
	if a.semantics.codeActions.open || !a.hasPending(pending) {
		t.Fatal("a late result was consumed by the new operation before acknowledgement")
	}
	f.deliver(t, "current", pluginMethodCodeActions, json.RawMessage(`{"actions":[{"title":"Current edits","group":"quickfix"}]}`))
	a.semanticRequestStarted(pending, "current", nil, nil)
	if state := a.semantics.codeActions; !state.open || len(state.actions) != 1 || state.actions[0].Title != "Current edits" {
		t.Fatalf("wrong code action opened: %+v", state)
	}
}

func TestLSPCodeActionCommandWaitsForDocumentSynchronization(t *testing.T) {
	f := newSemanticFixture(t)
	f.d.sync.running = true
	called := false
	f.h.app.deferCodeActionCommand(f.p, f.server, []renameDocumentUpdate{{id: f.d.id}}, func() { called = true })
	if called {
		t.Fatal("command ran while the text edit was still synchronizing")
	}
	f.h.app.finishDocumentChange(f.p, f.d, f.d.sync.generation, f.d.view.Revision(), nil, nil)
	if !called || f.server.codeActionCommand != nil {
		t.Fatal("command did not run once synchronization completed")
	}
}

func TestLSPInlayCoverageRejectsNewlyUnfoldedInterior(t *testing.T) {
	covered := []editorview.LineSpan{{First: 1, Last: 2}, {First: 5000, Last: 5010}}
	if !inlaySpansCover(covered, []editorview.LineSpan{{First: 2, Last: 2}, {First: 5000, Last: 5002}}) {
		t.Fatal("a viewport split by a fold was not covered by its two requests")
	}
	if inlaySpansCover(covered, []editorview.LineSpan{{First: 1, Last: 8}}) {
		t.Fatal("unfolded lines were treated as already requested")
	}
}
