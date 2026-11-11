package workbench

import (
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/githubapi"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// drawPullRequestChecks declares the checks of the selected pull request's head: each one's state
// icon, name and state, and the click that opens its page on GitHub.
func (a *App) drawPullRequestChecks(c ui.C) {
	pr := &a.pullRequests
	lang := a.language()
	size := a.theme.Metrics.FontSizeS
	ui.Text(c, i18n.Shared(lang, "desktop.github.checks")).Weight(gfx.WeightMedium).FontSize(size)
	switch {
	case pr.detail == nil:
		return
	case pr.detail.HeadSHA == nil || *pr.detail.HeadSHA == "":
		ui.Paragraph(c, i18n.Shared(lang, "desktop.github.checksUnavailable"), 2).FontSize(size).Color(a.colors.Subtle)
		return
	case !pr.checksLoaded:
		ui.Text(c, i18n.Shared(lang, "desktop.github.loading")).FontSize(size).Color(a.colors.Subtle)
		return
	}
	if pr.checksErr != "" {
		ui.Paragraph(c, pr.checksErr, 2).FontSize(size).Color(a.theme.Danger)
	}
	if len(pr.checks) == 0 {
		ui.Text(c, i18n.Shared(lang, "desktop.github.noChecks")).FontSize(size).Color(a.colors.Subtle)
		return
	}
	for i, check := range pr.checks {
		icon, color, label := a.checkLook(lang, check)
		k := c.KeyInt(i)
		row := ui.Row(k).FillWidth().Items(ui.Center).Gap(6).PadX(8).
			HitWith(ui.ID(k), check.Name, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}).
			Hover(ui.Look{}.Background(a.colors.Hover)).Children(func() {
			ui.Icon(k, icon).Size(14, 14).Color(color).Shrink(0)
			ui.Text(k, check.Name).FontSize(size).Ellipsis().Grow(1)
			ui.Text(k, label).FontSize(size).Color(color).Shrink(0)
		})
		if row.Clicked() && check.DetailsURL != nil && *check.DetailsURL != "" {
			url := *check.DetailsURL
			c.After(func() { a.openPullRequestInBrowser(url) })
		}
	}
}

// checkLook is the icon, its color and the state text of one check.
func (a *App) checkLook(lang i18n.Language, check githubapi.CheckRun) (gfx.Icon, gfx.Color, string) {
	if !strings.EqualFold(check.Status, "completed") {
		return icons.LoaderCircle, a.colors.Subtle, i18n.Shared(lang, "desktop.github.checkRunning")
	}
	conclusion := ""
	if check.Conclusion != nil {
		conclusion = strings.ToLower(*check.Conclusion)
	}
	switch conclusion {
	case "success":
		return icons.CircleCheck, a.colors.Success, i18n.Shared(lang, "desktop.github.checkPassed")
	case "failure", "timed_out", "cancelled", "action_required", "startup_failure", "error":
		return icons.CircleX, a.theme.Danger, i18n.Shared(lang, "desktop.github.checkFailed")
	case "skipped", "neutral":
		return icons.Minus, a.colors.Subtle, i18n.Shared(lang, "desktop.github.checkSkipped")
	}
	return icons.CircleAlert, a.colors.Warning, i18n.Shared(lang, "desktop.github.checkUnknown")
}

// drawPullRequestThreads declares the review threads of the selected pull request, grouped by file.
// A file's name and a thread's line open the file at that line.
func (a *App) drawPullRequestThreads(c ui.C, p *project) {
	pr := &a.pullRequests
	lang := a.language()
	size := a.theme.Metrics.FontSizeS
	ui.Text(c, i18n.Shared(lang, "desktop.github.reviewThreads")).Weight(gfx.WeightMedium).FontSize(size)
	if pr.threadsErr != "" {
		ui.Paragraph(c, pr.threadsErr, 2).FontSize(size).Color(a.theme.Danger)
	}
	files := groupReviewThreads(pr.threads)
	if len(files) == 0 {
		ui.Text(c, i18n.Shared(lang, "desktop.github.noReviewThreads")).FontSize(size).Color(a.colors.Subtle)
		return
	}
	for i, file := range files {
		k := c.KeyInt(i)
		path := file.path
		if ui.Button(k, path).Ghost().Clicked() {
			c.After(func() { a.openReviewLine(p, path, nil) })
		}
		for j, thread := range file.threads {
			tk := c.KeyInt(i*1000 + j)
			root := thread.root
			ui.Column(tk).FillWidth().Gap(2).PadX(8).Children(func() {
				line := i18n.Shared(lang, "desktop.github.threadOutdated")
				if root.Line != nil {
					line = i18n.SharedFormat(lang, "desktop.github.threadLine", map[string]string{"line": strconv.FormatUint(*root.Line, 10)})
				}
				if ui.Button(tk, line).Ghost().Clicked() {
					c.After(func() { a.openReviewLine(p, root.Path, root.Line) })
				}
				ui.Text(tk, root.Author.Login).FontSize(size).Weight(gfx.WeightMedium)
				ui.Paragraph(tk, root.Body, 6).FontSize(size)
				for _, reply := range thread.replies {
					ui.Column(tk).FillWidth().Gap(2).PadX(16).Children(func() {
						ui.Text(tk, reply.Author.Login).FontSize(size).Color(a.colors.Subtle)
						ui.Paragraph(tk, reply.Body, 6).FontSize(size)
					})
				}
			})
		}
	}
}
