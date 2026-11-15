package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// outlineKernel answers markdown.outline through Core and counts the requests. It can fail them,
// or hold them until release, so a test decides when an answer arrives.
type outlineKernel struct {
	*testKernel
	mu    sync.Mutex
	calls int
	err   error
	held  chan struct{}
}

func newOutlineKernel() *outlineKernel {
	return &outlineKernel{testKernel: &testKernel{Client: core.NewClient()}}
}

func (k *outlineKernel) MarkdownOutline(ctx context.Context, source string) ([]core.DocumentSymbol, error) {
	k.mu.Lock()
	k.calls++
	err, held := k.err, k.held
	k.mu.Unlock()
	if held != nil {
		select {
		case <-held:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	if err != nil {
		return nil, err
	}
	return k.testKernel.MarkdownOutline(ctx, source)
}

func (k *outlineKernel) requests() int {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.calls
}

func (k *outlineKernel) fail(err error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.err = err
}

// hold keeps the next answers back until the returned release runs; release may run twice.
func (k *outlineKernel) hold() (release func()) {
	held := make(chan struct{})
	k.mu.Lock()
	k.held = held
	k.mu.Unlock()
	var once sync.Once
	return func() {
		once.Do(func() {
			k.mu.Lock()
			k.held = nil
			k.mu.Unlock()
			close(held)
		})
	}
}

// openMarkdownFiles opens a project holding each named Markdown text, opens each file in order
// and returns their documents, the last one selected.
func openMarkdownFiles(t *testing.T, h *harness, files ...[2]string) []*document {
	t.Helper()
	root := t.TempDir()
	for _, file := range files {
		if err := os.WriteFile(filepath.Join(root, file[0]), []byte(file[1]), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	h.open(root)
	documents := make([]*document, 0, len(files))
	for _, file := range files {
		path := filepath.Join(root, file[0])
		h.app.openFile(h.app.project, path)
		h.settle()
		d := h.app.project.docs.byPath(path)
		if d == nil {
			t.Fatalf("%s did not open", file[0])
		}
		documents = append(documents, d)
	}
	return documents
}

// showStructure selects d's tab, opens the Structure tool window and paints frames until the
// outline of d has been asked for and, unless it is held back, answered. Opening the window
// through the reducer repaints nothing by itself, so the window is invalidated here rather than
// left to whatever else repaints it.
func showStructure(t *testing.T, h *harness, d *document) {
	t.Helper()
	h.app.selectDocument(h.app.project, d.id)
	h.app.reduceChrome(core.SetChromeOpen(itemStructure, true))
	h.app.invalidator.Invalidate()
	h.settle()
	h.settle()
}

// outlineNames lists the rows of the Structure tree, each indented by two spaces a level.
func outlineNames(s *outlineState) []string {
	names := make([]string, len(s.rows))
	for i, row := range s.rows {
		names[i] = strings.Repeat("  ", row.depth) + row.symbol.Name
	}
	return names
}

const outlineGuide = "# Guide\n\nIntro\n\n## Install\n\nSteps\n\n### macOS\n\n## Use\n"

// TestMarkdownOutlineShowsHeadingsWithoutServer: a Markdown file, which no language server
// serves, shows its headings nested by level; the caret's heading is selected, and going to one
// puts the caret on it.
func TestMarkdownOutlineShowsHeadingsWithoutServer(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	d := openMarkdownFiles(t, h, [2]string{"notes.md", outlineGuide})[0]
	d.view.SetSelection(0, 0)
	showStructure(t, h, d)
	s := &h.app.editor.outline
	if s.availability != outlineMarkdown || !s.loaded || s.total != 4 {
		t.Fatalf("availability = %d, loaded = %v, total = %d", s.availability, s.loaded, s.total)
	}
	want := []string{"Guide", "  Install", "    macOS", "  Use"}
	if got := outlineNames(s); !slices.Equal(got, want) {
		t.Fatalf("rows = %q, want %q", got, want)
	}
	language := h.app.language()
	if !h.shows("macOS") || h.showsWrapped(i18n.Shared(language, "desktop.outline.unavailable")) {
		t.Fatalf("the headings are not shown: %v", h.driver.Snapshot().Labels)
	}

	// The caret on the line under "### macOS" is in that heading's section.
	offset := d.view.TextSnapshot().LineStart(9)
	d.view.SetSelection(offset, offset)
	h.app.invalidator.Invalidate()
	h.settle()
	if s.selected != 2 {
		t.Fatalf("selected row = %d, want macOS's", s.selected)
	}

	h.app.outlineGo(h.app.project, d, s.rows[3].symbol)
	h.settle()
	if line, column := d.view.CaretUTF16(); line != 10 || column != 0 {
		t.Fatalf("caret = %d:%d, want Use's heading at 10:0", line, column)
	}
}

// TestMarkdownOutlineFollowsEditsAfterTheDelay: an edit is outlined again, once the delay since
// the last request has passed.
func TestMarkdownOutlineFollowsEditsAfterTheDelay(t *testing.T) {
	kernel := newOutlineKernel()
	h := newHarness(t, kernel)
	d := openMarkdownFiles(t, h, [2]string{"notes.md", outlineGuide})[0]
	showStructure(t, h, d)
	if got := kernel.requests(); got != 1 {
		t.Fatalf("requests = %d, want 1", got)
	}
	h.app.post(func(a *App) { a.insertForTest(d, "\n## Added\n") })
	h.settle()
	h.settle()
	if got := kernel.requests(); got != 1 {
		t.Fatalf("requests before the delay passed = %d, want 1", got)
	}
	if err := h.driver.Advance(outlineDelay + outlineDelay/2); err != nil {
		t.Fatal(err)
	}
	h.settle()
	s := &h.app.editor.outline
	if got := kernel.requests(); got != 2 || s.revision != d.view.Revision() {
		t.Fatalf("requests = %d, outline revision = %d, text revision = %d", got, s.revision, d.view.Revision())
	}
	want := []string{"Guide", "  Install", "    macOS", "  Use", "  Added"}
	if got := outlineNames(s); !slices.Equal(got, want) {
		t.Fatalf("rows = %q, want %q", got, want)
	}
}

// TestMarkdownOutlineSaysWhenThereAreNoHeadings: a Markdown file without headings says so instead
// of naming symbols.
func TestMarkdownOutlineSaysWhenThereAreNoHeadings(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	d := openMarkdownFiles(t, h, [2]string{"notes.md", "Just a paragraph.\n\n```\n# not a heading\n```\n"})[0]
	showStructure(t, h, d)
	language := h.app.language()
	if s := &h.app.editor.outline; !s.loaded || len(s.symbols) != 0 {
		t.Fatalf("loaded = %v, symbols = %+v", s.loaded, s.symbols)
	}
	if !h.showsWrapped(i18n.Shared(language, "desktop.outline.noHeadings")) || h.showsWrapped(i18n.Shared(language, "desktop.outline.empty")) {
		t.Fatalf("the no-headings notice is missing: %v", h.driver.Snapshot().Labels)
	}
}

// TestMarkdownOutlineSkipsTooLargeFile: a Markdown file over the preview's limit is not sent to
// Core, and the window says why there is no structure.
func TestMarkdownOutlineSkipsTooLargeFile(t *testing.T) {
	kernel := newOutlineKernel()
	h := newHarness(t, kernel)
	text := "# Big\n\n" + strings.Repeat("A line of text in a big file.\n", markdownPreviewMaxBytes/30+1)
	d := openMarkdownFiles(t, h, [2]string{"big.md", text})[0]
	showStructure(t, h, d)
	s := &h.app.editor.outline
	if got := kernel.requests(); got != 0 || !s.tooLarge || s.loaded {
		t.Fatalf("requests = %d, tooLarge = %v, loaded = %v", got, s.tooLarge, s.loaded)
	}
	if !h.showsWrapped(i18n.Shared(h.app.language(), "desktop.outline.tooLarge")) {
		t.Fatalf("the too-large notice is missing: %v", h.driver.Snapshot().Labels)
	}
}

// TestMarkdownOutlineFailureOffersRetry: a failed outline is shown with Retry and not asked
// again for the same text by itself; Retry asks again at once.
func TestMarkdownOutlineFailureOffersRetry(t *testing.T) {
	kernel := newOutlineKernel()
	kernel.fail(errors.New("boom"))
	h := newHarness(t, kernel)
	d := openMarkdownFiles(t, h, [2]string{"notes.md", outlineGuide})[0]
	showStructure(t, h, d)
	language := h.app.language()
	s := &h.app.editor.outline
	if !s.failed || !h.showsWrapped(i18n.Shared(language, "desktop.outline.failed")) {
		t.Fatalf("failed = %v, labels = %v", s.failed, h.driver.Snapshot().Labels)
	}
	h.app.invalidator.Invalidate()
	h.settle()
	if got := kernel.requests(); got != 1 {
		t.Fatalf("requests after the failure = %d, want 1", got)
	}
	kernel.fail(nil)
	h.click(center(h.hitLabeled(i18n.Shared(language, "ui.retry"))))
	h.settleUntil("the outline after Retry", func() bool { return s.loaded })
	if got := kernel.requests(); got != 2 || s.failed || !h.shows("Install") {
		t.Fatalf("requests = %d, failed = %v, labels = %v", got, s.failed, h.driver.Snapshot().Labels)
	}
}

// TestMarkdownOutlineDropsTheAnswerForAnotherFile: the order is the outline of a.md asked for
// and held, b.md selected and asked for, then both answers released; only b.md's is shown.
func TestMarkdownOutlineDropsTheAnswerForAnotherFile(t *testing.T) {
	kernel := newOutlineKernel()
	h := newHarness(t, kernel)
	documents := openMarkdownFiles(t, h, [2]string{"a.md", "# Alpha\n"}, [2]string{"b.md", "# Beta\n"})
	a, b := documents[0], documents[1]
	release := kernel.hold()
	// The harness waits for every task when the test ends: the held answers must come first.
	t.Cleanup(release)
	pump := func() {
		t.Helper()
		h.app.invalidator.Invalidate()
		if err := h.driver.Pump(); err != nil {
			t.Fatal(err)
		}
	}
	h.app.selectDocument(h.app.project, a.id)
	h.app.reduceChrome(core.SetChromeOpen(itemStructure, true))
	pump()
	s := &h.app.editor.outline
	if s.documentID != a.id || s.outlining == nil {
		t.Fatalf("a.md is not being outlined: document = %d, outlining = %v", s.documentID, s.outlining)
	}
	h.app.selectDocument(h.app.project, b.id)
	pump()
	if s.documentID != b.id || s.outlining == nil {
		t.Fatalf("b.md is not being outlined: document = %d, outlining = %v", s.documentID, s.outlining)
	}
	release()
	h.settleUntil("b.md's outline", func() bool { return s.loaded })
	if got := outlineNames(s); s.documentID != b.id || !slices.Equal(got, []string{"Beta"}) {
		t.Fatalf("document = %d, rows = %q, want b.md's Beta", s.documentID, got)
	}
	if got := kernel.requests(); got != 2 {
		t.Fatalf("requests = %d, want 2", got)
	}
}

// TestMarkdownOutlineMovesThePageShownAlone: going to a heading while the page is shown without
// its source scrolls the page to the heading.
func TestMarkdownOutlineMovesThePageShownAlone(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	d := openMarkdown(t, h, longMarkdown())
	h.click(center(h.hitLabeled(i18n.Shared(h.app.language(), "editor.markdownPreviewView"))))
	if d.pageMode != pageOnly {
		t.Fatalf("page mode = %d, want the page alone", d.pageMode)
	}
	showStructure(t, h, d)
	s := &h.app.editor.outline
	if !s.loaded || len(s.rows) != 40 || s.rows[11].symbol.Name != "Part 12" {
		t.Fatalf("loaded = %v, availability = %d, requested = %d, failed = %v, outlining = %v, doc = %d/%d, rows = %q", s.loaded, s.availability, s.requested, s.failed, s.outlining, s.documentID, d.id, outlineNames(s))
	}
	h.app.outlineGo(h.app.project, d, s.rows[11].symbol)
	h.settle()
	if line := pageTopLine(d.markdown); line != 55 {
		t.Fatalf("the page has line %d at its top, want Part 12's line 55", line)
	}
}
