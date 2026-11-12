package workbench

import (
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// drawLineHistoryDialog declares the line history of the editor: the commits that touched the
// traced lines, newest first, with the lines Core could not map onto the base commit. A click
// on a commit opens the diff of the file at that commit. State and the trace are in
// gitlinehistory.go.
func (a *App) drawLineHistoryDialog(c ui.C, p *project) {
	h := &p.lineHistory
	lang := a.language()
	open := true
	description := i18n.SharedFormat(lang, "desktop.lineHistory.lines", map[string]string{
		"file":  h.path,
		"start": strconv.Itoa(h.start),
		"end":   strconv.Itoa(h.end),
	})
	closed := ui.ModalWith(c, &open, i18n.Shared(lang, "desktop.lineHistory.title"), ui.ModalSpec{Description: description, Width: reviewDialogWidth, Height: reviewDialogHeight}, func() {
		ui.Column(c).Fill().Gap(8).Children(func() {
			if h.err != "" {
				ui.Paragraph(c, h.err, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
			}
			a.drawLineHistoryNotes(c, h)
			switch {
			case h.busy:
				a.gitEmpty(c, i18n.Shared(lang, "desktop.lineHistory.loading"))
			case h.err != "":
			case len(h.history.Commits) == 0:
				a.gitEmpty(c, i18n.Shared(lang, "desktop.lineHistory.empty"))
			default:
				a.drawLineHistoryRows(c, p, h)
			}
		})
	}, func() {
		if ui.Button(c, i18n.Shared(lang, "desktop.gitReview.close")).Outline().Clicked() {
			open = false
		}
	})
	if closed || !open {
		c.After(func() { a.closeLineHistory(p) })
	}
}

// drawLineHistoryNotes declares what Core says about the trace beside its commits: a truncated
// list, and the lines that have no history of their own.
func (a *App) drawLineHistoryNotes(c ui.C, h *lineHistoryState) {
	lang := a.language()
	size := a.theme.Metrics.FontSizeS
	if h.history.Truncated {
		ui.Paragraph(c, i18n.Shared(lang, "desktop.lineHistory.truncated"), 2).FontSize(size).Color(a.colors.Subtle)
	}
	if inserted := unmappedLinesOf(h.history.UnmappedLines, "new"); inserted != "" {
		ui.Paragraph(c, i18n.SharedFormat(lang, "desktop.lineHistory.inserted", map[string]string{"lines": inserted}), 2).FontSize(size).Color(a.colors.Subtle)
	}
	if rewritten := unmappedLinesOf(h.history.UnmappedLines, "unreliable"); rewritten != "" {
		ui.Paragraph(c, i18n.SharedFormat(lang, "desktop.lineHistory.rewritten", map[string]string{"lines": rewritten}), 2).FontSize(size).Color(a.colors.Subtle)
	}
}

// drawLineHistoryRows declares the traced commits, one row each.
func (a *App) drawLineHistoryRows(c ui.C, p *project, h *lineHistoryState) {
	size := a.theme.Metrics.FontSizeS
	ui.List(c, &h.list, len(h.history.Commits), func(row ui.ListRow) {
		commit := h.history.Commits[row.Index]
		when := time.Unix(commit.AuthorTime, 0).Format("2006-01-02")
		row.Element.FillWidth().Height(reviewRowHeight + 6).Items(ui.Center).Gap(8).PadX(8).
			Hover(ui.Look{}.Background(a.colors.Hover)).Children(func() {
			ui.Text(row.C, shortHash(commit.Hash)).Mono().FontSize(size).Color(a.colors.Accent).Width(64).Shrink(0)
			ui.Text(row.C, commit.Subject).FontSize(size).Ellipsis().Grow(1)
			ui.Text(row.C, commit.AuthorName).FontSize(size).Color(a.colors.Subtle).Ellipsis().Width(120).Shrink(0)
			ui.Text(row.C, when).FontSize(size).Color(a.colors.Subtle).Width(84).Shrink(0)
		})
		if row.Element.Clicked() {
			c.After(func() { a.openLineHistoryCommit(p, commit) })
		}
	})
}
