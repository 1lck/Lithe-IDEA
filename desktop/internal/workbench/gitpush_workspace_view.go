package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file declares the Push Commits dialog laid out as IDEA's: the repositories with their
// checkboxes, destinations and outgoing commits on the left, the changed files of the selected
// commit on the right, and the tag option under them. State and actions are in
// gitpush_workspace.go.

// workspacePushFilesWidth is the width of the changed files side.
const workspacePushFilesWidth = 320

// workspacePushTagIndexes number the choices of the tag select.
var workspacePushTagIndexes = []int{0, 1}

// drawWorkspacePushDialog declares the Push Commits dialog.
func (a *App) drawWorkspacePushDialog(c ui.C, p *project) {
	s := &p.review.workspacePush
	lang := a.language()
	size := a.theme.Metrics.FontSizeS
	open := true
	spec := ui.ModalSpec{Description: i18n.Shared(lang, "desktop.git.pushAll.description"), Width: reviewDialogWidth, Height: reviewDialogHeight}
	closed := ui.Modal(c, &open, i18n.Shared(lang, "desktop.git.pushAll.title"), spec, func() {
		ui.Column(c).Fill().Gap(8).Children(func() {
			switch {
			case !s.reviewed && s.err != "":
				ui.Paragraph(c, s.err, 4).FontSize(size).Color(a.theme.Danger)
				return
			case !s.reviewed:
				a.gitEmpty(c, i18n.Shared(lang, "git.pushDialog.loading"))
				return
			case len(s.repos) == 0:
				a.gitEmpty(c, i18n.Shared(lang, "desktop.git.pushAll.noRepositories"))
				return
			}
			if s.err != "" {
				ui.Paragraph(c, s.err, 3).FontSize(size).Color(a.theme.Danger)
			}
			ui.Row(c).FillWidth().Grow(1).Gap(8).Children(func() {
				ui.Scroll(c.Part("repositories")).Scrollbars().Grow(1).FillHeight().
					Border(1, a.colors.Line).Radius(a.theme.Metrics.RadiusItem()).Children(func() {
					ui.Column(c).FillWidth().Pad(2).Children(func() {
						for _, repo := range s.repos {
							a.drawWorkspacePushRepository(c.Key(repo.ID), p, repo)
						}
					})
				})
				ui.Column(c.Part("files")).Width(workspacePushFilesWidth).Shrink(0).FillHeight().
					Border(1, a.colors.Line).Radius(a.theme.Metrics.RadiusItem()).Children(func() {
					a.drawWorkspacePushFiles(c, p)
				})
			})
			ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(8).Children(func() {
				label := i18n.Shared(lang, "desktop.git.pushAll.pushTags")
				if ui.Checkbox(c, &s.tagsOn, label).Disabled(s.busy).Clicked() {
					c.After(func() { a.loadWorkspacePush(p) })
				}
				names := []string{i18n.Shared(lang, "desktop.git.pushAll.tagsCurrentBranch"), i18n.Shared(lang, "desktop.git.pushAll.tagsAll")}
				before := s.tags
				ui.Select(c, &s.tags, workspacePushTagIndexes, func(i int) string { return names[i] }).Label(label).Disabled(s.busy || !s.tagsOn)
				if s.tags != before {
					c.After(func() { a.loadWorkspacePush(p) })
				}
				ui.Spacer(c)
				if s.busy {
					if words := a.syncProgressWords(&p.log.sync); words != "" {
						ui.Text(c, words).FontSize(size).Color(a.colors.Subtle).Ellipsis().Shrink(1)
					}
					if sync := &p.log.sync; sync.hasProgress && sync.progress.Percent != nil {
						ui.Progress(c, float32(*sync.progress.Percent)/100).Width(syncProgressWidth)
					}
				}
			})
		})
	}, func() {
		if s.busy {
			if ui.Button(c, a.text.Sync.Cancel).Outline().Clicked() {
				c.After(func() { a.cancelSync(p) })
			}
			return
		}
		if ui.Button(c, i18n.Shared(lang, "desktop.gitReview.cancel")).Outline().Clicked() {
			open = false
		}
		if ui.Button(c, i18n.Shared(lang, "desktop.git.pushAll.push")).Disabled(!s.canPushWorkspace()).Clicked() {
			c.After(func() { a.submitWorkspacePush(p) })
		}
	})
	if (closed || !open) && !s.busy {
		c.After(func() { a.closeWorkspacePush(p) })
	}
}

// drawWorkspacePushRepository declares a repository's row, what its push needs or how it went,
// and the commits it would send under it.
func (a *App) drawWorkspacePushRepository(c ui.C, p *project, repo core.WorkspacePushRepository) {
	s := &p.review.workspacePush
	lang := a.language()
	size := a.theme.Metrics.FontSizeS
	commits := []core.GitCommit(nil)
	if repo.Preview != nil {
		commits = repo.Preview.Commits
	}
	name := s.nameOf(repo.ID)
	ui.Row(c).FillWidth().Height(logItemHeight).Shrink(0).Items(ui.Center).Gap(treelist.Gap).PadX(4).Children(func() {
		a.drawWorkspacePushFold(c, s, repo.ID, name, len(commits) > 0)
		ready := repo.State == core.WorkspacePushReady
		checked := ready && s.checked[repo.ID]
		if a.treeCheckbox(c, &checked, name).Disabled(s.busy || !ready).Clicked() && ready {
			id, value := repo.ID, checked
			c.After(func() { s.checked[id] = value })
		}
		ui.Text(c, name).FontSize(treeFontSize).Weight(gfx.WeightMedium).Ellipsis().Shrink(1)
		a.drawWorkspacePushDestination(c, repo)
	})
	indent := float32(treelist.Gutter + treelist.Disclosure + treelist.Gap)
	if repo.NeedsTarget && repo.Preview != nil {
		a.drawWorkspacePushTargetChoice(c, p, repo, indent)
	}
	if outcome, ok := s.outcomes[repo.ID]; ok {
		text, color := i18n.Shared(lang, "desktop.git.pushAll.pushed"), a.colors.Success
		switch {
		case outcome.skippedFor != "":
			text = i18n.SharedFormat(lang, "desktop.git.pushAll.skipped", map[string]string{"repository": s.nameOf(outcome.skippedFor)})
			color = a.colors.Warning
		case outcome.err != "":
			// Git's own reason is shown as it words it.
			text, color = i18n.SharedFormat(lang, "desktop.git.pushAll.failed", map[string]string{"reason": outcome.err}), a.theme.Danger
		}
		ui.Paragraph(c, text, 3).FontSize(size).Color(color).PadLeft(indent)
	}
	if s.folded[repo.ID] {
		return
	}
	for _, commit := range commits {
		a.drawWorkspacePushCommit(c.Key(commit.Hash), p, repo.ID, commit, indent+float32(treelist.Indent))
	}
	if repo.Preview != nil && repo.Preview.HasMore {
		ui.Text(c, i18n.Shared(lang, "git.pushDialog.moreCommits")).FontSize(size).Muted().PadLeft(indent + float32(treelist.Indent))
	}
}

// drawWorkspacePushFold declares the arrow that shows or hides a repository's commits; a
// repository without commits keeps the arrow's room so the checkboxes line up.
func (a *App) drawWorkspacePushFold(c ui.C, s *workspacePushState, id, name string, foldable bool) {
	k := c.Part("fold")
	if !foldable {
		ui.Row(k).Size(treelist.Disclosure, treelist.Icon).Shrink(0)
		return
	}
	open := !s.folded[id]
	label, chevron := i18n.Shared(a.language(), "native.collapseDirectory"), icons.ChevronDown
	if !open {
		label, chevron = i18n.Shared(a.language(), "native.expandDirectory"), icons.ChevronRight
	}
	slot := ui.Row(k).Size(treelist.Disclosure, treelist.Icon).Shrink(0).Center().
		HitWith(ui.ID(k), label+" "+name, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Expandable: true, Expanded: open, SkipFocus: true})
	slot.Children(func() {
		ui.Icon(c, chevron).Size(12, 12).Color(a.colors.Subtle)
	})
	if slot.Clicked() {
		c.After(func() { s.folded[id] = open })
	}
}

// drawWorkspacePushDestination declares where a repository's branch would go, or why it cannot
// push, after its name: IDEA's "main → origin : main".
func (a *App) drawWorkspacePushDestination(c ui.C, repo core.WorkspacePushRepository) {
	lang := a.language()
	size := a.theme.Metrics.FontSizeS
	muted := func(text string) {
		ui.Text(c, text).FontSize(size).Color(a.colors.Subtle).Ellipsis().Shrink(1)
	}
	switch repo.State {
	case core.WorkspacePushReady, core.WorkspacePushUpToDate:
		pv := repo.Preview
		if pv == nil {
			return
		}
		ui.Text(c, pv.LocalBranch).FontSize(size).Shrink(0)
		ui.Text(c, "→").FontSize(size).Color(a.colors.Subtle).Shrink(0)
		ui.Text(c, pv.Remote+" : "+pv.RemoteBranch).FontSize(size).Color(a.colors.Accent).Ellipsis().Shrink(1)
		if pv.CreatesRemoteBranch {
			ui.Text(c, i18n.Shared(lang, "git.pushDialog.createsRemoteBranch")).FontSize(size).Color(a.colors.Success).Shrink(0)
		}
		if repo.State == core.WorkspacePushUpToDate {
			muted(i18n.Shared(lang, "desktop.git.pushAll.upToDate"))
		}
	case core.WorkspacePushNoRemote:
		if repo.Branch != "" {
			ui.Text(c, repo.Branch).FontSize(size).Shrink(0)
			ui.Text(c, "→").FontSize(size).Color(a.colors.Subtle).Shrink(0)
		}
		ui.Text(c, i18n.Shared(lang, "desktop.git.pushAll.defineRemote")).FontSize(size).Color(a.colors.Accent).Shrink(0)
	case core.WorkspacePushEmpty:
		muted(i18n.Shared(lang, "desktop.git.pushAll.emptyRepository"))
	case core.WorkspacePushDetached:
		muted(i18n.Shared(lang, "desktop.git.pushAll.detachedHead"))
	default:
		// Core's detail is Git's own diagnostic, shown as it words it.
		ui.Text(c, i18n.SharedFormat(lang, "desktop.git.pushAll.readFailed", map[string]string{"reason": repo.Detail})).
			FontSize(size).Color(a.theme.Danger).Ellipsis().Shrink(1)
	}
}

// drawWorkspacePushTargetChoice declares the choice a divergent upstream needs: publish under
// the branch's own name, or push to the upstream it tracks.
func (a *App) drawWorkspacePushTargetChoice(c ui.C, p *project, repo core.WorkspacePushRepository, indent float32) {
	s := &p.review.workspacePush
	lang := a.language()
	size := a.theme.Metrics.FontSizeS
	pv := repo.Preview
	upstream := ""
	if pv.Upstream != nil {
		upstream = *pv.Upstream
	}
	ui.Column(c.Part("target")).FillWidth().Shrink(0).Gap(2).PadLeft(indent).Children(func() {
		ui.Paragraph(c, i18n.SharedFormat(lang, "git.pushDialog.divergentWarning", map[string]string{"branch": pv.LocalBranch, "upstream": upstream}), 3).
			FontSize(size).Color(a.colors.Warning)
		ui.Row(c).FillWidth().Shrink(0).Gap(8).Children(func() {
			id := repo.ID
			publish := s.targets[id] == core.PushTargetPublish
			if ui.Checkbox(c, &publish, i18n.SharedFormat(lang, "git.pushDialog.publishSameName", map[string]string{"remote": pv.Remote, "branch": pv.LocalBranch})).Disabled(s.busy).Clicked() {
				c.After(func() { a.chooseWorkspacePushTarget(p, id, core.PushTargetPublish) })
			}
			toUpstream := s.targets[id] == core.PushTargetUpstream
			if ui.Checkbox(c, &toUpstream, i18n.SharedFormat(lang, "git.pushDialog.pushToUpstream", map[string]string{"branch": upstream})).Disabled(s.busy).Clicked() {
				c.After(func() { a.chooseWorkspacePushTarget(p, id, core.PushTargetUpstream) })
			}
		})
	})
}

// drawWorkspacePushCommit declares one outgoing commit; clicking it lists its changed files.
func (a *App) drawWorkspacePushCommit(c ui.C, p *project, id string, commit core.GitCommit, indent float32) {
	s := &p.review.workspacePush
	size := a.theme.Metrics.FontSizeS
	selected := s.selRepo == id && s.selCommit == commit.Hash
	row := ui.Row(c).FillWidth().Height(reviewRowHeight+2).Shrink(0).Items(ui.Center).Gap(8).
		PadSides(0, 8, 0, indent).Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(c), commit.Subject, gfx.HitOptions{Cursor: gfx.PointerCursorHand})
	if selected {
		row = row.Background(a.colors.Selection)
	} else {
		row = row.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	row.Children(func() {
		ui.Text(c, commit.Subject).FontSize(treeFontSize).Ellipsis().Grow(1)
		ui.Text(c, commit.ShortHash).Mono().FontSize(size).Color(a.colors.Subtle).Shrink(0)
	})
	if row.Clicked() {
		hash := commit.Hash
		c.After(func() { a.selectWorkspacePushCommit(p, id, hash) })
	}
}

// drawWorkspacePushFiles declares the changed files of the selected commit; opening one shows
// its diff in that commit.
func (a *App) drawWorkspacePushFiles(c ui.C, p *project) {
	s := &p.review.workspacePush
	lang := a.language()
	switch s.fileState {
	case logFilesIdle:
		a.gitEmpty(c, i18n.Shared(lang, "desktop.git.pushAll.noCommitSelected"))
	case logFilesLoading:
		a.gitEmpty(c, i18n.Shared(lang, "desktop.git.pushAll.loadingFiles"))
	case logFilesFailed:
		ui.Paragraph(c, i18n.SharedFormat(lang, "desktop.git.pushAll.filesFailed", map[string]string{"reason": s.filesErr}), 4).
			FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger).Pad(8)
	default:
		if s.files.empty() {
			a.gitEmpty(c, i18n.Shared(lang, "desktop.git.pushAll.noChangedFiles"))
			return
		}
		a.drawSavedFileList(c, &s.files, func(file savedPath) { a.openWorkspacePushFile(p, file.path) })
	}
}
