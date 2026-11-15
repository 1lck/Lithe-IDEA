package webpreview

import (
	"context"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/app"
)

// waitLimit bounds every wait for an answer served on another goroutine.
const waitLimit = 5 * time.Second

// testPage is a page without a web view: its scheme server and navigation policy are what the
// tests drive.
func testPage(t *testing.T, config Config) *Page {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	if config.Log == nil {
		config.Log = func(string, error) {}
	}
	return &Page{config: config, ctx: ctx, cancel: cancel}
}

// request serves one path and waits for the answer.
func request(t *testing.T, p *Page, route string) app.WebResponse {
	t.Helper()
	answers := make(chan app.WebResponse, 1)
	p.serve(app.WebRequest{Path: route}, func(response app.WebResponse) { answers <- response })
	select {
	case response := <-answers:
		return response
	case <-time.After(waitLimit):
		t.Fatalf("no answer for %q within %s", route, waitLimit)
		return app.WebResponse{}
	}
}

func status(response app.WebResponse) int {
	if response.Status == 0 {
		return 200
	}
	return response.Status
}

func encoded(src string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(src))
}

func TestServesEmbeddedPagesOnlyByCleanPath(t *testing.T) {
	p := testPage(t, Config{Page: MarkdownPage})
	page := request(t, p, "markdown.html")
	if status(page) != 200 || page.MIME != "text/html; charset=utf-8" || !strings.Contains(string(page.Data), "markdown.js") {
		t.Fatalf("markdown.html = %d %q", status(page), page.MIME)
	}
	if page.Headers["Access-Control-Allow-Origin"] != "" || page.Headers["X-Content-Type-Options"] != "nosniff" {
		t.Fatalf("asset headers = %v", page.Headers)
	}
	if font := request(t, p, "vendor/fonts/KaTeX_Main-Regular.woff2"); status(font) != 200 || font.MIME != "font/woff2" {
		t.Fatalf("font = %d %q", status(font), font.MIME)
	}
	for _, route := range []string{"", "../webpreview.go", "vendor/../markdown.html", "./markdown.html", "vendor/", "missing.js"} {
		if got := status(request(t, p, route)); got != 404 {
			t.Fatalf("%q = %d, want 404", route, got)
		}
	}
}

func TestEveryPageReferencesOnlyEmbeddedFiles(t *testing.T) {
	p := testPage(t, Config{Page: MarkdownPage})
	for _, page := range []string{MarkdownPage, ImagePage} {
		html := string(request(t, p, page).Data)
		for _, part := range strings.Split(html, `"`) {
			if !strings.HasSuffix(part, ".js") && !strings.HasSuffix(part, ".css") {
				continue
			}
			if got := status(request(t, p, part)); got != 200 {
				t.Fatalf("%s references %q, served %d", page, part, got)
			}
		}
	}
	script := string(request(t, p, "markdown.js").Data)
	for _, library := range []string{"vendor/katex.min.js", "vendor/mhchem.min.js", "vendor/highlight.min.js", "vendor/mermaid.min.js", "vendor/d3.min.js", "vendor/markmap-lib.min.js", "vendor/markmap-view.min.js"} {
		if !strings.Contains(script, "'"+library+"'") {
			t.Fatalf("markdown.js does not load %s", library)
		}
		if got := status(request(t, p, library)); got != 200 {
			t.Fatalf("%s served %d", library, got)
		}
	}
}

func TestDecodesOnlyBoundedUTF8References(t *testing.T) {
	if got, ok := decodeReference(encoded("images/图.png")); !ok || got != "images/图.png" {
		t.Fatalf("decode = %q, %v", got, ok)
	}
	long := strings.Repeat("a", maxReference+1)
	for _, value := range []string{"", "%%%", encoded(long), base64.RawURLEncoding.EncodeToString([]byte{0xff, 0xfe})} {
		if _, ok := decodeReference(value); ok {
			t.Fatalf("decodeReference(%.20q) accepted", value)
		}
	}
}

func TestNavigationStaysAtTheOriginAndHandsUserLinksToTheHost(t *testing.T) {
	var followed []string
	markdown := testPage(t, Config{Page: MarkdownPage, Follow: func(address string) { followed = append(followed, address) }})
	if !markdown.navigate(app.WebNavigation{URL: Origin + MarkdownPage, MainFrame: true}) {
		t.Fatal("the page's own address was refused")
	}
	if !markdown.navigate(app.WebNavigation{URL: Origin + MarkdownPage + "#usage", MainFrame: true, UserGesture: true}) {
		t.Fatal("an anchor of the page was refused")
	}
	if markdown.navigate(app.WebNavigation{URL: Origin + "docs/guide.md", MainFrame: true, UserGesture: true}) || len(followed) != 0 {
		t.Fatalf("a relative link replaced the page or was followed: %v", followed)
	}
	if !markdown.navigate(app.WebNavigation{URL: "about:blank", MainFrame: true}) {
		t.Fatal("about:blank was refused")
	}
	if markdown.navigate(app.WebNavigation{URL: "https://example.com/", MainFrame: true}) || len(followed) != 0 {
		t.Fatalf("a scripted navigation left the page or was followed: %v", followed)
	}
	if markdown.navigate(app.WebNavigation{URL: "https://example.com/", MainFrame: true, UserGesture: true}) || len(followed) != 1 {
		t.Fatalf("a clicked link was not handed to the host: %v", followed)
	}
	if markdown.navigate(app.WebNavigation{URL: "https://example.com/frame"}) {
		t.Fatal("the Markdown page allowed a frame")
	}
	pdf := testPage(t, Config{Page: PDFPage, File: "/tmp/a.pdf"})
	if !pdf.navigate(app.WebNavigation{URL: pdf.FileURL(), MainFrame: true}) {
		t.Fatal("the PDF page refused its file")
	}
	if !pdf.navigate(app.WebNavigation{URL: "about:srcdoc"}) {
		t.Fatal("the PDF page refused the engine's viewer frame")
	}
}

func TestMarkdownImagesAreServedOnlyAsCoreResolvesThem(t *testing.T) {
	dir := t.TempDir()
	picture := filepath.Join(dir, "a.png")
	if err := os.WriteFile(picture, []byte("\x89PNG\r\n\x1a\nimage"), 0o600); err != nil {
		t.Fatal(err)
	}
	var asked []string
	p := testPage(t, Config{Page: MarkdownPage, Resolve: func(_ context.Context, reference string) (core.MarkdownReference, error) {
		asked = append(asked, reference)
		switch reference {
		case "a.png":
			return core.MarkdownReference{Kind: "file", Path: picture, MIME: "image/png"}, nil
		case "fail":
			return core.MarkdownReference{}, errors.New("core failed")
		}
		return core.MarkdownReference{Kind: "none"}, nil
	}})

	served := request(t, p, resourceRoute+encoded("a.png"))
	if status(served) != 200 || served.MIME != "image/png" || string(served.Data) != "\x89PNG\r\n\x1a\nimage" {
		t.Fatalf("resolved image = %d %q", status(served), served.MIME)
	}
	if served.Headers["Cache-Control"] != "no-store" || served.Headers["Access-Control-Allow-Origin"] != "" {
		t.Fatalf("user file headers = %v", served.Headers)
	}
	for _, reference := range []string{"../secret.txt", "fail"} {
		if got := status(request(t, p, resourceRoute+encoded(reference))); got != 404 {
			t.Fatalf("%q = %d, want 404", reference, got)
		}
	}
	if got := status(request(t, p, resourceRoute+"%%%")); got != 404 {
		t.Fatalf("an undecodable reference = %d", got)
	}
	if got := status(request(t, p, fileRoute)); got != 404 {
		t.Fatalf("the Markdown page was served a file: %d", got)
	}
	if strings.Join(asked, ",") != "a.png,../secret.txt,fail" {
		t.Fatalf("Core was asked %v", asked)
	}

	viewer := testPage(t, Config{Page: ImagePage, File: picture, Resolve: p.config.Resolve})
	if got := status(request(t, viewer, resourceRoute+encoded("a.png"))); got != 404 {
		t.Fatalf("an image viewer served a Markdown resource: %d", got)
	}
}

func TestViewerServesItsFileAndDocument(t *testing.T) {
	dir := t.TempDir()
	document := filepath.Join(dir, "report.pdf")
	if err := os.WriteFile(document, []byte("%PDF-1.7"), 0o600); err != nil {
		t.Fatal(err)
	}
	pdf := testPage(t, Config{Page: PDFPage, File: document, FileLimit: 64})
	if pdf.FileURL() != Origin+"file/report.pdf" {
		t.Fatalf("FileURL = %q", pdf.FileURL())
	}
	if served := request(t, pdf, "file/report.pdf"); status(served) != 200 || served.MIME != "application/pdf" {
		t.Fatalf("pdf = %d %q", status(served), served.MIME)
	}
	small := testPage(t, Config{Page: PDFPage, File: document, FileLimit: 4})
	if got := status(request(t, small, "file/report.pdf")); got != 413 {
		t.Fatalf("an oversized file = %d, want 413", got)
	}

	svg := testPage(t, Config{Page: ImagePage})
	if got := status(request(t, svg, documentRoute)); got != 404 {
		t.Fatalf("an empty document = %d", got)
	}
	svg.SetDocument([]byte("<svg/>"), "image/svg+xml")
	if served := request(t, svg, documentRoute); status(served) != 200 || served.MIME != "image/svg+xml" || served.Headers["Cache-Control"] != "no-store" {
		t.Fatalf("document = %d %q %v", status(served), served.MIME, served.Headers)
	}
}

func TestReadFileRefusesLinksUnlessFollowedAndBoundsSize(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "target.png")
	if err := os.WriteFile(target, []byte("12345"), 0o600); err != nil {
		t.Fatal(err)
	}
	if data, err := readFile(target, 5, false); err != nil || string(data) != "12345" {
		t.Fatalf("readFile = %q, %v", data, err)
	}
	if _, err := readFile(target, 4, false); !errors.Is(err, errTooLarge) {
		t.Fatalf("over the limit: %v", err)
	}
	if _, err := readFile(dir, 0, true); !errors.Is(err, errNotRegular) {
		t.Fatalf("a directory: %v", err)
	}
	link := filepath.Join(dir, "link.png")
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("symbolic links are unavailable: %v", err)
	}
	if _, err := readFile(link, 0, false); !errors.Is(err, errNotRegular) {
		t.Fatalf("a link read without follow: %v", err)
	}
	if data, err := readFile(link, 0, true); err != nil || string(data) != "12345" {
		t.Fatalf("a link read with follow = %q, %v", data, err)
	}
}

func TestRemoteFetchesOnceKeepsLatestAndRetriesFailuresLater(t *testing.T) {
	now := time.Unix(1_000, 0)
	var fetches atomic.Int32
	gate := make(chan struct{})
	entered := make(chan struct{}, 1)
	remote := &Remote{
		Now: func() time.Time { return now },
		Fetch: func(_ context.Context, address string) ([]byte, error) {
			fetches.Add(1)
			select {
			case entered <- struct{}{}:
			default:
			}
			if address == "https://example.com/slow.png" {
				<-gate
			}
			switch {
			case strings.HasSuffix(address, ".png"):
				return []byte("\x89PNG\r\n\x1a\n" + address), nil
			case strings.HasSuffix(address, ".svg"):
				return []byte(`<?xml version="1.0"?><!-- logo --><svg xmlns="http://www.w3.org/2000/svg"/>`), nil
			case strings.HasSuffix(address, ".html"):
				return []byte("<html></html>"), nil
			}
			return nil, errors.New("offline")
		},
	}
	ctx := context.Background()

	// The first request starts the fetch and the second one, started while it runs, shares it.
	results := make(chan error, 2)
	go func() { _, _, err := remote.Get(ctx, "https://example.com/slow.png"); results <- err }()
	select {
	case <-entered:
	case <-time.After(waitLimit):
		t.Fatal("the fetch did not start")
	}
	go func() { _, _, err := remote.Get(ctx, "https://example.com/slow.png"); results <- err }()
	close(gate)
	for range 2 {
		select {
		case err := <-results:
			if err != nil {
				t.Fatalf("Get: %v", err)
			}
		case <-time.After(waitLimit):
			t.Fatal("a shared fetch did not answer")
		}
	}
	if fetches.Load() != 1 {
		t.Fatalf("fetched %d times, want 1", fetches.Load())
	}

	if _, mime, err := remote.Get(ctx, "https://example.com/logo.svg"); err != nil || mime != "image/svg+xml" {
		t.Fatalf("svg = %q, %v", mime, err)
	}
	if _, _, err := remote.Get(ctx, "https://example.com/page.html"); err == nil {
		t.Fatal("a page that is not an image was served")
	}

	before := fetches.Load()
	if _, _, err := remote.Get(ctx, "https://example.com/down"); err == nil {
		t.Fatal("a failed fetch succeeded")
	}
	if _, _, err := remote.Get(ctx, "https://example.com/down"); err == nil || fetches.Load() != before+1 {
		t.Fatalf("a recent failure was fetched again (%d fetches)", fetches.Load()-before)
	}
	now = now.Add(remoteFailure)
	if _, _, err := remote.Get(ctx, "https://example.com/down"); err == nil || fetches.Load() != before+2 {
		t.Fatalf("an expired failure was not fetched again (%d fetches)", fetches.Load()-before)
	}

	for index := range remoteEntries + 1 {
		if _, _, err := remote.Get(ctx, "https://example.com/"+strings.Repeat("x", index)+".png"); err != nil {
			t.Fatal(err)
		}
	}
	if remote.order.Len() > remoteEntries {
		t.Fatalf("kept %d entries, bound is %d", remote.order.Len(), remoteEntries)
	}
}

func TestIsSVGRecognizesTheRootElementOnly(t *testing.T) {
	for _, data := range []string{
		`<svg xmlns="http://www.w3.org/2000/svg"></svg>`,
		"\xef\xbb\xbf<?xml version=\"1.0\"?>\n<!DOCTYPE svg><svg>",
		"<!-- a -->\n<svg/>",
	} {
		if !isSVG([]byte(data)) {
			t.Fatalf("isSVG(%q) = false", data)
		}
	}
	for _, data := range []string{"<svgx>", "<html><svg></svg></html>", "<!-- unterminated", "<svg"} {
		if isSVG([]byte(data)) {
			t.Fatalf("isSVG(%q) = true", data)
		}
	}
}
