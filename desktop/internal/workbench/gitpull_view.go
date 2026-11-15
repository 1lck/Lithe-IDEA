package workbench

import "github.com/vivaui/viva/ui"

// This file declares the Pull dialog of the log tab (gitpull.go): the repository select when the
// project has nested repositories, the remote and its branch, and the strategy.

// pullChoices numbers the choices of a select of n options.
func pullChoices(n int) []int {
	choices := make([]int, n)
	for i := range choices {
		choices[i] = i
	}
	return choices
}

// drawPullDialog declares the Pull dialog. A change of repository or remote resets the picks
// below it, so the branch list always belongs to the remote shown above it.
func (a *App) drawPullDialog(c ui.C, p *project) {
	s := &p.log.sync
	pull, t := &s.pull, a.text.Sync.Pull
	_, _, _, picked := pull.selection()
	ready := picked && !s.busy
	a.syncDialogOf(c, p, t.Title, t.Prompt, func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			if pull.loading {
				ui.Text(c, t.Loading).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
				return
			}
			if pull.err != "" {
				ui.Paragraph(c, pull.err, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
			}
			if len(pull.repos) > 1 {
				prev := pull.repo
				ui.Select(c, &pull.repo, pullChoices(len(pull.repos)), func(i int) string { return pull.repos[i].name }).Label(t.Repository).FillWidth()
				if pull.repo != prev {
					pull.preselectUpstream(pull.repos[pull.repo].root)
				}
			}
			remotes := pull.pickedRemotes()
			if len(remotes) == 0 {
				ui.Paragraph(c, t.NoRemote, 2).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			}
			prevRemote := pull.remote
			ui.Select(c, &pull.remote, pullChoices(len(remotes)), func(i int) string { return remotes[i].Name }).Label(t.Remote).FillWidth()
			if pull.remote != prevRemote {
				pull.branch = 0
			}
			branches := pull.pickedBranches()
			if len(remotes) > 0 && len(branches) == 0 {
				ui.Paragraph(c, t.NoBranch, 2).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			}
			ui.Select(c, &pull.branch, pullChoices(len(branches)), func(i int) string { return branches[i].ShortName }).Label(t.RemoteBranch).FillWidth()
			strategies := []string{t.Merge, t.Rebase, t.FastForward}
			ui.Select(c, &pull.strategy, pullChoices(len(strategies)), func(i int) string { return strategies[i] }).Label(t.Strategy).FillWidth()
		})
	}, func() {
		if ui.Button(c, a.text.Branch.Cancel).Outline().Clicked() {
			c.After(func() { s.dialog = syncDialogNone })
		}
		if ui.Button(c, t.Button).Disabled(!ready).Clicked() {
			c.After(func() { a.submitPull(p) })
		}
	})
}
