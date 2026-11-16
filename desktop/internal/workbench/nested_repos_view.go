package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// repositoryGroupGap is the space between the parts of a repository group's line; the rows of the
// group's changes are indented after it (repositoryChangeIndent).
const repositoryGroupGap = 6

// drawRepositoryChanges declares the change list of a workspace with nested repositories as Core
// groups it: one line for all the changes, then a foldable group per repository with changes, in
// Core's order. A group is named after its repository, so a workspace where only one repository has
// changes still shows its name. What each checkbox writes is Core's plan; state and staging are in
// nested_repos.go.
func (a *App) drawRepositoryChanges(c ui.C, p *project) {
	t := a.text.Commit
	n := &p.nested
	if !n.grouped {
		a.gitEmpty(c, a.text.Git.Loading)
		return
	}
	g := n.groups
	if len(g.Groups) == 0 {
		ui.Column(c).Fill().Center().Gap(8).Children(func() {
			ui.Icon(c, icons.Check).Size(20, 20).Color(a.colors.Success)
			ui.Text(c, t.Clean).Color(a.colors.Subtle)
		})
		return
	}
	ui.Scroll(c).Scrollbars().Grow(1).FillWidth().PadY(4).Children(func() {
		a.drawChangeListHeader(c, t.ChangeList, t.Files(g.FileCount), g.AllStaged, g.StageAll != nil, p.commit.busy, func() {
			if g.StageAll != nil {
				a.stageWorkspace(p, *g.StageAll)
			}
		})
		for _, group := range g.Groups {
			a.drawRepositoryGroup(c, p, group)
		}
	})
}

// drawRepositoryGroup declares the group of one repository of the change list: its fold, its
// checkbox, its color, name and count, its commit button, and then its changes unless it is folded.
// A nested repository's changes are read-only apart from staging; the project's own are the ones the
// Commit tool window's rows act on.
func (a *App) drawRepositoryGroup(c ui.C, p *project, group core.WorkspaceChangeGroup) {
	t := a.text.Commit
	lang := a.language()
	busy := p.commit.busy
	own := group.Role == core.RepositoryWorkspace
	id := group.ID
	changes := p.changesOf(id)
	rc := c.Key("nested/" + id)
	all := group.AllStaged
	color := a.colors.Text
	if !own && p.nested.focus == id {
		color = a.colors.Accent
	}
	folded := p.nested.folded[id]
	ui.Row(rc).Height(logItemHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(repositoryGroupGap).PadX(8).Children(func() {
		chevron, foldLabel := icons.ChevronDown, i18n.Shared(lang, "desktop.nested.collapse")
		if folded {
			chevron, foldLabel = icons.ChevronRight, i18n.Shared(lang, "desktop.nested.expand")
		}
		if a.gitIconButton(rc, foldLabel, chevron, false, false) {
			rc.After(func() {
				if p.nested.folded == nil {
					p.nested.folded = map[string]bool{}
				}
				p.nested.folded[id] = !folded
			})
		}
		if ui.Checkbox(rc, &all, "").Label(group.Name).Disabled(busy || group.Staging == nil).Clicked() && group.Staging != nil {
			plan := *group.Staging
			rc.After(func() { a.applyStaging(p, id, plan) })
		}
		a.drawRepositorySwatch(rc, p, id)
		ui.Text(rc, group.Name).Color(color).Weight(gfx.WeightMedium).Ellipsis().Shrink(1)
		ui.Text(rc, t.Files(group.FileCount)).Muted().Shrink(0)
		if own {
			if ui.Button(rc, i18n.Shared(lang, "desktop.nested.commit")).Outline().Disabled(!p.canCommit()).Clicked() {
				rc.After(func() { a.startCommitIn(p, p.projectCommit(), false, surfaceButton) })
			}
			return
		}
		repo, ok := p.nested.repo(id)
		if ui.Button(rc, i18n.Shared(lang, "desktop.nested.commit")).Outline().Disabled(!ok || !p.canCommitNested(*repo)).Clicked() && ok {
			target := a.nestedCommitTarget(p, *repo)
			rc.After(func() { a.startCommitIn(p, target, false, surfaceButton) })
		}
	})
	if folded {
		return
	}
	if group.ParentReference == core.ParentReferenceUnchanged {
		ui.Paragraph(rc, i18n.Shared(lang, "desktop.nested.refUnchanged"), 2).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).
			PadSides(0, 8, 0, repositoryChangeIndent)
	}
	repo, _ := p.nested.repo(id)
	for _, change := range changes {
		if own {
			a.drawCommitChange(rc, p, change, repositoryChangeIndent)
			continue
		}
		toggled, _, _, _ := a.drawChangeRow(rc, change, busy, false, repositoryChangeIndent, func(ui.C) func(*ui.MenuItems) {
			return func(*ui.MenuItems) {}
		})
		if toggled && repo != nil {
			r := *repo
			rc.After(func() { a.stageNestedChange(p, r, change) })
		}
	}
}
