package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

var (
	cloneScope   = tree.ID(shellPage, "clone-scope")
	cloneDismiss = tree.ID(shellPage, "clone-dismiss")
	cloneClose   = tree.ID(shellPage, "clone-close")
	cloneSource  = tree.ID(shellPage, "clone-source")
	cloneParent  = tree.ID(shellPage, "clone-parent")
	cloneName    = tree.ID(shellPage, "clone-name")
	cloneChoose  = tree.ID(shellPage, "clone-choose")
	cloneCancel  = tree.ID(shellPage, "clone-cancel")
	cloneConfirm = tree.ID(shellPage, "clone-confirm")
)

// cloneState belongs to the window, not to a project: cloning can start on the
// welcome screen or replace a project after the existing close checks succeed.
type cloneState struct {
	source, parent, name   ui.Field
	open, busy, cancelling bool
	generation             uint64
	cancel                 context.CancelFunc
	err                    string
	returnFocus            gfx.ID
	restoreFocus           bool
}

func (a *App) openClone(surface string) {
	c := &a.clone
	if c.open {
		return
	}
	c.generation++
	c.open, c.busy, c.cancelling, c.err = true, false, false, ""
	c.restoreFocus = false
	c.returnFocus = welcomeMore
	if a.project != nil {
		c.returnFocus = chromeProjectButton
	}
	c.source.SetText("")
	c.name.SetText("")
	home, err := os.UserHomeDir()
	if err != nil {
		a.gitOperationFailed("clone_home_directory", documentLogError(err))
	}
	c.parent.SetText(home)
	a.performed("workspace.clone", surface)
}

// closeClone invalidates pending picker results and cancels the Core operation.
// Git may have created partial output, which is deliberately not deleted.
func (a *App) closeClone() {
	c := &a.clone
	c.generation++
	if c.cancel != nil {
		c.cancel()
		c.cancel = nil
	}
	c.open, c.busy, c.cancelling = false, false, false
}

func (a *App) cancelClone() {
	c := &a.clone
	if c.busy {
		c.cancelling = true
		if c.cancel != nil {
			c.cancel()
		}
		return
	}
	a.dismissClone()
}

func (a *App) dismissClone() {
	a.closeClone()
	// The closing frame still paints the dialog's focus trap. Restore after
	// that frame, and only if another clone dialog has not replaced it.
	generation := a.clone.generation
	a.post(func(a *App) {
		if !a.clone.open && a.clone.generation == generation {
			a.clone.restoreFocus = true
		}
	})
}

func (a *App) chooseCloneParent() {
	c := &a.clone
	generation := c.generation
	title := i18n.Shared(a.language(), "desktop.clone.parent")
	a.background(nil, 0, func(context.Context) func(*App) {
		path, err := app.OpenDirectory(app.OpenDirectoryOptions{Title: title})
		return func(a *App) {
			c := &a.clone
			if !c.open || c.generation != generation || c.busy {
				if err != nil && !errors.Is(err, app.ErrCanceled) {
					a.gitOperationFailed("clone_choose_directory", documentLogError(err))
				}
				// log-exempt: 用户取消：关闭对话框后不再应用目录选择结果。
				return
			}
			if errors.Is(err, app.ErrCanceled) {
				// log-exempt: 用户取消：目录选择器没有选择结果。
				return
			}
			if err != nil {
				a.gitOperationFailed("clone_choose_directory", documentLogError(err))
				c.err = err.Error()
				return
			}
			c.parent.SetText(path)
			c.err = ""
		}
	})
}

// cloneDestination enforces the native filesystem boundary: the editable name
// must be one path component so it cannot escape the directory the user picked.
func cloneDestination(parent, name string) (string, bool) {
	if !filepath.IsAbs(parent) || name == "" || !filepath.IsLocal(name) || filepath.Base(name) != name {
		return "", false
	}
	return filepath.Join(parent, name), true
}

func (a *App) submitClone() {
	c := &a.clone
	if !c.open || c.busy || strings.TrimSpace(c.source.Text()) == "" {
		return
	}
	parent, source := c.parent.Text(), c.source.Text()
	destination, valid := cloneDestination(parent, c.name.Text())
	if !valid {
		a.gitOperationFailed("git_clone_destination", errors.New("invalid clone destination"))
		c.err = i18n.Shared(a.language(), "desktop.clone.invalidName")
		return
	}
	c.busy, c.cancelling, c.err = true, false, ""
	generation := c.generation
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	c.cancel = cancel
	kernel := a.kernel
	a.background(nil, 0, func(context.Context) func(*App) {
		defer cancel()
		err := kernel.GitClone(ctx, parent, source, destination)
		return func(a *App) {
			c := &a.clone
			if !c.open || c.generation != generation {
				if err != nil && !errors.Is(err, context.Canceled) {
					a.gitOperationFailed("git_clone", errors.New("clone operation failed after closing"))
				}
				// log-exempt: 用户取消：关闭对话框后不再应用克隆结果。
				return
			}
			c.cancel = nil
			c.busy = false
			if c.cancelling || errors.Is(err, context.Canceled) {
				if err != nil && !errors.Is(err, context.Canceled) {
					a.gitOperationFailed("git_clone", errors.New("clone operation failed during cancellation"))
				}
				// log-exempt: 用户取消：克隆已结束，任何部分目录留给用户处理。
				a.dismissClone()
				return
			}
			if err != nil {
				// Git's stderr can contain credentials or repository URLs. Neither
				// the on-screen message nor the log may reproduce those bytes.
				a.gitOperationFailed("git_clone", errors.New("clone operation failed"))
				c.err = i18n.Shared(a.language(), "desktop.clone.failed")
				return
			}
			a.closeClone()
			a.openProject(destination)
		}
	})
}

func (a *App) drawCloneDialog(f *ui.Frame) {
	c := &a.clone
	if !c.open {
		return
	}
	language := a.language()
	title := i18n.Shared(language, "desktop.clone.title")
	sourceLabel := i18n.Shared(language, "desktop.clone.source")
	parentLabel := i18n.Shared(language, "desktop.clone.parent")
	nameLabel := i18n.Shared(language, "desktop.clone.name")
	d := f.Dialog(ui.DialogSpec{Title: title, Width: 570,
		Scope: cloneScope, DismissID: cloneDismiss, CloseID: cloneClose, InitialFocusID: cloneSource})
	submitted := false
	d.Body(func() {
		f.Column().FillWidth().Gap(10).Children(func() {
			f.Text(sourceLabel)
			submitted = f.Field(&c.source, cloneSource, sourceLabel, i18n.Shared(language, "desktop.clone.sourcePlaceholder")).FillWidth().Disabled(c.busy).Submitted()
			f.Text(parentLabel)
			f.Row().FillWidth().Gap(8).Children(func() {
				f.Field(&c.parent, cloneParent, parentLabel, "").Grow(1).Disabled(c.busy)
				if f.Button(cloneChoose, i18n.Shared(language, "desktop.clone.choose")).Outline().Disabled(c.busy).Clicked() {
					a.chooseCloneParent()
				}
			})
			f.Text(nameLabel)
			if f.Field(&c.name, cloneName, nameLabel, i18n.Shared(language, "desktop.clone.namePlaceholder")).FillWidth().Disabled(c.busy).Submitted() {
				submitted = true
			}
			if c.err != "" {
				f.Paragraph(c.err, 3).Color(a.theme.Danger)
			}
		})
	})
	cancelled, confirmed := false, false
	d.Footer(func() {
		cancelled = f.Button(cloneCancel, i18n.Shared(language, "desktop.clone.cancel")).Outline().Disabled(c.cancelling).Clicked()
		label := i18n.Shared(language, "desktop.clone.submit")
		if c.busy {
			label = i18n.Shared(language, "desktop.clone.busy")
		}
		confirmed = f.Button(cloneConfirm, label).Disabled(c.busy || strings.TrimSpace(c.source.Text()) == "" || c.parent.Text() == "" || c.name.Text() == "").Clicked()
	})
	if cancelled || d.Dismissed() {
		a.cancelClone()
	} else if confirmed || submitted {
		a.submitClone()
	}
}
