package settingswindow

import (
	"context"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// The shared instruction page edits one Shared.md that Core copies between the Agents' native
// instruction files, each inside Lithe's own marked block. Core owns the markers, the revision
// guards and the atomic writes; this file keeps the editor draft apart from what was read, so a
// reload or an outside change never replaces text the user is still typing.

// sharedState is the state of the shared instruction card. Background work writes it under the
// agentSettings lock.
type sharedState struct {
	loaded, loading, saving bool
	// lib is the last snapshot Core read or wrote: the shared file and each Agent's target.
	lib core.AgentSharedInstructions
	// draft is the editor's text. It is replaced only when it still equals base, the content
	// the draft was started from, so unsaved text is never overwritten.
	draft string
	// base is the content and revision the draft started from; the revision is what a save
	// asks Core to guard against.
	base, baseRevision string
	// conflict says the file changed outside the window while the draft held unsaved text.
	conflict bool
	err      error
	saved    bool
	// toggling is the Agent whose native switch is being changed, "" when none is.
	toggling string
}

func (st *sharedState) dirty() bool { return st.loaded && st.draft != st.base }

// beginShared reads the shared file and its targets. The draft is kept when it holds text the
// user has not saved and the file changed meanwhile; then the window says so and keeps the draft.
func (s *agentSettings) beginShared(force bool) {
	s.mu.Lock()
	st := &s.shared
	if !s.available() || st.loading || st.saving || st.toggling != "" || (st.loaded && !force) {
		s.mu.Unlock()
		return
	}
	st.loading, st.err, st.saved = true, nil, false
	dir := s.dir()
	s.mu.Unlock()
	s.run(func(ctx context.Context) {
		lib, err := s.backend.ReadAgentSharedInstructions(ctx, dir)
		s.mu.Lock()
		defer s.mu.Unlock()
		st.loading = false
		st.err = err
		if err != nil {
			return
		}
		fresh := !st.loaded || !st.dirty()
		st.lib, st.loaded = lib, true
		if fresh {
			st.draft, st.base, st.baseRevision, st.conflict = lib.File.Content, lib.File.Content, lib.File.Revision, false
			return
		}
		st.conflict = lib.File.Revision != st.baseRevision
	})
}

// saveShared writes the draft with the revision it started from, and the native targets Core
// may update. A rejected save keeps the draft and reports the error.
func (s *agentSettings) saveShared() {
	s.mu.Lock()
	st := &s.shared
	if !s.available() || !st.loaded || st.saving || st.loading || st.toggling != "" || !st.dirty() {
		s.mu.Unlock()
		return
	}
	st.saving, st.err, st.saved = true, nil, false
	dir, draft, revision := s.dir(), st.draft, st.baseRevision
	var guards []core.AgentFileGuard
	for _, target := range st.lib.Agents {
		if target.File != nil {
			guards = append(guards, core.AgentFileGuard{AgentID: target.AgentID, Path: target.File.Path, Revision: target.File.Revision})
		}
	}
	s.mu.Unlock()
	s.run(func(ctx context.Context) {
		updated, err := s.backend.SaveAgentSharedInstructions(ctx, dir, draft, revision, guards)
		s.mu.Lock()
		defer s.mu.Unlock()
		st.saving = false
		if err != nil {
			st.err = err
			return
		}
		st.lib, st.saved, st.conflict = updated, true, false
		st.draft, st.base, st.baseRevision = updated.File.Content, updated.File.Content, updated.File.Revision
	})
}

// setSharedEnabled turns the shared block on or off in one Agent's native file and shows the
// snapshot Core reads back. The draft is not touched.
func (s *agentSettings) setSharedEnabled(agentID string, enabled bool) {
	s.mu.Lock()
	st := &s.shared
	if !s.available() || !st.loaded || st.saving || st.loading || st.toggling != "" {
		s.mu.Unlock()
		return
	}
	var guard core.AgentFileGuard
	found := false
	for _, target := range st.lib.Agents {
		if target.AgentID == agentID && target.File != nil {
			guard = core.AgentFileGuard{AgentID: agentID, Path: target.File.Path, Revision: target.File.Revision}
			found = true
		}
	}
	if !found {
		st.err = errors.New("the native instruction file of this Agent is not available")
		s.mu.Unlock()
		return
	}
	st.toggling, st.err, st.saved = agentID, nil, false
	dir, revision := s.dir(), st.lib.File.Revision
	s.mu.Unlock()
	s.run(func(ctx context.Context) {
		updated, err := s.backend.SetAgentSharedInstructionsEnabled(ctx, dir, agentID, enabled, revision, guard)
		s.mu.Lock()
		defer s.mu.Unlock()
		st.toggling = ""
		if err != nil {
			st.err = err
			return
		}
		st.lib = updated
	})
}
