package workbench

import (
	"os"
	"path"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// openLogFiles opens a repository whose last commit changes two files in src and one at the
// top, shows the Git log with that commit selected, and waits for its changed files.
func (h *harness) openLogFiles(t *testing.T) (*project, string, string) {
	t.Helper()
	return h.openLogFilesWith(t, "src/a.txt", "src/b.txt", "top.txt")
}

// openLogFilesWith opens a repository whose last commit adds names, which are in src or at
// the top, shows the Git log with that commit selected, and waits for its changed files.
func (h *harness) openLogFilesWith(t *testing.T, names ...string) (*project, string, string) {
	t.Helper()
	dir := newTestRepository(t)
	initial := gitRun(t, dir, "rev-parse", "HEAD")
	if err := os.MkdirAll(filepath.Join(dir, "src"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, name := range names {
		if err := os.WriteFile(filepath.Join(dir, filepath.FromSlash(name)), []byte(name+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	gitRun(t, dir, append([]string{"add"}, names...)...)
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
	if p.log.filesState != logFilesReady || len(p.log.files) != len(names) {
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

// logFileLabel is the label the last frame drew for a changed file or folder named name.
func (h *harness) logFileLabel(name string) (app.Label, bool) {
	area := h.app.logView.fileScroll.Area
	for _, label := range h.driver.Snapshot().Labels {
		if label.Value == name && label.Bounds.Y >= area.Y && label.Bounds.Y < area.Bottom() {
			return label, true
		}
	}
	return app.Label{}, false
}

func TestLogChangedFilesScrollSideways(t *testing.T) {
	h := newHarness(t, gitKernel{core.NewClient()})
	long := "src/" + strings.Repeat("n", 160) + ".txt"
	p, _, initial := h.openLogFilesWith(t, long, "top.txt")
	h.settle()
	v := &h.app.logView
	if !v.fileScroll.Overflows() {
		t.Fatalf("a name %v wide fits a list %v wide", v.fileScroll.Content, v.fileScroll.Viewport())
	}
	area := v.fileScroll.Area
	label, ok := h.logFileLabel(path.Base(long))
	if !ok || label.Bounds.Right() <= area.Right() {
		t.Fatalf("the long name is cut short: label %+v drawn %v, list %+v", label, ok, area)
	}
	if label.Bounds.Right()-area.X > v.fileScroll.Content {
		t.Fatalf("the name ends at %v, past the measured width %v", label.Bounds.Right()-area.X, v.fileScroll.Content)
	}

	if err := h.driver.Scroll(gfx.ScrollEvent{X: area.X + 20, Y: area.Y + 10, DeltaX: 10000, Precise: true}); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if v.fileScroll.Offset <= 0 || v.fileScroll.Offset != v.fileScroll.Max() {
		t.Fatalf("offset %v after scrolling to the end, max %v", v.fileScroll.Offset, v.fileScroll.Max())
	}
	if label, ok = h.logFileLabel(path.Base(long)); !ok || label.Bounds.Right() > area.Right() {
		t.Fatalf("scrolled to the end, the name ends at %v past the list's %v", label.Bounds.Right(), area.Right())
	}

	// An up and down swipe is the list's vertical scroll, not a sideways one.
	before := v.fileScroll.Offset
	if err := h.driver.Scroll(gfx.ScrollEvent{X: area.X + 20, Y: area.Y + 10, DeltaX: -2, DeltaY: 30, Precise: true}); err != nil {
		t.Fatal(err)
	}
	if v.fileScroll.Offset != before {
		t.Fatalf("an up and down swipe moved the list sideways to %v", v.fileScroll.Offset)
	}

	// Another commit starts at the left.
	h.app.selectCommit(p, initial)
	h.settle()
	h.settle()
	if v.fileScroll.Offset != 0 {
		t.Fatalf("another commit kept the offset %v", v.fileScroll.Offset)
	}
}
