package workbench

import (
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
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

// openLSPLogFromStatus opens the LSP Logs tab as the user does: the status bar item opens its
// menu, whose View Logs item opens the tab.
func openLSPLogFromStatus(h *harness) {
	h.t.Helper()
	h.click(center(h.button(itemLSP)))
	h.settle()
	h.clickNamed(i18n.Shared(h.app.language(), "native.inline.viewLogs"))
	h.settle()
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

	// The status bar item's menu opens the log as a tab of the group the file is shown in.
	group := f.p.terms.bench.GroupOf(documentMember(f.d.id)).ID
	openLSPLogFromStatus(f.h)
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

	// Opening it again, also from another tab, selects the same tab instead of a second.
	a.selectDocument(f.p, f.d.id)
	f.h.settle()
	openLSPLogFromStatus(f.h)
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
	if !f.h.shows("[WARN]") || !f.h.shows("after clearing") {
		t.Fatal("a line logged after clearing is not shown")
	}

	// Closing the tab shows the file again; the server keeps its lines for the next opening.
	a.closeTab(shownTab{lsp: true})
	f.h.settle()
	if n := lspLogTabs(f.p); n != 0 || f.p.selectedDocument(group) != f.d {
		t.Fatalf("after closing: %d log tabs, the file selected %v", n, f.p.selectedDocument(group) == f.d)
	}
	openLSPLogFromStatus(f.h)
	if !f.p.selectedLSPLog(group) || !f.h.shows("after clearing") {
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
	openLSPLogFromStatus(f.h)
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
	openLSPLogFromStatus(f.h)
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
	// The level in brackets stands out from the message: information in the accent color.
	for level, want := range map[string]gfx.Color{
		"ERROR":  a.theme.Danger,
		"WARN":   a.colors.Warning,
		"INFO":   a.colors.Accent,
		"NOTICE": a.colors.Accent,
		"TRACE":  a.colors.Subtle,
	} {
		if got := a.lspLevelColor(level); got != want {
			t.Fatalf("the %q tag is colored %v, not %v", level, got, want)
		}
	}
	// The tab paints the tags and the messages in those colors.
	a.recordServerEvent(f.server, core.BackendEvent{Type: "log", Level: "info", Message: "indexed"})
	a.recordServerEvent(f.server, core.BackendEvent{Type: "log", Level: "error", Message: "crashed"})
	openLSPLogFromStatus(f.h)
	painted := map[string]gfx.Color{}
	for _, label := range f.h.driver.Snapshot().Labels {
		painted[label.Value] = label.Color
	}
	for value, want := range map[string]gfx.Color{
		"[INFO]":  a.colors.Accent,
		"indexed": a.colors.Text,
		"[ERROR]": a.theme.Danger,
		"crashed": a.theme.Danger,
	} {
		if got, ok := painted[value]; !ok || got != want {
			t.Fatalf("%q is painted %v (shown %v), not %v", value, got, ok, want)
		}
	}
}

func TestLSPLogFilterKeepsMatchingLines(t *testing.T) {
	lines := []lspLogLine{
		{level: "INFO", text: "[INFO] indexing done", tag: 6},
		{level: "WARN", text: "[WARN] slow", tag: 6},
		{level: "ERROR", text: "[ERROR] failed", tag: 7},
	}
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
	if len(f.server.logs) != lspLogLines || len(f.server.logs[0].text) > lspLogLineBytes+16 || !strings.HasSuffix(f.server.logs[0].text, lspLogCut) {
		t.Fatalf("kept %d lines of %d bytes", len(f.server.logs), len(f.server.logs[0].text))
	}
	if f.server.logsAdded != lspLogLines+50 {
		t.Fatalf("counted %d lines added", f.server.logsAdded)
	}
}

// An event of several lines adds a row for each; only the first carries the level in
// brackets, and every row keeps the level's color. A huge line is cut on a character's
// boundary and marked.
func TestLSPLogSplitsLinesAndCutsHugeOnes(t *testing.T) {
	f := newSemanticFixture(t)
	a := f.h.app
	a.recordServerEvent(f.server, core.BackendEvent{Type: "log", Level: "error", Message: "panic: boom\r\n\tat main.go:3\n\nend"})
	got := f.server.logs
	if len(got) != 3 || f.server.logsAdded != 3 {
		t.Fatalf("a three-line event kept %+v", got)
	}
	if tag, message := got[0].parts(); tag != "[ERROR]" || message != "panic: boom" {
		t.Fatalf("the first row is %q %q", tag, message)
	}
	if tag, message := got[1].parts(); tag != "" || message != lspLogTab+"at main.go:3" || got[1].level != "ERROR" {
		t.Fatalf("the second row is %q %q of level %q", tag, message, got[1].level)
	}
	if _, message := got[2].parts(); message != "end" {
		t.Fatalf("the last row is %q", message)
	}
	a.recordServerEvent(f.server, core.BackendEvent{Type: "log", Message: strings.Repeat("中", lspLogLineBytes)})
	line := f.server.logs[len(f.server.logs)-1].text
	if len(line) > lspLogLineBytes+len(lspLogCut) || !strings.HasSuffix(line, lspLogCut) || !utf8.ValidString(line) {
		t.Fatalf("a huge line was kept as %d bytes, valid %v", len(line), utf8.ValidString(line))
	}
}

// The status bar item opens a menu over it that lists each server and acts on all of them;
// its dot takes the color of the server's state.
func TestLSPStatusMenuListsTheServersAndStopsThem(t *testing.T) {
	f := newSemanticFixture(t)
	a := f.h.app
	lang := a.language()
	if a.lspStatusColor() != a.colors.Success {
		t.Fatal("the dot of a ready server is not the success color")
	}
	a.recordServerEvent(f.server, core.BackendEvent{Type: "stateChanged", State: "failed"})
	if a.lspStatusColor() != a.theme.Danger {
		t.Fatal("the dot of a failed server is not the danger color")
	}
	a.recordServerEvent(f.server, core.BackendEvent{Type: "stateChanged", State: "stopped"})
	if a.lspStatusColor() != a.colors.Subtle {
		t.Fatal("the dot of a stopped server is not subdued")
	}
	a.recordServerEvent(f.server, core.BackendEvent{Type: "stateChanged", State: "ready"})

	item := f.h.button(itemLSP)
	f.h.click(center(item))
	f.h.settle()
	if !a.editor.lsp.menu || lspLogTabs(f.p) != 0 {
		t.Fatalf("the click opened the menu %v and %d log tabs", a.editor.lsp.menu, lspLogTabs(f.p))
	}
	plugin := f.server.session.PluginID
	server := f.h.pageHit(plugin).Bounds
	if server.Y+server.Height > item.Y {
		t.Fatalf("the menu's server row %v is not over the status bar item %v", server, item)
	}
	for _, key := range []string{"native.languageServices", "native.restartAllServers", "native.stopAllServers", "desktop.lsp.managePlugins"} {
		if !f.h.shows(i18n.Shared(lang, key)) {
			t.Fatalf("the menu does not show %s", key)
		}
	}
	// The server's submenu opens its log.
	f.h.click(center(server))
	f.h.settle()
	f.h.clickNamed(i18n.Shared(lang, "native.inline.viewLogs"))
	f.h.settle()
	if !f.p.selectedLSPLog(f.p.docs.group) || a.editor.lsp.plugin != plugin || a.editor.lsp.menu {
		t.Fatalf("the submenu did not open the server's log: selected %v plugin %q menu %v", f.p.selectedLSPLog(f.p.docs.group), a.editor.lsp.plugin, a.editor.lsp.menu)
	}

	f.h.click(center(f.h.button(itemLSP)))
	f.h.settle()
	f.h.clickNamed(i18n.Shared(lang, "native.stopAllServers"))
	f.h.settle()
	if servers := a.lspServers(); len(servers) != 0 {
		t.Fatalf("Stop All Servers left %d", len(servers))
	}
	f.h.click(center(f.h.button(itemLSP)))
	f.h.settle()
	if !f.h.shows(i18n.Shared(lang, "native.noRegisteredLanguageServers")) || f.h.shows(i18n.Shared(lang, "native.stopAllServers")) {
		t.Fatal("with no server the menu does not say so")
	}
}

// Unwrapped, a long line keeps one row and the rows scroll sideways to its end; wrapped, the
// rows fit the tab and the long line takes several lines.
func TestLSPLogScrollsSidewaysOrWrapsLongLines(t *testing.T) {
	f := newSemanticFixture(t)
	a := f.h.app
	a.recordServerEvent(f.server, core.BackendEvent{Type: "log", Level: "info", Message: "short"})
	a.recordServerEvent(f.server, core.BackendEvent{Type: "log", Level: "info", Message: "long " + strings.Repeat("abcdefghij", 60)})
	openLSPLogFromStatus(f.h)
	list := &a.editor.lsp.list
	last := len(f.server.logs) - 1
	if list.RowWidth < 600*5 || list.RowHeightAt(last) != lspLogRow {
		t.Fatalf("unwrapped rows are %v wide and the long one %v high", list.RowWidth, list.RowHeightAt(last))
	}
	at := f.h.labelBounds("short")
	if at.Width <= 0 {
		t.Fatal("the short line is not painted")
	}
	if err := f.h.driver.Scroll(gfx.ScrollEvent{X: at.X + 4, Y: at.Y + 4, DeltaX: 10000, Precise: true}); err != nil {
		t.Fatal(err)
	}
	f.h.settle()
	if list.ScrollX() <= 0 {
		t.Fatal("the rows do not scroll sideways")
	}

	f.h.clickNamed(i18n.Shared(a.language(), "native.softWraps"))
	f.h.settle()
	if !a.editor.lsp.wrap || list.RowWidth != 0 || list.ScrollX() != 0 {
		t.Fatalf("wrapping left the rows %v wide, scrolled %v", list.RowWidth, list.ScrollX())
	}
	if list.RowHeightAt(last) <= 2*lspLogRow {
		t.Fatalf("the wrapped long line is %v high", list.RowHeightAt(last))
	}
	if list.RowHeightAt(last-1) > lspLogRow+4 {
		t.Fatalf("the wrapped short line is %v high", list.RowHeightAt(last-1))
	}
}
