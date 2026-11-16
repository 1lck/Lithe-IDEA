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
// checkbox, its color, name and count, the branch its repository has checked out, and then its
// changes unless it is folded. The Commit button commits every repository with staged changes, as
// IDEA's does, so a group has no button of its own. A nested repository's changes are read-only
// apart from staging; the project's own are the ones the Commit tool window's rows act on.
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
		if a.treeCheckbox(rc, &all, group.Name).Disabled(busy || group.Staging == nil).Clicked() && group.Staging != nil {
			plan := *group.Staging
			rc.After(func() { a.applyStaging(p, id, plan) })
		}
		a.drawRepositorySwatch(rc, p, id)
		ui.Text(rc, group.Name).Color(color).Weight(gfx.WeightMedium).Ellipsis().Shrink(1)
		ui.Text(rc, t.Files(group.FileCount)).Muted().Shrink(0)
		a.drawRepositoryBranch(rc, p, id)
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

// drawRepositoryBranch declares the tag of the branch the repository of a group has checked out,
// the way IDEA's change tree names it after the group's count; there is none until its status is
// read.
func (a *App) drawRepositoryBranch(c ui.C, p *project, id string) {
	branch := p.branchOf(id)
	switch branch {
	case "":
		return
	case "detached":
		branch = i18n.Shared(a.language(), "git.detachedHead")
	}
	ui.Row(c.Part("branch")).Height(logRefChipHeight).Shrink(1).Items(ui.Center).Gap(logRefChipGap).PadX(logRefChipPad).
		Radius(a.theme.Metrics.RadiusItem()).Background(a.colors.Hover).Children(func() {
		ui.Icon(c, icons.GitBranch).Size(logRefIconSize, logRefIconSize).Color(a.colors.Subtle)
		ui.Text(c, branch).FontSize(a.theme.Metrics.FontSizeS).Ellipsis()
	})
}
