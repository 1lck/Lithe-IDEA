package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// drawRepositoryChanges declares the change list of a workspace with nested repositories: one line
// for all the changes, then a foldable group per repository with changes, the project's own first.
// A group is named after its repository, so a workspace where only one repository has changes still
// shows its name. State and staging are in nested_repos.go.
func (a *App) drawRepositoryChanges(c ui.C, p *project) {
	t := a.text.Commit
	changes := p.git.status.Changes
	all := append(append([]core.GitChange(nil), changes...), nestedChanges(p)...)
	if len(all) == 0 {
		ui.Column(c).Fill().Center().Gap(8).Children(func() {
			ui.Icon(c, icons.Check).Size(20, 20).Color(a.colors.Success)
			ui.Text(c, t.Clean).Color(a.colors.Subtle)
		})
		return
	}
	ui.Scroll(c).Grow(1).FillWidth().PadY(4).Children(func() {
		a.drawChangeListHeader(c, t.ChangeList, t.Files(fileCount(all)), all, p.commit.busy, func() { a.stageAllAcrossRepositories(p) })
		if len(changes) > 0 {
			a.drawRepositoryGroup(c, p, ownRepositoryGroup(p), true)
		}
		for _, repo := range p.nested.repos {
			if len(repo.changes) > 0 {
				a.drawRepositoryGroup(c, p, repo, false)
			}
		}
	})
}

// ownRepositoryGroup is the project's own repository as a group of the change list: the ID the
// group keys and the repository commit use, and the project's status changes.
func ownRepositoryGroup(p *project) nestedRepo {
	return nestedRepo{id: commitRepositoryID, root: p.git.repositoryRoot(p.root), changes: p.git.status.Changes}
}

// drawRepositoryGroup declares the group of one repository of the change list: its fold, its
// checkbox, its name and count, its commit button, and then its changes unless it is folded. A
// nested repository's changes are read-only apart from staging; the project's own are the ones the
// Commit tool window's rows act on.
func (a *App) drawRepositoryGroup(c ui.C, p *project, repo nestedRepo, own bool) {
	t := a.text.Commit
	lang := a.language()
	busy := p.commit.busy
	rc := c.Key("nested/" + repo.id)
	all := allStaged(repo.changes)
	name := p.repositoryName(repo.id)
	color := a.colors.Text
	if !own && p.nested.focus == repo.id {
		color = a.colors.Accent
	}
	folded := p.nested.folded[repo.id]
	ui.Row(rc).Height(logItemHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
		chevron, foldLabel := icons.ChevronDown, i18n.Shared(lang, "desktop.nested.collapse")
		if folded {
			chevron, foldLabel = icons.ChevronRight, i18n.Shared(lang, "desktop.nested.expand")
		}
		if a.gitIconButton(rc, foldLabel, chevron, false, false) {
			rc.After(func() {
				if p.nested.folded == nil {
					p.nested.folded = map[string]bool{}
				}
				p.nested.folded[repo.id] = !folded
			})
		}
		if ui.Checkbox(rc, &all, "").Label(name).Disabled(busy || !hasToggleable(repo.changes)).Clicked() {
			rc.After(func() { a.stageNestedChanges(p, repo, repo.changes, allStaged(repo.changes)) })
		}
		ui.Text(rc, name).Color(color).Weight(gfx.WeightMedium).Ellipsis().Shrink(1)
		ui.Text(rc, t.Files(fileCount(repo.changes))).Muted().Shrink(0)
		if own {
			if ui.Button(rc, i18n.Shared(lang, "desktop.nested.commit")).Outline().Disabled(!p.canCommit()).Clicked() {
				rc.After(func() { a.startCommitIn(p, p.projectCommit(), false, surfaceButton) })
			}
			return
		}
		if ui.Button(rc, i18n.Shared(lang, "desktop.nested.commit")).Outline().Disabled(!p.canCommitNested(repo)).Clicked() {
			rc.After(func() { a.startCommitIn(p, a.nestedCommitTarget(p, repo), false, surfaceButton) })
		}
	})
	if folded {
		return
	}
	if !own && !p.submoduleReferenceChanged(repo.id) {
		ui.Paragraph(rc, i18n.Shared(lang, "desktop.nested.refUnchanged"), 2).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).PadX(8)
	}
	for _, change := range repo.changes {
		if own {
			a.drawCommitChange(rc, p, change)
			continue
		}
		toggled, _, _, _ := a.drawChangeRow(rc, change, busy, false, func(ui.C) func(*ui.MenuItems) {
			return func(*ui.MenuItems) {}
		})
		if toggled {
			rc.After(func() { a.stageNestedChange(p, repo, change) })
		}
	}
}

// nestedChanges are the changes of every nested repository, in the order the repositories list.
func nestedChanges(p *project) []core.GitChange {
	var out []core.GitChange
	for _, repo := range p.nested.repos {
		out = append(out, repo.changes...)
	}
	return out
}

// stageAllAcrossRepositories is the project's stage-all checkbox: when every change of every
// repository is staged it unstages them all, otherwise it stages them all.
func (a *App) stageAllAcrossRepositories(p *project) {
	all := allStaged(append(append([]core.GitChange(nil), p.git.status.Changes...), nestedChanges(p)...))
	a.stageAllRepositories(p, !all)
}
