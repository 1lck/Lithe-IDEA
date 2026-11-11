package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// drawNestedRepos declares the changes of the repositories nested in the project folder, one
// group per repository with changes, below the project's own. The group a folder of the tree
// asked for is marked. State and staging are in nested_repos.go.
func (a *App) drawNestedRepos(c ui.C, p *project) {
	var groups []nestedRepo
	for _, repo := range p.nested.repos {
		if len(repo.changes) > 0 {
			groups = append(groups, repo)
		}
	}
	if len(groups) == 0 {
		return
	}
	t := a.text.Commit
	lang := a.language()
	busy := p.commit.busy
	ui.Scroll(c).Grow(1).FillWidth().PadY(4).Children(func() {
		for _, repo := range groups {
			rc := c.Key("nested/" + repo.id)
			all := allStaged(repo.changes)
			color := a.colors.Text
			if p.nested.focus == repo.id {
				color = a.colors.Accent
			}
			ui.Row(rc).Height(logItemHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
				if ui.Checkbox(rc, &all, "").Label(repo.id).Disabled(busy || !hasToggleable(repo.changes)).Clicked() {
					rc.After(func() { a.stageNestedChanges(p, repo, repo.changes, allStaged(repo.changes)) })
				}
				ui.Text(rc, repo.id).Color(color).Weight(gfx.WeightMedium).Ellipsis().Shrink(1)
				ui.Text(rc, t.Files(fileCount(repo.changes))).Muted().Shrink(0)
				if ui.Button(rc, i18n.Shared(lang, "desktop.nested.commit")).Outline().Disabled(!p.canCommitNested(repo)).Clicked() {
					rc.After(func() { a.startCommitIn(p, a.nestedCommitTarget(p, repo), false, surfaceButton) })
				}
			})
			if !p.submoduleReferenceChanged(repo.id) {
				ui.Paragraph(rc, i18n.Shared(lang, "desktop.nested.refUnchanged"), 2).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).PadX(8)
			}
			for _, change := range repo.changes {
				toggled, _ := a.drawChangeRow(rc, change, busy, func(ui.C) func(*ui.MenuItems) {
					return func(*ui.MenuItems) {}
				})
				if toggled {
					rc.After(func() { a.stageNestedChange(p, repo, change) })
				}
			}
		}
	})
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
