package workbench

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

func TestEverywhereTypesAndSymbolsUseSeparateTabs(t *testing.T) {
	root := t.TempDir()
	p := &project{root: root}
	var symbols []core.WorkspaceSymbol
	var order []int
	for i, kind := range []int{5, 10, 11, 23, 6, 12, 13} {
		uri, err := core.NewClient().PluginDocumentURI(context.Background(), filepath.Join(root, "source"+string(rune('a'+i))+".go"), "auto")
		if err != nil {
			t.Fatal(err)
		}
		symbols = append(symbols, core.WorkspaceSymbol{Name: "Search", Kind: kind, URI: uri})
		order = append(order, i)
	}
	ranked := everywhereRankedMatches(p, symbols, order)
	for scope, want := range map[int]int{1: 4, 3: 3} {
		p.everywhere = everywhereSearch{query: "Search", options: (&everywhereView{}).options(scope)}
		p.everywhereSymbols = everywhereSymbolState{generation: 1, query: "Search", ranked: ranked}
		(&App{}).everywhereSymbolsMerge(p)
		if len(p.everywhere.matches) != want {
			t.Fatalf("scope %d returned %d matches, want %d", scope, len(p.everywhere.matches), want)
		}
		for _, match := range p.everywhere.matches {
			if match.Kind != p.everywhere.options.kinds {
				t.Fatalf("scope %d includes another category: %+v", scope, match)
			}
		}
	}
}

// The Types and Symbols tabs list only what language servers report inside the
// project folder, so an ⓘ inside each tab, right after its name, says what it lists
// and how far it reaches: the ⓘ explains the tab, so it shares the tab's block (its
// fill when selected, its click). The filter's file options do not reach those
// results, so neither tab has a filter; the tabs that search files keep theirs.
func TestEverywhereLanguageTabsExplainTheirScopeAndHaveNoFilter(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.everywhereView.delay = 0
	h.open(t.TempDir())
	p := h.app.project
	h.app.openEverywhere(p)
	h.settleChain()
	language := h.app.language()
	control := func(label string) (gfx.Hit, bool) {
		for _, hit := range h.driver.Snapshot().Hits {
			if hit.Label == label && !hit.IsLabel && !hit.Backdrop && !hit.ID.IsZero() {
				return hit, true
			}
		}
		return gfx.Hit{}, false
	}
	info := i18n.Shared(language, "native.moreInformation")
	for _, tc := range []struct {
		scope     int
		tab, help string
	}{
		{scope: 1, tab: "desktop.everywhere.types", help: "desktop.everywhere.typesHelp"},
		{scope: 3, tab: "desktop.everywhere.symbols", help: "desktop.everywhere.symbolsHelp"},
	} {
		help := i18n.Shared(language, tc.help)
		tab, ok := control(i18n.Shared(language, tc.tab))
		if !ok {
			t.Fatalf("the %s tab is not shown", tc.tab)
		}
		var button gfx.Hit
		for _, hit := range h.driver.Snapshot().Hits {
			if hit.Label == info && hit.Hint == help && !hit.IsLabel && !hit.ID.IsZero() {
				button = hit
			}
		}
		if button.ID.IsZero() {
			t.Fatalf("no ⓘ tells assistive technology %q", help)
		}
		// Inside the tab and at its end: the tab's name, then the ⓘ, then only the
		// tab's own end padding.
		if button.Bounds.X <= tab.Bounds.X || button.Bounds.Right() > tab.Bounds.Right() || button.Bounds.Y < tab.Bounds.Y || button.Bounds.Bottom() > tab.Bounds.Bottom() {
			t.Fatalf("the ⓘ at %+v is not inside the %s tab at %+v", button.Bounds, tc.tab, tab.Bounds)
		}
		if end := tab.Bounds.Right() - button.Bounds.Right(); end > everywhereHelpTabEndPad {
			t.Fatalf("the ⓘ ends %v before the %s tab does, want at most %v", end, tc.tab, everywhereHelpTabEndPad)
		}
		at := center(button.Bounds)
		if err := h.driver.Move(at.X, at.Y); err != nil {
			t.Fatal(err)
		}
		h.settle()
		// The tip wraps, one label a line; the lines together are the whole text.
		unspaced := func(text string) string { return strings.Join(strings.Fields(text), "") }
		var shown []string
		for _, tip := range h.tooltips() {
			shown = append(shown, tip.Value)
		}
		if got := unspaced(strings.Join(shown, "")); got != unspaced(help) {
			t.Fatalf("resting on the ⓘ in the %s tab shows %q, want only %q", tc.tab, shown, help)
		}
		// The ⓘ is part of the tab, so a click on it chooses the tab.
		h.click(at)
		if got := h.app.everywhereView.scope; got != tc.scope {
			t.Fatalf("a click on the ⓘ in the %s tab leaves tab %d chosen, want %d", tc.tab, got, tc.scope)
		}
	}

	for scope, want := range map[int]bool{0: true, 1: false, 2: true, 3: false, 5: true} {
		h.app.everywhereView.scope = scope
		h.app.invalidator.Invalidate()
		h.settleChain()
		label := i18n.Shared(language, "native.filterResults")
		if scope == 5 {
			label = i18n.Shared(language, "native.searchOptions")
		}
		if _, shown := control(label); shown != want {
			t.Fatalf("tab %d shows the filter: %v, want %v", scope, shown, want)
		}
	}
}

func TestEverywhereContentUsesTheSameInterfaceFontAsFileNames(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.everywhereView.delay = 0
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "LockOSThread.go"), []byte("runtime.LockOSThread()\n"), 0600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.openEverywhere(h.app.project)
	h.app.everywhereView.query.SetText("LockOSThread")
	h.settleChain()
	h.await("file and content results", func() bool { return !h.app.project.everywhere.loading && len(h.app.project.everywhere.matches) == 2 })
	h.settleChain()
	seen := false
	for _, label := range h.driver.Snapshot().Labels {
		if label.Value == "runtime." || label.Value == "()" {
			seen = true
			if label.Mono || label.FontSize != 13 {
				t.Fatalf("content uses a different font: %+v", label)
			}
		}
	}
	if !seen {
		t.Fatal("content preview was not drawn")
	}
	if got := i18n.Shared(h.app.language(), "desktop.everywhere.types"); got != "类型" || !h.shows(got) {
		t.Fatalf("type tab = %q", got)
	}
}

func TestProjectSearchUsesCompactGroupedRows(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.searchView.delay = 0
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "main.go"), []byte("runtime.LockOSThread()\nruntime.LockOSThread()\n"), 0600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.openFindInFiles(h.app.project, false)
	h.app.searchView.query.SetText("LockOSThread")
	h.settleChain()
	h.await("grouped content results", func() bool { return !h.app.project.search.loading && len(h.app.project.search.presentation.Rows) == 3 })
	h.settleChain()
	for _, name := range []string{"main.go", "main.go:1:9", "main.go:2:9"} {
		hit := h.pageHit(name)
		if hit.Bounds.Height > 28 {
			t.Fatalf("%s row has excessive whitespace: %+v", name, hit.Bounds)
		}
	}
	row := h.pageHit("main.go:1:9")
	positions := 0
	for _, label := range h.driver.Snapshot().Labels {
		if (label.Value == "1:9" || label.Value == "2:9") && label.Bounds.Y >= row.Bounds.Y {
			positions++
			// The position starts at the file icon's column, after the heading chevron.
			if label.Bounds.X != row.Bounds.X+31 {
				t.Fatalf("position is indented beyond the file icon: %+v", label.Bounds)
			}
		}
	}
	if positions != 2 {
		t.Fatalf("drawn positions = %d, want 2", positions)
	}
}

func TestProjectSearchReadsUnsavedTextAndAllSearchesContents(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.searchView.delay = 0
	h.app.everywhereView.delay = 0
	h.app.settings.DisableAutoSave = true
	root := t.TempDir()
	path := filepath.Join(root, "notes.txt")
	if err := os.WriteFile(path, []byte("old disk text\n"), 0600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	h.app.openFile(p, path)
	h.settle()
	doc := p.docs.byPath(path)
	if err := doc.view.ApplyEdits([]editorview.TextEdit{{Range: editorview.Range{Start: 0, End: 0}, Text: "unsaved needle\n"}}); err != nil {
		t.Fatal(err)
	}
	h.app.updateProjectSearch(p, searchQuery{text: "needle"})
	awaitDocumentState(t, h, func() bool { return !p.search.loading && len(p.search.matches) == 1 })
	if *p.search.matches[0].Line != 1 {
		t.Fatal(p.search.matches)
	}
	h.app.openEverywhere(p)
	h.app.everywhereView.query.SetText("needle")
	h.settle()
	awaitDocumentState(t, h, func() bool { return !p.everywhere.loading && len(p.everywhere.matches) == 1 })
	if p.everywhere.matches[0].Kind != "content" {
		t.Fatal(p.everywhere.matches)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "old disk text\n" {
		t.Fatalf("search wrote disk: %q %v", data, err)
	}
}

func TestProjectReplacePreservesOriginalEncodingAndRejectsChangedPreview(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	client := core.NewClient()
	guardedWrite := func(_ context.Context, path string, data, expected []byte) error {
		return documentio.WriteGuarded(path, data, expected)
	}
	for _, encoding := range []string{"gbk", "utf-16le-bom", "utf-16be-bom", "utf-8-bom", "windows-1252"} {
		t.Run(encoding, func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, "source.txt")
			text := "needle\r\nnext\r\n"
			if encoding == "gbk" {
				text = "中文 " + text
			}
			if encoding == "windows-1252" {
				text = "café " + text
			}
			before, err := client.EncodeFileText(ctx, text, encoding, nil)
			if err != nil {
				t.Fatal(err)
			}
			if err = os.WriteFile(path, before.Bytes, 0600); err != nil {
				t.Fatal(err)
			}
			preview, err := client.PreviewWorkspaceReplace(ctx, core.WorkspaceReplaceRequest{Root: root, Query: "needle", Replacement: "found", MaxFileBytes: 1 << 20})
			if err != nil || len(preview) != 1 {
				t.Fatalf("preview %+v %v", preview, err)
			}
			outcome := replacePreviewInFile(ctx, client, localDocumentBytes, guardedWrite, path, searchQuery{text: "needle"}, "found", 1<<20, preview[0].SourceIdentity)
			if outcome.err != nil || outcome.skipped {
				t.Fatalf("replace %+v", outcome)
			}
			want, err := client.EncodeFileText(ctx, string(bytes.ReplaceAll([]byte(text), []byte("needle"), []byte("found"))), encoding, nil)
			if err != nil {
				t.Fatal(err)
			}
			got, err := os.ReadFile(path)
			if err != nil || !bytes.Equal(got, want.Bytes) {
				t.Fatalf("encoding/BOM/CRLF changed: %x %v", got, err)
			}
			if err = os.WriteFile(path, []byte("external needle"), 0600); err != nil {
				t.Fatal(err)
			}
			outcome = replacePreviewInFile(ctx, client, localDocumentBytes, guardedWrite, path, searchQuery{text: "needle"}, "found", 1<<20, preview[0].SourceIdentity)
			if !errors.Is(outcome.err, documentio.ErrConflict) {
				t.Fatalf("stale preview wrote: %+v", outcome)
			}
		})
	}
}

func TestEverywhereStartsRelevantLanguageServerWithoutOpeningFiles(t *testing.T) {
	kernel := &failingLSPPlanKernel{testKernel: &testKernel{Client: core.NewClient()}, msg: "fixture startup reached"}
	h := newHarness(t, kernel)
	plugins := t.TempDir()
	raw, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-documents.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Manifest json.RawMessage `json:"manifest"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(plugins, "dev.example.settings", "1.0.0")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "plugin.json"), fixture.Manifest, 0600); err != nil {
		t.Fatal(err)
	}
	service, err := pluginservice.Open(kernel, store.At(t.TempDir()), plugins)
	if err != nil {
		t.Fatal(err)
	}
	if err := service.Manager.SetEnabled("dev.example.settings", true); err != nil {
		t.Fatal(err)
	}
	h.app.plugins = service
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "source.fixture"), []byte("source\n"), 0600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	h.app.openEverywhere(p)
	h.app.everywhereView.scope = 1
	h.app.everywhereView.query.SetText("Search")
	h.settleChain()
	h.await("provider startup without open documents", func() bool { return h.app.pluginServerFailed["fixture"] != nil })
	if len(p.docs.list) != 0 {
		t.Fatal("symbol discovery opened a source document")
	}
	if got := h.app.pluginServerFailed["fixture"].message; !strings.Contains(got, "fixture startup reached") {
		t.Fatal(got)
	}
}

func TestEverywhereQueriesLateReadyServerAndSeparatesItsTypes(t *testing.T) {
	kernel := &semanticTestKernel{testKernel: &testKernel{Client: core.NewClient()}}
	h := newHarness(t, kernel)
	h.open(t.TempDir())
	service, err := pluginservice.Open(kernel, h.store, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h.app.plugins = service
	p := h.app.project
	server := &pluginServer{session: &pluginservice.LanguageSession{PluginID: "dev.lithe.test.symbols", Session: pluginbackend.Session{ID: "symbols"}}, project: p, buildReady: true}
	h.app.pluginServers = map[string]*pluginServer{"dev.lithe.test.symbols": server}
	h.app.openEverywhere(p)
	h.app.everywhereView.scope = 1
	h.app.everywhereView.query.SetText("Search")
	h.settleChain()
	if kernel.requestCount() != 0 {
		t.Fatal("queried a server before it advertised workspace symbols")
	}
	h.app.applyServerFeatures(server, core.BackendEvent{Capabilities: []string{featureWorkspaceSymbols}})
	h.settleChain()
	h.await("late ready workspace symbols request", func() bool { return kernel.requestCount() == 1 })
	h.app.applyServerFeatures(server, core.BackendEvent{Capabilities: []string{featureWorkspaceSymbols}})
	h.settleChain()
	if kernel.requestCount() != 1 {
		t.Fatal("duplicated current query on repeated feature event")
	}
	uri, err := core.NewClient().PluginDocumentURI(context.Background(), filepath.Join(p.root, "source.fixture"), "auto")
	if err != nil {
		t.Fatal(err)
	}
	result, err := json.Marshal(map[string]any{"symbols": []core.WorkspaceSymbol{{Name: "SearchType", Kind: 23, URI: uri}, {Name: "SearchFunction", Kind: 12, URI: uri}}})
	if err != nil {
		t.Fatal(err)
	}
	h.app.applyPluginSemanticEvent(server, core.BackendEvent{Type: pluginSemanticCompleted, OperationID: "op-1", Method: pluginMethodWorkspaceSymbols, Result: result})
	h.settleChain()
	h.await("ranked type result", func() bool { return len(p.everywhere.matches) == 1 })
	if p.everywhere.matches[0].Kind != "type" || len(p.docs.list) != 0 {
		t.Fatal(p.everywhere.matches)
	}
	h.app.closeEverywhere(p)
	delete(h.app.pluginServers, "dev.lithe.test.symbols")
}

func TestProjectSearchCompleteCountsRefreshAfterFileChanges(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.searchView.delay = 0
	root := t.TempDir()
	path := filepath.Join(root, "source.txt")
	if err := os.WriteFile(path, []byte(strings.Repeat("needle needle\n", 75)), 0600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	h.app.openFindInFiles(p, false)
	h.app.searchView.query.SetText("needle")
	h.settleChain()
	h.await("complete count beyond first page", func() bool { return p.search.counts != nil && p.search.counts.Occurrences == 150 })
	if p.search.counts.Files != 1 {
		t.Fatal(p.search.counts)
	}
	if err := os.WriteFile(path, []byte("needle\n"), 0600); err != nil {
		t.Fatal(err)
	}
	h.await("updated complete count", func() bool { return p.search.counts != nil && p.search.counts.Occurrences == 1 })
}
