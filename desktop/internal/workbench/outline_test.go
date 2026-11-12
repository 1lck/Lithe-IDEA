package workbench

import (
	"encoding/json"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
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
