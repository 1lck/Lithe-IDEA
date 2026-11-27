package workbench

import (
	"path"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"os"
	"path/filepath"
	"strings"

	"github.com/vivaui/viva/ui"
)

const (
	welcomeSidebarWidth = 224
	welcomeRowHeight    = 48
	// The original welcome list uses the same 20-point badge as the project switcher.
	welcomeAvatarSize = 20
)

// welcomeState is what the start screen remembers between frames.
type welcomeState struct {
	// search filters the project list. App.Config hands it to the platform text
	// service, so it lives as long as the window.
	search ui.Field
	// menuOpen is whether a recent project's action menu is open, which menuPath names.
	menuOpen bool
	// list is the recent project list's selection and scroll.
	list ui.ListState

	// The Core projection changes when the list, search text, or filter changes.
	projection                   core.RecentProjectsResult
	projectionValid              bool
	projectionStart              *core.RecentProject
	projectedQuery, projectedTag string
	tag                          string
	tagEdit                      welcomeTagEdit

	// rows holds what a recent project shows, by path. The list repaints on every hover,
	// and splitting names, shortening paths and folding case for each row each time would
	// allocate for nothing, so it is derived once per path.
	rows map[string]welcomeRow
	// ids give each recent project a number that stays with it when the list is
	// reordered, so a row keeps its focus and its open menu.
	ids map[string]int
	// branches are read by one page effect. A newer recent list changes its key,
	// which cancels the read and starts the next, so a stale result never
	// reintroduces removed entries.
	branches       map[string]string
	branchRevision int
	branchesFx     *keyedEffect[branchRead, []string]
	// home is the user's home folder, read once; paths under it show as "~/...".
	home     string
	homeRead bool
	// menuPath is stable across sorting and filtering, unlike a row index.
	menuPath string
}

// welcomeRow is the derived text of one recent project.
type welcomeRow struct {
	// name is the folder's name and path its location, shortened with "~" when it is
	// under the home folder.
	name, path string
	// identity is the project's badge, derived with the text because it hashes the path.
	identity projectIdentity
}

// row returns what the project at path shows. listed is the length of the recent list;
// the cache is dropped when it outgrows the list by a margin, so projects that left
// the list do not stay in memory.
func (w *welcomeState) row(path string, listed int) welcomeRow {
	if r, ok := w.rows[path]; ok {
		return r
	}
	if !w.homeRead {
		w.home, _ = os.UserHomeDir()
		w.homeRead = true
	}
	name := filepath.Base(path)
	r := welcomeRow{
		name:     name,
		path:     welcomeShorten(path, w.home),
		identity: identityOf(path, name),
	}
	if w.rows == nil {
		w.rows = make(map[string]welcomeRow, 32)
	} else if len(w.rows) >= 2*listed+16 {
		clear(w.rows)
	}
	w.rows[path] = r
	return r
}

// rowID is the number that names the project at path in the list.
func (w *welcomeState) rowID(path string) int {
	id, ok := w.ids[path]
	if !ok {
		if w.ids == nil {
			w.ids = make(map[string]int)
		}
		id = len(w.ids) + 1
		w.ids[path] = id
	}
	return id
}

// entryRow uses the original host folder for remote history and never displays its
// synthetic history key or the cache placeholder.
func (w *welcomeState) entryRow(entry core.RecentProject, listed int) welcomeRow {
	if entry.Remote == nil {
		return w.row(entry.Path, listed)
	}
	name := path.Base(entry.Remote.Folder)
	return welcomeRow{
		name:     name,
		path:     entry.Remote.Name + " — " + entry.Remote.Folder,
		identity: identityOf(entry.Path, name),
	}
}

// welcomeShorten writes a path under home as "~" plus the rest. The separator is
// checked so /Users/ann does not shorten /Users/anna.
func welcomeShorten(path, home string) string {
	if home == "" || !strings.HasPrefix(path, home) {
		return path
	}
	rest := path[len(home):]
	if rest != "" && rest[0] != os.PathSeparator {
		return path
	}
	return "~" + rest
}
