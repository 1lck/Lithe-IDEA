package workbench

import (
	"path"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/components"
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
	v.begin()
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
		a.drawChangeListBar(c, p)
		a.drawCommitBody(c, v, func() ui.Box { return a.drawCommitChanges(c, p) },
			func() ui.Box { return a.drawCommitArea(c, p) })
	})
	a.drawGeneratedMessageConfirm(c, p)
	a.drawChangeListDialog(c, p)
}

// drawCommitToolbar declares the buttons over the change list, as on macOS: read the status
// again, roll back the active ChangeList's changes, stage or unstage all of them, preview the
// first one, and the branch that is checked out.
func (a *App) drawCommitToolbar(c ui.C, p *project) {
	cs, t, lang := &p.commit, a.text.Commit, a.language()
	changes := p.activeChanges()
	_, review := a.reviewKernel()
	ui.Row(c).Height(logToolbarHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(4).PadX(6).Children(func() {
		if a.gitIconButton(c, t.Refresh, icons.RefreshCw, false, false) {
			c.After(func() { a.refreshChanges(p) })
		}
		if a.gitIconButton(c, i18n.Shared(lang, "git.rollback.title"), icons.Undo2, false, cs.busy || !review || len(changes) == 0) {
			c.After(func() { a.openRollback(p, changes) })
		}
		label, icon := t.StageAll, icons.Plus
		if allStaged(changes) {
			label, icon = t.UnstageAll, icons.Minus
		}
		if a.gitIconButton(c, label, icon, false, cs.busy || !p.listsReady() || !hasToggleable(changes)) {
			c.After(func() { a.stageAll(p, surfaceButton) })
		}
		if a.gitIconButton(c, i18n.Shared(lang, "git.previewFirstChange"), icons.Eye, false, !review || len(changes) == 0) {
			first := changes[0]
			c.After(func() { a.openChange(p, first) })
		}
		ui.Spacer(c)
		if branch := p.git.branch(); branch != "" {
			ui.Text(c, branch).Muted().Ellipsis().Shrink(1)
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
		a.drawRebaseBanner(c, p)
		if p.lists.inUse() {
			a.drawChangeListSections(c, p)
			return
		}
		if len(changes) == 0 {
			ui.Column(c).Fill().Center().Gap(8).Children(func() {
				ui.Icon(c, icons.Check).Size(20, 20).Color(a.colors.Success)
				ui.Text(c, t.Clean).Color(a.colors.Subtle)
			})
			a.drawNestedRepos(c, p)
			return
		}
		all := append(append([]core.GitChange(nil), changes...), nestedChanges(p)...)
		a.drawChangeRows(c, t.ChangeList, t.Files(fileCount(all)), all, cs.busy,
			func() { a.stageAllAcrossRepositories(p) },
			func(change core.GitChange) { a.drawCommitChange(c, p, change) })
		a.drawNestedRepos(c, p)
	})
}

// drawCommitChange declares the row of one change of the project's repository.
func (a *App) drawCommitChange(c ui.C, p *project, change core.GitChange) {
	toggled, opened := a.drawChangeRow(c, change, p.commit.busy, func(rowC ui.C) func(*ui.MenuItems) {
		return a.changeMenuItems(rowC, p, change)
	})
	if toggled {
		c.After(func() { a.stageChange(p, change) })
	}
	if opened {
		c.After(func() { a.openChange(p, change) })
	}
}

// drawChangeRows declares the rows of a change list in a scroll: the checkbox that stages or
// unstages them all, with the list's title and size, over a row per change.
func (a *App) drawChangeRows(c ui.C, title, size string, changes []core.GitChange, busy bool, toggleAll func(), row func(core.GitChange)) {
	ui.Scroll(c).Grow(1).FillWidth().PadY(4).Children(func() {
		ui.Row(c).Height(logItemHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
			all := allStaged(changes)
			if ui.Checkbox(c, &all, "").Label(title).Disabled(busy || !hasToggleable(changes)).Clicked() {
				c.After(toggleAll)
			}
			ui.Text(c, title).Weight(gfx.WeightMedium).Ellipsis().Shrink(1)
			ui.Text(c, size).Muted().Shrink(0)
		})
		for _, change := range changes {
			row(change)
		}
	})
}

// drawChangeRow declares the row of one change: its checkbox, its icon, its name and folder,
// and whether it is staged, with the context menu menu builds. It reports a click on the
// checkbox and a double click on the row.
func (a *App) drawChangeRow(c ui.C, change core.GitChange, busy bool, menu func(ui.C) func(*ui.MenuItems)) (toggled, opened bool) {
	t := a.text.Commit
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
	rowC := c.Key(change.Path)
	row := ui.Row(rowC).Height(logItemHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(6).
		PadSides(0, 8, 0, float32(8+logIndent)).Hover(ui.Look{}.Background(a.colors.Hover)).
		HitWith(ui.ID(rowC), change.Path, gfx.HitOptions{Cursor: gfx.PointerCursorHand})
	ui.ContextMenu(rowC, row, menu(rowC))
	row.Children(func() {
		staged := change.Staged
		toggled = ui.Checkbox(c, &staged, "").Label(label).Disabled(busy || !change.CanToggleStaging).Clicked()
		icon := fileicons.ForFile(path.Base(change.Path), a.colors.Dark)
		if folder {
			icon = fileicons.ForDirectory(path.Base(strings.TrimSuffix(change.Path, "/")), a.colors.Dark)
		}
		ui.Icon(c, icon).Size(14, 14).Color(a.colors.Subtle)
		ui.Text(c, name).Color(tint).Ellipsis().Shrink(0).MaxWidth(320)
		ui.Text(c, strings.TrimSuffix(dir, "/")).Muted().Ellipsis().Grow(1)
		ui.Text(c, state).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
	})
	return toggled, row.DoubleClicked()
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

// hasToggleable reports that some of the changes can be staged or unstaged.
func hasToggleable(changes []core.GitChange) bool {
	for _, change := range changes {
		if change.CanToggleStaging {
			return true
		}
	}
	return false
}

// fileCount is the number of files the changes stand for: an untracked folder shown as
// one change counts each file in it.
func fileCount(changes []core.GitChange) int {
	n := 0
	for _, change := range changes {
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
	return a.drawCommitAreaOf(c, p, commitArea{
		target: p.projectCommit(),
		staged: p.activeStagedCount(),
		ready:  p.canCommit,
		lists:  true,
	})
}

// commitArea is what a commit area commits: the checkout of target, with staged changes in
// it and ready saying the buttons may start a commit. lists says it is the project's own
// checkout, which is held to the active ChangeList and has its message generated.
type commitArea struct {
	target commitTarget
	staged int
	ready  func() bool
	lists  bool
}

// drawCommitAreaOf declares the commit area of area: amend, the staged count, the message, how
// the last run ended, the buttons that commit, and commit and push, and the commit options.
func (a *App) drawCommitAreaOf(c ui.C, p *project, area commitArea) ui.Box {
	cs, t := area.target.state, a.text.Commit
	return ui.Column(c).FillWidth().Clip().Pad(8).Gap(6).Children(func() {
		ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(6).Children(func() {
			ui.Checkbox(c, &cs.amend, t.Amend).Disabled(cs.busy)
			ui.Spacer(c)
			ui.Text(c, t.Staged(area.staged)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
		})
		if area.lists && p.otherStaged() {
			ui.Paragraph(c, i18n.Shared(a.language(), "native.otherChangeListsHaveStagedFilesUnstageThemBeforeCommittingTheCurrentChangeList"), 2).
				FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
		}
		message := ui.TextArea(c, &cs.messageField, t.MessageLabel, t.MessagePlaceholder).FillWidth().Grow(1).Disabled(cs.busy)
		if message.Shortcut(ui.Primary, "enter") {
			c.After(func() {
				if area.ready() {
					a.startCommitIn(p, area.target, false, surfaceShortcut)
				}
			})
		}
		if cs.attempt != nil {
			a.drawCommitResults(c, p, area.target)
		}
		ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(6).Children(func() {
			label := t.Commit
			if cs.busy {
				label = t.Committing
			}
			ready := area.ready()
			if ui.Button(c, label).Disabled(!ready).Clicked() {
				c.After(func() { a.startCommitIn(p, area.target, false, surfaceButton) })
			}
			if ui.Button(c, t.CommitAndPush).Outline().Disabled(!ready).Clicked() {
				c.After(func() { a.startCommitIn(p, area.target, true, surfaceButton) })
			}
			if area.lists {
				a.drawGenerateCommitButton(c, p)
			}
			ui.Spacer(c)
			a.drawCommitOptions(c, cs, area.lists)
		})
	})
}

// drawCommitOptions declares the gear at the end of the commit buttons and the options it
// opens, grouped as the commit options of other IDEs are: Git (the sign-off, whether the
// parent repositories' references are updated, and the author of the next commit) and, where
// the message can be generated, AI (the instructions handed to the generation, and the way to
// the AI settings). The gear is highlighted while the sign-off or the author is set, so a
// commit under another name is never a surprise.
func (a *App) drawCommitOptions(c ui.C, cs *commitState, generates bool) {
	t, lang := a.text.Commit, a.language()
	button, clicked := a.gitToolButton(c, t.Options, icons.Settings, cs.signOff || cs.authorText() != "", false)
	if clicked {
		cs.optionsOpen = !cs.optionsOpen
	}
	// The options open beside the commit panel, over the editor, rather than over the message
	// they belong to; they line up with the gear at the bottom and grow upwards, and open on
	// the left when the panel is docked at the window's right edge.
	spec := ui.PopoverSpec{Side: components.PopoverRight, Align: ui.End, Width: 320}
	ui.PopoverWith(c, button, spec, &cs.optionsOpen, func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			a.commitOptionHeading(c, i18n.Shared(lang, "desktop.commit.optionsGit"))
			ui.Row(c).FillWidth().Items(ui.Center).Gap(4).Children(func() {
				ui.Text(c, t.Author).Shrink(0)
				a.commitOptionHelp(c, t.AuthorHelp)
			})
			ui.TextField(c, &cs.author, t.Author, t.AuthorPlaceholder).FillWidth().Disabled(cs.busy)
			ui.Row(c).FillWidth().Items(ui.Center).Gap(4).Children(func() {
				// The checkbox writes a click into signOff only when it is asked, after Disabled.
				if ui.Checkbox(c, &cs.signOff, t.SignOff).Disabled(cs.busy).Changed() {
					a.performed("git.commit.signOff", surfaceButton)
				}
				a.commitOptionHelp(c, t.SignOffHelp)
			})
			ui.Row(c).FillWidth().Items(ui.Center).Gap(4).Children(func() {
				ui.Checkbox(c, &cs.parents, i18n.Shared(lang, "git.workspaceCommit.parents")).Disabled(cs.busy)
				a.commitOptionHelp(c, i18n.Shared(lang, "desktop.commit.parentsHelp"))
			})
			if !generates {
				return
			}
			a.commitOptionHeading(c, i18n.Shared(lang, "desktop.commit.optionsAI"))
			ui.Row(c).FillWidth().Items(ui.Center).Gap(4).Children(func() {
				label := i18n.Shared(lang, "desktop.commit.instructions")
				ui.Text(c, label).Shrink(0)
				a.commitOptionHelp(c, i18n.Shared(lang, "desktop.commit.instructionsHelp"))
				ui.Spacer(c)
				if ui.Button(c, i18n.Shared(lang, "desktop.commit.openSettings")).Ghost().Shrink(0).Clicked() {
					c.After(func() {
						cs.optionsOpen = false
						a.openSettingsPage(surfaceButton, settingsAI)
					})
				}
			})
			field := ui.TextArea(c, a.instructionsDraft(), i18n.Shared(lang, "desktop.commit.instructions"), i18n.Shared(lang, "desktop.commit.instructionsPlaceholder")).
				FillWidth().Height(88)
			// Typing delivers no click, and After runs only after a paint that does, so the
			// edit is stored in this paint.
			if field.Changed() {
				a.storeInstructionsDraft()
			}
		})
	})
}

// commitOptionHeading declares the heading of one group of the commit options.
func (a *App) commitOptionHeading(c ui.C, title string) {
	ui.Text(c, title).FontSize(a.theme.Metrics.FontSizeS).Weight(gfx.WeightMedium).Color(a.colors.Subtle)
}

// commitOptionHelp declares the ⓘ that explains a commit option.
func (a *App) commitOptionHelp(c ui.C, help string) {
	ui.Button(c, i18n.Shared(a.language(), "native.moreInformation")).Icon(icons.Info).IconOnly().Ghost().Size(18, 18).Tooltip(help)
}

// drawCommitResults declares how each repository of the last run in the checkout of target
// ended, and the buttons that forget the results or continue the run.
func (a *App) drawCommitResults(c ui.C, p *project, target commitTarget) {
	cs, t := target.state, a.text.Commit
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
				ui.Text(c, t.Result(target.repositoryName(id), a.commitStatusLabel(result.Status))).Color(tint).Ellipsis().Grow(1)
			})
			if result.Detail != "" {
				ui.Paragraph(c.Key(id+"/detail"), result.Detail, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			}
		}
		ui.Row(c).FillWidth().Items(ui.Center).Gap(6).Children(func() {
			if ui.Button(c, t.Dismiss).Ghost().Clicked() {
				c.After(func() { a.dismissResults(cs) })
			}
			if cs.retryable() && ui.Button(c, t.Retry).Outline().Disabled(cs.busy).Clicked() {
				c.After(func() { a.retryCommit(p, target) })
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

// drawCommitReviews declares the review that is open, of the project's repository or of a
// linked worktree, over the workbench wherever the commit was started.
func (a *App) drawCommitReviews(c ui.C, p *project) {
	if p.commit.review != nil {
		a.drawCommitReview(c.Key("commit-review"), p, p.projectCommit())
		return
	}
	// One review is shown at a time, the worktrees' in the order of their paths; the next
	// opens when it closes.
	first := ""
	for path, cs := range p.worktrees.commits {
		if cs.review != nil && (first == "" || path < first) {
			first = path
		}
	}
	if first != "" {
		a.drawCommitReview(c.Key("commit-review/"+first), p, p.worktreeCommit(first))
	}
}

// drawCommitReview declares the review of a plan in the checkout of target: the message, then
// each repository in the order the plan runs them with where it commits, what it pushes and
// the files it takes.
func (a *App) drawCommitReview(c ui.C, p *project, target commitTarget) {
	cs, t := target.state, a.text.Commit
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
			if session.Author != "" {
				ui.Paragraph(c, t.AuthorLine(session.Author), 2)
			}
			if session.SignOff {
				ui.Text(c, t.SignOffNote)
			}
			ui.Scroll(c).FillWidth().MaxHeight(commitReviewHeight).Children(func() {
				ui.Column(c).FillWidth().Gap(10).Children(func() {
					for n, id := range session.OrderedIDs {
						index, asked := questions[id]
						var question *core.PushTargetQuestion
						if asked {
							question = &r.prep.PushTargetQuestions[index]
						}
						a.drawCommitReviewStep(c, target, n, id, question)
					}
				})
			})
		})
	}, func() {
		if ui.Button(c, t.Cancel).Outline().Clicked() {
			c.After(func() { a.cancelReview(cs) })
		}
		confirm := t.Continue
		if session.Push {
			confirm = t.CommitAndPush
		}
		if ui.Button(c, confirm).Disabled(cs.busy || !r.answered()).Clicked() {
			c.After(func() { a.confirmReview(p, target) })
		}
	})
	if closed {
		c.After(func() { a.cancelReview(cs) })
	}
}

// drawCommitReviewStep declares one repository of a review in the checkout of target.
// question is the push of it the user is asked about, nil when there is none.
func (a *App) drawCommitReviewStep(c ui.C, target commitTarget, n int, id string, question *core.PushTargetQuestion) {
	r, t := target.state.review, a.text.Commit
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
		ui.Text(c, t.Step(n+1, action, target.repositoryName(id))).Weight(gfx.WeightMedium).Ellipsis()
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
