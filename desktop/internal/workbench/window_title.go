package workbench

import (
	"path/filepath"
	"runtime"
)

// The system title of the window names what it shows, so the task switcher, the taskbar
// preview and the Window menu tell windows apart: "project – file" for the file of the
// focused editor group, only the project when that group shows a terminal, a tool tab or
// nothing, and the application's name with no project. On macOS the title names only the
// project, as the earlier client did; the file is in the window's own tab strip. The
// window draws its own title bar, so the title is never painted by Lithe itself.

// windowTitleSeparator is the en dash with spaces IntelliJ IDEA puts between the parts.
const windowTitleSeparator = " – "

// windowTitle is the title the window should have now.
func (a *App) windowTitle() string {
	p := a.project
	if p == nil {
		return a.text.App.Name
	}
	title := p.name
	if runtime.GOOS == "darwin" {
		return title
	}
	if d := p.selectedDocument(p.terms.bench.FocusedGroup); d != nil && d.path != "" {
		title += windowTitleSeparator + filepath.Base(d.path)
	}
	return title
}

// syncWindowTitle gives the window the title windowTitle names, when it changed. It runs
// once per build; the comparison keeps typing and scrolling from reaching the system.
func (a *App) syncWindowTitle() {
	if a.window == nil {
		return
	}
	title := a.windowTitle()
	if title == a.shownTitle {
		return
	}
	a.shownTitle = title
	_ = a.window.SetTitle(title)
}
