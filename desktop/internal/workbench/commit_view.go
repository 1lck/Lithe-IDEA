package workbench

import (
	"path"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file declares the Commit tool window as a Page, laid out as the macOS one is: the
// toolbar, the change list with a checkbox on every change, and under a splitter the commit
// area with the message and the commit buttons. A review the plan asks for opens as a dialog
// over the window. The state and the actions are in commit.go; commit_page.go hosts the page.

const (
	commitButtonRefresh = iota
	commitButtonStageAll
)

// commitReviewHeight is the most the steps of a review take before they scroll.
const commitReviewHeight = 320

// commitPageView declares the body of the Commit tool window.
func (a *App) commitPageView(c ui.C) {
	v := &a.commitView
	v.hasBody = false
	p := a.project
	if p == nil {
		return
	}
	ui.Column(c).Fill().Background(a.colors.Editor).Children(func() {
		a.drawCommitToolbar(c, p)
		ui.Divider(c)
		if !a.drawCommitStatus(c, p) {
			return
		}
		v.body = ui.Column(c).Grow(1).Children(func() {
			if v.bodyHeight > 0 && !v.split.Dragging() {
				v.derived = max(v.bodyHeight-shellSplitter-v.areaHeight, commitListMin)
				v.split.Pos = v.derived
			}
			a.drawCommitChanges(c, p).Grow(1)
			ui.Splitter(c, &v.split).Mins(commitListMin, commitAreaMin).Label(a.text.Panel.Resize)
			a.drawCommitArea(c, p).Height(v.areaHeight).Shrink(0)
		})
		v.hasBody = true
	})
	if p.commit.review != nil {
		a.drawCommitReview(c, p)
	}
}

// drawCommitToolbar declares the buttons over the change list: read the status again, and
// stage or unstage everything.
func (a *App) drawCommitToolbar(c ui.C, p *project) {
	cs, t := &p.commit, a.text.Commit
	ui.Row(c).Height(logToolbarHeight).Shrink(0).Items(ui.Center).Gap(4).PadX(6).Children(func() {
		if a.gitIconButton(c, t.Refresh, icons.RefreshCw, false, false) {
			c.After(func() { a.refreshChanges(p) })
		}
		label, icon := t.StageAll, icons.Plus
		if p.git.allStaged() {
			label, icon = t.UnstageAll, icons.Minus
		}
		if a.gitIconButton(c, label, icon, false, cs.busy || !p.git.hasToggleable()) {
			c.After(func() { a.stageAll(p, surfaceButton) })
		}
	})
}

// drawCommitStatus declares what stands for the change list while there is none to show,
// and reports whether there is one.
func (a *App) drawCommitStatus(c ui.C, p *project) bool {
	g := a.text.Git
	switch {
	case !p.git.loaded:
		a.gitEmpty(c, g.Loading)
	case p.git.err != nil:
		ui.Column(c).Fill().Center().Gap(8).PadX(shellContentPad).Children(func() {
			ui.Paragraph(c, g.Failed(p.git.err.Error()), 3).TextCenter().Color(a.colors.Subtle)
			if ui.Button(c, g.Retry).Ghost().Clicked() {
				c.After(func() { a.refreshChanges(p) })
			}
		})
	case !p.git.isRepository():
		a.gitEmpty(c, g.NotRepository)
	default:
		return true
	}
	return false
}

// drawCommitChanges declares the change list: one checkbox for the whole list, then every
// change with its own.
func (a *App) drawCommitChanges(c ui.C, p *project) ui.Box {
	cs, t := &p.commit, a.text.Commit
	changes := p.git.status.Changes
	return ui.Column(c).FillWidth().Clip().Children(func() {
		if len(changes) == 0 {
			ui.Column(c).Fill().Center().Gap(8).Children(func() {
				ui.Icon(c, icons.Check).Size(20, 20).Color(a.colors.Success)
				ui.Text(c, t.Clean).Color(a.colors.Subtle)
			})
			return
		}
		ui.Scroll(c).Grow(1).PadY(4).Children(func() {
			ui.Row(c).Height(logItemHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
				all := p.git.allStaged()
				if ui.Checkbox(c, &all, "").Label(t.ChangeList).Disabled(cs.busy || !p.git.hasToggleable()).Clicked() {
					c.After(func() { a.stageAll(p, surfaceButton) })
				}
				ui.Text(c, t.ChangeList).Weight(gfx.WeightMedium).Ellipsis().Shrink(1)
				ui.Text(c, t.Files(p.git.fileCount())).Muted().Shrink(0)
			})
			for _, change := range changes {
				a.drawCommitChange(c, p, change)
			}
		})
	})
}

// drawCommitChange declares the row of one change: its checkbox, its icon, its name and
// folder, and whether it is staged.
func (a *App) drawCommitChange(c ui.C, p *project, change core.GitChange) {
	cs, t := &p.commit, a.text.Commit
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
	ui.Row(c.Key(change.Path)).Height(logItemHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(6).
		PadSides(0, 8, 0, float32(8+logIndent)).Hover(ui.Look{}.Background(a.colors.Hover)).Children(func() {
		staged := change.Staged
		if ui.Checkbox(c, &staged, "").Label(label).Disabled(cs.busy || !change.CanToggleStaging).Clicked() {
			c.After(func() { a.stageChange(p, change) })
		}
		icon := fileicons.ForFile(path.Base(change.Path), a.colors.Dark)
		if folder {
			icon = fileicons.ForDirectory(path.Base(strings.TrimSuffix(change.Path, "/")), a.colors.Dark)
		}
		ui.Icon(c, icon).Size(14, 14).Color(a.colors.Subtle)
		ui.Text(c, name).Color(tint).Ellipsis().Shrink(0).MaxWidth(320)
		ui.Text(c, strings.TrimSuffix(dir, "/")).Muted().Ellipsis().Grow(1)
		ui.Text(c, state).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
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
func (a *App) drawCommitArea(c ui.C, p *project) ui.Box {
	cs, t := &p.commit, a.text.Commit
	return ui.Column(c).FillWidth().Clip().Pad(8).Gap(6).Children(func() {
		ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(6).Children(func() {
			ui.Checkbox(c, &cs.amend, t.Amend).Disabled(cs.busy)
			ui.Spacer(c)
			ui.Text(c, t.Staged(p.git.stagedCount())).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
		})
		message := ui.TextArea(c, &cs.messageField, t.MessageLabel, t.MessagePlaceholder).FillWidth().Grow(1).Disabled(cs.busy)
		if message.Shortcut(ui.Primary, "enter") {
			c.After(func() {
				if p.canCommit() {
					a.startCommit(p, false, surfaceShortcut)
				}
			})
		}
		if cs.attempt != nil {
			a.drawCommitResults(c, p)
		}
		ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(6).Children(func() {
			label := t.Commit
			if cs.busy {
				label = t.Committing
			}
			ready := p.canCommit()
			if ui.Button(c, label).Disabled(!ready).Clicked() {
				c.After(func() { a.startCommit(p, false, surfaceButton) })
			}
			if ui.Button(c, t.CommitAndPush).Outline().Disabled(!ready).Clicked() {
				c.After(func() { a.startCommit(p, true, surfaceButton) })
			}
		})
	})
}

// drawCommitResults declares how each repository of the last run ended, and the buttons
// that forget the results or continue the run.
func (a *App) drawCommitResults(c ui.C, p *project) {
	cs, t := &p.commit, a.text.Commit
	session := cs.attempt
	ui.Column(c).FillWidth().Shrink(0).Gap(2).Children(func() {
		for _, id := range session.OrderedIDs {
			result := session.Results[id]
			tint := a.colors.Warning
			if result.Status == core.CommitCommittedAndPushed || result.Status == core.CommitCommitted && !session.Push {
				tint = a.colors.Success
			}
			ui.Row(c.Key(id)).FillWidth().Items(ui.Center).Gap(6).Children(func() {
				ui.Icon(c, icons.CircleAlert).Size(14, 14).Color(tint)
				ui.Text(c, t.Result(p.commitRepositoryName(id), a.commitStatusLabel(result.Status))).Color(tint).Ellipsis().Grow(1)
			})
			if result.Detail != "" {
				ui.Paragraph(c.Key(id+"/detail"), result.Detail, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			}
		}
		ui.Row(c).FillWidth().Items(ui.Center).Gap(6).Children(func() {
			if ui.Button(c, t.Dismiss).Ghost().Clicked() {
				c.After(func() { a.dismissResults(p) })
			}
			if cs.retryable() && ui.Button(c, t.Retry).Outline().Disabled(cs.busy).Clicked() {
				c.After(func() { a.retryCommit(p) })
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
func (a *App) drawCommitReview(c ui.C, p *project) {
	cs, t := &p.commit, a.text.Commit
	r := cs.review
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
	open := true
	closed := ui.ModalWith(c, &open, title, ui.ModalSpec{Description: t.Order, Width: 520}, func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			ui.Paragraph(c, t.MessageLine(firstLine(session.Message)), 2)
			if session.Amend {
				ui.Text(c, t.AmendNote).Color(a.colors.Warning)
			}
			ui.Scroll(c).FillWidth().MaxHeight(commitReviewHeight).Children(func() {
				ui.Column(c).FillWidth().Gap(10).Children(func() {
					for n, id := range session.OrderedIDs {
						index, asked := questions[id]
						var question *core.PushTargetQuestion
						if asked {
							question = &r.prep.PushTargetQuestions[index]
						}
						a.drawCommitReviewStep(c, p, n, id, question)
					}
				})
			})
		})
	}, func() {
		if ui.Button(c, t.Cancel).Outline().Clicked() {
			c.After(func() { a.cancelReview(p) })
		}
		confirm := t.Continue
		if session.Push {
			confirm = t.CommitAndPush
		}
		if ui.Button(c, confirm).Disabled(cs.busy || !r.answered()).Clicked() {
			c.After(func() { a.confirmReview(p) })
		}
	})
	if closed {
		c.After(func() { a.cancelReview(p) })
	}
}

// drawCommitReviewStep declares one repository of a review. question is the push of it the
// user is asked about, nil when there is none.
func (a *App) drawCommitReviewStep(c ui.C, p *project, n int, id string, question *core.PushTargetQuestion) {
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
	ui.Column(c.Key(id)).FillWidth().Gap(4).Children(func() {
		ui.Text(c, t.Step(n+1, action, p.commitRepositoryName(id))).Weight(gfx.WeightMedium).Ellipsis()
		ui.Text(c, t.Where(branch, head)).Mono().FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
		if question != nil {
			a.drawCommitTarget(c, r, *question)
		}
		for _, staged := range state.StagedPaths {
			ui.Row(c.Key(staged)).FillWidth().Items(ui.Center).Gap(6).PadX(8).Children(func() {
				ui.Icon(c, fileicons.ForFile(path.Base(staged), a.colors.Dark)).Size(14, 14).Color(a.colors.Subtle)
				ui.Text(c, staged).FontSize(a.theme.Metrics.FontSizeS).Ellipsis().Grow(1)
			})
		}
	})
}

// drawCommitTarget declares the question of a push whose branch tracks one with another
// name: publish the branch under its own name, or push to the branch it tracks.
func (a *App) drawCommitTarget(c ui.C, r *commitReview, q core.PushTargetQuestion) {
	t := a.text.Commit
	choice, picked := r.choices[q.RepositoryID]
	ui.Paragraph(c, t.TracksDifferent(q.LocalBranch, q.Upstream), 3).Color(a.colors.Warning)
	ui.Row(c).FillWidth().Gap(6).Children(func() {
		publish := ui.Button(c.Part("publish"), t.PublishTo(q.Remote, q.LocalBranch))
		upstream := ui.Button(c.Part("upstream"), t.PushTo(q.Upstream))
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

// byteOffsetOfRune is the byte offset in value of its n-th rune, or its length past the end.
// The agent composer still uses it.
func byteOffsetOfRune(value string, n int) int {
	for offset := range value {
		if n == 0 {
			return offset
		}
		n--
	}
	return len(value)
}
