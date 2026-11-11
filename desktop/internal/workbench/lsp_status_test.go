package workbench

import (
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestLSPStatusFollowsStateAndLogWindowShowsServerLines(t *testing.T) {
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
	if len(f.server.logs) != 2 || !strings.Contains(f.server.logs[0], "[INFO]") {
		t.Fatalf("logs = %q", f.server.logs)
	}
	f.h.click(center(f.h.button(itemLSP)))
	f.h.settle()
	if !a.editor.lsp.open || !f.h.shows("indexing done") {
		t.Fatalf("log window: open=%v ", a.editor.lsp.open)
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

	// The window stops the server it shows.
	f.h.clickNamed("停止服务器")
	f.h.settle()
	if servers := a.lspServers(); len(servers) != 0 {
		t.Fatalf("stopping the server left %d", len(servers))
	}
}

func TestLSPLogFilterKeepsMatchingLines(t *testing.T) {
	lines := []string{"[INFO] indexing done", "[WARN] slow", "[ERROR] failed"}
	if got := filterLogLines(lines, " warn "); len(got) != 1 || !strings.Contains(got[0], "slow") {
		t.Fatalf("warn filter = %q", got)
	}
	if got := filterLogLines(lines, ""); len(got) != 3 {
		t.Fatalf("empty filter = %q", got)
	}
	if got := filterLogLines(lines, "missing"); len(got) != 0 {
		t.Fatalf("missing filter = %q", got)
	}
}

func TestLSPLogIsBounded(t *testing.T) {
	f := newSemanticFixture(t)
	for i := 0; i < lspLogLines+50; i++ {
		f.h.app.recordServerEvent(f.server, core.BackendEvent{Type: "log", Message: "m", Detail: strings.Repeat("x", 2*lspLogLineBytes)})
	}
	if len(f.server.logs) != lspLogLines || len(f.server.logs[0]) > lspLogLineBytes+16 {
		t.Fatalf("kept %d lines of %d bytes", len(f.server.logs), len(f.server.logs[0]))
	}
}
