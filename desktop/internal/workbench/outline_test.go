package workbench

import (
	"encoding/json"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

func symbolsResult(t *testing.T, symbols ...core.DocumentSymbol) json.RawMessage {
	t.Helper()
	data, err := json.Marshal(struct {
		Symbols []core.DocumentSymbol `json:"symbols"`
	}{symbols})
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func symbolAt(name string, kind, startLine, endLine int, children ...core.DocumentSymbol) core.DocumentSymbol {
	rng := core.PluginDocumentRange{
		Start: core.PluginDocumentPosition{Line: startLine},
		End:   core.PluginDocumentPosition{Line: endLine, UTF16Column: 1},
	}
	return core.DocumentSymbol{Name: name, Kind: kind, Range: rng, SelectionRange: rng, Children: children}
}

func TestOutlineAsksOnceAndFollowsCaret(t *testing.T) {
	f := newSemanticFixture(t)
	f.server.features = map[string]bool{featureDocumentSymbols: true}
	f.h.app.reduceChrome(core.SetChromeOpen(itemStructure, true))
	f.h.settle()
	f.waitForRequests(t, 1)
	if got := f.kernel.request(0).Operation; got != pluginSemanticDocumentSymbols {
		t.Fatalf("operation = %q", got)
	}
	f.d.view.SetSelection(0, 0)
	f.deliver(t, "op-1", pluginMethodDocumentSymbols, symbolsResult(t,
		symbolAt("Foo", 5, 0, 9, symbolAt("bar", 6, 2, 4), symbolAt("baz", 6, 5, 7)),
		symbolAt("Other", 5, 10, 12),
	))
	if !f.h.shows("Foo") || !f.h.shows("bar") || !f.h.shows("Other") {
		t.Fatalf("outline rows missing: %v", f.h.driver.Snapshot().Labels)
	}
	// Moving the caret into bar selects bar's row.
	offset := f.d.view.TextSnapshot().LineStart(0)
	f.d.view.SetSelection(offset, offset)
	pump := func() {
		t.Helper()
		f.h.app.invalidator.Invalidate()
		if err := f.h.driver.Pump(); err != nil {
			t.Fatal(err)
		}
	}
	pump()
	s := &f.h.app.editor.outline
	if s.selected < 0 || s.rows[s.selected].symbol.Name != "Foo" {
		t.Fatalf("selected row = %d", s.selected)
	}
	// The same text asks again for nothing.
	pump()
	if got := f.kernel.requestCount(); got != 1 {
		t.Fatalf("requests = %d, want 1", got)
	}
}

func TestOutlineRowsSortAndFold(t *testing.T) {
	s := &outlineState{
		symbols: []core.DocumentSymbol{
			symbolAt("b", 5, 0, 5, symbolAt("y", 6, 1, 2), symbolAt("x", 6, 3, 4)),
			symbolAt("a", 5, 6, 8),
		},
		collapsed: map[string]bool{},
	}
	s.buildRows()
	names := func() (out []string) {
		for _, r := range s.rows {
			out = append(out, r.symbol.Name)
		}
		return
	}
	if got := names(); len(got) != 4 || got[0] != "b" || got[1] != "y" || got[3] != "a" {
		t.Fatalf("position order = %v", got)
	}
	s.sorted = true
	s.buildRows()
	if got := names(); got[0] != "a" || got[1] != "b" || got[2] != "x" {
		t.Fatalf("sorted = %v", got)
	}
	s.collapsed["0"] = true // the key is the symbol's index, so it follows b through the sort
	s.buildRows()
	if got := names(); len(got) != 2 || got[0] != "a" || got[1] != "b" {
		t.Fatalf("folded = %v", got)
	}
	if row := s.caretRow(7, 0); row != 0 {
		t.Fatalf("caret row = %d", row)
	}
}

func TestOutlineFilterKeepsAncestorsAndCounts(t *testing.T) {
	s := &outlineState{
		symbols: []core.DocumentSymbol{
			symbolAt("Service", 5, 0, 9, symbolAt("loadUser", 6, 1, 2), symbolAt("save", 6, 3, 4)),
			symbolAt("UserRepo", 11, 10, 12),
			symbolAt("helper", 12, 13, 14),
		},
		collapsed: map[string]bool{"0": true},
		selected:  -1,
	}
	if s.total = countSymbols(s.symbols); s.total != 5 {
		t.Fatalf("total = %d", s.total)
	}
	s.refresh()
	if len(s.rows) != 3 {
		t.Fatalf("folded rows = %d", len(s.rows))
	}
	names := func() (out []string) {
		for _, r := range s.rows {
			out = append(out, r.symbol.Name)
		}
		return
	}
	// A filter shows the match under Service although the user folded Service.
	s.filter = "USER"
	if !s.refresh() {
		t.Fatal("a new filter did not rebuild the rows")
	}
	if got := names(); len(got) != 3 || got[0] != "Service" || got[1] != "loadUser" || got[2] != "UserRepo" {
		t.Fatalf("filtered = %v", got)
	}
	// Service stays as loadUser's parent but is not a match of its own.
	if s.rows[0].match || !s.rows[1].match || !s.rows[2].match || s.matches != 2 {
		t.Fatalf("matches = %d, rows = %+v", s.matches, s.rows)
	}
	if !s.expanded(s.rows[0]) {
		t.Fatal("a filtered parent is shown folded")
	}
	if s.refresh() {
		t.Fatal("the same filter rebuilt the rows again")
	}
	s.filter = "nothing"
	s.refresh()
	if len(s.rows) != 0 || s.matches != 0 {
		t.Fatalf("rows = %v", names())
	}
	// Clearing the filter brings the fold back.
	s.filter = ""
	s.refresh()
	if got := names(); len(got) != 3 || s.expanded(s.rows[0]) {
		t.Fatalf("unfiltered = %v", got)
	}
}

func TestOutlineSelectionFollowsItsSymbol(t *testing.T) {
	s := &outlineState{
		symbols: []core.DocumentSymbol{
			symbolAt("b", 5, 0, 5, symbolAt("loadUser", 6, 1, 2), symbolAt("save", 6, 3, 4)),
			symbolAt("a", 5, 6, 8),
		},
		collapsed: map[string]bool{},
		selected:  -1,
	}
	s.refresh()
	s.selected = 3 // a
	s.sorted, s.rowsDirty = true, true
	s.refresh()
	if s.selected != 0 || s.rows[0].symbol.Name != "a" {
		t.Fatalf("the selection did not follow a through the sort: %d", s.selected)
	}
	s.selected = 3 // save, after b and loadUser
	s.filter = "user"
	s.refresh()
	if s.selected != -1 {
		t.Fatalf("a filtered-out symbol stays selected: %d", s.selected)
	}
}

func TestOutlineCollapseAndExpandAll(t *testing.T) {
	s := &outlineState{
		symbols: []core.DocumentSymbol{
			symbolAt("A", 5, 0, 9, symbolAt("inner", 5, 1, 8, symbolAt("leaf", 6, 2, 3))),
			symbolAt("B", 5, 10, 12),
		},
		collapsed: map[string]bool{},
		selected:  -1,
	}
	s.setAllCollapsed(true)
	if !s.collapsed["0"] || !s.collapsed["0.0"] || s.collapsed["1"] {
		t.Fatalf("collapsed = %v", s.collapsed)
	}
	s.refresh()
	if len(s.rows) != 2 {
		t.Fatalf("rows after collapse all = %d", len(s.rows))
	}
	s.setAllCollapsed(false)
	s.refresh()
	if len(s.collapsed) != 0 || len(s.rows) != 4 {
		t.Fatalf("rows after expand all = %d", len(s.rows))
	}
}

func TestOutlineWithoutServerShowsWhy(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	_, d := openSyncDocument(t, h, h.app.project.root, "notes.txt")
	h.app.focusDocument(d.id)
	h.app.reduceChrome(core.SetChromeOpen(itemStructure, true))
	h.settle()
	s := &h.app.editor.outline
	if s.availability != outlineNoServer || s.pending != nil || s.requested != -1 {
		t.Fatalf("availability = %d, pending = %v, requested = %d", s.availability, s.pending, s.requested)
	}
	language := h.app.language()
	if !h.showsWrapped(i18n.Shared(language, "desktop.outline.unavailable")) {
		t.Fatalf("the no-server notice is missing: %v", h.driver.Snapshot().Labels)
	}
	if h.showsWrapped(i18n.Shared(language, "desktop.outline.loading")) {
		t.Fatal("a file without a server still reads as loading")
	}
}

func TestOutlineWaitsForStartingServerThenAsks(t *testing.T) {
	f := newSemanticFixture(t)
	f.server.features = map[string]bool{featureDocumentSymbols: true}
	f.h.app.pluginServerMu.Lock()
	f.h.app.pluginServers = map[string]*pluginServer{}
	f.h.app.pluginServerStarting = map[string]bool{"java": true}
	f.h.app.pluginServerMu.Unlock()
	f.h.app.reduceChrome(core.SetChromeOpen(itemStructure, true))
	f.h.settle()
	language := f.h.app.language()
	if !f.h.showsWrapped(i18n.Shared(language, "desktop.outline.starting")) || f.kernel.requestCount() != 0 {
		t.Fatalf("starting: requests = %d, labels = %v", f.kernel.requestCount(), f.h.driver.Snapshot().Labels)
	}
	// The end of the start wakes the window, which then asks.
	f.h.app.pluginServerMu.Lock()
	f.h.app.pluginServers = map[string]*pluginServer{"test": f.server}
	f.h.app.pluginServerStarting = map[string]bool{}
	f.h.app.pluginServerMu.Unlock()
	f.h.app.invalidator.Invalidate()
	f.h.settle()
	f.waitForRequests(t, 1)
}

func TestOutlineUnsupportedFailedAndRetry(t *testing.T) {
	f := newSemanticFixture(t)
	f.server.features = map[string]bool{}
	f.h.app.reduceChrome(core.SetChromeOpen(itemStructure, true))
	f.h.settle()
	language := f.h.app.language()
	if !f.h.showsWrapped(i18n.Shared(language, "desktop.outline.unsupported")) || f.kernel.requestCount() != 0 {
		t.Fatalf("unsupported: requests = %d", f.kernel.requestCount())
	}
	f.server.features = map[string]bool{featureDocumentSymbols: true}
	f.h.app.invalidator.Invalidate()
	f.h.settle()
	f.waitForRequests(t, 1)
	f.h.app.applyPluginSemanticEvent(f.server, core.BackendEvent{
		Type:        pluginSemanticCompleted,
		OperationID: "op-1",
		Method:      pluginMethodDocumentSymbols,
		Error:       json.RawMessage(`{"message":"boom"}`),
	})
	f.h.app.invalidator.Invalidate()
	f.h.settle()
	s := &f.h.app.editor.outline
	if !s.failed || !f.h.showsWrapped(i18n.Shared(language, "desktop.outline.failed")) {
		t.Fatalf("failed = %v, labels = %v", s.failed, f.h.driver.Snapshot().Labels)
	}
	// The same text is not asked again by itself, only after Retry.
	if got := f.kernel.requestCount(); got != 1 {
		t.Fatalf("requests after failure = %d", got)
	}
	s.retry()
	f.h.app.invalidator.Invalidate()
	f.h.settle()
	f.waitForRequests(t, 2)
}
