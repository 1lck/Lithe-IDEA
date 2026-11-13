package workbench

import (
	"strconv"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// lspLogTabs counts the members of the project's groups that are the LSP Logs tab.
func lspLogTabs(p *project) int {
	count := 0
	for _, g := range p.terms.bench.Groups {
		for _, member := range g.Members {
			if member == lspLogMember {
				count++
			}
		}
	}
	return count
}

func TestLSPStatusFollowsStateAndLogOpensAsAnEditorTab(t *testing.T) {
	f := newSemanticFixture(t)
	a := f.h.app
	if got := a.lspStatusText(); got != "LSP 就绪" {
		t.Fatalf("ready server reads %q", got)
	}
	a.recordServerEvent(f.server, core.BackendEvent{Type: "stateChanged", State: "failed"})
	if got := a.lspStatusText(); got != "LSP 出错" {
		t.Fatalf("failed server reads %q", got)
	}
	a.recordServerEvent(f.server, core.BackendEvent{Type: "log", Level: "info", Message: "window/logMessage", Detail: "indexing done"})
	a.recordServerEvent(f.server, core.BackendEvent{Type: "log", Message: "other detail"})
	if len(f.server.logs) != 2 || f.server.logs[0].level != "INFO" || !strings.HasPrefix(f.server.logs[0].text, "[INFO] ") {
		t.Fatalf("logs = %+v", f.server.logs)
	}

	// The status bar item opens the log as a tab of the group the file is shown in.
	group := f.p.terms.bench.GroupOf(documentMember(f.d.id)).ID
	f.h.click(center(f.h.button(itemLSP)))
	f.h.settle()
	if g := f.p.terms.bench.GroupOf(lspLogMember); g == nil || g.ID != group || g.Selected != lspLogMember {
		t.Fatalf("the log tab is not selected in the file's group: %+v", f.p.terms.bench.Groups)
	}
	tabs, current := a.groupTabs(group)
	if len(tabs) != 2 || !tabs[1].lsp || current != lspLogMember || a.tabLabel(tabs[1]) != "LSP 日志" {
		t.Fatalf("group tabs = %+v, selected %q", tabs, current)
	}
	if !f.h.shows("indexing done") || !f.h.shows("other detail") {
		t.Fatal("the log tab does not show the server's lines")
	}
	// The status bar keeps reading the server the tab shows rather than "not started".
	if got := a.lspStatusText(); got != "LSP 出错" {
		t.Fatalf("with the log tab selected the status reads %q", got)
	}

	// Another click, also from another tab, selects the same tab instead of opening a second.
	a.selectDocument(f.p, f.d.id)
	f.h.settle()
	f.h.click(center(f.h.button(itemLSP)))
	f.h.settle()
	if n := lspLogTabs(f.p); n != 1 || !f.p.selectedLSPLog(group) {
		t.Fatalf("after a second click: %d log tabs, selected %v", n, f.p.selectedLSPLog(group))
	}

	// The filter keeps only the lines that contain the typed text.
	a.editor.lsp.filter = "indexing"
	a.invalidator.Invalidate()
	f.h.settle()
	if !f.h.shows("indexing done") || f.h.shows("other detail") {
		t.Fatal("the log filter did not narrow the rows")
	}
	a.editor.lsp.filter = "no such line"
	a.invalidator.Invalidate()
	f.h.settle()
	if !f.h.shows("没有匹配筛选条件的日志。") {
		t.Fatal("an unmatched filter did not say so")
	}
	a.editor.lsp.filter = ""
	a.invalidator.Invalidate()
	f.h.settle()

	// Clear View empties what the tab shows for this server; later lines show again.
	f.h.clickNamed("清空视图")
	f.h.settle()
	if len(f.server.logs) != 0 || !f.h.shows("此服务器暂无日志。") || f.h.shows("indexing done") {
		t.Fatalf("clearing left %d lines", len(f.server.logs))
	}
	a.recordServerEvent(f.server, core.BackendEvent{Type: "log", Level: "warn", Message: "after clearing"})
	f.h.settle()
	if !f.h.shows("[WARN] after clearing") {
		t.Fatal("a line logged after clearing is not shown")
	}

	// Closing the tab shows the file again; the server keeps its lines for the next opening.
	a.closeTab(shownTab{lsp: true})
	f.h.settle()
	if n := lspLogTabs(f.p); n != 0 || f.p.selectedDocument(group) != f.d {
		t.Fatalf("after closing: %d log tabs, the file selected %v", n, f.p.selectedDocument(group) == f.d)
	}
	f.h.click(center(f.h.button(itemLSP)))
	f.h.settle()
	if !f.p.selectedLSPLog(group) || !f.h.shows("[WARN] after clearing") {
		t.Fatal("the reopened tab does not show the server's lines")
	}

	// The tab stops the server it shows and then says no server runs.
	f.h.clickNamed("停止服务器")
	f.h.settle()
	if servers := a.lspServers(); len(servers) != 0 {
		t.Fatalf("stopping the server left %d", len(servers))
	}
	if !f.h.shows("没有正在运行的语言服务器。") {
		t.Fatal("the log tab does not say that no server runs")
	}
}

// The log tab splits off beside the file like any tab and shows its body there; closing it
// from the File menu takes the group it left alone away with it.
func TestLSPLogTabSplitsOffAndCloses(t *testing.T) {
	f := newSemanticFixture(t)
	a := f.h.app
	a.recordServerEvent(f.server, core.BackendEvent{Type: "log", Message: "split line"})
	f.h.click(center(f.h.button(itemLSP)))
	f.h.settle()
	first := f.p.terms.bench.GroupOf(lspLogMember).ID
	a.dropTab(lspLogMember, dropTarget{kind: dropSplit, group: first, edge: edgeRight})
	f.h.settle()
	g := f.p.terms.bench.GroupOf(lspLogMember)
	if g == nil || g.ID == first || editorGroups(f.p) != 2 || !f.p.selectedLSPLog(g.ID) || f.p.docs.group != g.ID {
		t.Fatalf("after the split the log tab is in %+v of %d groups", g, editorGroups(f.p))
	}
	if !f.h.shows("split line") || f.p.selectedDocument(first) != f.d {
		t.Fatal("the split does not show the log beside the file")
	}
	// The File menu's Close Tab closes the tab the group shows, here the log.
	if !runCommand(a, "tab.close") {
		t.Fatal("no Close Tab command while the log tab is selected")
	}
	f.h.settle()
	if lspLogTabs(f.p) != 0 || editorGroups(f.p) != 1 {
		t.Fatalf("after closing, %d log tabs in %d groups", lspLogTabs(f.p), editorGroups(f.p))
	}
}

// runCommand runs the catalog's command id, reporting whether it was listed and enabled.
func runCommand(a *App, id string) bool {
	for _, cmd := range a.commands() {
		if cmd.id == id && cmd.enabled {
			cmd.run()
			return true
		}
	}
	return false
}

func TestLSPLogFollowsTheNewestLineUntilScrolledAway(t *testing.T) {
	f := newSemanticFixture(t)
	a := f.h.app
	for i := 0; i < 200; i++ {
		a.recordServerEvent(f.server, core.BackendEvent{Type: "log", Message: "line " + strconv.Itoa(i)})
	}
	f.h.click(center(f.h.button(itemLSP)))
	f.h.settle()
	list := &a.editor.lsp.list
	if _, last := list.Visible(); last != 199 {
		t.Fatalf("the opened tab shows up to row %d, not the newest", last)
	}
	a.recordServerEvent(f.server, core.BackendEvent{Type: "log", Message: "line 200"})
	f.h.settle()
	if _, last := list.Visible(); last != 200 {
		t.Fatalf("a new line left the view at row %d", last)
	}

	// Scrolled to the top, a new line leaves the view where the user put it.
	list.ScrollTo(0, ui.ListStart)
	a.invalidator.Invalidate()
	f.h.settle()
	if first, _ := list.Visible(); first != 0 {
		t.Fatalf("scrolling to the top shows row %d first", first)
	}
	a.recordServerEvent(f.server, core.BackendEvent{Type: "log", Message: "line 201"})
	f.h.settle()
	if first, _ := list.Visible(); first != 0 {
		t.Fatalf("a new line moved the scrolled view to row %d", first)
	}
}

func TestLSPLogLineColorFollowsTheEventLevel(t *testing.T) {
	f := newSemanticFixture(t)
	a := f.h.app
	for level, want := range map[string]gfx.Color{
		"ERROR": a.theme.Danger,
		"WARN":  a.colors.Warning,
		"INFO":  a.colors.Text,
		"DEBUG": a.colors.Subtle,
		"":      a.colors.Text,
	} {
		if got := a.lspLogColor(level); got != want {
			t.Fatalf("%q lines are colored %v, not %v", level, got, want)
		}
	}
	a.recordServerEvent(f.server, core.BackendEvent{Type: "log", LegacyLevel: "warning", Message: "slow"})
	if line := f.server.logs[len(f.server.logs)-1]; line.level != "WARNING" || a.lspLogColor(line.level) != a.colors.Warning {
		t.Fatalf("a legacy warning is kept as %+v", line)
	}
}

func TestLSPLogFilterKeepsMatchingLines(t *testing.T) {
	lines := []lspLogLine{{"INFO", "[INFO] indexing done"}, {"WARN", "[WARN] slow"}, {"ERROR", "[ERROR] failed"}}
	if got := filterLogLines(lines, " warn "); len(got) != 1 || !strings.Contains(got[0].text, "slow") {
		t.Fatalf("warn filter = %+v", got)
	}
	if got := filterLogLines(lines, ""); len(got) != 3 {
		t.Fatalf("empty filter = %+v", got)
	}
	if got := filterLogLines(lines, "missing"); len(got) != 0 {
		t.Fatalf("missing filter = %+v", got)
	}
}

func TestLSPLogIsBounded(t *testing.T) {
	f := newSemanticFixture(t)
	for i := 0; i < lspLogLines+50; i++ {
		f.h.app.recordServerEvent(f.server, core.BackendEvent{Type: "log", Message: "m", Detail: strings.Repeat("x", 2*lspLogLineBytes)})
	}
	if len(f.server.logs) != lspLogLines || len(f.server.logs[0].text) > lspLogLineBytes+16 {
		t.Fatalf("kept %d lines of %d bytes", len(f.server.logs), len(f.server.logs[0].text))
	}
	if f.server.logsAdded != lspLogLines+50 {
		t.Fatalf("counted %d lines added", f.server.logsAdded)
	}
}
