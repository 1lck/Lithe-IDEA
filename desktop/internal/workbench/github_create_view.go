package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// drawCreatePullRequestDialog declares the dialog that creates a pull request: the title and the
// Markdown description (which the AI draft fills), the base branch picked from the repository's
// branches, the head branch, the draft choice, and why creation is blocked when it is.
func (a *App) drawCreatePullRequestDialog(c ui.C, p *project) {
	cr := &a.prCreate
	lang := a.language()
	open := true
	closed := ui.ModalWith(c, &open, i18n.Shared(lang, "desktop.github.newPullRequest"), ui.ModalSpec{Width: reviewDialogWidth, Height: reviewDialogHeight}, func() {
		ui.Column(c).Fill().Gap(8).Children(func() {
			if cr.err != "" {
				ui.Paragraph(c, cr.err, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
			}
			if cr.blocked != "" {
				ui.Paragraph(c, cr.blocked, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
			}
			ui.TextField(c, &cr.title, i18n.Shared(lang, "desktop.github.prTitle"), i18n.Shared(lang, "desktop.github.prTitle")).FillWidth()
			ui.TextArea(c, &cr.body, i18n.Shared(lang, "desktop.github.prBody"), i18n.Shared(lang, "desktop.github.prBody")).FillWidth().Grow(1)
			ui.Row(c).FillWidth().Shrink(0).Gap(8).Items(ui.Center).Children(func() {
				ui.Text(c, i18n.SharedFormat(lang, "desktop.github.prBranches", map[string]string{"head": cr.head, "base": cr.base}))
				if ui.Button(c, i18n.Shared(lang, "desktop.github.nextBase")).Outline().Disabled(len(cr.branches) == 0 || cr.busy).Clicked() {
					c.After(func() { a.cycleCreateBase(p) })
				}
				ui.Checkbox(c, &cr.draft, i18n.Shared(lang, "desktop.github.draftChoice")).Disabled(cr.busy)
			})
		})
	}, func() {
		if ui.Button(c, i18n.Shared(lang, "desktop.gitReview.cancel")).Outline().Clicked() {
			open = false
		}
		if ui.Button(c, i18n.Shared(lang, "desktop.github.generateDescription")).Outline().Disabled(cr.generating || cr.busy || cr.blocked != "").Clicked() {
			c.After(func() { a.generatePullRequestDescription(p) })
		}
		if ui.Button(c, i18n.Shared(lang, "desktop.github.createPullRequest")).Disabled(cr.busy || cr.blocked != "" || cr.title.Text() == "").Clicked() {
			c.After(func() { a.submitCreatePullRequest(p) })
		}
	})
	if closed || !open {
		c.After(a.closeCreatePullRequest)
	}
}

// cycleCreateBase moves the base branch to the next branch of the repository.
func (a *App) cycleCreateBase(p *project) {
	cr := &a.prCreate
	if len(cr.branches) == 0 {
		return
	}
	next := 0
	for i, b := range cr.branches {
		if b == cr.base {
			next = (i + 1) % len(cr.branches)
			break
		}
	}
	cr.base = cr.branches[next]
}
