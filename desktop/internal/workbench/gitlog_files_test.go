package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// openLogFiles opens a repository whose last commit changes two files in src and one at the
// top, shows the Git log with that commit selected, and waits for its changed files.
func (h *harness) openLogFiles(t *testing.T) (*project, string, string) {
	t.Helper()
	dir := newTestRepository(t)
	initial := gitRun(t, dir, "rev-parse", "HEAD")
	if err := os.MkdirAll(filepath.Join(dir, "src"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"src/a.txt", "src/b.txt", "top.txt"} {
		if err := os.WriteFile(filepath.Join(dir, filepath.FromSlash(name)), []byte(name+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	gitRun(t, dir, "add", "src", "top.txt")
	gitRun(t, dir, "commit", "-m", "files")
	head := gitRun(t, dir, "rev-parse", "HEAD")
	h.app.delays = logDelays{}
	h.open(dir)
	p := h.app.project
	if p == nil || !p.git.isRepository() {
		t.Fatalf("the project is not a loaded repository: %+v", p)
	}
	h.app.layout.gitTab = 0
	h.settle()
	if !p.log.started {
		h.click(center(h.button(itemGit)))
		h.settle()
	}
	h.app.selectCommit(p, head)
	h.settle()
	h.settle()
	if p.log.filesState != logFilesReady || len(p.log.files) != 3 {
		t.Fatalf("files %v of %q: %+v", p.log.filesState, head, p.log.files)
	}
	return p, head, initial
}

// logFileShown says the last frame drew a row of the changed files labelled label. The pane
// is short in the test window, so a row it drew can be scrolled out of the hits.
func (h *harness) logFileShown(label string) bool {
	for _, row := range h.app.logView.fileRows {
		if row.Label == label {
			return true
		}
	}
	return false
}

// logFileHit is the hit of the changed file or folder row labelled label, and false when the
// frame did not declare it in view.
func (h *harness) logFileHit(label string) (gfx.Hit, bool) {
	for _, hit := range h.driver.Snapshot().Hits {
		if _, ok := hit.ID.In(logFileRows); ok && hit.Label == label {
			return hit, true
		}
	}
	return gfx.Hit{}, false
}

func TestLogChangedFilesFoldersCollapse(t *testing.T) {
	h := newHarness(t, gitKernel{core.NewClient()})
	p, _, initial := h.openLogFiles(t)
	folder, ok := h.logFileHit("src")
	if !ok || !folder.Expandable || !folder.Expanded {
		t.Fatalf("src folder row %+v declared %v", folder, ok)
	}
	for _, name := range []string{"src/a.txt", "src/b.txt", "top.txt"} {
		if !h.logFileShown(name) {
			t.Fatalf("no row for %s", name)
		}
	}
	file, _ := h.logFileHit("src/a.txt")
	h.click(center(file.Bounds))
	if h.app.logView.file != "src/a.txt" {
		t.Fatalf("selected file %q", h.app.logView.file)
	}

	h.click(center(h.hit(logFileArrows.At(1))))
	if !p.log.closedFolders["src"] {
		t.Fatalf("src is not closed: %v", p.log.closedFolders)
	}
	if h.logFileShown("src/a.txt") || h.logFileShown("src/b.txt") {
		t.Fatal("a closed folder still shows its files")
	}
	if !h.logFileShown("top.txt") {
		t.Fatal("closing src hid a file at the top")
	}
	if v := &h.app.logView; v.file != "" || v.folder != "src" {
		t.Fatalf("closing over the selected file selected file %q folder %q", v.file, v.folder)
	}

	// The keyboard opens the folder again and steps into it.
	if r := h.app.logKey(gfx.KeyEvent{Key: gfx.KeyRight, Target: logFileRows.At(1)}); !r.Handled {
		t.Fatal("Right on a closed folder was not handled")
	}
	h.settle()
	if p.log.closedFolders["src"] {
		t.Fatal("Right did not open the folder")
	}
	if r := h.app.logKey(gfx.KeyEvent{Key: gfx.KeyRight, Target: logFileRows.At(1)}); !r.Handled {
		t.Fatal("Right on an open folder was not handled")
	}
	h.settle()
	if path := h.app.logView.file; path != "src/a.txt" && path != "src/b.txt" {
		t.Fatalf("Right on an open folder selected %q", path)
	}

	// Another commit starts with every folder open.
	h.click(center(h.hit(logFileArrows.At(1))))
	h.app.selectCommit(p, initial)
	h.settle()
	h.settle()
	if len(p.log.closedFolders) != 0 {
		t.Fatalf("a new commit kept the closed folders %v", p.log.closedFolders)
	}
}

func TestGroupLogFilesSortsFoldersAndKeepsGitOrder(t *testing.T) {
	files := []core.GitCommitFile{{Path: "b/x.go"}, {Path: "a.go"}, {Path: "b/c/y.go"}, {Path: "b/a.go"}}
	got := groupLogFiles(files)
	want := []logFolder{{dir: ".", files: []int{1}}, {dir: "b", files: []int{0, 3}}, {dir: "b/c", files: []int{2}}}
	if len(got) != len(want) {
		t.Fatalf("folders %+v", got)
	}
	for i := range want {
		if got[i].dir != want[i].dir || len(got[i].files) != len(want[i].files) {
			t.Fatalf("folder %d is %+v, want %+v", i, got[i], want[i])
		}
		for j := range want[i].files {
			if got[i].files[j] != want[i].files[j] {
				t.Fatalf("folder %d is %+v, want %+v", i, got[i], want[i])
			}
		}
	}
}
