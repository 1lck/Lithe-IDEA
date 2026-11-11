package workbench

import (
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// drawRebaseDialog declares the Rebase from Here dialog: the commits the preview replays, each
// with the action the user chose, or the reasons Core refuses the rebase. State and the calls
// are in git_rebase.go.
func (a *App) drawRebaseDialog(c ui.C, p *project) {
	r := &p.rebase
	lang := a.language()
	open := true
	description := i18n.SharedFormat(lang, "desktop.rebase.description", map[string]string{"hash": shortHash(r.base)})
	closed := ui.ModalWith(c, &open, i18n.Shared(lang, "desktop.rebase.title"), ui.ModalSpec{Description: description, Width: reviewDialogWidth, Height: reviewDialogHeight}, func() {
		ui.Column(c).Fill().Gap(8).Children(func() {
			if r.err != "" {
				ui.Paragraph(c, r.err, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
			}
			switch {
			case r.busy:
				a.gitEmpty(c, i18n.Shared(lang, "desktop.rebase.loading"))
			case !r.preview.Allowed && len(r.preview.Blockers) > 0:
				for _, blocker := range r.preview.Blockers {
					ui.Paragraph(c, blocker.Message, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
				}
			case len(r.preview.Commits) == 0:
				a.gitEmpty(c, i18n.Shared(lang, "desktop.rebase.empty"))
			default:
				a.drawRebaseRows(c, r)
			}
		})
	}, func() {
		if ui.Button(c, i18n.Shared(lang, "desktop.gitReview.close")).Outline().Clicked() {
			open = false
		}
		startable := !r.busy && r.preview.Allowed && len(r.preview.Commits) > 0
		if ui.Button(c, i18n.Shared(lang, "desktop.rebase.start")).Disabled(!startable).Clicked() {
			c.After(func() { a.startRebase(p) })
		}
	})
	if closed || !open {
		c.After(func() { a.closeRebase(p) })
	}
}

// drawRebaseRows declares the commits of the preview, oldest first as they replay. A click on
// an action cycles it through pick, fixup and drop.
func (a *App) drawRebaseRows(c ui.C, r *rebaseState) {
	lang := a.language()
	size := a.theme.Metrics.FontSizeS
	ui.List(c, &r.list, len(r.preview.Commits), func(row ui.ListRow) {
		commit := r.preview.Commits[row.Index]
		action := r.actions[commit.Hash]
		row.Element.FillWidth().Height(reviewRowHeight + 6).Items(ui.Center).Gap(8).PadX(8).Children(func() {
			if ui.Button(row.C, i18n.Shared(lang, "desktop.rebase.action."+action)).Outline().Shrink(0).Clicked() {
				next := rebaseActions[(indexOfAction(action)+1)%len(rebaseActions)]
				row.C.After(func() { r.actions[commit.Hash] = next })
			}
			ui.Text(row.C, shortHash(commit.Hash)).Mono().FontSize(size).Color(a.colors.Accent).Width(64).Shrink(0)
			ui.Text(row.C, firstLine(commit.Message)).FontSize(size).Ellipsis().Grow(1)
		})
	})
}

// indexOfAction is the position of action in rebaseActions, 0 for an unknown one.
func indexOfAction(action string) int {
	for i, a := range rebaseActions {
		if a == action {
			return i
		}
	}
	return 0
}

// drawRebaseBanner declares the rebase the repository holds while it is not finished: its
// status, the conflicted files, and the controls Core allows.
func (a *App) drawRebaseBanner(c ui.C, p *project) {
	s := p.rebase.session
	if s == nil || rebaseDone(s.Status) {
		return
	}
	lang := a.language()
	size := a.theme.Metrics.FontSizeS
	busy := p.rebase.busy
	ui.Column(c).FillWidth().Shrink(0).Gap(4).PadX(8).PadY(4).Children(func() {
		ui.Text(c, i18n.SharedFormat(lang, "desktop.rebase.status", map[string]string{"status": s.Status})).FontSize(size).Weight(gfx.WeightMedium)
		if n := len(s.ConflictedPaths); n > 0 {
			ui.Text(c, i18n.SharedFormat(lang, "desktop.rebase.conflicts", map[string]string{"count": strconv.Itoa(n)})).FontSize(size).Color(a.theme.Danger)
		}
		ui.Row(c).FillWidth().Gap(6).Children(func() {
			if ui.Button(c, i18n.Shared(lang, "desktop.rebase.continue")).Disabled(busy || !s.CanContinue).Clicked() {
				c.After(func() { a.controlRebase(p, "continue") })
			}
			if ui.Button(c, i18n.Shared(lang, "desktop.rebase.skip")).Outline().Disabled(busy || !s.CanSkip).Clicked() {
				c.After(func() { a.controlRebase(p, "skip") })
			}
			if ui.Button(c, i18n.Shared(lang, "desktop.rebase.abort")).Destructive().Outline().Disabled(busy || !s.CanAbort).Clicked() {
				c.After(func() { a.controlRebase(p, "abort") })
			}
		})
	})
	ui.Divider(c)
}

// logRowRebaseMenu declares the commit menu of a log row: Rebase from Here for the commit.
func (a *App) logRowRebaseMenu(p *project, hash string) func(*ui.MenuItems) {
	return func(menu *ui.MenuItems) {
		if menu.Item(i18n.Shared(a.language(), "desktop.rebase.fromHere")).Disabled(p.rebase.busy).Clicked() {
			a.beginRebaseFromHere(p, hash, "")
		}
	}
}
