package settingswindow

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// The AI pages (Agents, Instructions, Skills, Hooks) edit what the Agent tools really
// read: their own instruction files, skill directories and hook configuration. Core owns
// every rule (revision guards, native paths, validation); this file only carries the
// user's choices to it and shows what it read back. Opening a page reads and writes
// nothing; a change is written only after an explicit button press.

// AgentSettingsBackend is the Core surface the AI pages use; *core.Client satisfies it.
// Every call runs off the window thread.
type AgentSettingsBackend interface {
	ReadAgentInstructions(ctx context.Context, agentID string) (core.AgentInstructionFile, error)
	SaveAgentInstructions(ctx context.Context, agentID, content, expectedPath, expectedRevision string) (core.AgentInstructionFile, error)
	ReadAgentHooks(ctx context.Context, dataDirectory string) (core.AgentHookLibrary, error)
	SaveAgentHook(ctx context.Context, dataDirectory, expectedRevision string, files []core.AgentFileGuard, hook core.AgentHook) (core.AgentHookLibrary, error)
	RemoveAgentHook(ctx context.Context, dataDirectory, expectedRevision string, files []core.AgentFileGuard, id string) (core.AgentHookLibrary, error)
	SyncAgentHooks(ctx context.Context, dataDirectory, expectedRevision string, files []core.AgentFileGuard) (core.AgentHookLibrary, error)
	ValidateAgentHookDraft(ctx context.Context, draft core.AgentHookDraft, existing []core.AgentHookRef) (core.AgentHookValidation, error)
	ListAgentSkills(ctx context.Context, agentID, workspace string) (core.AgentSkillListing, error)
	ReadAgentSkill(ctx context.Context, agentID, source string) (string, error)
	SetAgentSkillEnabled(ctx context.Context, agentID, workspace, source, scope string, enabled bool) (core.AgentSkillListing, error)
	CreateAgentSkill(ctx context.Context, agentID, workspace, scope, name, description, instructions string) (string, error)
	ImportAgentSkill(ctx context.Context, agentID, workspace, scope, source string) (string, error)
	ReadAgentSharedInstructions(ctx context.Context, dataDirectory string) (core.AgentSharedInstructions, error)
	SaveAgentSharedInstructions(ctx context.Context, dataDirectory, content, expectedRevision string, files []core.AgentFileGuard) (core.AgentSharedInstructions, error)
	SetAgentSharedInstructionsEnabled(ctx context.Context, dataDirectory, agentID string, enabled bool, expectedRevision string, file core.AgentFileGuard) (core.AgentSharedInstructions, error)
}

// AgentContextLimit is one Agent's context window and auto-compact threshold in
// tokens; zero means unset, which keeps the Agent's own default.
type AgentContextLimit struct {
	WindowTokens      uint64
	AutoCompactTokens uint64
}

// agentSettingsAgents are the adapters the management commands accept.
var agentSettingsAgents = [...]string{"codex-acp", "claude-acp"}

const agentSettingsTimeout = 30 * time.Second

// agentSettings is the state of the four AI pages. Background work writes under mu and
// then wakes the window; a paint reads under mu, so the window thread never waits on Core.
type agentSettings struct {
	backend         AgentSettingsBackend
	dataDirectory   func() string
	workspace       func() string
	limits          func(agentID string) AgentContextLimit
	aiGeneration    func() AIGenerationSettings
	setAIGeneration func(AIGenerationSettings)
	aiProviders     func(context.Context) []AIProviderStatus
	setLimits       func(agentID string, limit AgentContextLimit)
	wake            func()

	mu sync.Mutex
	// agent is the selected adapter (index into agentSettingsAgents).
	agent int

	providerRead generationState
	// generationDraft is the text of the generation card's instructions field. Unlike the
	// state around it, only the settings window thread touches it, in a paint, so mu does
	// not guard it.
	generationDraft generationInstructions
	instructions    instructionsState
	shared          sharedState
	skills          skillsState
	hooks           hooksState
	limitDraft      limitsState
	management      agentManagementState
}

type limitsState struct {
	agent           int
	window, compact string
	loaded, saved   bool
	invalid         bool
}

type instructionsState struct {
	loaded, loading, saving, saved bool
	file                           core.AgentInstructionFile
	// draft is the editor's text; it is replaced only by a load or a save result.
	draft string
	err   error
	// agentFor is the adapter the loaded file belongs to.
	agentFor string
	// confirmReload asks before a reload replaces an edited draft.
	confirmReload bool
}

type skillsState struct {
	loaded, loading bool
	// query is the search text of the list, folded by the view.
	query string
	// viewPath is the SKILL.md shown in the viewer, "" when none; viewContent is its text.
	viewPath, viewContent string
	viewing               bool
	listing               core.AgentSkillListing
	agentFor              string
	err                   error
	notice                string
	createScope           int
	name, desc            string
	body                  string
	importPath            string
	busy                  bool
}

type hooksState struct {
	loaded, loading, saving bool
	library                 core.AgentHookLibrary
	err                     error
	issues                  []core.AgentHookIssue
	editing                 bool
	form                    hookForm
	// query is the search text of the list, folded by the view.
	query string
	// confirmRemove is the Hook the Remove button asks to confirm, and the name the
	// confirmation shows; removal happens only after the user confirms.
	confirmRemove, confirmName string
}

// hookForm is the editor draft of one Hook.
type hookForm struct {
	id, name, description, command, timeout string
	event, matcher                          int
	codex, claude, enabled                  bool
}

var (
	hookEvents   = [...]string{"turn-end", "after-tool", "before-tool", "prompt", "session-start"}
	hookMatchers = [...]string{"all", "shell", "edit"}
)

func newAgentSettings(o Options, wake func()) *agentSettings {
	return &agentSettings{
		backend: o.AgentSettings, dataDirectory: o.AgentDataDirectory, workspace: o.AgentWorkspace,
		limits: o.AgentContextLimits, setLimits: o.SetAgentContextLimits, wake: wake,
		aiGeneration: o.AIGeneration, setAIGeneration: o.SetAIGeneration, aiProviders: o.AIProviders,
	}
}

func (s *agentSettings) available() bool { return s != nil && s.backend != nil }

func (s *agentSettings) agentID() string { return agentSettingsAgents[s.agent] }

// run does work off the window thread, bounded in time, and wakes the window after.
func (s *agentSettings) run(work func(ctx context.Context)) {
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), agentSettingsTimeout)
		defer cancel()
		work(ctx)
		if s.wake != nil {
			s.wake()
		}
	}()
}

func (s *agentSettings) dir() string {
	if s.dataDirectory == nil {
		return ""
	}
	return s.dataDirectory()
}

func (s *agentSettings) root() string {
	if s.workspace == nil {
		return ""
	}
	return s.workspace()
}

// selectAgent switches the adapter; the pages read again for it on their next paint.
func (s *agentSettings) selectAgent(index int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if index < 0 || index >= len(agentSettingsAgents) || index == s.agent {
		return
	}
	s.agent = index
	s.instructions = instructionsState{}
	s.skills = skillsState{createScope: s.skills.createScope}
}

// ---- Context limits ------------------------------------------------------------

func formatLimit(v uint64) string {
	if v == 0 {
		return ""
	}
	return strconv.FormatUint(v, 10)
}

// loadLimits fills the draft from the saved limits of the selected adapter.
func (s *agentSettings) loadLimits() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.limitDraft.loaded && s.limitDraft.agent == s.agent || s.limits == nil {
		return
	}
	l := s.limits(s.agentID())
	s.limitDraft = limitsState{agent: s.agent, window: formatLimit(l.WindowTokens), compact: formatLimit(l.AutoCompactTokens), loaded: true}
}

// parseLimit reads a token count; empty is unset.
func parseLimit(text string) (uint64, bool) {
	text = strings.TrimSpace(text)
	if text == "" {
		return 0, true
	}
	v, err := strconv.ParseUint(text, 10, 64)
	return v, err == nil
}

// saveLimits writes the draft through the owner; an invalid number saves nothing.
func (s *agentSettings) saveLimits() {
	s.mu.Lock()
	defer s.mu.Unlock()
	window, ok1 := parseLimit(s.limitDraft.window)
	compact, ok2 := parseLimit(s.limitDraft.compact)
	if !ok1 || !ok2 {
		s.limitDraft.invalid, s.limitDraft.saved = true, false
		return
	}
	s.limitDraft.invalid, s.limitDraft.saved = false, true
	if s.setLimits != nil {
		s.setLimits(s.agentID(), AgentContextLimit{WindowTokens: window, AutoCompactTokens: compact})
	}
}

// resetLimits clears both limits, restoring the Agent's defaults.
func (s *agentSettings) resetLimits() {
	s.mu.Lock()
	s.limitDraft.window, s.limitDraft.compact, s.limitDraft.invalid = "", "", false
	s.mu.Unlock()
	s.saveLimits()
}

// ---- Instructions -------------------------------------------------------------

func (s *agentSettings) beginInstructions(force bool) {
	s.mu.Lock()
	st := &s.instructions
	if !s.available() || st.loading || st.saving || (st.loaded && st.agentFor == s.agentID() && !force) {
		s.mu.Unlock()
		return
	}
	st.loading, st.err, st.saved = true, nil, false
	id := s.agentID()
	s.mu.Unlock()
	s.run(func(ctx context.Context) {
		file, err := s.backend.ReadAgentInstructions(ctx, id)
		s.mu.Lock()
		defer s.mu.Unlock()
		st.loading = false
		if s.agentID() != id {
			return
		}
		st.err = err
		if err == nil {
			st.file, st.draft, st.loaded, st.agentFor = file, file.Content, true, id
		}
	})
}

// instructionsChanged says the draft differs from the file as read.
func (st *instructionsState) changed() bool { return st.loaded && st.draft != st.file.Content }

// saveInstructions writes the draft only while the file the editor read is still the one on
// disk (Core compares path and revision); a conflict keeps the draft.
func (s *agentSettings) saveInstructions() {
	s.mu.Lock()
	st := &s.instructions
	if !s.available() || !st.loaded || st.saving || st.loading || !st.changed() {
		s.mu.Unlock()
		return
	}
	st.saving, st.err, st.saved = true, nil, false
	id, draft, file := s.agentID(), st.draft, st.file
	s.mu.Unlock()
	s.run(func(ctx context.Context) {
		updated, err := s.backend.SaveAgentInstructions(ctx, id, draft, file.Path, file.Revision)
		s.mu.Lock()
		defer s.mu.Unlock()
		st.saving = false
		if s.agentID() != id {
			return
		}
		if err != nil {
			st.err = err
			return
		}
		st.file, st.draft, st.saved = updated, updated.Content, true
	})
}

// ---- Skills -------------------------------------------------------------------

func (s *agentSettings) beginSkills(force bool) {
	s.mu.Lock()
	st := &s.skills
	if !s.available() || st.loading || st.busy || (st.loaded && st.agentFor == s.agentID() && !force) {
		s.mu.Unlock()
		return
	}
	st.loading, st.err = true, nil
	id, root := s.agentID(), s.root()
	s.mu.Unlock()
	s.run(func(ctx context.Context) {
		listing, err := s.backend.ListAgentSkills(ctx, id, root)
		s.mu.Lock()
		defer s.mu.Unlock()
		st.loading = false
		if s.agentID() != id {
			return
		}
		st.err = err
		if err == nil {
			st.listing, st.loaded, st.agentFor = listing, true, id
		}
	})
}

// setSkillEnabled changes one skill's native visibility and shows the fresh listing Core
// reads back, never the guess.
func (s *agentSettings) setSkillEnabled(skill core.AgentSkill, enabled bool) {
	s.mu.Lock()
	st := &s.skills
	if !s.available() || st.busy || st.loading {
		s.mu.Unlock()
		return
	}
	st.busy, st.err, st.notice = true, nil, ""
	id, root := s.agentID(), s.root()
	s.mu.Unlock()
	s.run(func(ctx context.Context) {
		listing, err := s.backend.SetAgentSkillEnabled(ctx, id, root, skill.Path, skill.Scope, enabled)
		s.mu.Lock()
		defer s.mu.Unlock()
		st.busy = false
		if s.agentID() != id {
			return
		}
		st.err = err
		if err == nil {
			st.listing = listing
		}
	})
}

// skillScopes are the destinations the create/import controls offer.
var skillScopes = [...]string{"user", "repo"}

// createSkill writes a new skill (never overwriting) and lists again.
func (s *agentSettings) createSkill() {
	s.mu.Lock()
	st := &s.skills
	if !s.available() || st.busy {
		s.mu.Unlock()
		return
	}
	st.busy, st.err, st.notice = true, nil, ""
	id, root, scope := s.agentID(), s.root(), skillScopes[st.createScope]
	name, desc, body := strings.TrimSpace(st.name), strings.TrimSpace(st.desc), st.body
	s.mu.Unlock()
	s.run(func(ctx context.Context) {
		path, err := s.backend.CreateAgentSkill(ctx, id, root, scope, name, desc, body)
		s.finishSkillWrite(ctx, id, root, path, err, true)
	})
}

// importSkill copies a user-selected SKILL.md or package directory into the target scope.
func (s *agentSettings) importSkill() {
	s.mu.Lock()
	st := &s.skills
	if !s.available() || st.busy || strings.TrimSpace(st.importPath) == "" {
		s.mu.Unlock()
		return
	}
	st.busy, st.err, st.notice = true, nil, ""
	id, root, scope, src := s.agentID(), s.root(), skillScopes[st.createScope], strings.TrimSpace(st.importPath)
	s.mu.Unlock()
	s.run(func(ctx context.Context) {
		path, err := s.backend.ImportAgentSkill(ctx, id, root, scope, src)
		s.finishSkillWrite(ctx, id, root, path, err, false)
	})
}

func (s *agentSettings) finishSkillWrite(ctx context.Context, id, root, path string, err error, created bool) {
	var listing core.AgentSkillListing
	var listErr error
	if err == nil {
		listing, listErr = s.backend.ListAgentSkills(ctx, id, root)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	st := &s.skills
	st.busy = false
	if s.agentID() != id {
		return
	}
	st.err = errors.Join(err, listErr)
	if err == nil {
		st.notice = path
		if created {
			st.name, st.desc, st.body = "", "", ""
		} else {
			st.importPath = ""
		}
		if listErr == nil {
			st.listing = listing
		}
	}
}

// ---- Hooks --------------------------------------------------------------------

func (s *agentSettings) beginHooks(force bool) {
	s.mu.Lock()
	st := &s.hooks
	if !s.available() || st.loading || st.saving || (st.loaded && !force) {
		s.mu.Unlock()
		return
	}
	st.loading, st.err = true, nil
	st.confirmRemove, st.confirmName = "", ""
	dir := s.dir()
	s.mu.Unlock()
	s.run(func(ctx context.Context) {
		lib, err := s.backend.ReadAgentHooks(ctx, dir)
		s.mu.Lock()
		defer s.mu.Unlock()
		st.loading, st.err = false, err
		if err == nil {
			st.library, st.loaded = lib, true
		}
	})
}

func hookGuards(lib core.AgentHookLibrary) []core.AgentFileGuard {
	var files []core.AgentFileGuard
	for _, t := range lib.Targets {
		if t.File != nil {
			files = append(files, *t.File)
		}
	}
	return files
}

func newHookID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func agentIndexOf(list []string, value string) int {
	for i, v := range list {
		if v == value {
			return i
		}
	}
	return 0
}

// newHook starts an empty draft; editHook starts from a library row.
func (s *agentSettings) newHook() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hooks.editing, s.hooks.issues = true, nil
	s.hooks.form = hookForm{id: newHookID(), codex: true, claude: true, enabled: true}
}

func (s *agentSettings) editHook(h core.AgentHook) {
	s.mu.Lock()
	defer s.mu.Unlock()
	f := hookForm{id: h.ID, name: h.Name, description: h.Description, command: h.Command, enabled: h.Enabled,
		event: agentIndexOf(hookEvents[:], h.Event), matcher: agentIndexOf(hookMatchers[:], h.Matcher)}
	if h.TimeoutSeconds != nil {
		f.timeout = strconv.Itoa(*h.TimeoutSeconds)
	}
	for _, a := range h.Agents {
		f.codex = f.codex || a == "codex-acp"
		f.claude = f.claude || a == "claude-acp"
	}
	s.hooks.editing, s.hooks.issues, s.hooks.form = true, nil, f
}

func (s *agentSettings) cancelHook() {
	s.mu.Lock()
	s.hooks.editing, s.hooks.issues = false, nil
	s.mu.Unlock()
}

func (f hookForm) agents() []string {
	var out []string
	if f.codex {
		out = append(out, "codex-acp")
	}
	if f.claude {
		out = append(out, "claude-acp")
	}
	return out
}

// saveHook validates the draft with Core's rules and saves only a valid one, guarded by the
// library revision and native file revisions it read.
func (s *agentSettings) saveHook() {
	s.mu.Lock()
	st := &s.hooks
	if !s.available() || st.saving || !st.loaded || !st.editing {
		s.mu.Unlock()
		return
	}
	st.saving, st.err, st.issues = true, nil, nil
	form, lib, dir := st.form, st.library, s.dir()
	s.mu.Unlock()
	s.run(func(ctx context.Context) {
		var existing []core.AgentHookRef
		for _, h := range lib.Hooks {
			existing = append(existing, core.AgentHookRef{ID: h.ID, Name: h.Name})
		}
		draft := core.AgentHookDraft{ID: form.id, Name: form.name, Description: form.description,
			Event: hookEvents[form.event], Matcher: hookMatchers[form.matcher], Command: form.command,
			TimeoutText: form.timeout, Agents: form.agents()}
		verdict, err := s.backend.ValidateAgentHookDraft(ctx, draft, existing)
		if err == nil && verdict.Valid {
			hook := core.AgentHook{ID: draft.ID, Name: draft.Name, Description: draft.Description, Event: draft.Event,
				Matcher: draft.Matcher, Command: draft.Command, TimeoutSeconds: verdict.TimeoutSeconds, Agents: draft.Agents,
				Enabled: form.enabled}
			var updated core.AgentHookLibrary
			updated, err = s.backend.SaveAgentHook(ctx, dir, lib.Revision, hookGuards(lib), hook)
			s.mu.Lock()
			st.saving, st.err = false, err
			if err == nil {
				st.library, st.editing = updated, false
			}
			s.mu.Unlock()
			return
		}
		s.mu.Lock()
		st.saving, st.err, st.issues = false, err, verdict.Issues
		s.mu.Unlock()
	})
}

// hookMutation runs remove or sync and shows the library Core read back.
func (s *agentSettings) hookMutation(call func(ctx context.Context, dir string, lib core.AgentHookLibrary) (core.AgentHookLibrary, error)) {
	s.mu.Lock()
	st := &s.hooks
	if !s.available() || st.saving || !st.loaded {
		s.mu.Unlock()
		return
	}
	st.saving, st.err = true, nil
	lib, dir := st.library, s.dir()
	s.mu.Unlock()
	s.run(func(ctx context.Context) {
		updated, err := call(ctx, dir, lib)
		s.mu.Lock()
		defer s.mu.Unlock()
		st.saving, st.err = false, err
		if err == nil {
			st.library = updated
		}
	})
}

func (s *agentSettings) removeHook(id string) {
	s.hookMutation(func(ctx context.Context, dir string, lib core.AgentHookLibrary) (core.AgentHookLibrary, error) {
		return s.backend.RemoveAgentHook(ctx, dir, lib.Revision, hookGuards(lib), id)
	})
}

func (s *agentSettings) syncHooks() {
	s.hookMutation(func(ctx context.Context, dir string, lib core.AgentHookLibrary) (core.AgentHookLibrary, error) {
		return s.backend.SyncAgentHooks(ctx, dir, lib.Revision, hookGuards(lib))
	})
}

// readSkill loads the SKILL.md of one skill into the viewer. It runs only when the user asks.
func (s *agentSettings) readSkill(skill core.AgentSkill) {
	s.mu.Lock()
	st := &s.skills
	if !s.available() || st.viewing {
		s.mu.Unlock()
		return
	}
	st.viewing, st.err = true, nil
	id, path := s.agentID(), skill.Path
	s.mu.Unlock()
	s.run(func(ctx context.Context) {
		content, err := s.backend.ReadAgentSkill(ctx, id, path)
		s.mu.Lock()
		defer s.mu.Unlock()
		st.viewing = false
		if s.agentID() != id {
			return
		}
		if err != nil {
			st.err = err
			return
		}
		st.viewPath, st.viewContent = path, content
	})
}

// closeSkill hides the viewer.
func (s *agentSettings) closeSkill() {
	s.mu.Lock()
	s.skills.viewPath, s.skills.viewContent = "", ""
	s.mu.Unlock()
}

// dismissInstructionsReload closes the discard confirmation.
func (s *agentSettings) dismissInstructionsReload() {
	s.mu.Lock()
	s.instructions.confirmReload = false
	s.mu.Unlock()
}
