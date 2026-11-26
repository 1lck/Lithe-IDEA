package workbench

import (
	"context"
	"errors"
	"path/filepath"
	"runtime"

	"github.com/1lck/Lithe-IDEA/desktop/internal/fileapps"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// This file gives a Project tree row its Open In submenu, as the IDE's: Open With on a file,
// then the file manager and the terminal (matrix id file-open-with). Open With lists what the
// system's own Open With menu lists, through the fileapps package: the default application
// first, the other applications the system associates with the file, and Other… for any
// application, which is the application picker of openTreeFileWith.

// treeFileApps and treeOpenWithApp are the system calls Open With makes. They are variables so
// a test can answer them without the applications of the machine running it.
var (
	treeFileApps    = fileapps.List
	treeOpenWithApp = fileapps.Open
)

// treeApps is what the Open With submenu remembers between paints. The system is asked again
// each time the Open In submenu opens, off the window thread, because it reads the system's
// association database; the list found last for the same file is shown meanwhile.
type treeApps struct {
	// file is the file the list is of, and list what the system offered for it.
	file string
	list []fileapps.App
	// loading is the file a lookup is running for, or empty.
	loading string
	// drawn says this paint declared the Open In submenu of a file, and shown says the paint
	// before did, so the submenu asks once each time it opens.
	drawn, shown bool
}

// endFrame readies the marks for the next paint.
func (m *treeApps) endFrame() {
	m.shown, m.drawn = m.drawn, false
}

// openInMenu declares the Open In submenu of the row at full: Open With for a file, then the
// file manager, which shows the row, and the terminal, which opens in the row's folder or the
// folder of its file.
func (a *App) openInMenu(c ui.C, p *project, menu *ui.MenuItems, full string, dir bool) {
	language := a.language()
	menu.Sub(i18n.Shared(language, "desktop.files.openIn"), func(sub *ui.MenuItems) {
		if p.remote == nil && !dir {
			a.askTreeApps(full)
			sub.Sub(i18n.Shared(language, "desktop.files.openWith"), func(apps *ui.MenuItems) {
				a.openWithMenu(c, apps, full)
			})
		}
		if p.remote == nil && sub.Item(fileManagerLabel(language)).Clicked() {
			c.After(func() {
				a.performed("workspace.tree.reveal", surfaceContextMenu)
				a.revealPath(full)
			})
		}
		if sub.Item(i18n.Shared(language, "desktop.files.openInTerminal")).Clicked() {
			folder := full
			if !dir {
				folder = filepath.Dir(full)
			}
			c.After(func() { a.openTreeTerminal(p, folder) })
		}
	})
}

// fileManagerLabel is the Open In item that shows a row in the platform's file manager.
func fileManagerLabel(language i18n.Language) string {
	if runtime.GOOS == "windows" {
		return i18n.Shared(language, "desktop.files.openInExplorer")
	}
	return i18n.Shared(language, "desktop.files.openInFinder")
}

// askTreeApps asks the system for the applications of file when the Open In submenu has just
// opened, or opened for another file. It asks on this paint, not through ui.C.After: the
// submenu usually opens when the pointer rests on it, in a paint that delivers no click, and
// such a paint drops what is deferred. The lookup runs in the background, so asking here does
// not hold the paint.
func (a *App) askTreeApps(file string) {
	m := &a.treeApps
	m.drawn = true
	if !m.shown || m.file != file {
		a.findTreeApps(file)
	}
}

// openWithMenu declares the Open With submenu of file: the default application and a line
// under it, the other applications, then a line and Other…. While the system has not yet
// answered for this file, a disabled row says it is being asked; a system that offers no
// application leaves Other… alone.
func (a *App) openWithMenu(c ui.C, menu *ui.MenuItems, file string) {
	language := a.language()
	menu.WidthRange(200, 420)
	m := &a.treeApps
	switch {
	case m.file != file || m.loading == file && len(m.list) == 0:
		menu.Item(i18n.Shared(language, "desktop.files.openWithFinding")).Disabled(true)
		menu.Separator()
	case len(m.list) > 0:
		labels := fileapps.Labels(m.list, func(name, id string) string {
			return i18n.SharedFormat(language, "desktop.files.openWithAppPath", map[string]string{"name": name, "path": appLocation(id)})
		})
		for i, chosen := range m.list {
			label := labels[i]
			if chosen.Default {
				label = i18n.SharedFormat(language, "desktop.files.openWithDefault", map[string]string{"name": label})
			}
			if menu.Item(label).Clicked() {
				c.After(func() { a.openTreeFileWithApp(file, chosen) })
			}
			if chosen.Default && i+1 < len(m.list) {
				menu.Separator()
			}
		}
		menu.Separator()
	}
	if menu.Item(i18n.Shared(language, "desktop.files.openWithOther")).Clicked() {
		c.After(func() { a.openTreeFileWith(file) })
	}
}

// appLocation is where the application id is, for telling apart two applications of one
// name: the folder of a bundle or executable, or the identity of a packaged app.
func appLocation(id string) string {
	if filepath.IsAbs(id) {
		return filepath.Dir(id)
	}
	return id
}

// findTreeApps asks the system for the applications of file off the window thread, unless a
// lookup for it is already running, and hands the list to the Open With submenu when it is
// done. A list of another file is dropped first, so it is never offered for this one. A failed
// lookup leaves Other…, the application picker.
func (a *App) findTreeApps(file string) {
	m := &a.treeApps
	if m.file != file {
		m.file, m.list = file, nil
	}
	if m.loading == file {
		return
	}
	m.loading = file
	list := treeFileApps
	a.background(nil, 0, func(context.Context) func(*App) {
		found, err := list(file)
		return func(a *App) {
			m := &a.treeApps
			if m.loading == file {
				m.loading = ""
			}
			if err != nil {
				a.backgroundFailed("project_tree_list_apps", documentLogError(err))
			}
			if m.file == file {
				m.list = found
			}
		}
	})
}

// openTreeFileWithApp opens file with an application the system offered for it, off the
// window thread, as the system's call waits for the system to take the file. A failure is
// shown to the user, naming the application when the system no longer offers it.
func (a *App) openTreeFileWithApp(file string, chosen fileapps.App) {
	a.performed("workspace.tree.openWithApp", surfaceContextMenu)
	open := treeOpenWithApp
	a.background(nil, 0, func(context.Context) func(*App) {
		err := open(file, chosen)
		if err == nil {
			return nil
		}
		return func(a *App) {
			a.operationFailed("project_tree_open_with", documentLogError(err))
			lang := a.language()
			if errors.Is(err, fileapps.ErrNotOffered) {
				a.notifyError(i18n.SharedFormat(lang, "desktop.files.openWithGone", map[string]string{"name": chosen.Name}))
				return
			}
			a.notifyError(i18n.SharedFormat(lang, "desktop.files.openWithFailed", map[string]string{"reason": treeErrorReason(err)}))
		}
	})
}

// openTreeTerminal opens a terminal in folder in the Terminal tool window and gives it the
// keyboard. The terminal is made before the tool window opens, so the window does not open a
// terminal of its own as well; a terminal the kernel refuses is reported by newTerminalWith.
func (a *App) openTreeTerminal(p *project, folder string) {
	a.performed("workspace.tree.openInTerminal", surfaceContextMenu)
	t := a.newTerminalWith(p, terminalOptions{dir: folder, activate: true})
	if t == nil {
		return
	}
	a.openToolWindow(itemTerminal)
	a.focusTerminal(t.id)
}
