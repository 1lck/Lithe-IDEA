package workbench

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// recordSyncHarness is a window whose agent catalog has one agent whose sessions the user let
// Lithe read and one whose sessions it may not read, over a Core that answers every command.
func recordSyncHarness(t *testing.T) (*harness, *agentCore) {
	t.Helper()
	fake := &agentCore{}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarnessWithOptions(t, Options{
		Kernel:      &testKernel{},
		Store:       store.At(dir),
		Languages:   []string{"en-US"},
		AgentKernel: agents.NewClient(fake),
	})
	h.app.agentsView.catalog = []agents.CatalogAgent{
		{PluginID: "dev.lithe.test.agent", AgentID: "read", ReadsSessions: true, MayReadSessions: true},
		{PluginID: "dev.lithe.test.agent", AgentID: "unread", ReadsSessions: true},
	}
	return h, fake
}

func TestAgentRecordsSyncWhenConfiguredAndOnActivationAtMostOnceAMinute(t *testing.T) {
	h, fake := recordSyncHarness(t)

	// A configuration syncs the readable agent only.
	h.app.syncAgentRecords(true)
	h.settle()
	if got := fake.count("agentSessions.sync"); got != 1 {
		t.Fatalf("a configuration sent agentSessions.sync %d times, want once for the readable agent", got)
	}

	// The window activated within a minute of that sync does not sync again.
	if err := h.driver.Advance(agentRecordSyncInterval - time.Second); err != nil {
		t.Fatal(err)
	}
	h.app.resumeAgentRecordSync()
	h.settle()
	if got := fake.count("agentSessions.sync"); got != 1 {
		t.Fatalf("an activation within a minute synced again: %d syncs", got)
	}

	// A minute after the last sync, the activation syncs.
	if err := h.driver.Advance(time.Second); err != nil {
		t.Fatal(err)
	}
	h.app.resumeAgentRecordSync()
	h.settle()
	if got := fake.count("agentSessions.sync"); got != 2 {
		t.Fatalf("an activation a minute later sent %d syncs in all, want 2", got)
	}
}

func TestAgentRecordsSyncAgainWhenConfiguredWhileOneRuns(t *testing.T) {
	h, fake := recordSyncHarness(t)

	// Both run on the window thread before the first sync's answer is applied: the second
	// configuration waits for the first sync and then syncs once more, and an activation
	// meanwhile adds nothing.
	h.app.syncAgentRecords(true)
	h.app.syncAgentRecords(true)
	h.app.resumeAgentRecordSync()
	h.settle()
	h.settle()
	if got := fake.count("agentSessions.sync"); got != 2 {
		t.Fatalf("two configurations sent %d syncs, want 2", got)
	}
	if s := h.app.agentsView.recordSync; s.running || s.again {
		t.Fatalf("after the syncs the state is running %v again %v, want neither", s.running, s.again)
	}
}

func TestAgentRecordsDoNotSyncWithoutAReadableAgent(t *testing.T) {
	h, fake := recordSyncHarness(t)
	h.app.agentsView.catalog = h.app.agentsView.catalog[1:]

	h.app.syncAgentRecords(true)
	h.settle()
	if got := fake.count("agentSessions.sync"); got != 0 {
		t.Fatalf("an agent without consent was synced %d times", got)
	}
}
