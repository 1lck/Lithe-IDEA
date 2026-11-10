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
	"github.com/vivaui/viva/ui"
)

// cloneState belongs to the window, not to a project: cloning can start on the
// welcome screen or replace a project after the existing close checks succeed.
type cloneState struct {
	source, parent, name   ui.Field
	open, busy, cancelling bool
	generation             uint64
	cancel                 context.CancelFunc
	err                    string
}

func (a *App) openClone(surface string) {
	c := &a.clone
	if c.open {
		return
	}
	c.generation++
	c.open, c.busy, c.cancelling, c.err = true, false, false, ""
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

// dismissClone closes the dialog; the page gives the keyboard back to where it
// was when the dialog opened.
func (a *App) dismissClone() { a.closeClone() }

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
