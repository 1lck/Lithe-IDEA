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
	if len(f.server.logs) != 1 || !strings.Contains(f.server.logs[0], "[INFO]") {
		t.Fatalf("logs = %q", f.server.logs)
	}
	f.h.click(center(f.h.button(itemLSP)))
	f.h.settle()
	if !a.editor.lsp.open || !f.h.shows("indexing done") {
		t.Fatalf("log window: open=%v ", a.editor.lsp.open)
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
