package workbench

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// TestSearchOptionFlipsAreLogged clicks an option in Find in Files' options and in Search
// Everywhere's filter: each click flips the option and logs its action once.
func TestSearchOptionFlipsAreLogged(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.searchView.delay = 0
	h.app.everywhereView.delay = 0
	h.open(t.TempDir())
	p := h.app.project
	log := &treeRecordingLog{}
	h.app.logSink = log
	t.Cleanup(func() { h.app.logSink = nil })

	h.app.openFindInFiles(p, false)
	h.app.searchView.optionsOpen = true
	h.app.invalidator.Invalidate()
	h.settleChain()
	h.clickShared("native.matchCase")
	h.settleChain()
	if !h.app.searchView.matchCase {
		t.Fatal("clicking Match Case in Find in Files' options did not turn it on")
	}
	if n := countPerformed(log, "workspace.search.matchCase"); n != 1 {
		t.Fatalf("Find in Files' Match Case logged %d times, want once", n)
	}
	h.app.searchView.optionsOpen = false

	h.app.openEverywhere(p)
	h.app.everywhereView.filterOpen = true
	h.app.invalidator.Invalidate()
	h.settleChain()
	h.clickNamed(i18n.Shared(h.app.language(), "desktop.search.includeIgnored"))
	h.settleChain()
	if !h.app.everywhereView.includeIgnored {
		t.Fatal("clicking the ignored files option in Search Everywhere's filter did not turn it on")
	}
	if n := countPerformed(log, "workspace.searchEverywhere.includeIgnored"); n != 1 {
		t.Fatalf("Search Everywhere's ignored files option logged %d times, want once", n)
	}
}
