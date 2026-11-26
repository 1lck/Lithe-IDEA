package workbench

import (
	"context"
	"slices"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

// branchState is what the window keeps for the branch popup of the title bar: its text
// fields, which live as long as the window, and the session of the open popup.
type branchState struct {
	// search filters the list; name is the name typed in the create and rename dialogs;
	// revision is the revision typed in the checkout dialog.
	search, name, revision ui.Field
	// tagMessage is the annotation typed in the new tag dialog.
	tagMessage ui.Field
	branchSession
}

// branchDialog says which dialog of the popup is open.
type branchDialog int

const (
	branchDialogNone branchDialog = iota
	// branchDialogCreate asks for the name of a new branch.
	branchDialogCreate
	// branchDialogRename asks for the new name of a local branch.
	branchDialogRename
	// branchDialogRevision asks for a tag or revision to check out detached.
	branchDialogRevision
	// branchDialogConflict asks what to do with the local changes a checkout would
	// overwrite.
	branchDialogConflict
	// branchDialogDelete confirms deleting local and remote branches (branch_delete.go).
	branchDialogDelete
	// branchDialogDeleteUnmerged offers review after Core refused ordinary deletion.
	branchDialogDeleteUnmerged
	// branchDialogForceDelete requires a second explicit destructive confirmation.
	branchDialogForceDelete
	// branchDialogDeleteResult keeps every batch outcome visible until dismissed.
	branchDialogDeleteResult
	// branchDialogTag asks for the name, target and message of a new tag.
	branchDialogTag
	// branchDialogTagDelete confirms deleting a tag.
	branchDialogTagDelete
	// branchDialogRollback offers to undo a branch action on a common branch that failed after
	// it succeeded in some repositories (branch_common.go).
	branchDialogRollback
)

// branchSession is the state of the branch popup while it is open and of the dialog it
// opened. It is reset when the project closes.
type branchSession struct {
	// open says the popup is shown. A dialog closes the popup first.
	open bool
	// repo is the root of the repository the popup lists and the dialogs and writes act on: the
	// one the log walks when the popup opened, or one the user picked in the popup. Empty for the
	// project's own repository (branchRoot).
	repo string
	// repoOpen says the panel of the repository repo is open beside its row, in the popup of a
	// project folder with several repositories (drawWorkspaceBranchPanel).
	repoOpen bool
	// gen counts the loads of the references; the answer of an older load is dropped.
	gen int
	// loading is set while the kernel reads; loaded once it answered.
	loading, loaded bool
	err             error
	refs            core.GitReferences
	sections        [3]logSection
	// collapsed holds the sections the user folded, by key: one of branchSectionKeys, or
	// "nested/" and a nested repository's ID.
	collapsed map[string]bool
	// expanded holds the folders of the reference trees the user opened, by "f", the
	// section's kind, "/" and the folder's path; a folder starts closed.
	expanded map[string]bool
	// menu is the key of the row whose menu is open (branchRowKey), empty for none.
	menu string

	dialog branchDialog
	// target is the reference the dialog is about: the branch created from, renamed,
	// checked out or deleted.
	target core.GitReference
	// blocking are the paths the checkout of target would overwrite.
	blocking []string
	// typed is the text of the name field the preview was computed for.
	typed   string
	preview core.BranchNamePreview
	// checkout says the created branch is checked out at once.
	checkout bool
	// fromPopup says the popup started the write or opened its dialog, outside the Git tool
	// window, so that the write shows the Console tab; the Log page opens the same dialogs.
	fromPopup bool
	// busy is set while a write runs; the dialogs' buttons are disabled meanwhile.
	busy bool
	// annotated says the new tag takes the typed message; otherwise it is lightweight.
	annotated bool
	// deleting are the local and remote branches the delete dialog deletes, in the order it lists
	// them; deleteSkipped counts the marked references it leaves out (branch_delete.go).
	deleting      []core.GitReference
	deleteSkipped int
	// deleteReport belongs to the operation. Its notification can reopen it after this
	// dialog has been dismissed or replaced.
	deleteReport     *branchDeleteReport
	deleteFromNotice bool
	deleteError      string
	deleteList       ui.ListState
	deleteResultList ui.ListState

	// common are the branches every repository of a project folder with several has
	// (branch_common.go).
	common commonBranches
	// across says the open dialog acts on a common branch in every repository: the new branch
	// dialog, the conflict dialog and the rollback dialog. write is that action.
	across bool
	write  commonWrite
}

// branchOperationTimeout bounds one branch write and the status read after it.
const branchOperationTimeout = gitTimeout

// headReference is the reference a branch is created from when HEAD is detached.
var headReference = core.GitReference{FullName: "HEAD", ShortName: "HEAD"}

// openBranches opens the popup, closes the other menus of the title bar, and reads the
// references of the open project.
func (a *App) openBranches() {
	p := a.project
	if p == nil || !p.hasRepository() {
		return
	}
	a.closeRemoteHostMenu()
	a.title.projectOpen = false
	a.title.gearOpen = false
	a.title.runConfigOpen = false
	b := &a.branch
	b.open, b.menu, b.dialog = true, "", branchDialogNone
	b.repo, b.repoOpen = p.logBranchRepo(), false
	b.search.SetText("")
	if b.collapsed == nil {
		b.collapsed, b.expanded = map[string]bool{}, map[string]bool{}
	}
	a.loadBranches(p)
	a.loadCommonBranches(p)
}

// closeBranches closes the popup and the row menu in it.
func (a *App) closeBranches() {
	a.branch.open, a.branch.repoOpen, a.branch.menu = false, false, ""
}

// leaveBranches closes the popup before a write or a dialog starts and records whether the
// popup started it.
func (a *App) leaveBranches() {
	a.branch.fromPopup = a.branch.open
	a.branch.across = false
	a.closeBranches()
}

// loadBranches reads the references of p in the background. A popup that reopens while
// a read is on its way drops that read's answer.
func (a *App) loadBranches(p *project) {
	b := &a.branch
	b.gen++
	gen := b.gen
	b.loading = true
	kernel, root := a.kernel, a.branchRoot(p)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		refs, sections, _, err := readReferences(ctx, kernel, root)
		return func(a *App) {
			b := &a.branch
			if b.gen != gen {
				return
			}
			b.loading, b.loaded = false, true
			b.refs, b.sections, b.err = refs, sections, err
		}
	})
}

// currentReference is the checked-out local branch among the loaded references, or HEAD
// when it is detached or the references are not loaded.
func (b *branchSession) currentReference() core.GitReference {
	for _, r := range b.refs.References {
		if r.Kind == "local" && r.IsCurrent {
			return r
		}
	}
	return headReference
}

// branchRoot is the root the branch dialogs and writes act in: the nested repository the log walks
// when the log opened them, otherwise the project's own repository.
func (a *App) branchRoot(p *project) string {
	if a.branch.repo != "" {
		return a.branch.repo
	}
	return p.git.repositoryRoot(p.root)
}

// selectBranchRepo makes the repository at root the one the popup's repository panel lists and its
// dialogs act on, "" or the project's own root for the project's own repository, and reads its
// references.
func (a *App) selectBranchRepo(p *project, root string) {
	b := &a.branch
	b.menu = ""
	if p.git.isRepository() && root == p.git.repositoryRoot(p.root) {
		root = ""
	}
	if b.repo == root {
		return
	}
	b.repo = root
	b.refs, b.sections = core.GitReferences{}, [3]logSection{}
	b.loaded, b.err = false, nil
	a.loadBranches(p)
}

// toggleBranchRepo opens the panel of the repository at root beside its row, or closes it when it
// is the one open.
func (a *App) toggleBranchRepo(p *project, root string) {
	b := &a.branch
	if b.repoOpen && a.branchRoot(p) == root {
		b.repoOpen, b.menu = false, ""
		return
	}
	a.selectBranchRepo(p, root)
	b.repoOpen = true
}

// runBranchWrite runs write against the repository of p in the background and reads the
// status after it. operation names the write for the log, failed words its failure for the
// user, and done reports its success once the status is in place.
func (a *App) runBranchWrite(p *project, operation string, failed func(reason string) string,
	write func(ctx context.Context, kernel Kernel, root string) error, done func(a *App, status core.GitStatus)) {
	a.runBranchWriteWithin(p, branchOperationTimeout, operation, failed, write, done)
}

// runBranchWriteWithin is runBranchWrite bounded by timeout instead of branchOperationTimeout, for
// a write that talks to a remote.
func (a *App) runBranchWriteWithin(p *project, timeout time.Duration, operation string, failed func(reason string) string,
	write func(ctx context.Context, kernel Kernel, root string) error, done func(a *App, status core.GitStatus)) {
	b := &a.branch
	b.busy = true
	if b.fromPopup {
		a.showGitConsole("")
	}
	kernel, root := a.kernel, a.branchRoot(p)
	updatesProject := root == p.git.repositoryRoot(p.root)
	a.background(p, timeout, func(ctx context.Context) func(*App) {
		err := write(ctx, kernel, root)
		var status core.GitStatus
		var generation uint64
		if err == nil {
			// Order the observation after the write, not when the operation was launched.
			if updatesProject {
				generation = p.gitStatusGeneration.Add(1)
			}
			status, err = kernel.GitStatus(core.WithQueryCategory(core.AutomaticRefresh(ctx), core.GitQueryReload), root)
		}
		return func(a *App) {
			b := &a.branch
			b.busy = false
			if err != nil {
				a.notifyError(failed(err.Error()))
				a.operationFailed(operation, err)
				return
			}
			// The project's status describes its own repository only; a nested one's branch is read
			// again with the repositories of the folder.
			if p.git.isRepository() && root == p.git.repositoryRoot(p.root) {
				if a.setGit(p, gitState{loaded: true, status: status}, generation) {
					a.gitStatusPublished(p)
				}
			} else {
				a.loadNestedRepos(p)
			}
			b.dialog = branchDialogNone
			done(a, status)
			if p.log.started {
				a.loadLog(p)
			}
		}
	})
}

// checkoutBranch checks out r, after asking the kernel whether local changes stand in the
// way. A branch that is already checked out only says so. surface is where the user asked.
func (a *App) checkoutBranch(p *project, r core.GitReference, surface actionSurface) {
	a.leaveBranches()
	if r.Kind == "local" && r.IsCurrent {
		a.notifyInfo(a.text.Branch.AlreadyOn(r.ShortName))
		return
	}
	a.performed("git.checkout", surface)
	b := &a.branch
	b.busy = true
	kernel, root := a.kernel, a.branchRoot(p)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		blocking, err := kernel.GitCheckoutPreflight(ctx, root, r)
		return func(a *App) {
			b := &a.branch
			b.busy = false
			if err != nil {
				a.notifyError(a.text.Branch.CheckoutFailed(err.Error()))
				a.operationFailed("git_checkout", err)
				return
			}
			if len(blocking) > 0 {
				b.dialog, b.target, b.blocking = branchDialogConflict, r, blocking
				return
			}
			a.checkoutWith(p, r, core.CheckoutPlain)
		}
	})
}

// checkoutWith checks out r in mode and reports the branch the repository is on after it.
func (a *App) checkoutWith(p *project, r core.GitReference, mode core.CheckoutMode) {
	a.runBranchWrite(p, "git_checkout", a.text.Branch.CheckoutFailed,
		func(ctx context.Context, kernel Kernel, root string) error {
			return kernel.GitCheckout(ctx, root, r, mode)
		},
		func(a *App, status core.GitStatus) { a.noticeCheckedOut(r.ShortName, status) })
}

// noticeCheckedOut says what the checkout reached: the branch, or a detached HEAD at name.
func (a *App) noticeCheckedOut(name string, status core.GitStatus) {
	if status.Branch == "" || status.Branch == "detached" {
		a.notifyInfo(a.text.Branch.Detached(name))
		return
	}
	a.notifySuccess(a.text.Branch.CheckedOut(status.Branch))
}

// beginCreate opens the dialog that creates a branch from r.
func (a *App) beginCreate(p *project, r core.GitReference) { a.openCreate(p, r, false) }

// openCreate opens the dialog that creates a branch from r, in every repository of the folder
// when across is set and r is a common branch.
func (a *App) openCreate(p *project, r core.GitReference, across bool) {
	a.leaveBranches()
	b := &a.branch
	b.dialog, b.target, b.checkout, b.across = branchDialogCreate, r, true, across
	b.typed = ""
	b.preview = a.previewBranchName(p, "", false)
	b.name.SetText(b.preview.InitialName)
	b.typed = b.name.Text()
	b.preview = a.previewBranchName(p, b.typed, false)
}

// beginRename opens the dialog that renames the local branch r.
func (a *App) beginRename(p *project, r core.GitReference) {
	a.leaveBranches()
	b := &a.branch
	b.dialog, b.target = branchDialogRename, r
	b.name.SetText(r.ShortName)
	b.typed = r.ShortName
	b.preview = a.previewBranchName(p, b.typed, false)
}

// beginRevision opens the dialog that checks out a typed tag or revision.
func (a *App) beginRevision() {
	a.leaveBranches()
	b := &a.branch
	b.dialog = branchDialogRevision
	b.revision.SetText("")
}

// cancelBranchDialog closes the open dialog without doing what it asked.
func (a *App) cancelBranchDialog() {
	if a.branch.dialog == branchDialogDelete || a.branch.dialog == branchDialogDeleteUnmerged || a.branch.dialog == branchDialogForceDelete || a.branch.dialog == branchDialogDeleteResult {
		a.branch.deleteReport = nil
		a.branch.deleteError = ""
	}
	a.branch.dialog, a.branch.across = branchDialogNone, false
}

// previewBranchName asks the kernel how the typed name is cleaned and whether it can be
// created. The computation is pure and answers at once. The branch being renamed is left
// out of the references, so that its own name is not a clash. A branch created in every
// repository must clash with none of their references.
func (a *App) previewBranchName(p *project, raw string, require bool) core.BranchNamePreview {
	b := &a.branch
	refs := b.refs.References
	if b.across {
		refs = b.common.allReferences()
	}
	var from *core.GitReference
	switch b.dialog {
	case branchDialogCreate:
		from = &b.target
	case branchDialogRename:
		refs = slices.DeleteFunc(slices.Clone(refs), func(r core.GitReference) bool {
			return r.Kind == "local" && r.FullName == b.target.FullName
		})
	}
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	preview, err := a.kernel.GitBranchNamePreview(ctx, core.BranchNameRequest{
		RawName: raw, RequireName: require, References: refs, From: from})
	if err != nil {
		// The kernel could not clean the name; the typed text stands, and the submit tells
		// the user what Git says.
		a.backgroundFailed("git_branch_name_preview", err)
		return core.BranchNamePreview{TypingCleanedName: raw, CleanedName: strings.TrimSpace(raw)}
	}
	return preview
}

// syncBranchName recomputes the preview when the name field changed since the last
// one, and replaces what the field shows with the cleaned name.
func (a *App) syncBranchName(p *project) {
	b := &a.branch
	text := b.name.Text()
	if text == b.typed {
		return
	}
	b.preview = a.previewBranchName(p, text, false)
	if b.preview.TypingCleanedName != text {
		b.name.SetText(b.preview.TypingCleanedName)
	}
	b.typed = b.name.Text()
}

// branchNameError words the preview's error, empty when the name can be used.
func (a *App) branchNameError() string { return a.branchNameErrorText(a.branch.preview.Error) }

// branchNameErrorText words why a branch name cannot be used, empty for no error. Every
// dialog that names a new branch words Core's verdict with it.
func (a *App) branchNameErrorText(e *core.BranchNameError) string {
	if e == nil {
		return ""
	}
	t := a.text.Branch
	switch e.Code {
	case core.BranchNameEmpty:
		return t.NameEmpty
	case core.BranchNameHead:
		return t.NameHead
	case core.BranchNameClashesWithRemote:
		return t.NameRemote(e.Name)
	case core.BranchNameClashesWithDirectory:
		return t.NameDirectory(e.Name)
	case core.BranchNameAlreadyExists:
		return t.NameExists(e.Name)
	case core.BranchNameClashesWithBranchPrefix:
		return t.NamePrefix(e.Name, e.Branch)
	}
	return string(e.Code)
}

// submitName checks the typed name as a submit does and returns the name to create, or
// false when the dialog has to show why it cannot.
func (a *App) submitName(p *project) (string, bool) {
	b := &a.branch
	b.preview = a.previewBranchName(p, b.name.Text(), true)
	b.typed = b.name.Text()
	if b.preview.Error != nil {
		return "", false
	}
	return b.preview.CleanedName, true
}

// submitCreate creates the branch the create dialog describes.
func (a *App) submitCreate(p *project) {
	b := &a.branch
	if b.busy {
		return
	}
	name, ok := a.submitName(p)
	if !ok {
		return
	}
	from, checkout := b.target, b.checkout
	a.performed("git.branch.create", surfaceButton)
	if b.across {
		a.planCommon(p, commonWrite{operation: core.WorkspaceBranchCreate, reference: from, name: name, checkout: checkout})
		return
	}
	a.runBranchWrite(p, "git_branch_create", a.text.Branch.CreateFailed,
		func(ctx context.Context, kernel Kernel, root string) error {
			return kernel.GitCreateBranch(ctx, root, name, from, checkout)
		},
		func(a *App, status core.GitStatus) { a.notifySuccess(a.text.Branch.Created(name)) })
}

// submitRename renames the branch the rename dialog is about.
func (a *App) submitRename(p *project) {
	b := &a.branch
	if b.busy {
		return
	}
	name, ok := a.submitName(p)
	if !ok || name == b.target.ShortName {
		return
	}
	branch := b.target
	root := a.branchRoot(p)
	a.performed("git.branch.rename", surfaceButton)
	a.runBranchWrite(p, "git_branch_rename", a.text.Branch.RenameFailed,
		func(ctx context.Context, kernel Kernel, root string) error {
			return kernel.GitRenameBranch(ctx, root, branch, name)
		},
		func(a *App, status core.GitStatus) {
			a.renameLogReference(p, root, branch.FullName, "refs/heads/"+name, name)
			a.notifySuccess(a.text.Branch.Renamed(name))
		})
}

// submitRevision checks out the typed revision detached.
func (a *App) submitRevision(p *project) {
	b := &a.branch
	revision := strings.TrimSpace(b.revision.Text())
	if b.busy || revision == "" {
		return
	}
	a.performed("git.checkoutRevision", surfaceButton)
	a.runBranchWrite(p, "git_checkout_revision", a.text.Branch.CheckoutFailed,
		func(ctx context.Context, kernel Kernel, root string) error {
			return kernel.GitCheckoutRevision(ctx, root, revision)
		},
		func(a *App, status core.GitStatus) { a.noticeCheckedOut(revision, status) })
}

// resolveConflict checks out the blocked target in mode, as the conflict dialog chose: in every
// repository of the planned action when the dialog is about a common branch.
func (a *App) resolveConflict(p *project, mode core.CheckoutMode) {
	b := &a.branch
	if b.busy {
		return
	}
	if b.across {
		a.runCommon(p, b.write, mode)
		return
	}
	a.checkoutWith(p, b.target, mode)
}
