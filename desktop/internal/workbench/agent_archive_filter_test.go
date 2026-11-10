package workbench

import (
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func archiveTestSessions() []agentSessionSummary {
	return []agentSessionSummary{
		{SessionID: "a", Title: "Refactor parser", ModelProvider: "codex"},
		{SessionID: "b", Title: "数据库迁移", ModelProvider: "claude"},
		{SessionID: "c", Title: "Old notes"},
	}
}

func archiveRowIDs(rows []agentSessionSummary) []string {
	ids := make([]string, 0, len(rows))
	for _, row := range rows {
		ids = append(ids, row.SessionID)
	}
	return ids
}

func TestAgentArchiveRowsFilterBySearchProviderAndLocalRemoval(t *testing.T) {
	s := &agentArchiveState{sessions: archiveTestSessions(), hidden: map[string]bool{"c": true}}
	if got := archiveRowIDs(agentArchiveRows(s)); !slices.Equal(got, []string{"a", "b"}) {
		t.Fatalf("default rows = %v", got)
	}
	s.query = " REFACTOR "
	if got := archiveRowIDs(agentArchiveRows(s)); !slices.Equal(got, []string{"a"}) {
		t.Fatalf("search rows = %v", got)
	}
	s.query = "迁移"
	if got := archiveRowIDs(agentArchiveRows(s)); !slices.Equal(got, []string{"b"}) {
		t.Fatalf("Chinese search rows = %v", got)
	}
	s.query = ""
	s.provider = "codex"
	if got := archiveRowIDs(agentArchiveRows(s)); !slices.Equal(got, []string{"a"}) {
		t.Fatalf("provider rows = %v", got)
	}
	s.provider = "?"
	if got := archiveRowIDs(agentArchiveRows(s)); len(got) != 0 {
		t.Fatalf("unknown provider rows include the removed conversation: %v", got)
	}
	s.provider = "claude"
	s.showHidden = true
	if got := archiveRowIDs(agentArchiveRows(s)); len(got) != 0 {
		t.Fatalf("show removed rows ignore the provider filter: %v", got)
	}
	s.provider = ""
	if got := archiveRowIDs(agentArchiveRows(s)); !slices.Equal(got, []string{"c"}) {
		t.Fatalf("removed rows = %v", got)
	}
}

func TestAgentArchiveProvidersAreDeterministicAndIncludeUnknown(t *testing.T) {
	got := agentArchiveProviders(archiveTestSessions())
	if want := []string{"", "claude", "codex", "?"}; !slices.Equal(got, want) {
		t.Fatalf("providers = %v, want %v", got, want)
	}
	if got := agentArchiveProviders(nil); !slices.Equal(got, []string{""}) {
		t.Fatalf("providers of an empty list = %v", got)
	}
}

func TestAgentArchiveLocalRemovalPersistsPerProject(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	p.agent.history.archive.canList = true
	h.app.loadAgentArchiveHidden(p)
	if len(p.agent.history.archive.hidden) != 0 {
		t.Fatalf("hidden = %v", p.agent.history.archive.hidden)
	}
	h.app.setAgentArchiveHidden(p, "old-1", true)
	if !p.agent.history.archive.hidden["old-1"] {
		t.Fatal("the conversation was not removed from the local list")
	}
	var saved map[string][]string
	if found, err := h.store.Load(agentArchiveHiddenFile, &saved); err != nil || !found ||
		!slices.Equal(saved[p.root], []string{"old-1"}) {
		t.Fatalf("saved removed ids = %v, found=%v, err=%v", saved, found, err)
	}
	h.app.setAgentArchiveHidden(p, "old-1", false)
	saved = map[string][]string{}
	if found, err := h.store.Load(agentArchiveHiddenFile, &saved); err != nil {
		t.Fatal(err)
	} else if found && len(saved) != 0 {
		t.Fatalf("restoring kept removed ids: %v", saved)
	}
}
