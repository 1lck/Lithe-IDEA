package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// This file declares the common branches of the popup of a project folder with several
// repositories and the rollback dialog of the actions on them; branch_common.go reads them and
// runs the actions.

// drawCommonBranches declares IDEA's Common Local Branches and Common Remote Branches under the
// repositories of the folder's popup, filtered by query as one repository's sections are. Their
// rows' menus act in every repository. Nothing shows before the first read answered or when no
// branch is common.
func (a *App) drawCommonBranches(c ui.C, p *project, t i18n.BranchMessages, query string) {
	b := &a.branch
	cb := &b.common
	if cb.err != nil && !cb.loading {
		ui.Divider(c)
		ui.Paragraph(c, t.LoadFailed(cb.err.Error()), 4).Color(a.colors.Subtle).PadX(chromeEdge)
		return
	}
	if !cb.loaded {
		return
	}
	var shown [2][]core.GitReference
	listed := false
	for i := range cb.sections {
		shown[i] = cb.sections[i].refs
		if query != "" {
			shown[i] = matchingReferences(shown[i], query)
		}
		listed = listed || len(shown[i]) > 0
	}
	if !listed {
		return
	}
	ui.Divider(c)
	lang := a.language()
	labels := [2]string{i18n.Shared(lang, "desktop.branch.commonLocal"), i18n.Shared(lang, "desktop.branch.commonRemote")}
	current := cb.current()
	for i, key := range commonSectionKeys {
		refs := shown[i]
		if len(refs) == 0 {
			continue
		}
		collapsed := query == "" && b.collapsed[key]
		if a.drawBranchSection(c, key, labels[i], collapsed, query == "") {
			c.After(func() { b.collapsed[key] = !b.collapsed[key] })
		}
		switch {
		case collapsed:
		case query != "":
			for _, r := range refs {
				a.drawBranchRow(c, p, key, r, r.ShortName, 1, r.FullName == current.FullName)
			}
		default:
			s := &cb.sections[i]
			a.drawBranchNodes(c, p, s, key, s.nodes, 1, current)
		}
	}
}

// drawCommonBranchRowMenu declares the items of the menu of common branch r: a new branch from it
// and its checkout, both in every repository, in the order IDEA lists them. The local branch every
// repository is on is not checked out again.
func (a *App) drawCommonBranchRowMenu(c ui.C, menu *ui.MenuItems, p *project, r core.GitReference, current bool) {
	b, t := &a.branch, a.text.Branch
	busy := b.busy || p.log.sync.busy
	if menu.Item(t.NewBranchFrom(r.ShortName)).Clicked() {
		c.After(func() { a.beginCreateCommon(p, r) })
	}
	if !current {
		menu.Separator()
		if menu.Item(t.Checkout).Disabled(busy).Clicked() {
			c.After(func() { a.checkoutCommon(p, r, surfaceMenu) })
		}
	}
}

// drawBranchRollbackDialog declares the dialog of an action on a common branch that failed after
// it ran in some repositories: why it failed, where it ran, which of those a rollback cannot return
// to their branch, and the choice IDEA offers. The focus starts on Don't Roll Back, the first
// control, so Enter changes nothing.
func (a *App) drawBranchRollbackDialog(c ui.C, p *project) {
	b := &a.branch
	w := &b.write
	lang := a.language()
	ran, stuck := w.doneIDs()
	undoable := len(stuck) < len(ran)
	a.branchDialogOf(c, i18n.Shared(lang, "desktop.branch.rollbackTitle"), w.failedIn(lang), func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			ui.Paragraph(c, i18n.SharedFormat(lang, "desktop.branch.rollbackPrompt", map[string]string{"repositories": w.names(lang, ran)}), 4).
				Color(a.colors.Text)
			if len(stuck) > 0 {
				ui.Paragraph(c, i18n.SharedFormat(lang, "desktop.branch.rollbackImpossible", map[string]string{"repositories": w.names(lang, stuck)}), 3).
					FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			}
		})
	}, func() {
		if ui.Button(c, i18n.Shared(lang, "desktop.branch.keepButton")).Outline().Clicked() {
			c.After(a.cancelBranchDialog)
		}
		if ui.Button(c, i18n.Shared(lang, "desktop.branch.rollbackButton")).Disabled(b.busy || !undoable).Clicked() {
			c.After(func() { a.rollbackCommon(p) })
		}
	})
}
