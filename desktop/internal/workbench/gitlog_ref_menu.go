package workbench

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file is the menu a reference of the log's reference pane opens with the secondary
// button, in IDEA's order: a branch from it, the comparisons, the checkout, the checkout and
// rebase, the merge and the rebase of a branch that is not the
// checked-out one, the pulls of a remote branch, the update, push, rename and tracking branch of
// a local branch, the delete and the copy of the name. Everything acts in the repository the log
// walks. The merge, the rebase, the checkout and rebase and the pulls are confirmed first; Core
// runs them and refuses what Git does not allow, and one that stops at conflicts is shown on the
// Commit tool window by the operation banner of git_history.go.

// refKernel is the part of the kernel the reference menu writes with. *core.Client implements it.
type refKernel interface {
	GitMerge(ctx context.Context, root string, reference core.GitReference) error
	GitRebaseOnto(ctx context.Context, root string, reference core.GitReference) error
	GitCheckoutAndRebase(ctx context.Context, root string, reference core.GitReference) error
	GitSetUpstream(ctx context.Context, root string, branch, upstream core.GitReference) error
	GitUnsetUpstream(ctx context.Context, root string, branch core.GitReference) error
	GitIntegrationPreflight(ctx context.Context, root, operation, reference string) (core.IntegrationPreflight, error)
}

// The integrations of a reference the menu confirms first, for historyIntegrateState.operation.
// The merge and the rebase take the names git.integrationPreflight knows them by.
const (
	refMerge             = gitOperationMerge
	refRebase            = gitOperationRebase
	refCheckoutAndRebase = "checkoutAndRebase"
	refPullRebase        = "pullRebase"
	refPullMerge         = "pullMerge"
)

// historyIntegrateState is the dialog that confirms an integration of a reference: a merge into
// the current branch, a rebase of it, a checkout and rebase, or a pull of a remote branch.
type historyIntegrateState struct {
	open      bool
	operation string
	reference core.GitReference
	// root is the repository the log walked when the menu was opened, where the write runs.
	root string
}

// logRefPointer opens the reference menu of row i of the reference pane when it is pressed with
// the secondary button. A Tree has no menu of its own rows, so the press is read on the row.
func (a *App) logRefPointer(c ui.C, p *project, i int) {
	v := &a.logView
	row := v.refItems[i]
	canvas := c.Canvas()
	if row.kind != logRefReference || row.ref == nil || canvas == nil {
		return
	}
	event, ok := canvas.PointerOn(v.refs.RowID(i))
	if !ok || event.Kind != gfx.PointerDown || event.Button != gfx.PointerButtonSecondary {
		return
	}
	canvas.Consume()
	v.refMenu, v.refMenuAt, v.refMenuRef = true, ui.Rect{X: event.X, Y: event.Y}, *row.ref
	v.refMenuRoot = p.logRepositoryRoot()
}

// drawLogRefMenu declares the reference menu while it is open.
func (a *App) drawLogRefMenu(c ui.C, p *project) {
	v := &a.logView
	if !v.refMenu {
		return
	}
	if v.refMenuRoot != p.logRepositoryRoot() {
		// The log walks another repository now; the reference is not one of it.
		v.refMenu = false
		return
	}
	ui.MenuAt(c.Key("log-ref-menu"), v.refMenuAt.X, v.refMenuAt.Y, &v.refMenu, func(menu *ui.MenuItems) {
		a.drawLogRefMenuItems(c, menu, p, v.refMenuRef)
	})
}

// drawLogRefMenuItems declares the items of the menu of reference r. The checked-out branch is
// not checked out, merged, rebased or deleted; only a branch while one is checked out is merged
// or rebased, only a remote branch pulled, and only a local branch updated, pushed, renamed or
// given a tracking branch.
func (a *App) drawLogRefMenuItems(c ui.C, menu *ui.MenuItems, p *project, r core.GitReference) {
	l, v, t, g := &p.log, &a.logView, a.text.Branch, a.text.Git
	lang := a.language()
	root := p.logRepositoryRoot()
	busy := a.branch.busy || l.sync.busy || p.historyBusy()
	head := l.currentReference()
	onBranch := head.Kind == "local" && head.IsCurrent
	current := r.Kind == "local" && r.IsCurrent
	if menu.Item(t.NewBranchFrom(r.ShortName)).Disabled(busy).Clicked() {
		c.After(func() {
			a.adoptLogBranches(p)
			a.beginCreate(p, r)
		})
	}
	if menu.Item(g.CompareWorkingTree).Disabled(l.comparing).Clicked() {
		c.After(func() { a.compareReferencesAt(p, root, r, nil) })
	}
	if !current && onBranch && menu.Item(g.CompareWithCurrent).Disabled(l.comparing).Clicked() {
		c.After(func() { a.compareReferencesAt(p, root, head, &r) })
	}
	if source := v.compareSource; source != nil && v.compareRoot == root && source.FullName != r.FullName {
		label := i18n.SharedFormat(lang, "native.compareWith", map[string]string{"arg1": source.ShortName, "arg2": r.ShortName})
		if menu.Item(label).Disabled(l.comparing).Clicked() {
			base := *source
			c.After(func() {
				v.compareSource = nil
				a.compareReferencesAt(p, root, base, &r)
			})
		}
	} else if menu.Item(i18n.Shared(lang, "native.selectForCompare")).Clicked() {
		c.After(func() { v.compareSource, v.compareRoot = &r, root })
	}
	if !current {
		menu.Separator()
		if menu.Item(t.Checkout).Disabled(busy).Clicked() {
			c.After(func() {
				a.adoptLogBranches(p)
				a.checkoutBranch(p, r)
			})
		}
		if r.Kind != "tag" {
			a.logRefIntegrateItem(c, menu, p, r, refCheckoutAndRebase, i18n.Shared(lang, "native.checkoutAndRebaseOntoCurrentBranch"), busy || !onBranch)
			a.logRefIntegrateItem(c, menu, p, r, refMerge, i18n.Shared(lang, "native.mergeIntoCurrentBranch"), busy || !onBranch)
			a.logRefIntegrateItem(c, menu, p, r, refRebase, i18n.Shared(lang, "native.rebaseCurrentBranchOnto"), busy || !onBranch)
		}
	}
	if r.Kind == "remote" {
		menu.Separator()
		a.logRefIntegrateItem(c, menu, p, r, refPullRebase, i18n.Shared(lang, "native.pullWithRebase"), busy || !onBranch)
		a.logRefIntegrateItem(c, menu, p, r, refPullMerge, i18n.Shared(lang, "native.pullWithMerge"), busy || !onBranch)
	}
	if r.Kind == "local" {
		menu.Separator()
		// Any other local branch fast-forwards from its upstream in place, as in IDEA.
		if menu.Item(i18n.Shared(lang, "git.log.updateBranch")).Disabled(busy || !current && r.UpstreamShortName == "").Clicked() {
			c.After(func() { a.updateBranchAt(p, root, r) })
		}
		if menu.Item(i18n.Shared(lang, "git.contextMenu.push")).Disabled(busy).Clicked() {
			c.After(func() { a.openPushOf(p, root, r) })
		}
		if menu.Item(t.Rename).Disabled(busy).Clicked() {
			c.After(func() {
				a.adoptLogBranches(p)
				a.beginRename(p, r)
			})
		}
		menu.Sub(i18n.Shared(lang, "native.trackingBranch"), func(sub *ui.MenuItems) {
			a.drawLogTrackingMenu(c, sub, p, r, busy)
		}).Disabled(busy)
	}
	if r.Kind == "tag" || r.Kind == "local" && !current {
		menu.Separator()
		if menu.Item(t.Delete).Destructive().Disabled(busy).Clicked() {
			c.After(func() {
				a.adoptLogBranches(p)
				if r.Kind == "tag" {
					a.beginDeleteTag(r)
				} else {
					a.beginDelete(r)
				}
			})
		}
	}
	if r.Kind != "tag" {
		menu.Separator()
		if menu.Item(i18n.Shared(lang, "git.log.copyBranchName")).Clicked() {
			c.After(func() {
				if err := app.SetClipboardText(r.ShortName); err != nil {
					a.notifyError(i18n.SharedFormat(a.language(), "git.log.copyFailed", map[string]string{"label": r.ShortName}))
				}
			})
		}
	}
}

// logRefIntegrateItem declares the item named label that asks to confirm the integration
// operation of r.
func (a *App) logRefIntegrateItem(c ui.C, menu *ui.MenuItems, p *project, r core.GitReference, operation, label string, disabled bool) {
	if menu.Item(label).Disabled(disabled).Clicked() {
		c.After(func() {
			p.gitHistory.integrate = historyIntegrateState{open: true, operation: operation, reference: r, root: p.logRepositoryRoot()}
		})
	}
}

// drawLogTrackingMenu declares the submenu that sets the remote branch the local branch r
// tracks: the one it tracks, checked, with the item that stops tracking it, then every remote
// branch of the repository.
func (a *App) drawLogTrackingMenu(c ui.C, sub *ui.MenuItems, p *project, r core.GitReference, busy bool) {
	lang := a.language()
	if r.UpstreamShortName != "" {
		sub.Item(r.UpstreamShortName).Checked(true).Disabled(true)
		if sub.Item(i18n.Shared(lang, "native.stopTrackingBranch")).Disabled(busy).Clicked() {
			c.After(func() { a.setLogUpstream(p, r, nil) })
		}
		sub.Separator()
	}
	remotes := p.log.sections[1].refs
	if len(remotes) == 0 {
		sub.Item(i18n.Shared(lang, "native.noRemoteBranches")).Disabled(true)
	}
	for _, remote := range remotes {
		if sub.Item(remote.ShortName).Disabled(busy || remote.ShortName == r.UpstreamShortName).Clicked() {
			c.After(func() { a.setLogUpstream(p, r, &remote) })
		}
	}
}

// adoptLogBranches makes the branch dialogs act on the references and the repository of the log.
func (a *App) adoptLogBranches(p *project) {
	a.branch.refs = p.log.refs
	a.branch.repo = p.logBranchRepo()
}

// setLogUpstream makes the local branch track upstream, or nothing when upstream is nil.
func (a *App) setLogUpstream(p *project, branch core.GitReference, upstream *core.GitReference) {
	rk, ok := a.kernel.(refKernel)
	if !ok || a.branch.busy {
		return
	}
	a.adoptLogBranches(p)
	a.performed("git.log.trackingBranch", surfaceMenu)
	lang := a.language()
	a.runBranchWrite(p, "git_set_upstream",
		func(reason string) string {
			return i18n.SharedFormat(lang, "git.operationError", map[string]string{"error": reason})
		},
		func(ctx context.Context, _ Kernel, root string) error {
			if upstream == nil {
				return rk.GitUnsetUpstream(ctx, root, branch)
			}
			return rk.GitSetUpstream(ctx, root, branch, *upstream)
		},
		func(a *App, _ core.GitStatus) {
			if upstream == nil {
				a.notifySuccess(i18n.SharedFormat(a.language(), "desktop.refs.trackingStopped", map[string]string{"branch": branch.ShortName}))
				return
			}
			a.notifySuccess(i18n.SharedFormat(a.language(), "desktop.refs.trackingSet", map[string]string{"branch": branch.ShortName, "upstream": upstream.ShortName}))
		})
}

// runRefIntegration runs the integration the dialog confirmed. A pull runs as the other pulls
// do, with progress and Cancel; the others ask Core first which local changes they would
// overwrite. One that stops at conflicts leaves its operation active for the banner.
func (a *App) runRefIntegration(p *project) {
	h := &p.gitHistory
	in := h.integrate
	if !in.open || p.historyBusy() || p.log.sync.busy || a.branch.busy {
		return
	}
	h.integrate.open = false
	a.performed("git.log."+in.operation, surfaceButton)
	if in.operation == refPullRebase || in.operation == refPullMerge {
		a.runRefPull(p, in)
		return
	}
	rk, ok := a.kernel.(refKernel)
	if !ok {
		return
	}
	h.busy = true
	a.showGitConsole(in.root)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		var preflight core.IntegrationPreflight
		var err error
		if in.operation != refCheckoutAndRebase {
			// Core checks the working tree of a checkout and rebase itself.
			preflight, err = rk.GitIntegrationPreflight(ctx, in.root, in.operation, in.reference.FullName)
		}
		blocked := err == nil && len(preflight.BlockingPaths) > 0
		if err == nil && !blocked {
			switch in.operation {
			case refMerge:
				err = rk.GitMerge(ctx, in.root, in.reference)
			case refRebase:
				err = rk.GitRebaseOnto(ctx, in.root, in.reference)
			default:
				err = rk.GitCheckoutAndRebase(ctx, in.root, in.reference)
			}
		}
		return func(a *App) {
			p.gitHistory.busy = false
			lang := a.language()
			name := in.reference.ShortName
			switch {
			case blocked:
				a.notifyError(i18n.SharedFormat(lang, "git.log.operationBlocked", map[string]string{"paths": historyPathList(preflight.BlockingPaths)}))
				return
			case err != nil:
				a.notifyError(i18n.SharedFormat(lang, "git.operationError", map[string]string{"error": reviewReason(err)}))
				a.gitOperationFailed("git_"+in.operation, err)
			case in.operation == refMerge:
				a.notifySuccess(i18n.SharedFormat(lang, "desktop.refs.merged", map[string]string{"branch": name}))
			case in.operation == refRebase:
				a.notifySuccess(i18n.SharedFormat(lang, "desktop.refs.rebased", map[string]string{"branch": name}))
			default:
				a.notifySuccess(i18n.SharedFormat(lang, "desktop.refs.checkedOutAndRebased", map[string]string{"branch": name}))
			}
			a.afterHistoryWrite(p, in.root)
		}
	})
}

// runRefPull pulls the remote branch of the confirmed dialog into the current branch, with a
// rebase or a merge, and reads the operation Git holds active afterwards.
func (a *App) runRefPull(p *project, in historyIntegrateState) {
	pk, ok := a.kernel.(pullKernel)
	if !ok {
		return
	}
	strategy := core.GitPullMerge
	if in.operation == refPullRebase {
		strategy = core.GitPullRebase
	}
	t := a.text.Sync
	p.log.sync.done = func(a *App, _ error) {
		if in.root != p.git.repositoryRoot(p.root) {
			p.gitHistory.operationRoot = in.root
		}
		a.loadGitOperation(p)
	}
	a.runSyncAt(p, in.root, "git_pull", t.Updating(in.reference.ShortName), t.UpdateFailed,
		func(ctx context.Context, _ Kernel, root string) (func(*App), error) {
			return func(a *App) { a.notifySuccess(t.Updated(in.reference.ShortName)) }, pk.GitPullFrom(ctx, root, in.reference, strategy)
		})
}

// drawRefIntegrateDialog declares the confirmation of an integration of a reference.
func (a *App) drawRefIntegrateDialog(c ui.C, p *project) {
	h := &p.gitHistory
	lang := a.language()
	name := h.integrate.reference.ShortName
	var title, description, action string
	switch h.integrate.operation {
	case refMerge:
		title, action = i18n.Shared(lang, "native.mergeBranch"), i18n.Shared(lang, "native.merge")
		description = i18n.SharedFormat(lang, "desktop.refs.mergeConfirm", map[string]string{"branch": name})
	case refRebase:
		title, action = i18n.Shared(lang, "native.rebaseBranch"), i18n.Shared(lang, "native.rebase")
		description = i18n.SharedFormat(lang, "desktop.refs.rebaseConfirm", map[string]string{"branch": name})
	case refCheckoutAndRebase:
		title, action = i18n.Shared(lang, "native.checkoutAndRebaseBranch"), i18n.Shared(lang, "native.checkoutAndRebase")
		description = i18n.SharedFormat(lang, "native.checkoutThenReplayItOntoTheBranchThatIsCurrentNow", map[string]string{"arg1": name})
	case refPullRebase:
		title, action = i18n.Shared(lang, "native.pullRemoteBranchWithRebase"), i18n.Shared(lang, "native.pullWithRebase")
		description = i18n.SharedFormat(lang, "native.pullIntoTheCurrentBranchAndReplayLocalCommits", map[string]string{"arg1": name})
	default:
		title, action = i18n.Shared(lang, "native.pullRemoteBranchWithMerge"), i18n.Shared(lang, "native.pullWithMerge")
		description = i18n.SharedFormat(lang, "native.pullIntoTheCurrentBranchWithAMerge", map[string]string{"arg1": name})
	}
	open := true
	closed := ui.ModalWith(c, &open, title, ui.ModalSpec{Description: description, Width: 460}, nil, func() {
		if ui.Button(c, i18n.Shared(lang, "desktop.gitReview.cancel")).Outline().Clicked() {
			open = false
		}
		if ui.Button(c, action).Disabled(p.historyBusy() || p.log.sync.busy || a.branch.busy).Clicked() {
			c.After(func() { a.runRefIntegration(p) })
		}
	})
	if closed || !open {
		c.After(func() { h.integrate.open = false })
	}
}
