package workbench

import (
	"path"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/gfx"
)

// treeStatus is the Git state the project tree shows beside a path, keyed by a
// project-root-relative path with "/" separators. A folder carries the state of one
// change below it, so a collapsed folder still shows that something changed.
type treeStatus map[string]string

// newTreeStatus indexes the repository's changes for the project tree. Change paths are
// relative to the repository root, so they are rebased onto the project root; a directory
// that is not inside a repository, or one where the repository root cannot be reached from
// the project root, leaves the tree uncolored.
func newTreeStatus(projectRoot string, status core.GitStatus) treeStatus {
	prefix, ok := treeStatusPrefix(projectRoot, status.RepositoryRoot)
	if !ok {
		return nil
	}
	index := make(treeStatus, len(status.Changes))
	for _, change := range status.Changes {
		letter := treeStatusLetter(change)
		rel, inProject := strings.CutPrefix(change.Path, prefix)
		if letter == "" || !inProject || rel == "" {
			continue
		}
		index[rel] = letter
		// Folders summarize what changed below them. An inner folder keeps the state of
		// its own change, because the loop stops at the nearest one first.
		for dir := path.Dir(rel); dir != "." && dir != "/"; dir = path.Dir(dir) {
			if _, seen := index[dir]; !seen {
				index[dir] = letter
			}
		}
	}
	if len(index) == 0 {
		return nil
	}
	return index
}

// treeStatusPrefix is the prefix that rebases a repository-relative change path onto the
// project root, and false when the tree cannot be colored at all.
func treeStatusPrefix(projectRoot, repositoryRoot string) (string, bool) {
	switch {
	case repositoryRoot == "":
		return "", false
	case repositoryRoot == ".":
		return "", true
	case !filepath.IsAbs(repositoryRoot):
		return "", false
	}
	rel, err := filepath.Rel(repositoryRoot, projectRoot)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", false
	}
	if rel == "." {
		return "", true
	}
	return filepath.ToSlash(rel) + "/", true
}

// treeStatusLetter is the letter the tree colors one change with. A conflict keeps the
// warning color of the change list, a rename keeps its own color, and every other state
// reads whichever side of the change carries it.
func treeStatusLetter(change core.GitChange) string {
	if change.Untracked || change.Status == "??" {
		return "?"
	}
	letters := strings.TrimSpace(change.Status)
	if letters == "" {
		return ""
	}
	switch {
	case strings.ContainsRune(letters, 'U'), letters == "AA", letters == "DD":
		return "!"
	case strings.ContainsRune(letters, 'R'):
		return "R"
	case strings.ContainsRune(letters, 'A'):
		return "A"
	case strings.ContainsRune(letters, 'D'):
		return "D"
	case strings.ContainsRune(letters, 'M'), strings.ContainsRune(letters, 'T'):
		return "M"
	}
	return ""
}

// treeTextColor is the color of a tree row's name: the Git state of the path when the
// repository reports one, the ordinary tree text otherwise.
func (a *App) treeTextColor(p *project, n *treeNode) gfx.Color {
	if letter, ok := p.git.tree[n.path]; ok {
		return a.colors.treeStatusColor(letter)
	}
	return treelist.Text(a.colors.Dark)
}
