package settingswindow

import (
	"errors"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func sharedFixture(content, revision string) core.AgentSharedInstructions {
	enabled := true
	return core.AgentSharedInstructions{
		File: core.AgentInstructionFile{AgentID: "shared", Path: "/data/Shared.md", Content: content, Exists: true, Revision: revision},
		Agents: []core.AgentSharedTarget{{
			AgentID: "codex-acp", Enabled: &enabled,
			File: &core.AgentInstructionFile{AgentID: "codex-acp", Path: "/home/AGENTS.md", Revision: "native-1"},
		}},
	}
}

func TestSharedDraftSurvivesReloadAndSaveFailure(t *testing.T) {
	b := &fakeAgentBackend{shared: sharedFixture("one", "rev-1")}
	s, _ := newTestAgentSettings(b)
	s.beginShared(false)
	settle(t, s, "shared load", func() bool { return s.shared.loaded })

	s.mu.Lock()
	s.shared.draft = "my unsaved edit"
	s.mu.Unlock()

	// The file changed outside: the reload keeps the draft and reports the conflict.
	b.mu.Lock()
	b.shared = sharedFixture("external", "rev-9")
	b.mu.Unlock()
	s.beginShared(true)
	settle(t, s, "reload", func() bool { return !s.shared.loading && s.shared.lib.File.Revision == "rev-9" })
	s.mu.Lock()
	if s.shared.draft != "my unsaved edit" || !s.shared.conflict {
		t.Fatalf("draft %q conflict %v", s.shared.draft, s.shared.conflict)
	}
	s.mu.Unlock()

	// A rejected save keeps the draft and the error.
	b.mu.Lock()
	b.sharedErr = errors.New("file_changed")
	b.mu.Unlock()
	s.saveShared()
	settle(t, s, "failed save", func() bool { return !s.shared.saving })
	s.mu.Lock()
	if s.shared.draft != "my unsaved edit" || s.shared.err == nil {
		t.Fatalf("after failed save draft %q err %v", s.shared.draft, s.shared.err)
	}
	s.mu.Unlock()
}

func TestSharedSaveWritesTheDraftAndTakesTheReadBack(t *testing.T) {
	b := &fakeAgentBackend{shared: sharedFixture("one", "rev-1")}
	s, _ := newTestAgentSettings(b)
	s.beginShared(false)
	settle(t, s, "shared load", func() bool { return s.shared.loaded })
	s.mu.Lock()
	s.shared.draft = "two"
	s.mu.Unlock()
	s.saveShared()
	settle(t, s, "save", func() bool { return s.shared.saved && !s.shared.saving })
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.shared.draft != "two" || s.shared.base != "two" || s.shared.baseRevision != "shared-rev-2" || s.shared.dirty() {
		t.Fatalf("state after save = %#v", s.shared)
	}
}
