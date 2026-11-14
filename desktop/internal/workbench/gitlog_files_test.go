package workbench

import (
	"context"
	"os"
	"path"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

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
	h.app.reduceChrome(core.SetChromeOpen(itemGit, true))
	h.settleChain()
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

// The changed-file lists group through Core: the top first, as "", then each folder before
// its subfolders, folders and files in the project tree's natural order.
func TestGroupLogFilesUsesCoreNaturalOrder(t *testing.T) {
	paths := []string{"b/x.go", "a.go", "b/c/y.go", "b/a.go", "v0.1.12/n", "v0.1.4/n", "file10.go", "file2.go"}
	got, err := groupLogFiles(context.Background(), core.NewClient(), paths)
	if err != nil {
		t.Fatal(err)
	}
	want := []logFolder{
		{dir: "", files: []int{1, 7, 6}},
		{dir: "b", files: []int{3, 0}},
		{dir: "b/c", files: []int{2}},
		{dir: "v0.1.4", files: []int{5}},
		{dir: "v0.1.12", files: []int{4}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("folders %+v, want %+v", got, want)
	}
	if !got[1].holds("b/a.go", func(i int) string { return paths[i] }) || got[1].holds("b/c/y.go", func(i int) string { return paths[i] }) {
		t.Fatalf("folder b holds %v", got[1].files)
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
	if len(p.diffs.list) != 1 {
		t.Fatalf("compare opened %d Diff tabs, want 1", len(p.diffs.list))
	}
	d := p.diffs.list[0]
	h.await("the commit's diff", func() bool { return !d.loading })
	if d.commit != head || d.change.Path != "top.txt" || d.err != "" || d.file == nil || !d.readOnly() {
		t.Fatalf("compare opened %+v", d)
	}
	if g := p.terms.bench.GroupOf(diffMember(d.id)); g == nil || g.Selected != diffMember(d.id) {
		t.Fatalf("the commit's diff is not the selected tab of an editor group: %+v", g)
	}
	if len(d.files) != 3 {
		t.Fatalf("the commit's diff steps through %d files, want the commit's 3", len(d.files))
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
	h.app.closeDiffTab(p, d.id)
	h.settle()

	h.clickNamed(g.FileHistory)
	h.settle()
	if p.log.path != "top.txt" || h.app.logView.pathField.Text() != "top.txt" {
		t.Fatalf("history filtered by %q, field %q", p.log.path, h.app.logView.pathField.Text())
	}
}

// heldCommitFiles is a kernel whose GitCommitFiles waits for its context to end and then tells
// which commit's read ended.
type heldCommitFiles struct {
	Kernel
	ended chan string
}

func (k heldCommitFiles) GitCommitFiles(ctx context.Context, _, commit string) ([]core.GitCommitFile, error) {
	<-ctx.Done()
	k.ended <- commit
	return nil, ctx.Err()
}

// A newer selection cancels the Git read of the commit it replaces, which would otherwise run
// on, showing as running in the Git console, for an answer nothing reads.
func TestLogSelectionCancelsTheReadOfTheCommitItReplaces(t *testing.T) {
	h := newHarness(t, gitKernel{core.NewClient()})
	p, head, initial := h.openLogFiles(t)
	held := heldCommitFiles{Kernel: h.app.kernel, ended: make(chan string, 2)}
	h.app.kernel = held
	const bound = 10 * time.Second
	wait := func(want string) {
		t.Helper()
		select {
		case got := <-held.ended:
			if got != want {
				t.Fatalf("the read of %q ended, want the read of %q", got, want)
			}
		case <-time.After(bound):
			t.Fatalf("the read of %q still runs %v after another selection replaced it", want, bound)
		}
	}
	h.app.selectCommit(p, initial)
	h.app.selectCommit(p, head)
	wait(initial)
	h.app.selectCommit(p, "")
	wait(head)
}
