package workbench

import (
	"context"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// This file creates and deletes tags from the branch popup (matrix id git-branches-remotes):
// a New Tag action that tags HEAD, optionally with an annotation, and a Delete item on a tag's
// menu. Both run through the branch writes, so the popup's references and the log are read
// again afterwards. The dialogs are declared in branch_view.go's dialog switch.

// beginCreateTag opens the dialog that creates a tag on HEAD; beginTagAt puts it on another
// commit.
func (a *App) beginCreateTag(p *project) {
	a.leaveBranches()
	b := &a.branch
	b.dialog, b.target, b.annotated = branchDialogTag, headReference, false
	b.name.SetText("")
	b.tagMessage.SetText("")
}

// beginDeleteTag opens the dialog that confirms deleting the tag r.
func (a *App) beginDeleteTag(r core.GitReference) {
	a.leaveBranches()
	b := &a.branch
	b.dialog, b.target = branchDialogTagDelete, r
}

// drawTagDialog declares the dialog that creates a tag: its name, an annotation when the
// annotated choice is on, and the commit it is put on.
func (a *App) drawTagDialog(c ui.C, p *project) {
	b := &a.branch
	lang := a.language()
	name := strings.TrimSpace(b.name.Text())
	ready := !b.busy && name != ""
	submitted := false
	description := i18n.Shared(lang, "desktop.tags.createFrom")
	if b.target.FullName != headReference.FullName {
		description = i18n.SharedFormat(lang, "desktop.tags.createAt", map[string]string{"hash": b.target.ShortName})
	}
	a.branchDialogOf(c, i18n.Shared(lang, "desktop.tags.createTitle"), description, func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			submitted = ui.TextField(c, &b.name, i18n.Shared(lang, "desktop.tags.name"), i18n.Shared(lang, "desktop.tags.name")).FillWidth().Submitted()
			ui.Checkbox(c, &b.annotated, i18n.Shared(lang, "desktop.tags.annotated")).Disabled(b.busy)
			if b.annotated {
				ui.TextField(c, &b.tagMessage, i18n.Shared(lang, "desktop.tags.message"), i18n.Shared(lang, "desktop.tags.message")).FillWidth()
			}
		})
	}, func() {
		if ui.Button(c, a.text.Branch.Cancel).Outline().Clicked() {
			c.After(a.cancelBranchDialog)
		}
		if ui.Button(c, i18n.Shared(lang, "desktop.tags.create")).Disabled(!ready).Clicked() {
			c.After(func() { a.submitTag(p) })
		}
	})
	if submitted && ready {
		c.After(func() { a.submitTag(p) })
	}
}

// drawTagDeleteDialog declares the dialog that confirms deleting the tag of the popup.
func (a *App) drawTagDeleteDialog(c ui.C, p *project) {
	b := &a.branch
	lang := a.language()
	a.branchDialogOf(c, i18n.Shared(lang, "desktop.tags.deleteTitle"), i18n.SharedFormat(lang, "desktop.tags.deletePrompt", map[string]string{"name": b.target.ShortName}), nil, func() {
		if ui.Button(c, a.text.Branch.Cancel).Outline().Clicked() {
			c.After(a.cancelBranchDialog)
		}
		if ui.Button(c, i18n.Shared(lang, "desktop.tags.delete")).Destructive().Disabled(b.busy).Clicked() {
			c.After(func() { a.confirmDeleteTag(p) })
		}
	})
}

// submitTag creates the tag the open dialog names on the commit it was opened on: HEAD, or
// the commit of the log's menu.
func (a *App) submitTag(p *project) {
	b := &a.branch
	name := strings.TrimSpace(b.name.Text())
	if b.busy || name == "" {
		return
	}
	revision := b.target.FullName
	if revision == "" {
		revision = headReference.FullName
	}
	message := ""
	if b.annotated {
		message = strings.TrimSpace(b.tagMessage.Text())
	}
	a.performed("git.tag.create", surfaceButton)
	a.runBranchWrite(p, "git_tag_create", func(reason string) string {
		return i18n.SharedFormat(a.language(), "desktop.tags.failed", map[string]string{"reason": reason})
	},
		func(ctx context.Context, kernel Kernel, root string) error {
			return kernel.GitCreateTag(ctx, root, name, revision, message)
		},
		func(a *App, status core.GitStatus) {
			a.notifySuccess(i18n.SharedFormat(a.language(), "desktop.tags.created", map[string]string{"name": name}))
		})
}

// confirmDeleteTag deletes the tag the delete dialog names.
func (a *App) confirmDeleteTag(p *project) {
	b := &a.branch
	if b.busy {
		return
	}
	name := b.target.ShortName
	a.performed("git.tag.delete", surfaceButton)
	a.runBranchWrite(p, "git_tag_delete", func(reason string) string {
		return i18n.SharedFormat(a.language(), "desktop.tags.deleteFailed", map[string]string{"reason": reason})
	},
		func(ctx context.Context, kernel Kernel, root string) error {
			return kernel.GitDeleteTag(ctx, root, name)
		},
		func(a *App, status core.GitStatus) {
			a.notifySuccess(i18n.SharedFormat(a.language(), "desktop.tags.deleted", map[string]string{"name": name}))
		})
}
