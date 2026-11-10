package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

var (
	syncAllRemotesID = tree.ID(shellPage, "sync-all-remotes")
	syncRemoteID     = tree.ID(shellPage, "sync-remote")
	syncPruneID      = tree.ID(shellPage, "sync-prune")
	syncSubmodulesID = tree.Sub(shellPage, tree.Name("sync-submodules"))
	syncTagsID       = tree.Sub(shellPage, tree.Name("sync-tags"))
	syncCancelID     = tree.ID(shellPage, "sync-cancel")
)

// syncStatusHeight is the height of the status line under the log's filter bar.
const syncStatusHeight = 28

// drawSyncStatus declares the line that says a fetch or update is running, with its Cancel
// button. It declares nothing while no operation runs.
func (a *App) drawSyncStatus(f *ui.Frame, p *project) {
	s := &p.log.sync
	if !s.busy {
		return
	}
	f.Row().Height(syncStatusHeight).Shrink(0).Items(ui.Center).Gap(8).PadX(8).Background(a.colors.Hover).Children(func() {
		f.Text(s.label).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Text).Ellipsis().Shrink(1)
		f.Spacer()
		if f.Button(syncCancelID, a.text.Sync.Cancel).Outline().Clicked() {
			a.cancelSync(p)
		}
	})
}

// drawSyncDialog declares the dialog of the log tab's sync operations that is open.
func (a *App) drawSyncDialog(f *ui.Frame) {
	p := a.project
	if p == nil {
		return
	}
	switch p.log.sync.dialog {
	case syncDialogFetch:
		a.drawFetchDialog(f, p)
	case syncDialogDiverged:
		a.drawDivergedDialog(f, p)
	}
}

// drawFetchDialog declares the options of one fetch.
func (a *App) drawFetchDialog(f *ui.Frame, p *project) {
	s, t := &p.log.sync, a.text.Sync
	d := f.Dialog(branchDialogSpec(t.FetchTitle, t.FetchPrompt, syncAllRemotesID))
	submitted := false
	d.Body(func() {
		f.Column().FillWidth().Gap(8).Children(func() {
			if f.Checkbox(syncAllRemotesID, !s.onlyRemote).Label(t.AllRemotes).Clicked() {
				s.onlyRemote = !s.onlyRemote
			}
			if s.onlyRemote {
				submitted = f.Field(&s.remote, syncRemoteID, t.RemoteName, t.RemoteName).FillWidth().Submitted()
			}
			if f.Checkbox(syncPruneID, !s.keepStale).Label(t.Prune).Clicked() {
				s.keepStale = !s.keepStale
			}
			submodules := []string{t.Inherit, t.No, t.OnDemand, t.Yes}
			if index, ok := f.Select(syncSubmodulesID, &s.submoduleSel, submodules, s.submodules).Label(t.Submodules).FillWidth().Picked(); ok {
				s.submodules = index
			}
			tags := []string{t.Inherit, t.TagsAll, t.TagsNone, t.TagsPrune}
			if index, ok := f.Select(syncTagsID, &s.tagSel, tags, s.tags).Label(t.Tags).FillWidth().Picked(); ok {
				s.tags = index
			}
		})
	})
	cancelled, confirmed := false, false
	ready := !s.onlyRemote || s.remote.Text() != ""
	d.Footer(func() {
		cancelled = f.Button(branchDialogCancel, a.text.Branch.Cancel).Outline().Clicked()
		confirmed = f.Button(branchDialogConfirm, t.FetchButton).Disabled(!ready).Clicked()
	})
	switch {
	case cancelled, d.Dismissed():
		s.dialog = syncDialogNone
	case (confirmed || submitted) && ready:
		a.submitFetchOptions(p)
	}
}

// drawDivergedDialog declares the choice between merging and rebasing a diverged branch.
func (a *App) drawDivergedDialog(f *ui.Frame, p *project) {
	s, t := &p.log.sync, a.text.Sync
	pre := s.preflight
	d := f.Dialog(branchDialogSpec(t.DivergeTitle, t.DivergePrompt(s.branch, pre.Upstream, pre.Ahead, pre.Behind), branchDialogCancel))
	d.Body(func() {})
	cancelled, merge, rebase := false, false, false
	d.Footer(func() {
		cancelled = f.Button(branchDialogCancel, a.text.Branch.Cancel).Outline().Clicked()
		merge = f.Button(branchDialogAlt, t.Merge).Outline().Clicked()
		rebase = f.Button(branchDialogConfirm, t.Rebase).Clicked()
	})
	switch {
	case cancelled, d.Dismissed():
		s.dialog = syncDialogNone
	case merge:
		a.resolveDiverged(p, core.GitPullMerge)
	case rebase:
		a.resolveDiverged(p, core.GitPullRebase)
	}
}
