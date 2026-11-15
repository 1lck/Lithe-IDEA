package workbench

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// The tree colors exactly the paths the repository reports, rebased onto the project
// root, and folds each change into the folders above it so a collapsed folder still
// shows that something changed.
func TestNewTreeStatusIndexesChangesForTheProjectRoot(t *testing.T) {
	status := core.GitStatus{
		RepositoryRoot: ".",
		Changes: []core.GitChange{
			{Path: "src/app.go", Status: " M"},
			{Path: "src/util/x.go", Status: "A "},
			{Path: "docs/readme.md", Status: "??", Untracked: true},
			{Path: "gone.txt", Status: " D"},
			{Path: "old/name.go", Status: "R ", OriginalPath: "old/before.go"},
		},
	}
	index := newTreeStatus("/work/project", status)
	want := map[string]string{
		"src/app.go":     "M",
		"src":            "M",
		"src/util/x.go":  "A",
		"src/util":       "A",
		"docs/readme.md": "?",
		"docs":           "?",
		"gone.txt":       "D",
		"old/name.go":    "R",
		"old":            "R",
	}
	for path, letter := range want {
		if got := index[path]; got != letter {
			t.Fatalf("index[%q] = %q, want %q", path, got, letter)
		}
	}
	if len(index) != len(want) {
		t.Fatalf("index has %d entries, want %d: %+v", len(index), len(want), index)
	}
}

// A project that is a folder inside a larger repository rebases the repository's paths
// onto its own root, and a project outside its repository colors nothing.
func TestTreeStatusPrefixRebasesOntoTheProjectRoot(t *testing.T) {
	root := t.TempDir()
	inside := root + "/module"
	if prefix, ok := treeStatusPrefix(inside, root); !ok || prefix != "module/" {
		t.Fatalf("prefix = %q, %v; want module/", prefix, ok)
	}
	if prefix, ok := treeStatusPrefix(root, "."); !ok || prefix != "" {
		t.Fatalf("same-directory prefix = %q, %v; want empty", prefix, ok)
	}
	if _, ok := treeStatusPrefix(root, ""); ok {
		t.Fatal("a directory outside a repository must not be colored")
	}
	if _, ok := treeStatusPrefix("/elsewhere", root); ok {
		t.Fatal("a project outside the repository root must not be colored")
	}
}

// Untracked wins over the porcelain letters, a conflict keeps its own color, and every
// other state reads whichever side carries the change.
func TestTreeStatusLetterReadsBothSidesOfAChange(t *testing.T) {
	cases := []struct {
		change core.GitChange
		want   string
	}{
		{core.GitChange{Status: "??", Untracked: true}, "?"},
		{core.GitChange{Status: "UU"}, "!"},
		{core.GitChange{Status: "AA"}, "!"},
		{core.GitChange{Status: "R ", Staged: true}, "R"},
		{core.GitChange{Status: " M", Worktree: true}, "M"},
		{core.GitChange{Status: "M ", Staged: true}, "M"},
		{core.GitChange{Status: "A ", Staged: true}, "A"},
		{core.GitChange{Status: " D"}, "D"},
		{core.GitChange{Status: "T "}, "M"},
		{core.GitChange{}, ""},
	}
	for _, c := range cases {
		if got := treeStatusLetter(c.change); got != c.want {
			t.Fatalf("treeStatusLetter(%q) = %q, want %q", c.change.Status, got, c.want)
		}
	}
}
