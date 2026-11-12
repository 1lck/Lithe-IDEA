package workbench

import (
	"context"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// This file runs the interactive rebase "Rebase from Here" (matrix id git-rebase-stash): the
// commit menu of the log opens a dialog that previews the commits after the chosen one, each
// with its action (pick, fixup or drop), and starts the reviewed plan through Core. A rebase
// that stops at a conflict or is still running is kept as the project's session and shown with
// Continue, Skip and Abort on the Commit tool window (git_rebase_view.go). Reword, edit and
// squash need a message and are not offered here.

// rebaseActions are the actions the dialog offers, in the order a click on an action cycles them.
var rebaseActions = []string{"pick", "reword", "edit", "squash", "fixup", "drop"}

// Modes of the message editor the dialog shows in place of its commits.
const (
	rebaseEditNone = iota
	// rebaseEditPlan edits the message of a commit the plan rewords or squashes.
	rebaseEditPlan
	// rebaseEditAmend edits the message of the commit a session paused at an edit.
	rebaseEditAmend
)

// rebaseState is the rebase dialog of a project and the session of its last rebase.
type rebaseState struct {
	open bool
	// gen counts the previews started; an answer of an older preview is dropped.
	gen     int
	busy    bool
	base    string
	subject string
	preview core.RebasePreview
	// actions holds the chosen action of each commit of the preview, by hash.
	actions map[string]string
	// order is the replay order of the preview's commits, by hash, oldest first as Core lists them
	// until the user moves one.
	order []string
	// messages holds the message a reword or squash takes, by hash.
	messages map[string]string
	// editMode says the message editor is open; editHash and editAction are the commit and the
	// action it is for, and message is its text.
	editMode   int
	editHash   string
	editAction string
	message    ui.Field
	err        string
	list       ui.ListState
	// session is the last rebase session the repository holds, nil when there is none.
	session *core.RebaseSession
	// root is the repository the dialog and the session act in: the one the log walked when the
	// rebase began, empty for the project's own repository.
	root string
}

// rebaseRoot is the repository the rebase dialog and session act in.
func (p *project) rebaseRoot() string {
	if p.rebase.root != "" {
		return p.rebase.root
	}
	return p.git.repositoryRoot(p.root)
}

// rebaseKernel is the part of the kernel a rebase uses. *core.Client implements it.
type rebaseKernel interface {
	GitRebasePreview(ctx context.Context, root, base string) (core.RebasePreview, error)
	GitRebaseStart(ctx context.Context, root string, preview core.RebasePreview, steps []core.RebaseStep) (*core.RebaseSession, error)
	GitRebaseSession(ctx context.Context, root string) (*core.RebaseSession, error)
	GitRebaseControl(ctx context.Context, root string, session core.RebaseSession, action, amendMessage, expectedHead string) (*core.RebaseSession, error)
}

// rebaseDone reports that a session has nothing left to continue.
func rebaseDone(status string) bool {
	return status == "completed" || status == "aborted"
}

// beginRebaseFromHere opens the rebase dialog on the commits after base and reads their preview.
func (a *App) beginRebaseFromHere(p *project, base, subject string) {
	if _, ok := a.kernel.(rebaseKernel); !ok {
		return
	}
	// The project keeps one rebase session, in one slot. A new rebase would overwrite the session
	// of an unfinished one, in any repository, so it waits until that session is finished.
	if s := p.rebase.session; s != nil && !rebaseDone(s.Status) {
		a.notifyInfo(i18n.Shared(a.language(), "desktop.rebase.slotBusy"))
		return
	}
	r := &p.rebase
	r.gen++
	gen := r.gen
	root := p.logRepositoryRoot()
	*r = rebaseState{open: true, gen: gen, busy: true, base: base, subject: subject, session: r.session, root: root}
	kernel := a.kernel.(rebaseKernel)
	a.performed("git.rebase.fromHere", surfaceMenu)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		preview, err := kernel.GitRebasePreview(ctx, root, base)
		return func(a *App) {
			r := &p.rebase
			if !r.open || r.gen != gen {
				return
			}
			r.busy = false
			if err != nil {
				r.err = reviewReason(err)
				a.gitOperationFailed("git_rebase_preview", err)
				return
			}
			r.preview = preview
			r.actions = map[string]string{}
			r.messages = map[string]string{}
			r.order = r.order[:0]
			for _, commit := range preview.Commits {
				r.actions[commit.Hash] = "pick"
				r.order = append(r.order, commit.Hash)
			}
		}
	})
}

// closeRebase closes the dialog and drops the preview it waits for.
func (a *App) closeRebase(p *project) {
	r := &p.rebase
	r.open = false
	r.gen++
}

// startRebase runs the reviewed plan of the open dialog: every commit of the preview once, in
// the order it replays, with the action the user chose.
func (a *App) startRebase(p *project) {
	kernel, ok := a.kernel.(rebaseKernel)
	r := &p.rebase
	if !ok || r.busy || len(r.preview.Commits) == 0 {
		return
	}
	steps := make([]core.RebaseStep, 0, len(r.preview.Commits))
	for _, hash := range r.order {
		commit, ok := r.commitByHash(hash)
		if !ok {
			continue
		}
		step := core.RebaseStep{Hash: commit.Hash, Action: r.actions[commit.Hash]}
		switch step.Action {
		case "reword":
			step.Message = r.messageOf(commit)
		case "squash":
			if msg, ok := r.messages[commit.Hash]; ok && strings.TrimSpace(msg) != "" {
				step.Message = msg
			}
		}
		steps = append(steps, step)
	}
	preview := r.preview
	r.busy = true
	a.performed("git.rebase.start", surfaceButton)
	root := p.rebaseRoot()
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		session, err := kernel.GitRebaseStart(ctx, root, preview, steps)
		return func(a *App) {
			r := &p.rebase
			r.busy = false
			if err != nil {
				r.err = reviewReason(err)
				a.gitOperationFailed("git_rebase_start", err)
				return
			}
			r.open = false
			r.session = session
			a.afterRebaseWrite(p)
		}
	})
}

// controlRebase continues, skips or aborts the session the repository holds.
func (a *App) controlRebase(p *project, action string) {
	a.controlRebaseWith(p, action, "")
}

// controlRebaseWith is controlRebase with the message an amended continue at an edit pause
// carries; the amendment is checked against the HEAD the session showed.
func (a *App) controlRebaseWith(p *project, action, message string) {
	kernel, ok := a.kernel.(rebaseKernel)
	r := &p.rebase
	if !ok || r.busy || r.session == nil {
		return
	}
	session := *r.session
	expectedHead := ""
	if message != "" && session.Head != nil {
		expectedHead = *session.Head
	}
	r.busy = true
	a.performed("git.rebase."+action, surfaceButton)
	root := p.rebaseRoot()
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		next, err := kernel.GitRebaseControl(ctx, root, session, action, message, expectedHead)
		return func(a *App) {
			r := &p.rebase
			r.busy = false
			if err != nil {
				a.notifyError(i18n.SharedFormat(a.language(), "desktop.rebase.controlFailed", map[string]string{"reason": reviewReason(err)}))
				a.gitOperationFailed("git_rebase_control", err)
				a.loadRebaseSession(p)
				return
			}
			r.session = next
			a.afterRebaseWrite(p)
		}
	})
}

// loadRebaseSession reads the repository's latest rebase session in the background, so a
// rebase that stopped at a conflict is still shown after a restart.
func (a *App) loadRebaseSession(p *project) {
	kernel, ok := a.kernel.(rebaseKernel)
	if !ok || !p.git.isRepository() {
		return
	}
	root := p.rebaseRoot()
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		session, err := kernel.GitRebaseSession(ctx, root)
		return func(a *App) {
			if err == nil {
				p.rebase.session = session
			}
		}
	})
}

// afterRebaseWrite reads the status, the log and the session again after a rebase moved HEAD.
func (a *App) afterRebaseWrite(p *project) {
	a.loadGit(p)
	if p.log.started {
		a.loadLog(p)
	}
	if p.rebase.session != nil {
		a.notifyInfo(i18n.SharedFormat(a.language(), "desktop.rebase.status", map[string]string{"status": p.rebase.session.Status}))
	}
}

// commitByHash is the commit of the preview with hash.
func (r *rebaseState) commitByHash(hash string) (core.RebaseCommit, bool) {
	for _, commit := range r.preview.Commits {
		if commit.Hash == hash {
			return commit, true
		}
	}
	return core.RebaseCommit{}, false
}

// moveRebaseCommit moves the commit with hash one place up (by -1) or down (by 1) in the replay order.
func (r *rebaseState) moveRebaseCommit(hash string, by int) {
	for i, h := range r.order {
		if h != hash {
			continue
		}
		j := i + by
		if j >= 0 && j < len(r.order) {
			r.order[i], r.order[j] = r.order[j], r.order[i]
		}
		return
	}
}

// messageOf is the message a commit of the plan takes: the one the user typed, or the commit's own.
func (r *rebaseState) messageOf(commit core.RebaseCommit) string {
	if msg, ok := r.messages[commit.Hash]; ok {
		return msg
	}
	return commit.Message
}

// nextRebaseAction is the action after action in the cycle a click on a commit's action walks.
func nextRebaseAction(action string) string {
	return rebaseActions[(indexOfAction(action)+1)%len(rebaseActions)]
}

// openRebaseMessage opens the message editor of the commit of a reword or squash the user picked.
// current is the message to start from; the action is applied when the editor is confirmed.
func (a *App) openRebaseMessage(p *project, commit core.RebaseCommit, action string) {
	r := &p.rebase
	r.editMode, r.editHash, r.editAction = rebaseEditPlan, commit.Hash, action
	start := r.messageOf(commit)
	if action == "squash" {
		start = r.messages[commit.Hash]
	}
	r.message.SetText(start)
}

// confirmRebaseMessage applies the message of the open plan editor, or the amended message of
// an edit pause, and closes the editor. A reword needs a message; an empty one keeps the action.
func (a *App) confirmRebaseMessage(p *project) {
	r := &p.rebase
	msg := strings.TrimSpace(r.message.Text())
	switch r.editMode {
	case rebaseEditPlan:
		if r.editAction == "reword" && msg == "" {
			return
		}
		r.messages[r.editHash] = msg
		r.actions[r.editHash] = r.editAction
		r.editMode = rebaseEditNone
	case rebaseEditAmend:
		r.editMode = rebaseEditNone
		a.controlRebaseWith(p, "continue", msg)
	}
}

// cancelRebaseMessage closes the message editor without changing the plan or the session.
func (a *App) cancelRebaseMessage(p *project) {
	p.rebase.editMode = rebaseEditNone
}

// openRebaseAmend opens the editor for the message of the commit a session paused at an edit
// holds, to be amended and continued.
func (a *App) openRebaseAmend(p *project) {
	r := &p.rebase
	if r.session == nil || r.session.CurrentMessage == nil {
		return
	}
	r.editMode = rebaseEditAmend
	r.message.SetText(*r.session.CurrentMessage)
}
