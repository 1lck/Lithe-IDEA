package workbench

import (
	"errors"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
)

// This file holds the file opening actions of the project tree that leave the editor: F4
// opens the selected file (matrix id file-open-selected), and Open With asks the system for
// the application to open a file with (matrix id file-open-with), through the platform's
// application picker and the open-with call of the Viva toolkit.

// openSelectedTreeFile opens the file the tree selected, or expands the folder it selected.
func (a *App) openSelectedTreeFile(p *project) {
	n := p.tree.selected
	if n == nil || n.dir {
		return
	}
	a.performed("workspace.tree.openSelected", surfaceShortcut)
	a.activateTreeNode(p, n)
}

// openTreeFileWith asks for an application and opens file with it. A cancelled picker does
// nothing; a failure is shown to the user.
func (a *App) openTreeFileWith(file string) {
	lang := a.language()
	a.performed("workspace.tree.openWith", surfaceMenu)
	paths, err := app.OpenFiles(app.OpenFileOptions{Title: i18n.Shared(lang, "desktop.files.openWithTitle")})
	if errors.Is(err, app.ErrCanceled) || (err == nil && len(paths) == 0) {
		return
	}
	if err == nil {
		err = app.OpenWith(paths[0], filepath.Clean(file))
	}
	if err != nil {
		a.notify(i18n.SharedFormat(lang, "desktop.files.openWithFailed", map[string]string{"reason": treeErrorReason(err)}))
	}
}
