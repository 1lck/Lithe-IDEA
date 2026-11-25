package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/webpreview"
	"github.com/vivaui/viva/app"
)

const testHTML = `<!doctype html><link rel=stylesheet href=style.css><h1>Board</h1>`

// openHTML opens a project whose site folder holds an HTML file of text, its style sheet and a
// hidden file, and returns the file's document.
func openHTML(t *testing.T, h *harness, text string) *document {
	t.Helper()
	root := t.TempDir()
	for name, content := range map[string]string{
		"site/board.html": text,
		"site/style.css":  "h1{}",
		".env":            "TOKEN=1",
	} {
		path := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	h.open(root)
	path := filepath.Join(root, "site", "board.html")
	h.app.openFile(h.app.project, path)
	h.settle()
	d := h.app.project.docs.byPath(path)
	if d == nil {
		t.Fatal("the HTML file did not open")
	}
	h.settle()
	h.settle()
	return d
}

// heldHTMLWaits makes the HTML pages' waits end only when the test calls the returned function.
func heldHTMLWaits(t *testing.T) func() int {
	t.Helper()
	var held []func()
	previous := htmlPreviewWait
	htmlPreviewWait = func(done func()) { held = append(held, done) }
	t.Cleanup(func() { htmlPreviewWait = previous })
	return func() int {
		ended := len(held)
		for _, done := range held {
			done()
		}
		held = nil
		return ended
	}
}

// TestHTMLFileShowsItsPageBesideTheSource: an HTML file opens as text with its page beside it, on
// the site page of the workspace Core names, given the editor's text as an HTML document; the
// page's requests are put to Core for the file, an edit is given after the wait, the bar moves
// through the page's history and loads it again, a link followed off the site opens as Core
// resolves it, and the tab strip's switch shows either side alone.
func TestHTMLFileShowsItsPageBesideTheSource(t *testing.T) {
	endWaits := heldHTMLWaits(t)
	var opened []string
	previous := openURL
	openURL = func(address string) error { opened = append(opened, address); return nil }
	t.Cleanup(func() { openURL = previous })

	h := newHarness(t, &testKernel{Client: core.NewClient()})
	pages := fakePreviews(h)
	d := openHTML(t, h, testHTML)
	if len(*pages) != 1 || d.html == nil || d.html.site == nil {
		t.Fatalf("the HTML file opened %d web pages", len(*pages))
	}
	page := (*pages)[0]
	if page.config.Page != webpreview.SitePage || page.config.Address != "site/board.html" || page.config.Request == nil {
		t.Fatalf("the file's page is %q at %q", page.config.Page, page.config.Address)
	}
	if editorRect(h, d).Width == 0 {
		t.Fatal("the source is not shown beside the page")
	}
	if len(page.documents) != 1 || string(page.documents[0]) != testHTML || page.mimes[0] != "text/html; charset=utf-8" {
		t.Fatalf("the page was given %q as %q", page.documents, page.mimes)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for route, kind := range map[string]string{"site/board.html": "document", "site/style.css": "file", ".env": "denied", "site/missing.js": "none"} {
		resource, err := page.config.Request(ctx, route)
		if err != nil || resource.Kind != kind {
			t.Fatalf("%q is %+v (%v), want %s", route, resource, err, kind)
		}
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
	if len(page.documents) != 2 || !strings.Contains(string(page.documents[1]), "<!-- edit -->") {
		t.Fatalf("after the wait the page was given %d texts", len(page.documents))
	}

	language := h.app.language()
	// Back and Forward stay disabled until the page has history in each direction.
	for _, key := range []string{"desktop.htmlPreview.back", "desktop.htmlPreview.forward"} {
		h.click(center(h.hitLabeled(i18n.Shared(language, key))))
		h.settle()
	}
	if page.backs != 0 || page.forwards != 0 {
		t.Fatalf("disabled history buttons fired: back=%d forward=%d", page.backs, page.forwards)
	}
	page.canGoBack, page.canGoForward = true, true
	h.app.invalidator.Invalidate()
	h.settle()
	for _, key := range []string{"desktop.htmlPreview.back", "desktop.htmlPreview.forward", "desktop.htmlPreview.reload"} {
		h.click(center(h.hitLabeled(i18n.Shared(language, key))))
		h.settle()
	}
	if page.backs != 1 || page.forwards != 1 || page.reloads != 1 {
		t.Fatalf("the bar went back %d, forward %d and reloaded %d times", page.backs, page.forwards, page.reloads)
	}
	if !controlShown(h, i18n.Shared(language, "desktop.editorMenu.openInBrowser")) {
		t.Fatal("the bar does not open the file in the browser")
	}

	page.config.Follow("https://example.com/docs")
	h.await("the followed link", func() bool { return len(opened) == 1 })
	if opened[0] != "https://example.com/docs" {
		t.Fatalf("opened %v", opened)
	}

	h.click(center(h.hitLabeled(i18n.Shared(language, "editor.markdownPreviewView"))))
	h.settle()
	if editorRect(h, d).Width != 0 || !controlShown(h, i18n.Shared(language, "desktop.htmlPreview.reload")) {
		t.Fatal("the page alone still shows the source, or not the bar")
	}
	h.click(center(h.hitLabeled(i18n.Shared(language, "editor.markdownSourceView"))))
	h.settle()
	if editorRect(h, d).Width == 0 || controlShown(h, i18n.Shared(language, "desktop.htmlPreview.reload")) || page.closed || len(*pages) != 1 {
		t.Fatalf("the source alone shows the page, or the hidden page closed %v", page.closed)
	}
}

// TestHTMLFileIsTextWhereItsPageCannotOpen: where the engine cannot open an HTML file's page, HTML
// files are text alone from then on, without the switch of their view, and the other previews
// still open.
func TestHTMLFileIsTextWhereItsPageCannotOpen(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	pages := fakePreviews(h)
	open := h.app.previews.open
	h.app.previews.open = func(config webpreview.Config) (previewView, error) {
		if config.Page == webpreview.SitePage {
			return nil, errors.New("no ephemeral store")
		}
		return open(config)
	}
	d := openHTML(t, h, testHTML)
	language := h.app.language()
	if !h.app.previews.siteFailed || h.app.previews.failed || len(*pages) != 0 {
		t.Fatalf("the page that failed marked the site %v and the previews %v", h.app.previews.siteFailed, h.app.previews.failed)
	}
	if editorRect(h, d).Width == 0 || controlShown(h, i18n.Shared(language, "editor.markdownPreviewView")) {
		t.Fatal("the HTML file is not text alone")
	}

	svg := filepath.Join(h.app.project.root, "icon.svg")
	if err := os.WriteFile(svg, []byte(testSVG), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.openFile(h.app.project, svg)
	h.settle()
	h.settle()
	if len(*pages) != 1 || (*pages)[0].config.Page != webpreview.ImagePage {
		t.Fatalf("an SVG file opened %d pages once the HTML page failed", len(*pages))
	}
}

// TestHTMLFileIsTextWithoutAWebEngine: where no page can be opened, an HTML file is text alone,
// without the switch of its view.
func TestHTMLFileIsTextWithoutAWebEngine(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	d := openHTML(t, h, testHTML)
	if d.html != nil || editorRect(h, d).Width == 0 || controlShown(h, i18n.Shared(h.app.language(), "editor.markdownPreviewView")) {
		t.Fatal("without a web engine the HTML file is not text alone")
	}
}

// TestHTMLPreviewShowsTitleCrashAndLoadFailureRecovery verifies native browser state integration:
// document title in the toolbar, crash recovery with reload, and load failure recovery.
func TestHTMLPreviewShowsTitleCrashAndLoadFailureRecovery(t *testing.T) {
	heldHTMLWaits(t)
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	pages := fakePreviews(h)
	d := openHTML(t, h, testHTML)
	page := (*pages)[0]
	language := h.app.language()

	page.title = "Interactive Board"
	h.app.invalidator.Invalidate()
	h.settle()
	if !h.shows("Interactive Board") {
		t.Fatal("the HTML preview bar does not show the page title")
	}

	page.processFailure = app.WebProcessCrashed
	page.config.OnProcessFailed(app.WebProcessCrashed)
	h.settle()
	if !h.showsWrapped(i18n.Shared(language, "desktop.htmlPreview.crashed")) {
		t.Fatal("crash message was not shown")
	}
	h.click(center(h.hitLabeled(i18n.Shared(language, "desktop.htmlPreview.reload"))))
	h.settle()
	if page.reloads != 1 {
		t.Fatalf("reload button after crash called Reload %d times, want 1", page.reloads)
	}

	page.processFailure = app.WebProcessNoFailure
	page.loadFailure = "host name not found"
	h.app.invalidator.Invalidate()
	h.settle()
	wantLoadErr := i18n.SharedFormat(language, "desktop.htmlPreview.loadFailed", map[string]string{"reason": "host name not found"})
	if !h.showsWrapped(wantLoadErr) {
		t.Fatalf("load failure message %q was not shown", wantLoadErr)
	}
	h.click(center(h.hitLabeled(i18n.Shared(language, "desktop.htmlPreview.reload"))))
	h.settle()
	if page.reloads != 2 {
		t.Fatalf("reload button after load failure called Reload %d times, want 2", page.reloads)
	}
	if d.html.entry == nil || d.html.entry.view != page {
		t.Fatal("reload replaced the page entry unexpectedly")
	}
}

// TestStandaloneHTMLShowsPageAndIsolatesEachFilesFolder verifies that Single File Mode previews
// HTML files natively with the view switch and isolates each file's site to its own folder.
func TestStandaloneHTMLShowsPageAndIsolatesEachFilesFolder(t *testing.T) {
	heldHTMLWaits(t)
	root := t.TempDir()
	nested := filepath.Join(root, "nested")
	otherDir := t.TempDir()
	for _, dir := range []string{nested, otherDir} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	first := filepath.Join(root, "index.html")
	nestedFile := filepath.Join(nested, "sub.html")
	otherFile := filepath.Join(otherDir, "other.html")
	for name, content := range map[string]string{
		first:                               "<!doctype html><h1>First</h1>",
		filepath.Join(root, "app.js"):       "console.log(1)",
		filepath.Join(root, ".env"):         "SECRET=1",
		nestedFile:                          "<!doctype html><h1>Nested</h1>",
		filepath.Join(nested, "local.css"):  "body{}",
		otherFile:                           "<!doctype html><h1>Other</h1>",
		filepath.Join(otherDir, "other.js"): "console.log(2)",
	} {
		if err := os.WriteFile(name, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	h := standaloneMarkdownReferenceHarness(t, first)
	pages := fakePreviews(h)
	h.app.openStandaloneFile(first)
	h.await("first standalone HTML", func() bool { return h.app.project != nil && h.app.project.docs.byPath(first) != nil })
	h.settle()
	h.settle()

	p := h.app.project
	d := p.docs.byPath(first)
	if len(*pages) != 1 || d.html == nil || d.html.site == nil {
		t.Fatalf("standalone HTML opened %d pages", len(*pages))
	}
	language := h.app.language()
	if editorRect(h, d).Width == 0 || !controlShown(h, i18n.Shared(language, "editor.markdownPreviewView")) {
		t.Fatal("standalone HTML does not show split editor and view switch")
	}
	firstPage := (*pages)[0]
	if firstPage.config.Page != webpreview.SitePage || firstPage.config.Address != "index.html" {
		t.Fatalf("standalone HTML page = %q at %q", firstPage.config.Page, firstPage.config.Address)
	}

	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	for route, kind := range map[string]string{"app.js": "file", ".env": "denied", "../secret.txt": "none"} {
		res, err := firstPage.config.Request(ctx, route)
		if err != nil || res.Kind != kind {
			t.Fatalf("first standalone HTML %q = %+v (%v), want %s", route, res, err, kind)
		}
	}

	// Open a nested HTML file and an unrelated HTML file in the same standalone window: each must
	// resolve its site relative to its own folder without inheriting the first file's directory.
	h.app.openFile(p, nestedFile)
	h.await("nested standalone HTML", func() bool { return p.docs.byPath(nestedFile) != nil })
	h.settle()
	h.settle()
	nestedDoc := p.docs.byPath(nestedFile)
	if nestedDoc.html == nil || nestedDoc.html.site == nil || len(*pages) != 2 {
		t.Fatalf("nested standalone HTML opened %d pages", len(*pages))
	}
	nestedPage := (*pages)[1]
	if res, err := nestedPage.config.Request(ctx, "local.css"); err != nil || res.Kind != "file" {
		t.Fatalf("nested standalone local.css = %+v (%v)", res, err)
	}
	if res, err := nestedPage.config.Request(ctx, "../app.js"); err != nil || res.Kind != "none" {
		t.Fatalf("nested standalone escaped into parent dir: %+v (%v)", res, err)
	}

	h.app.openFile(p, otherFile)
	h.await("other standalone HTML", func() bool { return p.docs.byPath(otherFile) != nil })
	h.settle()
	h.settle()
	otherDoc := p.docs.byPath(otherFile)
	if otherDoc.html == nil || otherDoc.html.site == nil || len(*pages) != 3 {
		t.Fatalf("other standalone HTML opened %d pages", len(*pages))
	}
	otherPage := (*pages)[2]
	if res, err := otherPage.config.Request(ctx, "other.js"); err != nil || res.Kind != "file" {
		t.Fatalf("other standalone other.js = %+v (%v)", res, err)
	}
	if res, err := otherPage.config.Request(ctx, "index.html"); err != nil || res.Kind != "none" {
		t.Fatalf("other standalone saw first folder's index.html: %+v (%v)", res, err)
	}

	if !p.standalone || h.app.plugins != nil || p.search.watch != nil || p.git.isRepository() {
		t.Fatal("standalone HTML preview activated project services")
	}

	h.app.closeProject()
	h.await("standalone session closed", func() bool { return h.app.project == nil })
	h.settle()
	for _, page := range *pages {
		if !page.closed {
			t.Fatal("closing standalone session kept an HTML preview page open")
		}
	}
}
