package workbench

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/vivaui/viva/gfx"
)

func TestLSPCodeActionsUseTheActiveServerDiagnosticsAndApplyEdit(t *testing.T) {
	f := newSemanticFixture(t)
	f.server.features = map[string]bool{featureCodeActions: true}
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
	f.h.await("code action edit", func() bool { return f.d.view.TextSnapshot().String() == "two\n" })
	if got := f.d.view.TextSnapshot().String(); got != "two\n" {
		t.Fatalf("code action produced %q", got)
	}
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

func TestLSPWorkspaceEditWriteRestoresFilesOnCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	first := filepath.Join(t.TempDir(), "first.txt")
	second := filepath.Join(t.TempDir(), "second.txt")
	contents := map[string]string{first: "old first", second: "old second"}
	writes := []renameClosedWrite{
		{path: first, before: []byte("old first"), after: []byte("new first")},
		{path: second, before: []byte("old second"), after: []byte("new second")},
	}
	if err := writeWorkspaceEdit(ctx, writes, func(path string, next, expected []byte) error {
		if contents[path] != string(expected) {
			t.Fatalf("write to %s expected %q, got %q", path, expected, contents[path])
		}
		contents[path] = string(next)
		cancel()
		return nil
	}); err == nil {
		t.Fatal("workspace edit completed despite cancellation")
	}
	if contents[first] != "old first" || contents[second] != "old second" {
		t.Fatalf("cancellation left edits behind: %v", contents)
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
