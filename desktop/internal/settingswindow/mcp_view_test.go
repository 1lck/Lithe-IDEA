package settingswindow

import (
	"context"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/mcpconfig"
)

type fakeMCP struct {
	mu      sync.Mutex
	applied []core.McpBatchIntent
}

func (f *fakeMCP) Load(context.Context) (mcpconfig.Library, error) {
	return mcpconfig.Library{Snapshot: core.McpLibrarySnapshot{Rows: []core.McpLibraryRow{{
		ID:         "docs#h",
		Definition: core.McpServer{Name: "docs", Transport: "http", URL: "https://user:pw@example.invalid/mcp?token=secret"},
		Sources:    []core.McpLibrarySource{{File: "codex|global|", SourceHash: "s1", OwnedByLithe: true}},
	}}}}, nil
}
func (f *fakeMCP) Apply(_ context.Context, intent core.McpBatchIntent) (core.McpBatchPlan, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.applied = append(f.applied, intent)
	return core.McpBatchPlan{Status: "ready"}, nil
}
func (f *fakeMCP) Featured(context.Context) (core.McpRegistryPage, error) {
	return core.McpRegistryPage{Entries: []core.McpRegistryEntry{{ID: "f", Title: "Featured One", Source: "featured"}}}, nil
}
func (f *fakeMCP) Search(context.Context, string, string) (core.McpRegistryPage, error) {
	return core.McpRegistryPage{}, nil
}
func (f *fakeMCP) Probe(context.Context, core.McpServer) ([]core.McpTool, error) { return nil, nil }
func (f *fakeMCP) ToolPolicy(context.Context, string, string, []string) (core.McpToolPolicy, error) {
	return core.McpToolPolicy{}, nil
}
func (f *fakeMCP) SetTool(context.Context, string, string, []string, string, bool) (core.McpToolPolicy, error) {
	return core.McpToolPolicy{}, nil
}
func (f *fakeMCP) CommandLine(_ context.Context, command string, _ []string) (string, error) {
	return command, nil
}
func (f *fakeMCP) ParseCommandLine(_ context.Context, line string) (string, []string, error) {
	return line, nil, nil
}

// Opening the page reads and shows the files' servers without a credential in the address and
// writes nothing; a delete asks first and then sends exactly one delete intent for the files
// the entry is in.
func TestMCPPageShowsRealServersAndDeletesAfterConfirmation(t *testing.T) {
	fake := &fakeMCP{}
	w := newWindow(NewController(Options{MCP: fake}), Values{})
	w.sess.page = pageMCP
	d := openWindow(t, w)
	d.until("the servers", func() bool { return w.mcp.loaded })
	d.until("the featured catalog", func() bool { return len(w.mcp.featuredPage.Entries) == 1 })
	if len(fake.applied) != 0 {
		t.Fatalf("opening the page wrote %v", fake.applied)
	}
	if got := summary(w.mcp.library.Snapshot.Rows[0].Definition); got != "https://example.invalid/mcp" {
		t.Fatalf("summary = %q", got)
	}
	del := w.mcpText("delete")
	d.click(del)
	if len(fake.applied) != 0 {
		t.Fatal("delete did not ask first")
	}
	// The dialog's button carries the same label; the front-most control is the dialog's.
	d.click(del)
	d.until("the delete", func() bool { fake.mu.Lock(); defer fake.mu.Unlock(); return len(fake.applied) == 1 })
	got := fake.applied[0]
	if got.Kind != "delete" || got.Name != "docs" || len(got.Files) != 1 || got.Files[0] != "codex|global|" {
		t.Fatalf("intent = %#v", got)
	}
}

func TestMCPEntriesKeepMaskedSecrets(t *testing.T) {
	stored := []core.McpEntry{{Key: "TOKEN", Value: "real"}, {Key: "OTHER", Value: "x"}}
	shown := formatEntries(stored, "=")
	if shown != "TOKEN="+mcpMask+"\nOTHER="+mcpMask {
		t.Fatalf("shown = %q", shown)
	}
	got := parseEntries("TOKEN="+mcpMask+"\nOTHER=new\nADDED=v", "=", stored)
	want := []core.McpEntry{{Key: "TOKEN", Value: "real"}, {Key: "OTHER", Value: "new"}, {Key: "ADDED", Value: "v"}}
	if len(got) != 3 || got[0] != want[0] || got[1] != want[1] || got[2] != want[2] {
		t.Fatalf("got %v", got)
	}
}
