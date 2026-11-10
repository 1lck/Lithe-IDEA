package settingswindow

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// fakeAgentBackend records the writes the AI pages make and answers reads from memory.
type fakeAgentBackend struct {
	mu          sync.Mutex
	file        core.AgentInstructionFile
	saveErr     error
	savedWith   [2]string
	lib         core.AgentHookLibrary
	savedHook   *core.AgentHook
	validate    core.AgentHookValidation
	skills      core.AgentSkillListing
	enabledCall []bool
	shared      core.AgentSharedInstructions
	sharedSaves []string
	sharedErr   error
	sharedTurns []bool
}

func (f *fakeAgentBackend) ReadAgentInstructions(context.Context, string) (core.AgentInstructionFile, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.file, nil
}
func (f *fakeAgentBackend) SaveAgentInstructions(_ context.Context, _, content, path, revision string) (core.AgentInstructionFile, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.savedWith = [2]string{path, revision}
	if f.saveErr != nil {
		return core.AgentInstructionFile{}, f.saveErr
	}
	f.file.Content, f.file.Revision = content, "rev-2"
	return f.file, nil
}
func (f *fakeAgentBackend) ReadAgentHooks(context.Context, string) (core.AgentHookLibrary, error) {
	return f.lib, nil
}
func (f *fakeAgentBackend) SaveAgentHook(_ context.Context, _, _ string, _ []core.AgentFileGuard, hook core.AgentHook) (core.AgentHookLibrary, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.savedHook = &hook
	return core.AgentHookLibrary{Revision: "r2", Hooks: []core.AgentHook{hook}}, nil
}
func (f *fakeAgentBackend) RemoveAgentHook(context.Context, string, string, []core.AgentFileGuard, string) (core.AgentHookLibrary, error) {
	return core.AgentHookLibrary{}, nil
}
func (f *fakeAgentBackend) SyncAgentHooks(context.Context, string, string, []core.AgentFileGuard) (core.AgentHookLibrary, error) {
	return f.lib, nil
}
func (f *fakeAgentBackend) ValidateAgentHookDraft(context.Context, core.AgentHookDraft, []core.AgentHookRef) (core.AgentHookValidation, error) {
	return f.validate, nil
}
func (f *fakeAgentBackend) ListAgentSkills(context.Context, string, string) (core.AgentSkillListing, error) {
	return f.skills, nil
}
func (f *fakeAgentBackend) SetAgentSkillEnabled(_ context.Context, _, _, _, _ string, enabled bool) (core.AgentSkillListing, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.enabledCall = append(f.enabledCall, enabled)
	listing := f.skills
	on := enabled
	listing.Skills = []core.AgentSkill{{Name: "s", Path: "/p", Scope: "user", Enabled: &on}}
	return listing, nil
}
func (f *fakeAgentBackend) CreateAgentSkill(context.Context, string, string, string, string, string, string) (string, error) {
	return "/new/SKILL.md", nil
}
func (f *fakeAgentBackend) ImportAgentSkill(context.Context, string, string, string, string) (string, error) {
	return "/imported/SKILL.md", nil
}

// settle waits, with a deadline, until condition holds on the settings state.
func settle(t *testing.T, s *agentSettings, what string, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		s.mu.Lock()
		ok := condition()
		s.mu.Unlock()
		if ok {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func newTestAgentSettings(b *fakeAgentBackend) (*agentSettings, *[]AgentContextLimit) {
	var saved []AgentContextLimit
	s := newAgentSettings(Options{
		AgentSettings:         b,
		AgentDataDirectory:    func() string { return "/data" },
		AgentWorkspace:        func() string { return "/project" },
		AgentContextLimits:    func(string) AgentContextLimit { return AgentContextLimit{WindowTokens: 200000} },
		SetAgentContextLimits: func(_ string, l AgentContextLimit) { saved = append(saved, l) },
	}, nil)
	return s, &saved
}

func TestAgentInstructionsLoadEditSaveWithRevisionGuard(t *testing.T) {
	b := &fakeAgentBackend{file: core.AgentInstructionFile{AgentID: "codex-acp", Path: "/home/AGENTS.md", Content: "old", Exists: true, Revision: "rev-1"}}
	s, _ := newTestAgentSettings(b)
	s.beginInstructions(false)
	settle(t, s, "load", func() bool { return s.instructions.loaded })
	if s.instructions.draft != "old" || s.instructions.changed() {
		t.Fatal("opening the page must show the file as read, unchanged")
	}
	s.mu.Lock()
	s.instructions.draft = "new"
	s.mu.Unlock()
	s.saveInstructions()
	settle(t, s, "save", func() bool { return s.instructions.saved })
	if b.savedWith != [2]string{"/home/AGENTS.md", "rev-1"} {
		t.Fatalf("save guard = %v, want the path and revision that were read", b.savedWith)
	}
	if s.instructions.file.Revision != "rev-2" || s.instructions.changed() {
		t.Fatal("the page must show what Core read back")
	}
	// A conflict keeps the draft.
	b.saveErr = errors.New("file_changed")
	s.mu.Lock()
	s.instructions.draft = "newer"
	s.mu.Unlock()
	s.saveInstructions()
	settle(t, s, "conflict", func() bool { return s.instructions.err != nil && !s.instructions.saving })
	if s.instructions.draft != "newer" {
		t.Fatal("a failed save lost the draft")
	}
}

func TestAgentLimitsValidateAndSave(t *testing.T) {
	s, saved := newTestAgentSettings(&fakeAgentBackend{})
	s.loadLimits()
	if s.limitDraft.window != "200000" || s.limitDraft.compact != "" {
		t.Fatalf("draft = %#v, want the saved limits", s.limitDraft)
	}
	s.limitDraft.window = "abc"
	s.saveLimits()
	if len(*saved) != 0 || !s.limitDraft.invalid {
		t.Fatal("an invalid number must save nothing")
	}
	s.limitDraft.window, s.limitDraft.compact = "100000", "80000"
	s.saveLimits()
	if len(*saved) != 1 || (*saved)[0] != (AgentContextLimit{100000, 80000}) {
		t.Fatalf("saved = %v", *saved)
	}
	s.resetLimits()
	if (*saved)[len(*saved)-1] != (AgentContextLimit{}) {
		t.Fatal("restore defaults must clear both limits")
	}
}

func TestAgentHookSaveOnlyWhenCoreValidates(t *testing.T) {
	b := &fakeAgentBackend{lib: core.AgentHookLibrary{Revision: "r1"}, validate: core.AgentHookValidation{Issues: []core.AgentHookIssue{{Field: "name", Code: "required"}}}}
	s, _ := newTestAgentSettings(b)
	s.beginHooks(false)
	settle(t, s, "hooks load", func() bool { return s.hooks.loaded })
	s.newHook()
	s.saveHook()
	settle(t, s, "issues", func() bool { return len(s.hooks.issues) == 1 && !s.hooks.saving })
	if b.savedHook != nil {
		t.Fatal("an invalid draft was saved")
	}
	secs := 30
	b.validate = core.AgentHookValidation{Valid: true, TimeoutSeconds: &secs}
	s.mu.Lock()
	s.hooks.form.name, s.hooks.form.command, s.hooks.form.timeout = "notify", "printf done", "30"
	s.mu.Unlock()
	s.saveHook()
	settle(t, s, "saved", func() bool { return !s.hooks.editing && !s.hooks.saving })
	if b.savedHook == nil || b.savedHook.TimeoutSeconds == nil || *b.savedHook.TimeoutSeconds != 30 || len(b.savedHook.Agents) != 2 {
		t.Fatalf("saved hook = %#v", b.savedHook)
	}
}

func TestAgentSkillSwitchShowsCoreReadback(t *testing.T) {
	off := false
	b := &fakeAgentBackend{skills: core.AgentSkillListing{Skills: []core.AgentSkill{{Name: "s", Path: "/p", Scope: "user", Enabled: &off}}}}
	s, _ := newTestAgentSettings(b)
	s.beginSkills(false)
	settle(t, s, "skills", func() bool { return s.skills.loaded })
	s.setSkillEnabled(s.skills.listing.Skills[0], true)
	settle(t, s, "toggled", func() bool { return !s.skills.busy && *s.skills.listing.Skills[0].Enabled })
	if len(b.enabledCall) != 1 || !b.enabledCall[0] {
		t.Fatalf("calls = %v", b.enabledCall)
	}
	s.mu.Lock()
	s.skills.name, s.skills.desc, s.skills.body = "new-skill", "when", "do it"
	s.mu.Unlock()
	s.createSkill()
	settle(t, s, "created", func() bool { return s.skills.notice == "/new/SKILL.md" })
	if s.skills.name != "" {
		t.Fatal("a created skill must clear the form")
	}
}

// TestAgentPagesPaintAndShowWhatCoreRead opens each AI page in a real window: the page
// declares without error, shows what the backend read, and reading writes nothing.
func TestAgentPagesPaintAndShowWhatCoreRead(t *testing.T) {
	on := true
	b := &fakeAgentBackend{
		file:   core.AgentInstructionFile{Path: "/home/AGENTS.md", Content: "Use concise replies.", Exists: true, Revision: "r"},
		lib:    core.AgentHookLibrary{Revision: "r1", Hooks: []core.AgentHook{{ID: "1", Name: "notify", Event: "turn-end", Matcher: "all", Command: "printf done"}}},
		skills: core.AgentSkillListing{Skills: []core.AgentSkill{{Name: "shared-checks", Description: "Common checks", Path: "/p", Scope: "user", Enabled: &on}}},
	}
	for _, tc := range []struct {
		page pageID
		want string
	}{
		{pageAIAgents, "200000"},
		{pageAIInstructions, "/home/AGENTS.md"},
		{pageAISkills, "shared-checks · Global"},
		{pageAIHooks, "notify · When a turn ends"},
	} {
		w := newWindow(NewController(Options{
			AgentSettings:      b,
			AgentDataDirectory: func() string { return "/data" },
			AgentWorkspace:     func() string { return "/project" },
			AgentContextLimits: func(string) AgentContextLimit { return AgentContextLimit{WindowTokens: 200000} },
		}), Values{})
		w.sess.page = tc.page
		d := openWindow(t, w)
		d.until("the page shows what was read", func() bool { return d.textContaining(tc.want) })
	}
	if b.savedHook != nil || b.enabledCall != nil || b.savedWith != ([2]string{}) {
		t.Fatal("opening the pages wrote something")
	}
}

func (f *fakeAgentBackend) ReadAgentSharedInstructions(context.Context, string) (core.AgentSharedInstructions, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.shared, nil
}

func (f *fakeAgentBackend) SaveAgentSharedInstructions(_ context.Context, _, content, _ string, _ []core.AgentFileGuard) (core.AgentSharedInstructions, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sharedSaves = append(f.sharedSaves, content)
	if f.sharedErr != nil {
		return core.AgentSharedInstructions{}, f.sharedErr
	}
	f.shared.File.Content, f.shared.File.Revision = content, "shared-rev-2"
	return f.shared, nil
}

func (f *fakeAgentBackend) SetAgentSharedInstructionsEnabled(_ context.Context, _, _ string, enabled bool, _ string, _ core.AgentFileGuard) (core.AgentSharedInstructions, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sharedTurns = append(f.sharedTurns, enabled)
	return f.shared, nil
}

func (f *fakeAgentBackend) ReadAgentSkill(context.Context, string, string) (string, error) {
	return "---\nname: demo\n---\nBody", nil
}
