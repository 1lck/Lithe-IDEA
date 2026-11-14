package workbench

import (
	"context"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/webpreview"
	"github.com/vivaui/viva/gfx"
)

// fakePreview stands in for a web page, which the headless driver cannot open: it keeps what the
// host sends once the page is ready, as webpreview.Page drops what is sent before.
type fakePreview struct {
	id        gfx.NativeViewID
	config    webpreview.Config
	ready     bool
	sent      []any
	documents [][]byte
	closed    bool
}

func (f *fakePreview) ID() gfx.NativeViewID { return f.id }
func (f *fakePreview) Ready() bool          { return f.ready }
func (f *fakePreview) Close()               { f.closed = true }
func (f *fakePreview) FileURL() string {
	return webpreview.Origin + "file/" + filepath.Base(f.config.File)
}

func (f *fakePreview) Send(message any) {
	if f.ready && !f.closed {
		f.sent = append(f.sent, message)
	}
}

func (f *fakePreview) SetDocument(data []byte, _ string) {
	f.documents = append(f.documents, data)
}

// load is the page finishing loading: it is ready and says so.
func (f *fakePreview) load() {
	f.ready = true
	f.config.OnMessage(webpreview.Message{Type: "ready"})
}

// sentOf is what the host sent the page of type T, in order.
func sentOf[T any](f *fakePreview) []T {
	var out []T
	for _, message := range f.sent {
		if typed, ok := message.(T); ok {
			out = append(out, typed)
		}
	}
	return out
}

// fakePreviews makes h's web host ready and its previews open fakes, listed as they open.
func fakePreviews(h *harness) *[]*fakePreview {
	pages := &[]*fakePreview{}
	h.app.webReady = true
	h.app.previews.open = func(config webpreview.Config) (previewView, error) {
		page := &fakePreview{id: gfx.NativeViewID(len(*pages) + 1), config: config}
		*pages = append(*pages, page)
		return page, nil
	}
	return pages
}

// longMarkdownHeadings are the headings the web page reports for longMarkdown.
func longMarkdownHeadings() []webpreview.Heading {
	headings := make([]webpreview.Heading, 0, 40)
	for i := 1; i <= 40; i++ {
		headings = append(headings, webpreview.Heading{Level: 2, Text: fmt.Sprintf("Part %d", i), Line: 5*(i-1) + 1})
	}
	return headings
}

// TestMarkdownWebPageRendersCoreHTMLAndScrollsWithTheSource: a Markdown file's page is a web page
// given Core's HTML once it loads, with the line at the editor's top; the Contents list jumps to a
// heading the page reported, the source and the page lead each other without either echoing the
// other, an edit is rendered again, and the page coming back after the source was shown alone
// takes up the source's line.
func TestMarkdownWebPageRendersCoreHTMLAndScrollsWithTheSource(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	pages := fakePreviews(h)
	d := openMarkdown(t, h, longMarkdown())
	s := d.markdown
	if len(*pages) != 1 || s == nil || s.web == nil {
		t.Fatalf("the Markdown file opened %d web pages, state %+v", len(*pages), s)
	}
	page := (*pages)[0]
	if page.config.Page != webpreview.MarkdownPage || controlShown(h, i18n.Shared(h.app.language(), "desktop.markdown.preview")) {
		t.Fatal("the page is not the web Markdown page, or the native page is shown beside it")
	}
	h.await("Core's HTML", func() bool { return s.web.html != "" })
	if !strings.Contains(s.web.html, "data-sourcepos") || !strings.Contains(s.web.html, "Part 12") {
		t.Fatalf("the page's HTML is not Core's rendering of the source: %.200q", s.web.html)
	}

	page.load()
	if setups := sentOf[markdownPageSetup](page); len(setups) != 1 || setups[0].Strings["empty"] == "" || len(setups[0].Theme.Variables) == 0 {
		t.Fatalf("the loaded page was given %+v, want its strings and theme", setups)
	}
	if renders := sentOf[markdownPageRender](page); len(renders) != 1 || renders[0].HTML != s.web.html || renders[0].Revision != d.view.Revision() {
		t.Fatalf("the loaded page was given renders %+v", len(renders))
	}
	if scrolls := sentOf[markdownPageScroll](page); len(scrolls) != 1 || scrolls[0].Line != 1 {
		t.Fatalf("the loaded page was scrolled %+v, want to line 1", scrolls)
	}

	page.config.OnMessage(webpreview.Message{Type: "rendered", Revision: d.view.Revision(), Headings: longMarkdownHeadings()})
	h.settle()
	h.click(center(h.hitLabeled(i18n.Shared(h.app.language(), "desktop.markdown.contents"))))
	var entry gfx.Rect
	for _, label := range h.driver.Snapshot().Labels {
		if label.Value == "Part 12" && label.FontSize == 12.5 {
			entry = label.Bounds
		}
	}
	if !s.contentsOpen || entry.Width == 0 {
		t.Fatalf("Contents does not list the page's headings: %v", h.driver.Snapshot().Labels)
	}
	h.click(center(entry))
	h.settle()
	scrolls := sentOf[markdownPageScroll](page)
	if s.contentsOpen || len(scrolls) != 2 || scrolls[1].Line != 56 {
		t.Fatalf("choosing Part 12 scrolled the page %+v, want once more to line 56", scrolls)
	}
	if line := editorTopLine(d); line != 55 {
		t.Fatalf("the source's top line is %d, want the heading's line 55", line)
	}

	source := editorRect(h, d)
	lineHeight := d.view.LineHeight()
	if err := h.driver.Scroll(gfx.ScrollEvent{X: source.X + 20, Y: source.Y + 20, DeltaY: 40 * lineHeight, Precise: true}); err != nil {
		t.Fatal(err)
	}
	h.settle()
	scrolls = sentOf[markdownPageScroll](page)
	if editorTopLine(d) != 95 || len(scrolls) != 3 || math.Abs(scrolls[2].Line-96) > 0.01 {
		t.Fatalf("the source at line %d scrolled the page %+v, want to line 96", editorTopLine(d), scrolls)
	}

	page.config.OnMessage(webpreview.Message{Type: "scrolled", Line: 46})
	h.settle()
	h.settle()
	if line := editorTopLine(d); line != 45 {
		t.Fatalf("the source's top line is %d after the page scrolled, want 45", line)
	}
	if got := len(sentOf[markdownPageScroll](page)); got != 3 {
		t.Fatalf("the page was scrolled back after it led the source: %d scrolls", got)
	}

	h.app.post(func(a *App) { a.insertForTest(d, "\n## Appendix\n") })
	h.settle()
	h.await("the edit's rendering", func() bool { return len(sentOf[markdownPageRender](page)) == 2 })
	if renders := sentOf[markdownPageRender](page); !strings.Contains(renders[1].HTML, "Appendix") || renders[1].Revision != d.view.Revision() {
		t.Fatalf("the edit was rendered as %+v", renders[1].Revision)
	}

	language := h.app.language()
	mode := func(id string) { h.click(center(h.hitLabeled(i18n.Shared(language, id)))) }
	mode("editor.markdownSourceView")
	editor := editorRect(h, d)
	_, scroll := d.view.ScrollOffset()
	if err := h.driver.Scroll(gfx.ScrollEvent{X: editor.X + 40, Y: editor.Y + 20, DeltaY: 20*lineHeight - scroll, Precise: true}); err != nil {
		t.Fatal(err)
	}
	h.settle()
	mode("editor.markdownPreviewView")
	h.settle()
	scrolls = sentOf[markdownPageScroll](page)
	if last := scrolls[len(scrolls)-1]; math.Abs(last.Line-21) > 0.01 || page.closed || len(*pages) != 1 {
		t.Fatalf("the page came back at line %v (closed %v, %d pages), want the source's line 21", last.Line, page.closed, len(*pages))
	}
}

// TestMarkdownWebPageFollowsLinksAndServesImagesAsCoreResolvesThem: the page's links and the
// addresses it navigates to are followed as Core resolves them, its images resolve against the
// file inside the workspace, and the page closes with its file.
func TestMarkdownWebPageFollowsLinksAndServesImagesAsCoreResolvesThem(t *testing.T) {
	var opened []string
	previous := openURL
	openURL = func(address string) error { opened = append(opened, address); return nil }
	t.Cleanup(func() { openURL = previous })

	h := newHarness(t, &testKernel{Client: core.NewClient()})
	pages := fakePreviews(h)
	outside := t.TempDir()
	root := filepath.Join(outside, "work")
	if err := os.MkdirAll(filepath.Join(root, "docs"), 0o700); err != nil {
		t.Fatal(err)
	}
	guide := filepath.Join(root, "docs", "guide.md")
	readme := filepath.Join(root, "README.md")
	for path, data := range map[string][]byte{
		guide:                                []byte("# Guide\n"),
		readme:                               []byte("[Guide](docs/guide.md)\n\n![logo](docs/logo.png)\n"),
		filepath.Join(root, "docs/logo.png"): pngOf(t, 2, 2),
		filepath.Join(outside, "secret.png"): pngOf(t, 2, 2),
	} {
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	h.open(root)
	p := h.app.project
	h.app.openFile(p, readme)
	h.settle()
	d := p.docs.byPath(readme)
	if d == nil || len(*pages) != 1 {
		t.Fatalf("the Markdown file opened %d web pages", len(*pages))
	}
	page := (*pages)[0]
	page.load()

	page.config.OnMessage(webpreview.Message{Type: "link", Href: "https://example.com/x"})
	h.settle()
	page.config.Follow("https://example.com/y")
	h.settle()
	page.config.OnMessage(webpreview.Message{Type: "link", Href: "file:///etc/hosts"})
	h.settle()
	if want := []string{"https://example.com/x", "https://example.com/y"}; !slices.Equal(opened, want) {
		t.Fatalf("opened %v, want %v", opened, want)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	logo, err := page.config.Resolve(ctx, "docs/logo.png")
	if err != nil || logo.Kind != "file" || logo.MIME != "image/png" {
		t.Fatalf("the page's image resolved to %+v, %v", logo, err)
	}
	if secret, err := page.config.Resolve(ctx, "../secret.png"); err != nil || secret.Kind != "none" {
		t.Fatalf("an image outside the workspace resolved to %+v, %v", secret, err)
	}

	page.config.OnMessage(webpreview.Message{Type: "link", Href: "docs/guide.md"})
	awaitStateWithin(t, h, 8*time.Second, "the linked file in the editor", func() bool {
		shown := p.selectedDocument(p.docs.group)
		return shown != nil && filepath.Clean(shown.path) == filepath.Clean(guide)
	})
	h.settle()
	if page.closed {
		t.Fatal("the page closed while its file is open in a tab not shown")
	}
	h.app.closeDocument(p, d.id)
	h.settle()
	if !page.closed {
		t.Fatal("the page stayed open after its file closed")
	}
}

// TestPreviewPagesKeepTheHiddenOnesUpToTheLimit: pages of tabs not shown stay open up to
// previewPagesKept, the one shown longest ago closing past it; a closed page opens again when its
// tab is shown.
func TestPreviewPagesKeepTheHiddenOnesUpToTheLimit(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	pages := fakePreviews(h)
	root := t.TempDir()
	var paths []string
	for i := range previewPagesKept + 2 {
		path := filepath.Join(root, fmt.Sprintf("note%d.md", i))
		if err := os.WriteFile(path, []byte(fmt.Sprintf("# Note %d\n", i)), 0o600); err != nil {
			t.Fatal(err)
		}
		paths = append(paths, path)
	}
	h.open(root)
	p := h.app.project
	for _, path := range paths {
		h.app.openFile(p, path)
		h.settle()
		h.settle()
	}
	open := func() int {
		count := 0
		for _, page := range *pages {
			if !page.closed {
				count++
			}
		}
		return count
	}
	if len(*pages) != len(paths) || open() != previewPagesKept+1 || !(*pages)[0].closed {
		t.Fatalf("%d pages opened and %d are open, the first closed %v; want %d open with the first closed",
			len(*pages), open(), (*pages)[0].closed, previewPagesKept+1)
	}

	h.app.openFile(p, paths[0])
	h.settle()
	h.settle()
	if len(*pages) != len(paths)+1 || (*pages)[len(paths)].closed || !(*pages)[1].closed || open() != previewPagesKept+1 {
		t.Fatalf("showing the first tab again: %d pages, %d open, the second closed %v", len(*pages), open(), (*pages)[1].closed)
	}
	if d := p.docs.byPath(paths[0]); d == nil || d.markdown == nil || d.markdown.web == nil || d.markdown.web.entry.view != (*pages)[len(paths)] {
		t.Fatal("the first file did not take the page opened again")
	}
}

// TestMarkdownPageIsNativeOnceAWebPageCannotOpen: a page that cannot be opened leaves the
// preview to the page Viva draws, and no other page is tried.
func TestMarkdownPageIsNativeOnceAWebPageCannotOpen(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.webReady = true
	tries := 0
	h.app.previews.open = func(webpreview.Config) (previewView, error) {
		tries++
		return nil, errors.New("the system has no web engine")
	}
	d := openMarkdown(t, h, "# Title\n\n## Second part\n")
	if tries != 1 || !h.app.previews.failed || d.markdown == nil || d.markdown.web != nil {
		t.Fatalf("tries = %d, failed = %v", tries, h.app.previews.failed)
	}
	if !controlShown(h, i18n.Shared(h.app.language(), "desktop.markdown.preview")) || len(d.markdown.headings) != 2 {
		t.Fatal("the native page is not shown with its headings")
	}
	other := filepath.Join(filepath.Dir(d.path), "OTHER.md")
	if err := os.WriteFile(other, []byte("# Other\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.openFile(h.app.project, other)
	h.settle()
	h.settle()
	if tries != 1 {
		t.Fatalf("another page was tried after one failed: %d tries", tries)
	}
}
