package workbench

import (
	"path/filepath"
	"runtime"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
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
	if p.standalone {
		if d := a.selectedEditorDocument(); d != nil {
			return d.name + windowTitleSeparator + a.text.App.Name
		}
		return a.text.App.Name
	}
	title := a.projectDisplayName(p)
	if runtime.GOOS == "darwin" {
		return title
	}
	if d := p.selectedDocument(p.terms.bench.FocusedGroup); d != nil && d.path != "" {
		title += windowTitleSeparator + filepath.Base(d.path)
	}
	return title
}

// projectDisplayName is the name the taskbar and Alt+Tab show for p: its folder's name, or
// that name under the folder above it when another open tab shows a project of the same name,
// so two checkouts of one repository do not look alike. A remote workspace's name says the
// connection it is on, as "folder [SSH: connection]" or "folder [WSL: distribution]".
func (a *App) projectDisplayName(p *project) string {
	name := p.name
	if r := p.remote; r != nil {
		return i18n.SharedFormat(a.language(), "desktop.remote.workspace.title", map[string]string{"folder": name, "kind": r.host.kind(a.language()), "connection": r.name})
	}
	if !a.projectNameShared(p) {
		return name
	}
	parent := filepath.Base(filepath.Dir(p.root))
	if parent == "" || parent == "." || parent == string(filepath.Separator) {
		return name
	}
	return filepath.Join(parent, name)
}

// projectNameShared reports whether another open tab shows a project with p's name.
func (a *App) projectNameShared(p *project) bool {
	if a.sessions == nil {
		return false
	}
	for _, other := range a.sessions.list {
		if other == a || other.project == nil {
			continue
		}
		if other.project.name == p.name {
			return true
		}
	}
	return false
}

// syncWindowTitle gives the window the title windowTitle names, when it changed. It runs
// once per build; the comparison keeps typing and scrolling from reaching the system.
func (a *App) syncWindowTitle() {
	if a.window == nil {
		return
	}
	title := systemTitle(a.windowTitle())
	if title == a.shownTitle {
		return
	}
	a.shownTitle = title
	_ = a.window.SetTitle(title)
}

// systemTitle is title in the form Window.SetTitle accepts. Viva refuses a title that is not
// valid UTF-8 or holds a NUL byte and keeps the old one, and a Linux file or folder name need
// not be valid UTF-8, so each invalid sequence and each NUL becomes U+FFFD.
func systemTitle(title string) string {
	title = strings.ToValidUTF8(title, "\uFFFD")
	return strings.ReplaceAll(title, "\x00", "\uFFFD")
}
