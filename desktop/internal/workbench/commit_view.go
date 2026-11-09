package workbench

import (
	"path"
	"strings"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file declares the Commit tool window, laid out as the macOS one is: the toolbar,
// the change list with a checkbox on every change, and under a splitter the commit area
// with the message and the commit buttons. A review the plan asks for opens as a dialog
// over the window. The state and the actions are in commit.go.

var (
	commitMessageID     = tree.ID(shellPage, "commit-message")
	commitListID        = tree.ID(shellPage, "commit-list")
	commitSplitID       = tree.ID(shellPage, "commit-split")
	commitAllID         = tree.ID(shellPage, "commit-all")
	commitAmendID       = tree.ID(shellPage, "commit-amend")
	commitButtonID      = tree.ID(shellPage, "commit-button")
	commitPushID        = tree.ID(shellPage, "commit-push")
	commitDismissID     = tree.ID(shellPage, "commit-dismiss")
	commitRetryID       = tree.ID(shellPage, "commit-retry")
	commitStatusRetryID = tree.ID(shellPage, "commit-status-retry")
	commitReviewScope   = tree.ID(shellPage, "commit-review")
	commitReviewCancel  = tree.ID(shellPage, "commit-review-cancel")
	commitReviewClose   = tree.ID(shellPage, "commit-review-close")
	commitReviewConfirm = tree.ID(shellPage, "commit-review-confirm")
	commitReviewListID  = tree.ID(shellPage, "commit-review-list")

	// commitChecks.At(i) is the checkbox of the i-th change of the status.
	commitChecks = tree.Sub(shellPage, tree.Name("commit-checks"))
	// commitButtons.At(i) is a toolbar button, i one of the commitButton constants.
	commitButtons = tree.Sub(shellPage, tree.Name("commit-buttons"))
	// commitTargets.At(2*i) and At(2*i+1) are the two destinations of the i-th push the
	// review asks about: publishing the branch, and pushing to its upstream.
	commitTargets = tree.Sub(shellPage, tree.Name("commit-targets"))
)

const (
	commitButtonRefresh = iota
	commitButtonStageAll
)

// commitReviewHeight is the most the steps of a review take before they scroll.
const commitReviewHeight = 320

// drawCommitPanel declares the body of the Commit tool window.
func (a *App) drawCommitPanel(f *ui.Frame, p *project) {
	v := &a.commitView
	f.Column().Fill().Background(a.colors.Editor).Children(func() {
		a.drawCommitToolbar(f, p)
		f.Divider()
		if !a.drawCommitStatus(f, p) {
			return
		}
		v.body = f.Column().Grow(1).Children(func() {
			if v.bodyHeight > 0 && !v.split.Dragging() {
				v.derived = max(v.bodyHeight-shellSplitter-v.areaHeight, commitListMin)
				v.split.Pos = v.derived
			}
			a.drawCommitChanges(f, p).Grow(1)
			f.Splitter(commitSplitID, &v.split).Mins(commitListMin, commitAreaMin).Label(a.text.Panel.Resize)
			a.drawCommitArea(f, p).Height(v.areaHeight).Shrink(0)
		})
		v.hasBody = true
	})
	if p.commit.review != nil {
		a.drawCommitReview(f, p)
	}
}

// drawCommitToolbar declares the buttons over the change list: read the status again, and
// stage or unstage everything.
func (a *App) drawCommitToolbar(f *ui.Frame, p *project) {
	c, t := &p.commit, a.text.Commit
	f.Row().Height(logToolbarHeight).Shrink(0).Items(ui.Center).Gap(4).PadX(6).Children(func() {
		if a.logIconButton(f, commitButtons.At(commitButtonRefresh), t.Refresh, icons.RefreshCw, false, false) {
			a.refreshChanges(p)
		}
		label, icon := t.StageAll, icons.Plus
		if p.git.allStaged() {
			label, icon = t.UnstageAll, icons.Minus
		}
		if a.logIconButton(f, commitButtons.At(commitButtonStageAll), label, icon, false, c.busy || !p.git.hasToggleable()) {
			a.stageAll(p, surfaceButton)
		}
	})
}

// drawCommitStatus declares what stands for the change list while there is none to show,
// and reports whether there is one.
func (a *App) drawCommitStatus(f *ui.Frame, p *project) bool {
	g := a.text.Git
	switch {
	case !p.git.loaded:
		a.logEmpty(f, g.Loading)
	case p.git.err != nil:
		f.Column().Fill().Center().Gap(8).PadX(shellContentPad).Children(func() {
			f.Paragraph(g.Failed(p.git.err.Error()), 3).TextCenter().Color(a.colors.Subtle)
			if f.Button(commitStatusRetryID, g.Retry).Ghost().Clicked() {
				a.refreshChanges(p)
			}
		})
	case !p.git.isRepository():
		a.logEmpty(f, g.NotRepository)
	default:
		return true
	}
	return false
}

// drawCommitChanges declares the change list: one checkbox for the whole list, then every
// change with its own.
func (a *App) drawCommitChanges(f *ui.Frame, p *project) ui.Box {
	c, t := &p.commit, a.text.Commit
	changes := p.git.status.Changes
	return f.Column().FillWidth().Clip().Children(func() {
		if len(changes) == 0 {
			f.Column().Fill().Center().Gap(8).Children(func() {
				f.Icon(icons.Check).Size(20, 20).Color(a.colors.Success)
				f.Text(t.Clean).Color(a.colors.Subtle)
			})
			return
		}
		f.ScrollArea(commitListID).Grow(1).PadY(4).Children(func() {
			f.Row().Height(logItemHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
				if f.Checkbox(commitAllID, p.git.allStaged()).Label(t.ChangeList).Disabled(c.busy || !p.git.hasToggleable()).Clicked() {
					a.stageAll(p, surfaceButton)
				}
				f.Text(t.ChangeList).Weight(gfx.WeightMedium).Ellipsis().Shrink(1)
				f.Text(t.Files(p.git.fileCount())).Muted().Shrink(0)
			})
			for i, change := range changes {
				a.drawCommitChange(f, p, i, change)
			}
		})
	})
}

// drawCommitChange declares the row of one change: its checkbox, its icon, its name and
// folder, and whether it is staged.
func (a *App) drawCommitChange(f *ui.Frame, p *project, i int, change core.GitChange) {
	c, t := &p.commit, a.text.Commit
	state, label := t.UnstagedState, t.StageFile(change.Path)
	switch {
	case change.Staged && change.Worktree:
		state = t.PartlyStagedState
	case change.Staged:
		state, label = t.StagedState, t.UnstageFile(change.Path)
	}
	tint := a.changeColor(change)
	folder := strings.HasSuffix(change.Path, "/")
	dir, name := path.Split(strings.TrimSuffix(change.Path, "/"))
	if change.OriginalPath != "" && change.OriginalPath != change.Path {
		name = path.Base(change.OriginalPath) + " → " + name
	}
	f.Row().Height(logItemHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(6).
		PadSides(0, 8, 0, float32(8+logIndent)).Hover(ui.Look{}.Background(a.colors.Hover)).Children(func() {
		if f.Checkbox(commitChecks.At(i), change.Staged).Label(label).Disabled(c.busy || !change.CanToggleStaging).Clicked() {
			a.stageChange(p, change)
		}
		icon := fileicons.ForFile(path.Base(change.Path), a.colors.Dark)
		if folder {
			icon = fileicons.ForDirectory(path.Base(strings.TrimSuffix(change.Path, "/")), a.colors.Dark)
		}
		f.Icon(icon).Size(14, 14).Color(a.colors.Subtle)
		f.Text(name).Color(tint).Ellipsis().Shrink(0).MaxWidth(320)
		f.Text(strings.TrimSuffix(dir, "/")).Muted().Ellipsis().Grow(1)
		f.Text(state).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
	})
}

// changeColor is the color of a change's name, by the side of the change the row shows: the
// index when something is staged, the worktree otherwise.
func (a *App) changeColor(change core.GitChange) gfx.Color {
	status := change.Status
	switch {
	case change.Untracked || status == "??":
		return a.colors.Warning
	case len(status) < 2:
		return a.colors.Text
	case strings.ContainsRune(status, 'U') || status == "AA" || status == "DD":
		return a.colors.Warning
	}
	side := status[1]
	if change.Staged {
		side = status[0]
	}
	switch side {
	case 'A', 'C':
		return a.colors.Success
	case 'D':
		return a.colors.Deleted
	case 'M', 'R', 'T':
		return a.colors.Accent
	}
	return a.colors.Text
}

// hasToggleable reports that some change can be staged or unstaged.
func (g gitState) hasToggleable() bool {
	for _, change := range g.status.Changes {
		if change.CanToggleStaging {
			return true
		}
	}
	return false
}

// fileCount is the number of files the changes stand for: an untracked folder shown as
// one change counts each file in it.
func (g gitState) fileCount() int {
	n := 0
	for _, change := range g.status.Changes {
		if change.UntrackedFileCount > 0 {
			n += change.UntrackedFileCount
			continue
		}
		n++
	}
	return n
}

// drawCommitArea declares the commit area: amend and the staged count, the message, the
// results of the last run, and the commit buttons.
func (a *App) drawCommitArea(f *ui.Frame, p *project) ui.Box {
	c, t := &p.commit, a.text.Commit
	return f.Column().FillWidth().Clip().Pad(8).Gap(6).Children(func() {
		f.Row().FillWidth().Shrink(0).Items(ui.Center).Gap(6).Children(func() {
			if f.Checkbox(commitAmendID, c.amend).Label(t.Amend).Disabled(c.busy).Clicked() {
				c.amend = !c.amend
			}
			f.Text(t.Amend).Ellipsis().Shrink(1)
			f.Spacer()
			f.Text(t.Staged(p.git.stagedCount())).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
		})
		a.drawCommitMessage(f, p).Grow(1)
		if c.attempt != nil {
			a.drawCommitResults(f, p)
		}
		f.Row().FillWidth().Shrink(0).Items(ui.Center).Gap(6).Children(func() {
			label := t.Commit
			if c.busy {
				label = t.Committing
			}
			ready := p.canCommit()
			if f.Button(commitButtonID, label).Disabled(!ready).Clicked() {
				a.startCommit(p, false, surfaceButton)
			}
			if f.Button(commitPushID, t.CommitAndPush).Outline().Disabled(!ready).Clicked() {
				a.startCommit(p, true, surfaceButton)
			}
		})
	})
}

// drawCommitMessage declares the message box. The box paints the text itself and the
// platform's editor behind it only takes the input, so the caret starts on the first row.
func (a *App) drawCommitMessage(f *ui.Frame, p *project) ui.Box {
	c, t := &p.commit, a.text.Commit
	value := c.editor.String()
	selection := c.editor.Selection()
	snapshot := components.TextareaSnapshot{
		ID:             commitMessageID,
		Label:          t.MessageLabel,
		Value:          value,
		Placeholder:    t.MessagePlaceholder,
		Disabled:       c.busy,
		HideEditorText: true,
		ShowCaret:      true,
		Layout:         c.layout,
		Caret:          byteOffsetOfRune(value, c.editor.Caret()),
		SelectionStart: byteOffsetOfRune(value, selection.Start),
		SelectionEnd:   byteOffsetOfRune(value, selection.End),
	}
	if composition, ok := c.editor.Composition(); ok {
		snapshot.CompositionStart = byteOffsetOfRune(value, composition.Start)
		snapshot.CompositionEnd = byteOffsetOfRune(value, composition.End)
	}
	return f.Textarea(snapshot).FillWidth()
}

// byteOffsetOfRune is the byte offset in value of its n-th rune, or its length past the end.
func byteOffsetOfRune(value string, n int) int {
	for offset := range value {
		if n == 0 {
			return offset
		}
		n--
	}
	return len(value)
}

// drawCommitResults declares how each repository of the last run ended, and the buttons
// that forget the results or continue the run.
func (a *App) drawCommitResults(f *ui.Frame, p *project) {
	c, t := &p.commit, a.text.Commit
	session := c.attempt
	f.Column().FillWidth().Shrink(0).Gap(2).Children(func() {
		for _, id := range session.OrderedIDs {
			result := session.Results[id]
			tint := a.colors.Warning
			if result.Status == core.CommitCommittedAndPushed || result.Status == core.CommitCommitted && !session.Push {
				tint = a.colors.Success
			}
			f.Row().FillWidth().Items(ui.Center).Gap(6).Children(func() {
				f.Icon(icons.CircleAlert).Size(14, 14).Color(tint)
				f.Text(t.Result(p.commitRepositoryName(id), a.commitStatusLabel(result.Status))).Color(tint).Ellipsis().Grow(1)
			})
			if result.Detail != "" {
				f.Paragraph(result.Detail, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			}
		}
		f.Row().FillWidth().Items(ui.Center).Gap(6).Children(func() {
			if f.Button(commitDismissID, t.Dismiss).Ghost().Clicked() {
				a.dismissResults(p)
			}
			if c.retryable() && f.Button(commitRetryID, t.Retry).Outline().Disabled(c.busy).Clicked() {
				a.retryCommit(p)
			}
		})
	})
}

// commitStatusLabel is how a repository's place in a run is shown; a status this client does
// not know is shown as the kernel wrote it.
func (a *App) commitStatusLabel(status core.WorkspaceCommitStatus) string {
	t := a.text.Commit
	switch status {
	case core.CommitPending:
		return t.Pending
	case core.CommitNotIncluded:
		return t.NotIncluded
	case core.CommitCommitted:
		return t.Committed
	case core.CommitPushPending:
		return t.CommittedPushPending
	case core.CommitCommittedAndPushed:
		return t.CommittedAndPushed
	case core.CommitFailed:
		return t.CommitFailed
	case core.CommitHeadAdvanced:
		return t.HeadAdvanced
	case core.CommitOutcomeUnknown:
		return t.OutcomeUnknown
	case core.CommitPushFailed:
		return t.PushFailed
	case core.CommitReviewRequired:
		return t.ReviewRequired
	case core.CommitWaitingForSubmodule:
		return t.WaitingForSubmodule
	}
	return string(status)
}

// drawCommitReview declares the review of a plan: the message, then each repository in the
// order the plan runs them with where it commits, what it pushes and the files it takes.
func (a *App) drawCommitReview(f *ui.Frame, p *project) {
	c, t := &p.commit, a.text.Commit
	r := c.review
	session := r.prep.Session
	title := t.ReviewTitle
	switch {
	case session.IsRetry:
		title = t.ReviewRetry
	case session.Push:
		title = t.ReviewPushTitle
	}
	questions := map[string]int{}
	for i, q := range r.prep.PushTargetQuestions {
		questions[q.RepositoryID] = i
	}
	d := f.Dialog(ui.DialogSpec{Title: title, Description: t.Order, Width: 520,
		Scope: commitReviewScope, DismissID: commitReviewCancel, CloseID: commitReviewClose, InitialFocusID: commitReviewConfirm})
	d.Body(func() {
		f.Column().FillWidth().Gap(8).Children(func() {
			f.Paragraph(t.MessageLine(firstLine(session.Message)), 2)
			if session.Amend {
				f.Text(t.AmendNote).Color(a.colors.Warning)
			}
			f.ScrollArea(commitReviewListID).FillWidth().MaxHeight(commitReviewHeight).Children(func() {
				f.Column().FillWidth().Gap(10).Children(func() {
					for n, id := range session.OrderedIDs {
						index, asked := questions[id]
						var question *core.PushTargetQuestion
						if asked {
							question = &r.prep.PushTargetQuestions[index]
						}
						a.drawCommitReviewStep(f, p, n, id, question)
					}
				})
			})
		})
	})
	d.Footer(func() {
		if f.Button(commitReviewCancel, t.Cancel).Outline().Clicked() {
			a.cancelReview(p)
		}
		confirm := t.Continue
		if session.Push {
			confirm = t.CommitAndPush
		}
		if f.Button(commitReviewConfirm, confirm).Disabled(c.busy || !r.answered()).Clicked() {
			a.confirmReview(p)
		}
	})
	if d.Dismissed() {
		a.cancelReview(p)
	}
}

// drawCommitReviewStep declares one repository of a review. question is the push of it the
// user is asked about, nil when there is none.
func (a *App) drawCommitReviewStep(f *ui.Frame, p *project, n int, id string, question *core.PushTargetQuestion) {
	r, t := p.commit.review, a.text.Commit
	session := r.prep.Session
	state := session.States[id]
	action := t.StepCommit
	switch {
	case session.Results[id].Status == core.CommitCommitted || session.Results[id].Status == core.CommitPushPending:
		action = t.StepPushOnly
	case session.Push:
		action = t.StepPush
	}
	branch := strings.TrimPrefix(state.Branch, "refs/heads/")
	if branch == "" {
		branch = t.DetachedHead
	}
	head := t.NoCommits
	if state.Head != "" {
		head = state.Head[:min(len(state.Head), 10)]
	}
	f.Column().FillWidth().Gap(4).Children(func() {
		f.Text(t.Step(n+1, action, p.commitRepositoryName(id))).Weight(gfx.WeightMedium).Ellipsis()
		f.Text(t.Where(branch, head)).Mono().FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
		if question != nil {
			a.drawCommitTarget(f, r, n, *question)
		}
		for _, staged := range state.StagedPaths {
			f.Row().FillWidth().Items(ui.Center).Gap(6).PadX(8).Children(func() {
				f.Icon(fileicons.ForFile(path.Base(staged), a.colors.Dark)).Size(14, 14).Color(a.colors.Subtle)
				f.Text(staged).FontSize(a.theme.Metrics.FontSizeS).Ellipsis().Grow(1)
			})
		}
	})
}

// drawCommitTarget declares the question of a push whose branch tracks one with another
// name: publish the branch under its own name, or push to the branch it tracks.
func (a *App) drawCommitTarget(f *ui.Frame, r *commitReview, n int, q core.PushTargetQuestion) {
	t := a.text.Commit
	choice, picked := r.choices[q.RepositoryID]
	f.Paragraph(t.TracksDifferent(q.LocalBranch, q.Upstream), 3).Color(a.colors.Warning)
	f.Row().FillWidth().Gap(6).Children(func() {
		publish := f.Button(commitTargets.At(2*n), t.PublishTo(q.Remote, q.LocalBranch))
		upstream := f.Button(commitTargets.At(2*n+1), t.PushTo(q.Upstream))
		if !picked || choice != core.PushTargetPublish {
			publish.Outline()
		}
		if !picked || choice != core.PushTargetUpstream {
			upstream.Outline()
		}
		if publish.Clicked() {
			r.choices[q.RepositoryID] = core.PushTargetPublish
		}
		if upstream.Clicked() {
			r.choices[q.RepositoryID] = core.PushTargetUpstream
		}
	})
}

// firstLine is the subject of a commit message.
func firstLine(message string) string {
	if i := strings.IndexByte(message, '\n'); i >= 0 {
		return message[:i]
	}
	return message
}

// commitKey gives a key press to the Commit tool window: a focused splitter takes the
// arrows, and the message box moves its caret by the rows it shows.
func (a *App) commitKey(event gfx.KeyEvent) gfx.EventResult {
	p := a.project
	if p == nil {
		return gfx.EventResult{}
	}
	v, c := &a.commitView, &p.commit
	if r := v.split.Key(event); r.Handled {
		v.adoptArea()
		return r
	}
	if event.Target != commitMessageID {
		return gfx.EventResult{}
	}
	movement, extend := components.TextareaMovementForKey(event.Key, event.Modifiers)
	if movement == components.TextareaMoveNone {
		return gfx.EventResult{}
	}
	value := c.editor.String()
	to := c.layout.Move(value, byteOffsetOfRune(value, c.editor.Caret()), movement)
	c.editor.MoveTo(utf8.RuneCountInString(value[:to]), extend)
	return gfx.EventResult{Handled: true, Repaint: true}
}
