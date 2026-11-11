package workbench

import (
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// drawPullRequestsDialog declares the pull-request panel: the filter, the list of pull requests and
// the selected one's detail with its conversation, the checkout that is reviewed, and the reply box.
// State and the calls are in github_prs.go.
func (a *App) drawPullRequestsDialog(c ui.C, p *project) {
	pr := &a.pullRequests
	lang := a.language()
	open := true
	closed := ui.ModalWith(c, &open, i18n.Shared(lang, "desktop.github.pullRequests"), ui.ModalSpec{Width: reviewDialogWidth, Height: reviewDialogHeight}, func() {
		ui.Column(c).Fill().Gap(8).Children(func() {
			ui.Row(c).FillWidth().Shrink(0).Gap(6).Children(func() {
				for _, filter := range pullRequestFilters {
					label := i18n.Shared(lang, "desktop.github.filter."+filter)
					if ui.Button(c, label).Outline().Disabled(pr.repo == nil && pr.err == "").Clicked() {
						c.After(func() { a.setPullRequestFilter(p, filter) })
					}
				}
			})
			if pr.err != "" {
				ui.Paragraph(c, pr.err, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
			}
			a.drawPullRequestList(c, p)
			a.drawPullRequestDetail(c, p)
		})
	}, func() {
		if ui.Button(c, i18n.Shared(lang, "desktop.gitReview.close")).Outline().Clicked() {
			open = false
		}
	})
	if closed || !open {
		c.After(a.closePullRequests)
	}
}

// drawPullRequestList declares the rows of the current filter; a click selects one.
func (a *App) drawPullRequestList(c ui.C, p *project) {
	pr := &a.pullRequests
	lang := a.language()
	switch {
	case !pr.loaded && pr.repo != nil:
		a.gitEmpty(c, i18n.Shared(lang, "desktop.github.loading"))
		return
	case len(pr.items) == 0:
		a.gitEmpty(c, i18n.Shared(lang, "desktop.github.noPullRequests"))
		return
	}
	size := a.theme.Metrics.FontSizeS
	ui.List(c, &pr.list, len(pr.items), func(row ui.ListRow) {
		item := pr.items[row.Index]
		row.Element.FillWidth().Height(reviewRowHeight + 8).Items(ui.Center).Gap(8).PadX(8).
			Hover(ui.Look{}.Background(a.colors.Hover)).Children(func() {
			ui.Text(row.C, "#"+strconv.FormatUint(item.Number, 10)).Mono().FontSize(size).Color(a.colors.Accent).Width(56).Shrink(0)
			ui.Text(row.C, item.Title).FontSize(size).Ellipsis().Grow(1)
			if item.IsDraft {
				ui.Text(row.C, i18n.Shared(lang, "desktop.github.draft")).FontSize(size).Color(a.colors.Subtle).Shrink(0)
			}
			ui.Text(row.C, item.Author.Login).FontSize(size).Color(a.colors.Subtle).Ellipsis().Width(110).Shrink(0)
		})
		if row.Element.Clicked() {
			number := item.Number
			c.After(func() { a.selectPullRequest(p, number) })
		}
	})
}

// drawPullRequestDetail declares the selected pull request: its state and branches, its
// description, the conversation, and the checkout and reply actions.
func (a *App) drawPullRequestDetail(c ui.C, p *project) {
	pr := &a.pullRequests
	lang := a.language()
	if pr.detail == nil {
		if pr.detailErr != "" {
			ui.Paragraph(c, pr.detailErr, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
		}
		return
	}
	d := pr.detail
	size := a.theme.Metrics.FontSizeS
	ui.Scroll(c).Grow(1).FillWidth().Children(func() {
		ui.Column(c).FillWidth().Gap(6).PadX(8).Children(func() {
			ui.Text(c, d.Title).Weight(gfx.WeightSemibold)
			ui.Text(c, i18n.SharedFormat(lang, "desktop.github.prMeta", map[string]string{
				"state": d.State, "head": d.HeadRef, "base": d.BaseRef, "author": d.Author.Login,
			})).FontSize(size).Color(a.colors.Subtle)
			if d.Body != "" {
				ui.Paragraph(c, d.Body, 12).FontSize(size)
			}
			ui.Row(c).FillWidth().Gap(6).Children(func() {
				if ui.Button(c, i18n.Shared(lang, "desktop.github.openInBrowser")).Outline().Clicked() {
					url := d.URL
					c.After(func() { a.openPullRequestInBrowser(url) })
				}
				if ui.Button(c, i18n.Shared(lang, "desktop.github.reviewCheckout")).Outline().Disabled(pr.busy).Clicked() {
					c.After(func() { a.previewPullRequestCheckout(p) })
				}
			})
			a.drawPullRequestCheckout(c, p)
			for _, comment := range pr.comments {
				ui.Text(c, comment.Author.Login).FontSize(size).Weight(gfx.WeightMedium)
				ui.Paragraph(c, comment.Body, 8).FontSize(size)
			}
			if pr.detailErr != "" {
				ui.Paragraph(c, pr.detailErr, 3).FontSize(size).Color(a.theme.Danger)
			}
			ui.TextField(c, &pr.replyField, i18n.Shared(lang, "desktop.github.reply"), i18n.Shared(lang, "desktop.github.reply")).FillWidth()
			ui.Row(c).FillWidth().Gap(6).Children(func() {
				if ui.Button(c, i18n.Shared(lang, "desktop.github.comment")).Outline().Disabled(pr.replyPending).Clicked() {
					c.After(func() { a.postPullRequestComment(p) })
				}
				if ui.Button(c, i18n.Shared(lang, "desktop.github.approve")).Outline().Disabled(pr.replyPending).Clicked() {
					c.After(func() { a.submitPullRequestReview(p, "APPROVE") })
				}
				if ui.Button(c, i18n.Shared(lang, "desktop.github.requestChanges")).Outline().Disabled(pr.replyPending).Clicked() {
					c.After(func() { a.submitPullRequestReview(p, "REQUEST_CHANGES") })
				}
			})
		})
	})
}

// drawPullRequestCheckout declares the reviewed checkout of the selected pull request: the branch
// Core proposes and the confirm button that runs it, or the conflict that stops it.
func (a *App) drawPullRequestCheckout(c ui.C, p *project) {
	pr := &a.pullRequests
	lang := a.language()
	if pr.preview == nil {
		if pr.checkoutOK {
			ui.Text(c, i18n.Shared(lang, "desktop.github.checkedOutHint")).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		}
		return
	}
	plan := pr.preview.Plan
	ui.Text(c, i18n.SharedFormat(lang, "desktop.github.checkoutBranch", map[string]string{"branch": plan.Branch})).FontSize(a.theme.Metrics.FontSizeS)
	if !plan.Allowed {
		ui.Paragraph(c, i18n.Shared(lang, "desktop.github.branchExists"), 2).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
		return
	}
	if ui.Button(c, i18n.Shared(lang, "desktop.github.confirmCheckout")).Disabled(pr.busy).Clicked() {
		c.After(func() { a.checkoutPullRequest(p) })
	}
}
