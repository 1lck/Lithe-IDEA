package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

// This file declares what the log tab's sync operations show: the status line of a running
// fetch or update, in the log page, and the dialogs they open, in the overlay page. The
// operations themselves are in gitsync.go.

// syncStatusHeight is the height of the status line under the log's filter bar.
const syncStatusHeight = 28

// syncProgressWidth is the width of the progress bar of the running operation's phase.
const syncProgressWidth = 120

// syncChoiceIndexes number the choices of the fetch dialog's selects, which hold an index
// into syncSubmoduleChoices and syncTagChoices.
var syncChoiceIndexes = []int{0, 1, 2, 3}

// syncProgressWords names the Git phase the running operation is in, empty before Git has
// printed one.
func (a *App) syncProgressWords(s *syncState) string {
	if !s.hasProgress {
		return ""
	}
	percent := -1
	if s.progress.Percent != nil {
		percent = *s.progress.Percent
	}
	return a.text.Sync.Progress(s.progress.Stage, percent)
}

// drawSyncStatus declares the line that says a fetch or update is running, with its Cancel
// button. It declares nothing while no operation runs.
func (a *App) drawSyncStatus(c ui.C, p *project) {
	s := &p.log.sync
	if !s.busy {
		return
	}
	ui.Row(c).Height(syncStatusHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(8).PadX(8).Background(a.colors.Hover).Children(func() {
		ui.Text(c, s.label).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Text).Ellipsis().Shrink(1)
		ui.Spacer(c)
		if words := a.syncProgressWords(s); words != "" {
			ui.Text(c, words).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1)
		}
		if s.hasProgress && s.progress.Percent != nil {
			ui.Progress(c, float32(*s.progress.Percent)/100).Width(syncProgressWidth)
		}
		if ui.Button(c, a.text.Sync.Cancel).Outline().Clicked() {
			c.After(func() { a.cancelSync(p) })
		}
	})
}

// drawSyncDialog declares the dialog of the log tab's sync operations that is open.
func (a *App) drawSyncDialog(c ui.C, p *project) {
	switch p.log.sync.dialog {
	case syncDialogFetch:
		a.drawFetchDialog(c, p)
	case syncDialogDiverged:
		a.drawDivergedDialog(c, p)
	}
}

// syncDialogOf shows one dialog of the sync operations with its words, and closes it when
// the user dismisses it.
func (a *App) syncDialogOf(c ui.C, p *project, title, description string, body, footer func()) {
	open := true
	if ui.ModalWith(c, &open, title, ui.ModalSpec{Description: description, Width: branchDialogWidth}, body, footer) {
		c.After(func() { p.log.sync.dialog = syncDialogNone })
	}
}

// drawFetchDialog declares the options of one fetch.
func (a *App) drawFetchDialog(c ui.C, p *project) {
	s, t := &p.log.sync, a.text.Sync
	submitted := false
	ready := !s.settingsLoading && (!s.onlyRemote || s.remote.Text() != "")
	a.syncDialogOf(c, p, t.FetchTitle, t.FetchPrompt, func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			if s.settingsLoading {
				// No control is offered before the repository's own choices are known, so
				// nothing typed here can be overwritten by the answer.
				ui.Text(c, t.SettingsLoading).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
				return
			}
			ui.Paragraph(c, t.SettingsHint, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			if s.settingsNote != "" {
				ui.Paragraph(c, s.settingsNote, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
			}
			if s.tagBehavior != "" {
				ui.Text(c, s.tagBehavior).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			}
			all := !s.onlyRemote
			if ui.Checkbox(c, &all, t.AllRemotes).Clicked() {
				s.onlyRemote = !all
			}
			if s.onlyRemote {
				submitted = ui.TextField(c, &s.remote, t.RemoteName, t.RemoteName).FillWidth().Submitted()
			}
			prune := !s.keepStale
			if ui.Checkbox(c, &prune, t.Prune).Clicked() {
				s.keepStale = !prune
			}
			submodules := []string{t.Inherit, t.No, t.OnDemand, t.Yes}
			ui.Select(c, &s.submodules, syncChoiceIndexes, func(i int) string { return submodules[i] }).Label(t.Submodules).FillWidth()
			tags := []string{t.Inherit, t.TagsAll, t.TagsNone, t.TagsPrune}
			ui.Select(c, &s.tags, syncChoiceIndexes, func(i int) string { return tags[i] }).Label(t.Tags).FillWidth()
		})
	}, func() {
		if ui.Button(c, a.text.Branch.Cancel).Outline().Clicked() {
			c.After(func() { s.dialog = syncDialogNone })
		}
		if ui.Button(c, t.FetchButton).Disabled(!ready).Clicked() {
			c.After(func() { a.submitFetchOptions(p) })
		}
	})
	if submitted && ready {
		c.After(func() { a.submitFetchOptions(p) })
	}
}

// drawDivergedDialog declares the choice between merging and rebasing a diverged branch.
func (a *App) drawDivergedDialog(c ui.C, p *project) {
	s, t := &p.log.sync, a.text.Sync
	pre := s.preflight
	a.syncDialogOf(c, p, t.DivergeTitle, t.DivergePrompt(s.branch, pre.Upstream, pre.Ahead, pre.Behind), nil, func() {
		if ui.Button(c, a.text.Branch.Cancel).Outline().Clicked() {
			c.After(func() { s.dialog = syncDialogNone })
		}
		if ui.Button(c, t.Merge).Outline().Clicked() {
			c.After(func() { a.resolveDiverged(p, core.GitPullMerge) })
		}
		if ui.Button(c, t.Rebase).Clicked() {
			c.After(func() { a.resolveDiverged(p, core.GitPullRebase) })
		}
	})
}
