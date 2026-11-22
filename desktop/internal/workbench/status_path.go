package workbench

import (
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// This file decides what the navigation path at the leading end of the status bar names. As in
// IntelliJ IDEA, the path follows the area the user last put the keyboard in, by a click or by the
// keyboard. The editor names its file, the Project tool window the row selected in it, and the
// Problems tool window the file of the problem selected in it. When the focus moves somewhere
// with no item of its own, such as a terminal, a button or a toolbar, the path keeps naming the
// area it named. The item is read from the area's current selection on every paint, so the path
// follows the arrow keys inside the area. status_path_view.go draws the path.

// statusPathSource is the area whose current item the navigation path names.
type statusPathSource uint8

const (
	// statusPathEditor names the file of the selected editor tab. It is the source until the
	// user focuses one of the others.
	statusPathEditor statusPathSource = iota
	// statusPathProject names the row selected in the Project tool window.
	statusPathProject
	// statusPathProblems names the file of the row selected in the Problems tool window.
	statusPathProblems
)

// statusPath is the state of the navigation path.
type statusPath struct {
	source statusPathSource
	// focus is the keyboard focus the source was last decided for. The source is decided again
	// only when the focus moves.
	focus gfx.ID
	// root and file are the last absolute path made relative to the project. rel is what it
	// gave, and inside says whether the file lies in the project. host is the host path, under
	// ~ when it is below the home directory, of a remote workspace's file outside its folder,
	// and "" for any other file. A paint that names the same file reuses them instead of
	// allocating the relative path again.
	root, file, rel, host string
	inside                bool
	// valueOf is the project name and crumbs of the last path the bar drew, and value is the
	// accessible value made from them.
	valueOf statusValueKey
	value   string
}

// statusCrumbs is what the path names after the project. rel is a project-relative path with
// forward slashes, and dir says its last segment is a folder. A document that is not in the
// project has no rel: name holds its name, and the path shows that name alone, without the
// project. When both rel and name are empty, the path names the project itself.
type statusCrumbs struct {
	rel, name string
	dir       bool
}

// statusValueKey is what the accessible value of the path is made from.
type statusValueKey struct {
	project string
	crumbs  statusCrumbs
}

// noteStatusPathFocus makes the area the focus moved into the source of the path. The status bar
// is declared after the editors and the tool windows, so the rows they declared in this paint are
// known. Focus on anything else leaves the source as it was.
func (a *App) noteStatusPathFocus(p *project, focused gfx.ID) {
	s := &a.statusPath
	if focused == s.focus {
		return
	}
	s.focus = focused
	switch {
	case focused.IsZero():
	case p.documentOwning(focused) != nil:
		s.source = statusPathEditor
	case p.tree.rowFocused(focused):
		s.source = statusPathProject
	case a.problems.rowFocused(focused):
		s.source = statusPathProblems
	}
}

// statusPathCrumbs is what the path names now: the current item of its source. A source with no
// current item, such as the Problems tool window after it closed, names the editor's file
// instead. With no file open, the path names the project alone.
func (a *App) statusPathCrumbs(p *project) statusCrumbs {
	switch a.statusPath.source {
	case statusPathProject:
		if n := p.tree.selected; n != nil {
			if n.path == "" {
				return statusCrumbs{}
			}
			return statusCrumbs{rel: n.path, dir: n.dir}
		}
	case statusPathProblems:
		if file, selected := a.problems.selectedFile(); selected {
			if file == "" {
				return statusCrumbs{}
			}
			return a.statusFileCrumbs(p, file, "")
		}
	case statusPathEditor:
	}
	d := a.selectedEditorDocument()
	if d == nil {
		return statusCrumbs{}
	}
	return a.statusFileCrumbs(p, d.path, d.name)
}

// statusFileCrumbs names the file at the absolute path file. A file in the project is named by
// its path in the project. A host file outside a remote workspace's folder is named by its host
// path, so the user sees which file of the host the read-only tab holds. Any other file outside
// the project, such as a scratch file or a document a plugin provides, is named by its name
// alone. name is the name a document shows in its tab; when it is empty, the last element of
// the path is used.
func (a *App) statusFileCrumbs(p *project, file, name string) statusCrumbs {
	s := &a.statusPath
	if s.root != p.root || s.file != file {
		s.root, s.file, s.host = p.root, file, ""
		s.rel, s.inside = projectRelative(p.root, file)
		if !s.inside && p.remoteOutsideDocument(file) {
			s.host = remoteHomeRelative(p.remoteHostPath(file), p.remote.home)
		}
	}
	if s.inside {
		return statusCrumbs{rel: s.rel}
	}
	if s.host != "" {
		return statusCrumbs{name: s.host}
	}
	if name == "" {
		name = filepath.Base(file)
	}
	return statusCrumbs{name: name}
}

// statusPathValue is the accessible value of the path. It is the project and the crumbs after it
// joined by slashes, or a document's name when the document is not in the project. The value is
// made again only when the path changes.
func (a *App) statusPathValue(project string, crumbs statusCrumbs) string {
	s := &a.statusPath
	key := statusValueKey{project: project, crumbs: crumbs}
	if s.valueOf == key {
		return s.value
	}
	s.valueOf = key
	switch {
	case crumbs.name != "":
		s.value = crumbs.name
	case crumbs.rel == "":
		s.value = project
	default:
		s.value = project + "/" + crumbs.rel
	}
	return s.value
}

// documentOwning is the open document whose editor holds the control focused, or nil when no
// editor holds it.
func (p *project) documentOwning(focused gfx.ID) *document {
	for _, d := range p.docs.list {
		if d.view.Owns(focused) {
			return d
		}
	}
	return nil
}

// rowFocused says whether focused is a row of the Project tool window's tree.
func (t *fileTree) rowFocused(focused gfx.ID) bool {
	for i := range t.rows {
		if t.view.RowID(i) == focused {
			return true
		}
	}
	return false
}

// rowFocused says whether focused is a row of the Problems tool window's tree.
func (v *problemsView) rowFocused(focused gfx.ID) bool {
	for i := range v.result.Rows {
		if v.view.RowID(i) == focused {
			return true
		}
	}
	return false
}

// selectedFile is the absolute path of the file the selected row belongs to. For a diagnostic,
// it is the diagnostic's file. For a file's node, it is that file. For a severity's node, it is
// empty. selected is false when no row is selected.
func (v *problemsView) selectedFile() (file string, selected bool) {
	i := v.selectedRow
	if i < 0 || i >= len(v.result.Rows) {
		return "", false
	}
	if r := v.result.Rows[i]; r.Kind == core.ProblemsRowGroup {
		g, ok := v.group(r.Group)
		if !ok || g.Kind != core.ProblemsGroupByFile {
			return "", ok
		}
		return g.FileKey, true
	}
	d, ok := v.shown(i)
	return d.FileKey, ok
}
