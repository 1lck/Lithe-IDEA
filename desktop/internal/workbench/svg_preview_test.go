package workbench

import (
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/webpreview"
)

const testSVG = `<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20"/></svg>`

// openSVG opens a project with one SVG file of text and returns the file's document.
func openSVG(t *testing.T, h *harness, text string) *document {
	t.Helper()
	root := t.TempDir()
	path := filepath.Join(root, "icon.svg")
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.openFile(h.app.project, path)
	h.settle()
	d := h.app.project.docs.byPath(path)
	if d == nil {
		t.Fatal("the SVG file did not open")
	}
	h.settle()
	return d
}

// heldSVGWaits makes the SVG pictures' waits end only when the test calls the returned function.
func heldSVGWaits(t *testing.T) func() int {
	t.Helper()
	var held []func()
	previous := svgPreviewWait
	svgPreviewWait = func(done func()) { held = append(held, done) }
	t.Cleanup(func() { svgPreviewWait = previous })
	return func() int {
		ended := len(held)
		for _, done := range held {
			done()
		}
		held = nil
		return ended
	}
}

// TestSVGFileShowsItsPictureBesideTheSource: an SVG file opens as text with its picture beside it,
// on the image page given the editor's text; an edit is given after the wait and keeps the zoom,
// a change the engine cannot draw keeps the last picture, and the tab strip's switch shows either
// side alone.
func TestSVGFileShowsItsPictureBesideTheSource(t *testing.T) {
	endWaits := heldSVGWaits(t)
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	pages := fakePreviews(h)
	d := openSVG(t, h, testSVG)
	if len(*pages) != 1 || d.svg == nil {
		t.Fatalf("the SVG file opened %d web pages", len(*pages))
	}
	page := (*pages)[0]
	if page.config.Page != webpreview.ImagePage || page.config.File != "" {
		t.Fatalf("the picture's page is %q of %q", page.config.Page, page.config.File)
	}
	if editorRect(h, d).Width == 0 || len(page.documents) != 0 {
		t.Fatalf("the source is not shown, or the page was given the text before it loaded")
	}

	page.load()
	if setups := sentOf[previewTheme](page); len(setups) != 1 || setups[0].Type != "setup" {
		t.Fatalf("the page was given the look %+v", setups)
	}
	h.settle()
	first := d.view.Revision()
	if len(page.documents) != 1 || string(page.documents[0]) != testSVG {
		t.Fatalf("the page was given %q", page.documents)
	}
	if shows := sentOf[imagePageShow](page); len(shows) != 1 || shows[0] != (imagePageShow{Type: "show", Src: "document?r=" + strconv.Itoa(first), SVG: true}) {
		t.Fatalf("the page was told to show %+v", shows)
	}

	page.config.OnMessage(webpreview.Message{Type: "scale", Scale: 1, Fit: 1, Width: 40, Height: 20})
	h.settle()
	language := h.app.language()
	if !h.shows("40 × 20") || hitOf(h, i18n.Shared(language, "desktop.viewer.zoom")).Value != "100%" {
		t.Fatal("the bar does not show the picture's dimensions and zoom")
	}
	h.click(center(h.hitLabeled(i18n.Shared(language, "desktop.viewer.zoomIn"))))
	h.settle()
	if zooms := sentOf[imagePageZoom](page); !slices.Equal(zooms, []imagePageZoom{{Type: "zoom", By: imageZoomStep}}) {
		t.Fatalf("the bar sent %+v", zooms)
	}

	h.app.post(func(a *App) { a.insertForTest(d, "<!-- edit -->") })
	h.settle()
	h.settle()
	if len(page.documents) != 1 {
		t.Fatal("an edit was given before the wait ended")
	}
	if ended := endWaits(); ended != 1 {
		t.Fatalf("%d waits ended, want 1", ended)
	}
	h.settle()
	h.settle()
	shows := sentOf[imagePageShow](page)
	if len(page.documents) != 2 || !strings.Contains(string(page.documents[1]), "<!-- edit -->") || len(shows) != 2 {
		t.Fatalf("after the wait the page was given %d texts and %d shows", len(page.documents), len(shows))
	}
	if shows[1] != (imagePageShow{Type: "show", Src: "document?r=" + strconv.Itoa(d.view.Revision()), SVG: true, Keep: true}) || d.view.Revision() == first {
		t.Fatalf("the edit was shown as %+v", shows[1])
	}

	page.config.OnMessage(webpreview.Message{Type: "failed"})
	h.settle()
	if d.svg.failed || h.shows(i18n.Shared(language, "desktop.viewer.imageFailed")) || page.closed {
		t.Fatal("a change the engine cannot draw replaced the last picture with the failure")
	}

	h.click(center(h.hitLabeled(i18n.Shared(language, "editor.markdownPreviewView"))))
	h.settle()
	if editorRect(h, d).Width != 0 || !controlShown(h, i18n.Shared(language, "desktop.viewer.zoomIn")) {
		t.Fatal("the picture alone still shows the source, or not the bar")
	}
	h.click(center(h.hitLabeled(i18n.Shared(language, "editor.markdownSourceView"))))
	h.settle()
	if editorRect(h, d).Width == 0 || controlShown(h, i18n.Shared(language, "desktop.viewer.zoomIn")) || page.closed || len(*pages) != 1 {
		t.Fatalf("the source alone shows the picture, or the hidden page closed %v", page.closed)
	}
}

// TestSVGTextNeverDrawnShowsTheFailure: a text the engine never could draw shows the viewer's
// failure in place of the page, until a change it draws.
func TestSVGTextNeverDrawnShowsTheFailure(t *testing.T) {
	endWaits := heldSVGWaits(t)
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	pages := fakePreviews(h)
	d := openSVG(t, h, "<svg")
	page := (*pages)[0]
	page.load()
	h.settle()
	page.config.OnMessage(webpreview.Message{Type: "failed"})
	h.settle()
	language := h.app.language()
	if !d.svg.failed || !h.shows(i18n.Shared(language, "desktop.viewer.imageFailed")) || page.closed {
		t.Fatal("a text never drawn does not show the failure, or its page closed")
	}

	h.app.post(func(a *App) { a.insertForTest(d, testSVG) })
	h.settle()
	endWaits()
	h.settle()
	h.settle()
	if len(page.documents) != 2 {
		t.Fatalf("the change was not given: %d texts", len(page.documents))
	}
	page.config.OnMessage(webpreview.Message{Type: "scale", Scale: 1, Fit: 1, Width: 40, Height: 20})
	h.settle()
	if d.svg.failed || h.shows(i18n.Shared(language, "desktop.viewer.imageFailed")) {
		t.Fatal("the drawn change still shows the failure")
	}
}

// TestSVGFileIsTextWithoutAWebEngine: where no page can be opened, an SVG file is text alone,
// without the switch of its view.
func TestSVGFileIsTextWithoutAWebEngine(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	d := openSVG(t, h, testSVG)
	if d.svg != nil || editorRect(h, d).Width == 0 || controlShown(h, i18n.Shared(h.app.language(), "editor.markdownPreviewView")) {
		t.Fatal("without a web engine the SVG file is not text alone")
	}
}
