package workbench

import (
	"context"
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

// branchState is what the window keeps for the branch popup of the title bar: its text
// fields, which live as long as the window, and the session of the open popup.
type branchState struct {
	// search filters the list; name is the name typed in the create and rename dialogs;
	// revision is the revision typed in the checkout dialog.
	search, name, revision ui.Field
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
	// branchDialogDelete confirms deleting a local branch.
	branchDialogDelete
)

// branchSession is the state of the branch popup while it is open and of the dialog it
// opened. It is reset when the project closes.
type branchSession struct {
	// open says the popup is shown. A dialog closes the popup first.
	open bool
	// gen counts the loads of the references; the answer of an older load is dropped.
	gen int
	// loading is set while the kernel reads; loaded once it answered.
	loading, loaded bool
	err             error
	refs            core.GitReferences
	sections        [3]logSection
	// collapsed holds the sections the user folded, by key: "recent" or "s"+kind.
	collapsed map[string]bool
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
}

// branchOperationTimeout bounds one branch write and the status read after it.
const branchOperationTimeout = gitTimeout

// headReference is the reference a branch is created from when HEAD is detached.
var headReference = core.GitReference{FullName: "HEAD", ShortName: "HEAD"}

// openBranches opens the popup, closes the other menus of the title bar, and reads the
// references of the open project.
func (a *App) openBranches() {
	p := a.project
	if p == nil || !p.git.isRepository() {
		return
	}
	a.title.projectOpen = false
	a.title.gearOpen = false
	b := &a.branch
	b.open, b.menu, b.dialog = true, "", branchDialogNone
	b.search.SetText("")
	if b.collapsed == nil {
		b.collapsed = map[string]bool{}
	}
	a.loadBranches(p)
}

// closeBranches closes the popup and the row menu in it.
func (a *App) closeBranches() {
	a.branch.open, a.branch.menu = false, ""
}

// leaveBranches closes the popup before a write or a dialog starts and records whether the
// popup started it.
func (a *App) leaveBranches() {
	a.branch.fromPopup = a.branch.open
	a.closeBranches()
}

// loadBranches reads the references of p in the background. A popup that reopens while
// a read is on its way drops that read's answer.
func (a *App) loadBranches(p *project) {
	b := &a.branch
	b.gen++
	gen := b.gen
	b.loading = true
	kernel, root := a.kernel, p.git.repositoryRoot(p.root)
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

// runBranchWrite runs write against the repository of p in the background and reads the
// status after it. operation names the write for the log, failed words its failure for the
// user, and done reports its success once the status is in place.
func (a *App) runBranchWrite(p *project, operation string, failed func(reason string) string,
	write func(ctx context.Context, kernel Kernel, root string) error, done func(a *App, status core.GitStatus)) {
	b := &a.branch
	b.busy = true
	if b.fromPopup {
		a.showGitConsole("")
	}
	kernel, root := a.kernel, p.git.repositoryRoot(p.root)
	a.background(p, branchOperationTimeout, func(ctx context.Context) func(*App) {
		err := write(ctx, kernel, root)
		var status core.GitStatus
		if err == nil {
			status, err = kernel.GitStatus(core.AutomaticRefresh(ctx), p.root)
		}
		return func(a *App) {
			b := &a.branch
			b.busy = false
			if err != nil {
				a.notify(failed(err.Error()))
				a.gitOperationFailed(operation, err)
				return
			}
			a.setGit(p, gitState{loaded: true, status: status})
			if p.log.started {
				a.loadLog(p)
			}
			b.dialog = branchDialogNone
			done(a, status)
		}
	})
}

// checkoutBranch checks out r, after asking the kernel whether local changes stand in the
// way. A branch that is already checked out only says so.
func (a *App) checkoutBranch(p *project, r core.GitReference) {
	a.leaveBranches()
	if r.Kind == "local" && r.IsCurrent {
		a.notify(a.text.Branch.AlreadyOn(r.ShortName))
		return
	}
	a.performed("git.checkout", surfaceMenu)
	b := &a.branch
	b.busy = true
	kernel, root := a.kernel, p.git.repositoryRoot(p.root)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		blocking, err := kernel.GitCheckoutPreflight(ctx, root, r)
		return func(a *App) {
			b := &a.branch
			b.busy = false
			if err != nil {
				a.notify(a.text.Branch.CheckoutFailed(err.Error()))
				a.gitOperationFailed("git_checkout", err)
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
		a.notify(a.text.Branch.Detached(name))
		return
	}
	a.notify(a.text.Branch.CheckedOut(status.Branch))
}

// beginCreate opens the dialog that creates a branch from r.
func (a *App) beginCreate(p *project, r core.GitReference) {
	a.leaveBranches()
	b := &a.branch
	b.dialog, b.target, b.checkout = branchDialogCreate, r, true
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

// beginDelete opens the dialog that confirms deleting the local branch r.
func (a *App) beginDelete(r core.GitReference) {
	a.leaveBranches()
	b := &a.branch
	b.dialog, b.target = branchDialogDelete, r
}

// cancelBranchDialog closes the open dialog without doing what it asked.
func (a *App) cancelBranchDialog() {
	a.branch.dialog = branchDialogNone
}

// previewBranchName asks the kernel how the typed name is cleaned and whether it can be
// created. The computation is pure and answers at once. The branch being renamed is left
// out of the references, so that its own name is not a clash.
func (a *App) previewBranchName(p *project, raw string, require bool) core.BranchNamePreview {
	b := &a.branch
	refs := b.refs.References
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
		a.gitOperationFailed("git_branch_name_preview", err)
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
	a.runBranchWrite(p, "git_branch_create", a.text.Branch.CreateFailed,
		func(ctx context.Context, kernel Kernel, root string) error {
			return kernel.GitCreateBranch(ctx, root, name, from, checkout)
		},
		func(a *App, status core.GitStatus) { a.notify(a.text.Branch.Created(name)) })
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
	a.performed("git.branch.rename", surfaceButton)
	a.runBranchWrite(p, "git_branch_rename", a.text.Branch.RenameFailed,
		func(ctx context.Context, kernel Kernel, root string) error {
			return kernel.GitRenameBranch(ctx, root, branch, name)
		},
		func(a *App, status core.GitStatus) { a.notify(a.text.Branch.Renamed(name)) })
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

// resolveConflict checks out the blocked target in mode, as the conflict dialog chose.
func (a *App) resolveConflict(p *project, mode core.CheckoutMode) {
	b := &a.branch
	if b.busy {
		return
	}
	a.checkoutWith(p, b.target, mode)
}

// confirmDelete deletes the branch the delete dialog is about.
func (a *App) confirmDelete(p *project) {
	b := &a.branch
	if b.busy {
		return
	}
	branch := b.target
	var deleted core.GitBranchDeletion
	a.performed("git.branch.delete", surfaceButton)
	a.runBranchWrite(p, "git_branch_delete", a.text.Branch.DeleteFailed,
		func(ctx context.Context, kernel Kernel, root string) (err error) {
			deleted, err = kernel.GitDeleteBranch(ctx, root, branch)
			return err
		},
		func(a *App, status core.GitStatus) {
			target := deleted.DeletedTarget
			if len(target) > 10 {
				target = target[:10]
			}
			a.notify(a.text.Branch.Deleted(deleted.Name, target))
		})
}
