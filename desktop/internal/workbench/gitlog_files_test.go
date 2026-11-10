package workbench

import (
	"os"
	"path"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
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
	h.app.layout.gitTab = gitTabLog
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
		if row.label == label {
			return true
		}
	}
	return false
}

// logFileArrow is the hit of the arrow of the folder row labelled label.
func (h *harness) logFileArrow(label string) (gfx.Hit, bool) {
	for _, name := range []string{"native.collapseDirectory", "native.expandDirectory"} {
		if hit, ok := h.findPageHit(i18n.Shared(h.app.language(), name) + " " + label); ok {
			return hit, true
		}
	}
	return gfx.Hit{}, false
}

// logFileHit is the hit of the changed file or folder row labelled label, and false when the
// frame did not declare it in view.
func (h *harness) logFileHit(label string) (gfx.Hit, bool) {
	return h.findPageHit(label)
}

func TestLogChangedFilesFoldersCollapse(t *testing.T) {
	h := newHarness(t, gitKernel{core.NewClient()})
	p, _, initial := h.openLogFiles(t)
	if _, ok := h.logFileHit("src"); !ok {
		t.Fatal("no row for the src folder")
	}
	if arrow, ok := h.logFileArrow("src"); !ok || !arrow.Expandable || !arrow.Expanded {
		t.Fatalf("src folder arrow %+v declared %v", arrow, ok)
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

	arrow, _ := h.logFileArrow("src")
	h.click(center(arrow.Bounds))
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
	folder, ok := h.logFileHit("src")
	if !ok {
		t.Fatal("the closed src folder has no row")
	}
	h.click(center(folder.Bounds))
	right := func() {
		if err := h.driver.Key(gfx.KeyRight, 0); err != nil {
			t.Fatal(err)
		}
		h.settle()
	}
	right()
	if p.log.closedFolders["src"] {
		t.Fatal("Right did not open the folder")
	}
	right()
	if path := h.app.logView.file; path != "src/a.txt" && path != "src/b.txt" {
		t.Fatalf("Right on an open folder selected %q", path)
	}

	// Another commit starts with every folder open.
	arrow, _ = h.logFileArrow("src")
	h.click(center(arrow.Bounds))
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

// logFileLabel is the label the last frame drew for a changed file or folder named name, over
// the splitter that ends the changed files. A name scrolled sideways starts left of the pane.
func (h *harness) logFileLabel(name string) (app.Label, bool) {
	bottom := h.logFilesSplit().Y
	for _, label := range h.driver.Snapshot().Labels {
		if label.Value == name && label.Bounds.Y < bottom {
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
	left := h.logDetailsSplit().Right()
	right := left + v.detailWidth
	if v.files.RowWidth <= v.detailWidth {
		t.Fatalf("a name %v wide fits a list %v wide", v.files.RowWidth, v.detailWidth)
	}
	label, ok := h.logFileLabel(path.Base(long))
	if !ok || label.Bounds.Right() <= right {
		t.Fatalf("the long name is cut short: label %+v drawn %v, list ends at %v", label, ok, right)
	}
	if label.Bounds.Right()-left > v.files.RowWidth {
		t.Fatalf("the name ends at %v, past the measured width %v", label.Bounds.Right()-left, v.files.RowWidth)
	}

	row, ok := h.logFileHit(long)
	if !ok {
		t.Fatal("the long name's row is not shown")
	}
	at := center(row.Bounds)
	if err := h.driver.Scroll(gfx.ScrollEvent{X: at.X, Y: at.Y, DeltaX: 10000, Precise: true}); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if v.files.ScrollX() <= 0 {
		t.Fatalf("offset %v after scrolling to the end", v.files.ScrollX())
	}
	if label, ok = h.logFileLabel(path.Base(long)); !ok || label.Bounds.Right() > right+1 {
		t.Fatalf("scrolled to the end, the name ends at %v past the list's %v", label.Bounds.Right(), right)
	}

	// An up and down swipe is the list's vertical scroll, not a sideways one.
	before := v.files.ScrollX()
	if err := h.driver.Scroll(gfx.ScrollEvent{X: at.X, Y: at.Y, DeltaX: -2, DeltaY: 30, Precise: true}); err != nil {
		t.Fatal(err)
	}
	if v.files.ScrollX() != before {
		t.Fatalf("an up and down swipe moved the list sideways to %v", v.files.ScrollX())
	}

	// Another commit starts at the left.
	h.app.selectCommit(p, initial)
	h.settle()
	h.settle()
	if v.files.ScrollX() != 0 {
		t.Fatalf("another commit kept the offset %v", v.files.ScrollX())
	}
}

func TestLogChangedFileCompareAndHistory(t *testing.T) {
	h := newHarness(t, gitKernel{core.NewClient()})
	p, head, _ := h.openLogFiles(t)
	g := h.app.text.Git
	if hit, ok := h.findPageHit(g.CompareChanges); ok && !hit.Disabled {
		t.Fatal("Compare is on with no file selected")
	}
	file, _ := h.logFileHit("top.txt")
	h.click(center(file.Bounds))
	h.clickNamed(g.CompareChanges)
	h.await("the commit's diff", func() bool { return !p.review.diff.loading })
	d := &p.review.diff
	if !d.open || d.commit != head || d.change.Path != "top.txt" || d.err != "" || d.file == nil {
		t.Fatalf("compare opened %+v", d)
	}
	if d.plan != nil {
		t.Fatal("a commit's change offers blocks to stage")
	}
	added := false
	for _, line := range d.file.Lines {
		added = added || (line.LineType == "added" && strings.Contains(line.Content, "top.txt"))
	}
	if !added {
		t.Fatalf("the diff does not add the file's line: %+v", d.file.Lines)
	}
	h.app.closeDiff(p)
	h.settle()

	h.clickNamed(g.FileHistory)
	h.settle()
	if p.log.path != "top.txt" || h.app.logView.pathField.Text() != "top.txt" {
		t.Fatalf("history filtered by %q, field %q", p.log.path, h.app.logView.pathField.Text())
	}
}
