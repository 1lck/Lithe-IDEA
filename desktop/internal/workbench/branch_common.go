package workbench

import (
	"context"
	"fmt"
	"path"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// This file runs the branch actions on the common branches of a project folder with several
// repositories, as IntelliJ IDEA's branch popup does for several roots: Core lists the local and
// remote branches every repository has (git.workspaceCommonReferences) and plans a checkout or a new
// branch across them (git.workspaceBranchPlan). The window runs the plan's writes one repository
// after another, stops at the first that fails, and offers to undo the ones that ran, so that the
// repositories do not stay on different branches. The popup draws the sections in branch_view.go.

// workspaceBrancher is the part of the kernel the common branches use. Core's client implements
// it; a kernel that does not lists no common branch.
type workspaceBrancher interface {
	GitWorkspaceCommonReferences(ctx context.Context, repositories []core.WorkspaceRepositoryReferences) (core.WorkspaceCommonReferences, error)
	GitWorkspaceBranchPlan(ctx context.Context, request core.WorkspaceBranchPlanRequest) (core.WorkspaceBranchPlan, error)
}

// commonSectionKeys are the keys of the Common Local Branches and Common Remote Branches sections,
// as branchSession.collapsed keeps them and as the rows' keys start (branchRowKey). Each is also
// its section's logSection kind, so that their folders open apart from one repository's.
var commonSectionKeys = [2]string{commonSectionPrefix + "local", commonSectionPrefix + "remote"}

// commonSectionPrefix starts the keys of the common sections and of their rows.
const commonSectionPrefix = "common/"

// commonBranches is what the popup of a folder with several repositories read of the branches
// every repository has. It is read again each time the popup opens.
type commonBranches struct {
	// gen counts the reads; the answer of an older one is dropped.
	gen int
	// loading is set while the kernel reads; loaded once it answered.
	loading, loaded bool
	err             error
	// references are each repository's git.references entries in the order of
	// workspaceRepositories; a new branch for every repository is checked against all of them.
	references []core.WorkspaceRepositoryReferences
	// sections are Core's common local and remote branches with their folder trees, in the order
	// of commonSectionKeys.
	sections [2]logSection
}

// current is the common local branch every repository has checked out, or HEAD when they are on
// different branches.
func (cb *commonBranches) current() core.GitReference {
	for _, r := range cb.sections[0].refs {
		if r.IsCurrent {
			return r
		}
	}
	return headReference
}

// allReferences are the references of every repository, one after another.
func (cb *commonBranches) allReferences() []core.GitReference {
	var out []core.GitReference
	for _, repository := range cb.references {
		out = append(out, repository.References...)
	}
	return out
}

// commonWrite is a branch action on a common branch that runs in every repository of the folder.
type commonWrite struct {
	operation core.WorkspaceBranchOperation
	// reference is the common branch the action is on; name and checkout are the new branch of
	// WorkspaceBranchCreate and whether every repository switches to it.
	reference core.GitReference
	name      string
	checkout  bool
	// repos are the repositories the action runs in, in Core's order.
	repos []workspaceRepository
	// plan is Core's plan of the writes.
	plan core.WorkspaceBranchPlan
	// done are the steps that ran, in order. failed is the ID of the repository whose step failed,
	// empty when none did, and err what Git said.
	done   []core.WorkspaceBranchStep
	failed string
	err    error
	// branch is the branch the first repository is on after a checkout that succeeded everywhere.
	branch string
}

// repo is the repository of the action with Core's ID id.
func (w *commonWrite) repo(id string) (workspaceRepository, bool) {
	for _, repo := range w.repos {
		if repo.id == id {
			return repo, true
		}
	}
	return workspaceRepository{}, false
}

// rootOf is where the repository with Core's ID id is on disk, or an error when the action does
// not run in it, so that no write runs in another folder.
func (w *commonWrite) rootOf(id string) (string, error) {
	if repo, ok := w.repo(id); ok && repo.root != "" {
		return repo.root, nil
	}
	return "", fmt.Errorf("the workspace branch plan names repository %q, which the folder does not list", id)
}

// names are the names of the repositories with the IDs ids, joined for a message.
func (w *commonWrite) names(lang i18n.Language, ids []string) string {
	out := make([]string, 0, len(ids))
	for _, id := range ids {
		if repo, ok := w.repo(id); ok {
			out = append(out, repo.name)
		} else {
			out = append(out, id)
		}
	}
	return strings.Join(out, i18n.Shared(lang, "desktop.branch.repositorySeparator"))
}

// operationName names the action for the log.
func (w *commonWrite) operationName() string {
	if w.operation == core.WorkspaceBranchCreate {
		return "git_workspace_branch_create"
	}
	return "git_workspace_checkout"
}

// planFailed words a failure of the action before any repository was written.
func (w *commonWrite) planFailed(t i18n.BranchMessages, reason string) string {
	if w.operation == core.WorkspaceBranchCreate {
		return t.CreateFailed(reason)
	}
	return t.CheckoutFailed(reason)
}

// failedIn words the failure of the action's step in the repository failed.
func (w *commonWrite) failedIn(lang i18n.Language) string {
	repository, reason := w.names(lang, []string{w.failed}), w.err.Error()
	if w.operation == core.WorkspaceBranchCreate {
		return i18n.SharedFormat(lang, "desktop.branch.createFailedIn", map[string]string{"name": w.name, "repository": repository, "reason": reason})
	}
	return i18n.SharedFormat(lang, "desktop.branch.checkoutFailedIn", map[string]string{"name": w.reference.ShortName, "repository": repository, "reason": reason})
}

// succeeded words the action that ran in every repository.
func (w *commonWrite) succeeded(lang i18n.Language) string {
	if w.operation == core.WorkspaceBranchCreate {
		return i18n.SharedFormat(lang, "desktop.branch.commonCreated", map[string]string{"name": w.name})
	}
	name := w.branch
	if name == "" || name == "detached" {
		name = w.reference.ShortName
	}
	return i18n.SharedFormat(lang, "desktop.branch.commonCheckedOut", map[string]string{"name": name})
}

// doneIDs are the IDs of the repositories the action's steps ran in, and of those among them that
// a rollback cannot return to their branch.
func (w *commonWrite) doneIDs() (ran, stuck []string) {
	for _, step := range w.done {
		ran = append(ran, step.Repository)
		if step.Rollback == nil {
			stuck = append(stuck, step.Repository)
		}
	}
	return ran, stuck
}

// loadCommonBranches reads the references of every repository of the folder in the background and
// asks Core which local and remote branches they all have. A folder with one repository, or a
// kernel without the workspace commands, has no common branch.
func (a *App) loadCommonBranches(p *project) {
	cb := &a.branch.common
	cb.gen++
	gen := cb.gen
	brancher, ok := a.kernel.(workspaceBrancher)
	repos := p.workspaceRepositories()
	if !ok || !p.workspaceMode() || len(repos) < 2 {
		*cb = commonBranches{gen: gen}
		return
	}
	cb.loading = true
	kernel := a.kernel
	// Each repository's read is bounded on its own, so a folder of many is not cut short.
	a.background(p, 0, func(ctx context.Context) func(*App) {
		references, sections, err := readCommonReferences(ctx, kernel, brancher, repos)
		return func(a *App) {
			cb := &a.branch.common
			if cb.gen != gen {
				return
			}
			cb.loading, cb.loaded = false, true
			cb.references, cb.sections, cb.err = references, sections, err
			if err != nil {
				a.backgroundFailed("git_workspace_common_references", err)
			}
		}
	})
}

// readWorkspaceReferences reads the references of each repository as Core's workspace commands
// take them, each read bounded by gitTimeout.
func readWorkspaceReferences(ctx context.Context, kernel Kernel, repos []workspaceRepository) ([]core.WorkspaceRepositoryReferences, error) {
	out := make([]core.WorkspaceRepositoryReferences, 0, len(repos))
	for _, repo := range repos {
		readCtx, cancel := context.WithTimeout(ctx, gitTimeout)
		refs, err := kernel.GitReferences(readCtx, repo.root)
		cancel()
		if err != nil {
			return nil, err
		}
		out = append(out, core.WorkspaceRepositoryReferences{ID: repo.id, References: refs.References})
	}
	return out, nil
}

// readCommonReferences reads the references of repos, asks Core for the branches they all have,
// and has Core lay each section out as a folder tree with the common current branch first.
func readCommonReferences(ctx context.Context, kernel Kernel, brancher workspaceBrancher, repos []workspaceRepository) ([]core.WorkspaceRepositoryReferences, [2]logSection, error) {
	var sections [2]logSection
	references, err := readWorkspaceReferences(ctx, kernel, repos)
	if err != nil {
		return nil, sections, err
	}
	callCtx, cancel := context.WithTimeout(ctx, gitTimeout)
	defer cancel()
	common, err := brancher.GitWorkspaceCommonReferences(callCtx, references)
	if err != nil {
		return references, sections, err
	}
	prioritized := map[string]bool{}
	for _, r := range common.Local {
		if r.IsCurrent {
			prioritized[r.ShortName] = true
		}
	}
	for i, refs := range [2][]core.GitReference{common.Local, common.Remote} {
		sections[i] = logSection{kind: commonSectionKeys[i], refs: refs}
		if len(refs) == 0 {
			continue
		}
		names := make([]string, len(refs))
		for j, r := range refs {
			names[j] = r.ShortName
		}
		nodes, err := kernel.GitReferenceTree(callCtx, names, prioritized)
		if err != nil {
			return references, sections, err
		}
		sections[i].nodes = nodes
	}
	return references, sections, nil
}

// checkoutCommon checks out the common branch r in every repository of the folder. A local branch
// every repository is on only says so. surface is where the user asked.
func (a *App) checkoutCommon(p *project, r core.GitReference, surface actionSurface) {
	a.leaveBranches()
	if r.Kind == "local" && r.IsCurrent {
		a.notifyInfo(a.text.Branch.AlreadyOn(r.ShortName))
		return
	}
	a.performed("git.workspace.checkout", surface)
	a.planCommon(p, commonWrite{operation: core.WorkspaceBranchCheckout, reference: r})
}

// beginCreateCommon opens the dialog that creates a branch from the common branch r in every
// repository of the folder.
func (a *App) beginCreateCommon(p *project, r core.GitReference) { a.openCreate(p, r, true) }

// planCommon reads the references of every repository again, so that the plan starts from where
// they are now, asks Core for the plan of w, and runs it. A checkout first asks each repository
// which local changes it would overwrite; the conflict dialog then lists them all and its choice
// applies to every repository.
func (a *App) planCommon(p *project, w commonWrite) {
	brancher, ok := a.kernel.(workspaceBrancher)
	if !ok {
		return
	}
	b := &a.branch
	b.busy = true
	w.repos = p.workspaceRepositories()
	kernel := a.kernel
	a.background(p, 0, func(ctx context.Context) func(*App) {
		plan, blocking, err := planCommonWrite(ctx, kernel, brancher, &w)
		return func(a *App) {
			b := &a.branch
			b.busy = false
			if err != nil {
				a.notifyError(w.planFailed(a.text.Branch, err.Error()))
				a.operationFailed(w.operationName(), err)
				return
			}
			w.plan = plan
			if len(plan.Steps) == 0 {
				// Every repository is on the branch already.
				b.dialog, b.across = branchDialogNone, false
				a.notifyInfo(a.text.Branch.AlreadyOn(w.reference.ShortName))
				return
			}
			if len(blocking) > 0 {
				b.dialog, b.target, b.blocking, b.across, b.write = branchDialogConflict, w.reference, blocking, true, w
				return
			}
			a.runCommon(p, w, core.CheckoutPlain)
		}
	})
}

// planCommonWrite asks Core for the plan of w from the references the repositories have now and,
// for a checkout, the paths it would overwrite in each repository it switches, relative to the
// project folder.
func planCommonWrite(ctx context.Context, kernel Kernel, brancher workspaceBrancher, w *commonWrite) (core.WorkspaceBranchPlan, []string, error) {
	references, err := readWorkspaceReferences(ctx, kernel, w.repos)
	if err != nil {
		return core.WorkspaceBranchPlan{}, nil, err
	}
	planCtx, cancel := context.WithTimeout(ctx, gitTimeout)
	plan, err := brancher.GitWorkspaceBranchPlan(planCtx, core.WorkspaceBranchPlanRequest{
		Operation: w.operation, Reference: w.reference.FullName, Name: w.name, Checkout: w.checkout, Repositories: references})
	cancel()
	if err != nil || w.operation != core.WorkspaceBranchCheckout {
		return plan, nil, err
	}
	var blocking []string
	for _, step := range plan.Steps {
		root, err := w.rootOf(step.Repository)
		if err != nil {
			return plan, nil, err
		}
		checkCtx, cancel := context.WithTimeout(ctx, gitTimeout)
		paths, err := kernel.GitCheckoutPreflight(checkCtx, root, step.Reference)
		cancel()
		if err != nil {
			return plan, nil, err
		}
		for _, file := range paths {
			blocking = append(blocking, path.Join(step.Repository, file))
		}
	}
	return plan, blocking, nil
}

// runCommon runs the steps of w's plan in the background, one repository after another, checking
// out in mode, and stops at the first that fails. The statuses and the log are read again after
// it. A failure after some steps ran opens the rollback dialog; one before any leaves the open
// dialog as it is, as the write of one repository does.
func (a *App) runCommon(p *project, w commonWrite, mode core.CheckoutMode) {
	b := &a.branch
	b.busy = true
	if b.fromPopup {
		a.showGitConsole("")
	}
	kernel := a.kernel
	a.background(p, 0, func(ctx context.Context) func(*App) {
		w := runCommonSteps(ctx, kernel, w, mode)
		return func(a *App) {
			b := &a.branch
			b.busy = false
			a.commonWritten(p)
			lang := a.language()
			switch {
			case w.failed == "":
				b.dialog, b.across = branchDialogNone, false
				a.notifySuccess(w.succeeded(lang))
			case len(w.done) == 0:
				a.notifyError(w.failedIn(lang))
				a.operationFailed(w.operationName(), w.err)
			default:
				a.operationFailed(w.operationName(), w.err)
				b.dialog, b.across, b.write = branchDialogRollback, true, w
			}
		}
	})
}

// runCommonSteps runs the steps of w's plan in order, each bounded by branchOperationTimeout, and
// returns w with the steps that ran and the one that failed. After a checkout that succeeded
// everywhere it reads the branch the first repository reached.
func runCommonSteps(ctx context.Context, kernel Kernel, w commonWrite, mode core.CheckoutMode) commonWrite {
	w.done, w.failed, w.err, w.branch = nil, "", nil, ""
	for _, step := range w.plan.Steps {
		root, err := w.rootOf(step.Repository)
		if err == nil {
			stepCtx, cancel := context.WithTimeout(ctx, branchOperationTimeout)
			switch w.operation {
			case core.WorkspaceBranchCreate:
				err = kernel.GitCreateBranch(stepCtx, root, w.name, step.Reference, w.checkout)
			default:
				err = kernel.GitCheckout(stepCtx, root, step.Reference, mode)
			}
			cancel()
		}
		if err != nil {
			w.failed, w.err = step.Repository, err
			return w
		}
		w.done = append(w.done, step)
	}
	if w.operation == core.WorkspaceBranchCheckout && len(w.done) > 0 {
		if root, err := w.rootOf(w.done[0].Repository); err == nil {
			statusCtx, cancel := context.WithTimeout(ctx, gitTimeout)
			if status, err := kernel.GitStatus(core.WithQueryCategory(core.AutomaticRefresh(statusCtx), core.GitQueryReload), root); err == nil {
				w.branch = status.Branch
			}
			cancel()
		}
	}
	return w
}

// commonWritten reads the statuses of the folder's repositories and the open log again after a
// write across them.
func (a *App) commonWritten(p *project) {
	if p.git.isRepository() {
		a.reloadGit(p)
	}
	a.loadNestedRepos(p)
	if p.log.started {
		a.loadLog(p)
	}
}

// rollbackCommon undoes the steps of the failed action that ran, the last one first, as IDEA's
// Rollback does, and reads the statuses again. A step that nothing can undo stays as it is.
func (a *App) rollbackCommon(p *project) {
	b := &a.branch
	if b.busy || b.dialog != branchDialogRollback {
		return
	}
	w := b.write
	a.performed("git.workspace.rollback", surfaceButton)
	b.busy = true
	kernel := a.kernel
	a.background(p, 0, func(ctx context.Context) func(*App) {
		rolled, failed, err := rollbackCommonSteps(ctx, kernel, &w)
		return func(a *App) {
			b := &a.branch
			b.busy = false
			b.dialog, b.across = branchDialogNone, false
			a.commonWritten(p)
			lang := a.language()
			if err != nil {
				repository := w.names(lang, []string{failed})
				a.notifyError(i18n.SharedFormat(lang, "desktop.branch.rollbackFailed", map[string]string{"repository": repository, "reason": err.Error()}))
				a.operationFailed("git_workspace_rollback", err)
				return
			}
			a.notifySuccess(i18n.SharedFormat(lang, "desktop.branch.rolledBack", map[string]string{"repositories": w.names(lang, rolled)}))
		}
	})
}

// rollbackCommonSteps runs the rollback of each step of w that ran, the last step first and each
// step's writes in order, and returns the IDs of the repositories it undid. It stops at the first
// write that fails and returns that repository's ID with the error.
func rollbackCommonSteps(ctx context.Context, kernel Kernel, w *commonWrite) (rolled []string, failed string, err error) {
	for i := len(w.done) - 1; i >= 0; i-- {
		step := w.done[i]
		if step.Rollback == nil {
			continue
		}
		root, err := w.rootOf(step.Repository)
		if err != nil {
			return rolled, step.Repository, err
		}
		for _, action := range step.Rollback {
			writeCtx, cancel := context.WithTimeout(ctx, branchOperationTimeout)
			switch action.Operation {
			case core.WorkspaceRollbackCheckout:
				err = kernel.GitCheckout(writeCtx, root, action.Reference, core.CheckoutPlain)
			case core.WorkspaceRollbackDeleteBranch:
				_, err = kernel.GitDeleteBranch(writeCtx, root, action.Reference)
			default:
				err = fmt.Errorf("unknown rollback operation %q", action.Operation)
			}
			cancel()
			if err != nil {
				return rolled, step.Repository, err
			}
		}
		rolled = append(rolled, step.Repository)
	}
	return rolled, "", nil
}
