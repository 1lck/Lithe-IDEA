package workbench

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// longMarkdown is a file of parts, each a heading over a two-line paragraph, five source lines a
// part, long enough for the source and the page to scroll.
func longMarkdown() string {
	var b strings.Builder
	for i := 1; i <= 40; i++ {
		fmt.Fprintf(&b, "## Part %d\n\nParagraph %d line one.\nline two.\n\n", i, i)
	}
	return b.String()
}

// openMarkdown opens a project with one Markdown file of text and returns the file's document.
func openMarkdown(t *testing.T, h *harness, text string) *document {
	t.Helper()
	root := t.TempDir()
	path := filepath.Join(root, "README.md")
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.openFile(h.app.project, path)
	h.settle()
	d := h.app.project.docs.byPath(path)
	if d == nil {
		t.Fatal("the Markdown file did not open")
	}
	h.settle()
	return d
}

// editorRect is where d's editor was laid out in the last frame, empty when it was not shown.
func editorRect(h *harness, d *document) gfx.Rect {
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.ID == d.hit && !hit.IsLabel {
			return hit.Bounds
		}
	}
	return gfx.Rect{}
}

// controlShown reports whether a control named label was laid out in the last frame.
func controlShown(h *harness, label string) bool {
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == label && !hit.IsLabel {
			return true
		}
	}
	return false
}

// TestMarkdownFileOpensAsSourceBesidePage: a Markdown file opens with its source and its page in
// equal halves of the group; the strip's switch shows the page alone or the source alone and
// back; the page follows edits.
func TestMarkdownFileOpensAsSourceBesidePage(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	d := openMarkdown(t, h, "# Title\n\nSome **bold** text.\n\n## Second part\n\nmore\n")
	language := h.app.language()
	page := i18n.Shared(language, "desktop.markdown.preview")
	text := func(id string) string { return i18n.Shared(language, id) }

	source, rendered := editorRect(h, d), h.hitLabeled(page)
	if source.X >= rendered.X || math.Abs(float64(source.Width-rendered.Width)) > 2 {
		t.Fatalf("source %+v and page %+v are not equal halves side by side", source, rendered)
	}
	s := d.markdown
	if s == nil || len(s.headings) != 2 || s.headings[0].text != "Title" || s.headings[1].level != 2 {
		t.Fatalf("the page's headings are %+v", s)
	}

	h.click(center(h.hitLabeled(text("editor.markdownPreviewView"))))
	if editorRect(h, d).Width != 0 || h.hitLabeled(page).Width < source.Width*1.5 {
		t.Fatalf("Preview left the source shown or the page in half the group: %+v", h.hitLabeled(page))
	}
	h.click(center(h.hitLabeled(text("editor.markdownSourceView"))))
	if controlShown(h, page) || editorRect(h, d).Width < source.Width*1.5 {
		t.Fatal("Editor left the page shown or the source in half the group")
	}
	h.click(center(h.hitLabeled(text("editor.markdownSplitView"))))
	if !controlShown(h, page) || editorRect(h, d).Width == 0 {
		t.Fatal("Editor and Preview did not bring both halves back")
	}

	// An edit made off the window's own input, as a reload or a format is, reaches the page by
	// the window thread like they do.
	h.app.post(func(a *App) { a.insertForTest(d, "\n### Third\n") })
	h.settle()
	if len(s.headings) != 3 {
		t.Fatalf("headings after the edit are %+v", s.headings)
	}
}

// TestMarkdownPreviewIgnoresOtherFiles: another file has no page and no view switch.
func TestMarkdownPreviewIgnoresOtherFiles(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "main.go")
	if err := os.WriteFile(path, []byte("package main\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.openFile(h.app.project, path)
	h.settle()
	d := h.app.project.docs.byPath(path)
	if d == nil || d.markdown != nil || controlShown(h, i18n.Shared(h.app.language(), "editor.markdownSplitView")) {
		t.Fatalf("a Go file was given a page or the view switch: %+v", d)
	}
}

// TestMarkdownContentsJumpsToHeading: the page's Contents button lists the headings, and choosing
// one closes the list and scrolls the page and the source beside it to that heading.
func TestMarkdownContentsJumpsToHeading(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	d := openMarkdown(t, h, longMarkdown())
	s := d.markdown
	h.click(center(h.hitLabeled(i18n.Shared(h.app.language(), "desktop.markdown.contents"))))
	if !s.contentsOpen {
		t.Fatal("Contents did not open the list of headings")
	}
	var entry gfx.Rect
	for _, label := range h.driver.Snapshot().Labels {
		// The list's rows are in its own smaller type; the page shows the same heading too.
		if label.Value == "Part 12" && label.FontSize == 12.5 {
			entry = label.Bounds
		}
	}
	if entry.Width == 0 {
		t.Fatalf("the list does not show the twelfth heading: %v", h.driver.Snapshot().Labels)
	}
	h.click(center(entry))
	h.settle()
	if s.contentsOpen {
		t.Fatal("choosing a heading left the list open")
	}
	want, _ := s.view.YAtSource(s.source, s.headings[11].start)
	if math.Abs(float64(s.scroll-want)) > 1 {
		t.Fatalf("the page is at %v, want the heading at %v", s.scroll, want)
	}
	if line := editorTopLine(d); line != 55 {
		t.Fatalf("the source's top line is %d, want the heading's line 55", line)
	}
}

// TestMarkdownContentsIndentsHeadingsByLevel: the Contents list of the page Viva draws shows each
// heading on a row of its own, indented by how much deeper it is than the shallowest heading.
func TestMarkdownContentsIndentsHeadingsByLevel(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	openMarkdown(t, h, "## Intro\n\nText.\n\n### Setup\n\n#### Keys\n\n## Usage\n")
	title := i18n.Shared(h.app.language(), "desktop.markdown.contents")
	h.click(center(h.hitLabeled(title)))
	rows := map[string]gfx.Rect{}
	expanded := false
	for _, label := range h.driver.Snapshot().Labels {
		if label.FontSize == 12.5 {
			rows[label.Value] = label.Bounds
		}
	}
	var list gfx.Rect
	for _, hit := range h.driver.Snapshot().Hits {
		switch {
		case hit.Label != title || hit.IsLabel:
		case hit.Role == gfx.RoleButton:
			expanded = hit.Expanded
		case hit.Role == gfx.RoleListBox:
			list = hit.Bounds
		}
	}
	order := []string{"Intro", "Setup", "Keys", "Usage"}
	for _, name := range order {
		if rows[name].Width == 0 {
			t.Fatalf("the list does not show %q: %v", name, rows)
		}
	}
	if !expanded {
		t.Fatal("the Contents button does not say the list is open")
	}
	for i := 1; i < len(order); i++ {
		above, below := rows[order[i-1]], rows[order[i]]
		if below.Y < above.Y+above.Height {
			t.Fatalf("%q at %v overlaps %q at %v", order[i], below, order[i-1], above)
		}
	}
	intro, setup, keys, usage := rows["Intro"].X, rows["Setup"].X, rows["Keys"].X, rows["Usage"].X
	if setup-intro != markdownContentsIndent || keys-setup != markdownContentsIndent || usage != intro {
		t.Fatalf("the headings start at %v, %v, %v and %v, want each level %d further in", intro, setup, keys, usage, markdownContentsIndent)
	}
	// The shallowest headings are not indented: the page's headings start at the second level.
	if list.Width == 0 || intro-list.X != markdownContentsInset {
		t.Fatalf("the shallowest heading starts at %v in the list at %v, want %d in", intro, list, markdownContentsInset)
	}
}

// editorTopLine is the line most of whose first row is at the top of d's editor.
func editorTopLine(d *document) int {
	v := d.view
	_, scroll := v.ScrollOffset()
	line, _ := v.LineAt(v.LineTop(0) + scroll + v.LineHeight()/2)
	return line
}

// TestMarkdownSourceAndPageScrollTogether: scrolling the source brings the page to the same
// source line, and scrolling the page brings the source to its line, without either pulling the
// other back afterwards.
func TestMarkdownSourceAndPageScrollTogether(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	d := openMarkdown(t, h, longMarkdown())
	s := d.markdown
	source, page := editorRect(h, d), h.hitLabeled(i18n.Shared(h.app.language(), "desktop.markdown.preview"))
	lineHeight := d.view.LineHeight()
	if lineHeight <= 0 {
		t.Fatal("the source was not painted")
	}

	if err := h.driver.Scroll(gfx.ScrollEvent{X: source.X + 20, Y: source.Y + 20, DeltaY: 95 * lineHeight, Precise: true}); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if line := editorTopLine(d); line != 95 {
		t.Fatalf("the source's top line is %d, want 95", line)
	}
	want, _ := s.view.YAtSource(s.source, s.lineStart(95))
	if math.Abs(float64(s.scroll-want)) > 1 {
		t.Fatalf("the page is at %v after the source scrolled, want line 95's rendering at %v", s.scroll, want)
	}

	target, _ := s.view.YAtSource(s.source, s.lineStart(45))
	if err := h.driver.Scroll(gfx.ScrollEvent{X: page.X + 20, Y: page.Y + 40, DeltaY: target - s.scroll, Precise: true}); err != nil {
		t.Fatal(err)
	}
	h.settle()
	h.settle()
	if line := editorTopLine(d); line != 45 {
		t.Fatalf("the source's top line is %d after the page scrolled, want 45", line)
	}
	if math.Abs(float64(s.scroll-target)) > 1 {
		t.Fatalf("the page moved to %v after leading the source, want it kept at %v", s.scroll, target)
	}
}

// pageTopLine is the source line at the top of d's page.
func pageTopLine(s *markdownPreviewState) int {
	offset, _ := s.view.SourceAtY(s.source, s.scroll+1)
	return max(sort.SearchInts(s.lineStarts, offset+1)-1, 0)
}

// TestMarkdownModeSwitchKeepsThePlace: the page shown alone keeps the line it had at its top
// though it is laid out wider; the source coming back beside it takes up the page's line, and
// the page coming back after the source was shown alone takes up the source's line.
func TestMarkdownModeSwitchKeepsThePlace(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	d := openMarkdown(t, h, longMarkdown())
	s := d.markdown
	language := h.app.language()
	mode := func(id string) { h.click(center(h.hitLabeled(i18n.Shared(language, id)))) }
	page := h.hitLabeled(i18n.Shared(language, "desktop.markdown.preview"))

	target, _ := s.view.YAtSource(s.source, s.lineStart(45))
	if err := h.driver.Scroll(gfx.ScrollEvent{X: page.X + 20, Y: page.Y + 40, DeltaY: target, Precise: true}); err != nil {
		t.Fatal(err)
	}
	h.settle()
	mode("editor.markdownPreviewView")
	if line := pageTopLine(s); line != 45 {
		t.Fatalf("the page alone has line %d at its top, want 45", line)
	}

	page = h.hitLabeled(i18n.Shared(language, "desktop.markdown.preview"))
	next, _ := s.view.YAtSource(s.source, s.lineStart(100))
	if err := h.driver.Scroll(gfx.ScrollEvent{X: page.X + 20, Y: page.Y + 40, DeltaY: next - s.scroll, Precise: true}); err != nil {
		t.Fatal(err)
	}
	h.settle()
	mode("editor.markdownSplitView")
	if line := editorTopLine(d); line != 100 {
		t.Fatalf("the source came back at line %d, want the page's line 100", line)
	}

	mode("editor.markdownSourceView")
	editor := editorRect(h, d)
	_, scroll := d.view.ScrollOffset()
	if err := h.driver.Scroll(gfx.ScrollEvent{X: editor.X + 40, Y: editor.Y + 20, DeltaY: 20*d.view.LineHeight() - scroll, Precise: true}); err != nil {
		t.Fatal(err)
	}
	h.settle()
	mode("editor.markdownPreviewView")
	if line := pageTopLine(s); line != 20 {
		t.Fatalf("the page came back at line %d, want the source's line 20", line)
	}
}

// TestMarkdownPreviewFollowsLinksAsCoreResolvesThem: a web or mail link opens outside, an anchor
// brings its heading to the top of the page and the source, and another scheme is not followed.
func TestMarkdownPreviewFollowsLinksAsCoreResolvesThem(t *testing.T) {
	var opened []string
	previous := openURL
	openURL = func(address string) error { opened = append(opened, address); return nil }
	t.Cleanup(func() { openURL = previous })

	h := newHarness(t, &testKernel{Client: core.NewClient()})
	d := openMarkdown(t, h, longMarkdown())
	p, s := h.app.project, d.markdown
	for _, destination := range []string{"https://example.com/a?b=1", "mailto:me@example.com", "file:///etc/hosts", "javascript:alert(1)", "#part-12"} {
		h.app.followMarkdownLink(p, d, s, destination)
		h.settle()
	}
	if want := []string{"https://example.com/a?b=1", "mailto:me@example.com"}; !slices.Equal(opened, want) {
		t.Fatalf("opened %v, want %v", opened, want)
	}
	want, _ := s.view.YAtSource(s.source, s.headings[11].start)
	if math.Abs(float64(s.scroll-want)) > 1 {
		t.Fatalf("the page is at %v after the anchor, want the heading at %v", s.scroll, want)
	}
	if line := editorTopLine(d); line != 55 {
		t.Fatalf("the source's top line is %d after the anchor, want the heading's line 55", line)
	}
}

// A relative link in the page opens the file it points at in the editor.
func TestMarkdownPreviewFollowsRelativeLink(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "docs"), 0o700); err != nil {
		t.Fatal(err)
	}
	guide := filepath.Join(root, "docs", "guide.md")
	if err := os.WriteFile(guide, []byte("# Guide\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	readme := filepath.Join(root, "README.md")
	if err := os.WriteFile(readme, []byte("[Guide](docs/guide.md)\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	h.app.openFile(p, readme)
	h.settle()
	d := p.docs.byPath(readme)
	if d == nil || d.markdown == nil {
		t.Fatal("the Markdown file did not open beside its page")
	}
	h.app.followMarkdownLink(p, d, d.markdown, "docs/guide.md")
	awaitStateWithin(t, h, 8*time.Second, "the linked file in the editor", func() bool {
		return p.selectedDocument(p.docs.group) != nil && filepath.Clean(p.selectedDocument(p.docs.group).path) == filepath.Clean(guide)
	})
}
