package webpreview

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// fakeView stands in for the engine's page and keeps what the host asked of it.
type fakeView struct {
	loads, evals             []string
	reloads, backs, forwards int
	canGoBack, canGoForward  bool
	loading                  bool
	title                    string
	failure                  app.WebProcessFailure
	focused                  int
	closed                   bool
}

func (f *fakeView) ID() gfx.NativeViewID                  { return 1 }
func (f *fakeView) Load(url string)                       { f.loads = append(f.loads, url) }
func (f *fakeView) Reload()                               { f.reloads++ }
func (f *fakeView) Back()                                 { f.backs++ }
func (f *fakeView) Forward()                              { f.forwards++ }
func (f *fakeView) CanGoBack() bool                       { return f.canGoBack }
func (f *fakeView) CanGoForward() bool                    { return f.canGoForward }
func (f *fakeView) IsLoading() bool                       { return f.loading }
func (f *fakeView) Title() string                         { return f.title }
func (f *fakeView) IsCrashed() bool                       { return f.failure != app.WebProcessNoFailure }
func (f *fakeView) ProcessFailure() app.WebProcessFailure { return f.failure }
func (f *fakeView) Eval(script string)                    { f.evals = append(f.evals, script) }
func (f *fakeView) PostMessage(string)                    {}
func (f *fakeView) Focus()                                { f.focused++ }
func (f *fakeView) Close()                                { f.closed = true }
func (f *fakeView) count(script string) int               { return countOf(f.evals, script) }

func countOf(list []string, item string) int {
	n := 0
	for _, entry := range list {
		if entry == item {
			n++
		}
	}
	return n
}

// sitePage is a site page of the file at site/page one.html, on a fake engine page.
func sitePage(t *testing.T, request func(ctx context.Context, path string) (core.HTMLPreviewResource, error)) (*Page, *fakeView) {
	t.Helper()
	p := testPage(t, Config{Page: SitePage, Address: "site/page%20one.html", Request: request})
	view := &fakeView{}
	p.view = view
	return p, view
}

// siteRequest serves one path of the site page and waits for the answer.
func siteRequest(t *testing.T, p *Page, route string) app.WebResponse {
	t.Helper()
	answers := make(chan app.WebResponse, 1)
	p.serveSite(app.WebRequest{Path: "/" + route}, func(response app.WebResponse) { answers <- response })
	select {
	case response := <-answers:
		return response
	case <-time.After(waitLimit):
		t.Fatalf("no answer for %q within %s", route, waitLimit)
		return app.WebResponse{}
	}
}

const documentAddress = SiteOrigin + "site/page%20one.html"

// TestSiteServesWhatCoreResolvesAndTheFileFromTheEditor: the file asked for by its own path is
// the editor's last text, without asking Core; every other request is served as Core resolves
// it, with the type Core names, never sniffed or cached.
func TestSiteServesWhatCoreResolvesAndTheFileFromTheEditor(t *testing.T) {
	style := filepath.Join(t.TempDir(), "style.css")
	if err := os.WriteFile(style, []byte("body{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	var asked []string
	p, _ := sitePage(t, func(_ context.Context, path string) (core.HTMLPreviewResource, error) {
		asked = append(asked, path)
		switch path {
		case "site/style.css":
			return core.HTMLPreviewResource{Kind: "file", Path: style, MIME: "text/css; charset=utf-8"}, nil
		case "site/./page one.html":
			return core.HTMLPreviewResource{Kind: "document"}, nil
		case "site/docs/":
			return core.HTMLPreviewResource{Kind: "directory"}, nil
		case ".env":
			return core.HTMLPreviewResource{Kind: "denied"}, nil
		case "site/broken":
			return core.HTMLPreviewResource{}, errors.New("core failed")
		}
		return core.HTMLPreviewResource{Kind: "none"}, nil
	})
	if response := siteRequest(t, p, "site/page one.html"); status(response) != 404 {
		t.Fatalf("the file was served %d before the editor gave its text", status(response))
	}
	p.SetDocument([]byte("<h1>draft</h1>"), "text/html; charset=utf-8")
	asked = nil

	page := siteRequest(t, p, "site/page one.html")
	if status(page) != 200 || string(page.Data) != "<h1>draft</h1>" || page.MIME != "text/html; charset=utf-8" ||
		page.Headers["Cache-Control"] != "no-store" || page.Headers["X-Content-Type-Options"] != "nosniff" {
		t.Fatalf("the file was served %d %q as %q with %v", status(page), page.Data, page.MIME, page.Headers)
	}
	if len(asked) != 0 {
		t.Fatalf("Core was asked %v for the file's own path", asked)
	}
	if css := siteRequest(t, p, "site/style.css"); status(css) != 200 || string(css.Data) != "body{}" || css.MIME != "text/css; charset=utf-8" {
		t.Fatalf("the style sheet was served %d %q as %q", status(css), css.Data, css.MIME)
	}
	if other := siteRequest(t, p, "site/./page one.html"); string(other.Data) != "<h1>draft</h1>" {
		t.Fatalf("the file under another name was served %q", other.Data)
	}
	if folder := siteRequest(t, p, "site/docs/"); status(folder) != 200 || string(folder.Data) != string(directoryPage) {
		t.Fatalf("a folder was served %d %q", status(folder), folder.Data)
	}
	for route, want := range map[string]int{".env": 403, "site/missing.js": 404, "site/broken": 404} {
		if got := status(siteRequest(t, p, route)); got != want {
			t.Fatalf("%q was served %d, want %d", route, got, want)
		}
	}
}

// TestSiteKeepsTheMainFrameOnTheSite: the main frame and frames load the site, frames also web
// pages; a link the user follows elsewhere goes to Follow, and a script's navigation nowhere.
func TestSiteKeepsTheMainFrameOnTheSite(t *testing.T) {
	var followed []string
	p := testPage(t, Config{Page: SitePage, Address: "index.html", Follow: func(address string) { followed = append(followed, address) }})
	for _, allowed := range []app.WebNavigation{
		{URL: SiteOrigin + "other.html", MainFrame: true},
		{URL: SiteOrigin + "index.html#part", MainFrame: true},
		{URL: "about:blank", MainFrame: true},
		{URL: "https://example.com/embed", MainFrame: false},
		{URL: "data:text/html,hi", MainFrame: false},
		{URL: SiteOrigin + "frame.html", MainFrame: false},
	} {
		if !p.navigateSite(allowed) {
			t.Fatalf("%+v was refused", allowed)
		}
	}
	for _, refused := range []app.WebNavigation{
		{URL: "https://example.com/", MainFrame: true},
		{URL: "https://example.com/", MainFrame: true, UserGesture: true},
		{URL: "file:///etc/passwd", MainFrame: false},
		{URL: Origin + "markdown.html", MainFrame: false},
	} {
		if p.navigateSite(refused) {
			t.Fatalf("%+v was allowed", refused)
		}
	}
	if !slices.Equal(followed, []string{"https://example.com/"}) {
		t.Fatalf("Follow was given %v", followed)
	}
}

// TestSiteWindowsLoadInPlaceOrGoToFollowAtMostOncePerInterval: a window the page opens on the
// site loads in place of the page, and one elsewhere goes to Follow, at most once per
// popupInterval.
func TestSiteWindowsLoadInPlaceOrGoToFollowAtMostOncePerInterval(t *testing.T) {
	var followed []string
	p := testPage(t, Config{Page: SitePage, Address: "index.html", Follow: func(address string) { followed = append(followed, address) }})
	view := &fakeView{}
	p.view = view
	clock := time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)
	p.now = func() time.Time { return clock }

	if p.newWindow(SiteOrigin+"next.html") || !slices.Equal(view.loads, []string{SiteOrigin + "next.html"}) {
		t.Fatalf("a window on the site loaded %v", view.loads)
	}
	if p.newWindow("https://example.com/a") || p.newWindow("https://example.com/b") || p.newWindow("about:blank") {
		t.Fatal("the engine was let open a window")
	}
	clock = clock.Add(popupInterval)
	p.newWindow("https://example.com/c")
	if !slices.Equal(followed, []string{"https://example.com/a", "https://example.com/c"}) {
		t.Fatalf("Follow was given %v", followed)
	}
}

// TestSiteShowsEachTextAndKeepsItsScroll: a text the editor gives reloads the page while it
// shows the file and has loaded, at most one reload at a time, and the page is scrolled back to
// where it reported it was; a page of the site that is not the file is not reloaded, and the
// file shown again after a text it was not served loads again.
func TestSiteShowsEachTextAndKeepsItsScroll(t *testing.T) {
	p, view := sitePage(t, nil)
	p.SetDocument([]byte("v1"), "text/html; charset=utf-8")
	siteRequest(t, p, "site/page one.html")
	p.siteLoaded(app.WebLoad{Phase: app.WebLoadCommitted, URL: documentAddress})
	p.SetDocument([]byte("v2"), "text/html; charset=utf-8")
	if len(view.evals) != 0 {
		t.Fatalf("the page was reloaded before it had loaded: %v", view.evals)
	}
	// v2 came after the page was served v1, so the page loads again once it has loaded.
	p.siteLoaded(app.WebLoad{Phase: app.WebLoadFinished, URL: documentAddress})
	if view.count(reloadScript) != 1 {
		t.Fatalf("the page was not reloaded for the text it was not served: %v", view.evals)
	}
	p.receive(`{"type":"position","x":0,"y":120}`)
	p.SetDocument([]byte("v3"), "text/html; charset=utf-8")
	if view.count(reloadScript) != 1 {
		t.Fatal("the page was reloaded again while it reloads")
	}
	siteRequest(t, p, "site/page one.html")
	p.siteLoaded(app.WebLoad{Phase: app.WebLoadCommitted, URL: documentAddress})
	p.siteLoaded(app.WebLoad{Phase: app.WebLoadFinished, URL: documentAddress})
	if view.count("scrollTo(0,120)") != 1 || view.count(reloadScript) != 1 {
		t.Fatalf("the page was not scrolled back once, or reloaded for the text it was served: %v", view.evals)
	}

	// A position the page posts while the host does not reload it is not taken.
	p.receive(`{"type":"position","x":0,"y":900}`)
	p.siteLoaded(app.WebLoad{Phase: app.WebLoadFinished, URL: documentAddress})
	if view.count("scrollTo(0,900)") != 0 {
		t.Fatal("the page scrolled to a position it posted on its own")
	}

	// Another page of the site is not reloaded for the file's text.
	p.siteLoaded(app.WebLoad{Phase: app.WebLoadCommitted, URL: SiteOrigin + "site/other.html"})
	p.siteLoaded(app.WebLoad{Phase: app.WebLoadFinished, URL: SiteOrigin + "site/other.html"})
	p.SetDocument([]byte("v4"), "text/html; charset=utf-8")
	if view.count(reloadScript) != 1 {
		t.Fatal("another page of the site was reloaded for the file's text")
	}
	// Back on the file, served v3 from the engine's history, the page loads v4.
	p.siteLoaded(app.WebLoad{Phase: app.WebLoadCommitted, URL: documentAddress + "#part"})
	p.siteLoaded(app.WebLoad{Phase: app.WebLoadFinished, URL: documentAddress + "#part"})
	if view.count(reloadScript) != 2 {
		t.Fatalf("the file shown again with an old text was not reloaded: %v", view.evals)
	}

	// The reload button keeps the scroll too; Back and Forward go to the engine.
	siteRequest(t, p, "site/page one.html")
	p.siteLoaded(app.WebLoad{Phase: app.WebLoadFinished, URL: documentAddress})
	p.Reload()
	p.Back()
	p.Forward()
	if view.count(reloadScript) != 3 || view.reloads != 0 || view.backs != 1 || view.forwards != 1 {
		t.Fatalf("the buttons did %v, %d reloads, %d backs, %d forwards", view.evals, view.reloads, view.backs, view.forwards)
	}
}

// TestSitePageTakesNoMessageButItsPosition: the page's scripts are the user's, so what they post
// is neither handed to the host nor makes the page ready to be sent the host's messages.
func TestSitePageTakesNoMessageButItsPosition(t *testing.T) {
	var received []Message
	p := testPage(t, Config{Page: SitePage, Address: "index.html", OnMessage: func(message Message) { received = append(received, message) }})
	p.view = &fakeView{}
	p.receive(`{"type":"ready"}`)
	p.receive(`{"type":"link","href":"https://example.com"}`)
	if p.Ready() || len(received) != 0 {
		t.Fatalf("the page is ready %v after posting, the host got %+v", p.Ready(), received)
	}
}

func TestSitePathDecodesAddressesOfTheSiteOnly(t *testing.T) {
	for address, want := range map[string]string{
		SiteOrigin:                            "",
		SiteOrigin + "a%20b/c.html?x=1#y":     "a b/c.html",
		SiteOrigin + "docs/":                  "docs/",
		SiteOrigin + "%E4%B8%AD%E6%96%87.htm": "中文.htm",
	} {
		if got, ok := sitePath(address); !ok || got != want {
			t.Fatalf("sitePath(%q) = %q, %v; want %q", address, got, ok, want)
		}
	}
	for _, address := range []string{Origin + "file", "https://lithe-site.viva-app.invalid/site/x", SiteOrigin + "%zz"} {
		if _, ok := sitePath(address); ok {
			t.Fatalf("sitePath(%q) is on the site", address)
		}
	}
}

func TestSiteLoadFailureAndCrashReloadDirectly(t *testing.T) {
	var logged []string
	p, view := sitePage(t, nil)
	p.config.Log = func(stage string, err error) {
		logged = append(logged, stage+":"+err.Error())
	}

	p.siteLoaded(app.WebLoad{Phase: app.WebLoadStarted, URL: documentAddress})
	p.siteLoaded(app.WebLoad{Phase: app.WebLoadFinished, URL: documentAddress, Code: app.WebLoadHostNotFound, Description: "host missing"})
	if p.LoadFailure() != "host missing" || len(logged) != 1 {
		t.Fatalf("load failure = %q, logged = %v", p.LoadFailure(), logged)
	}
	// Reloading after a load failure calls view.Reload rather than Eval(reloadScript).
	p.Reload()
	if view.reloads != 1 || view.count(reloadScript) != 0 || p.LoadFailure() != "" {
		t.Fatalf("reload after load failure: reloads=%d evals=%v loadFailure=%q", view.reloads, view.evals, p.LoadFailure())
	}

	// Reloading a crashed page also calls view.Reload directly and invokes OnProcessFailed.
	var processFailures []app.WebProcessFailure
	p.config.OnProcessFailed = func(f app.WebProcessFailure) { processFailures = append(processFailures, f) }
	view.failure = app.WebProcessCrashed
	p.processFailed(app.WebProcessCrashed)
	if !p.Crashed() || p.ProcessFailure() != app.WebProcessCrashed || len(processFailures) != 1 {
		t.Fatalf("process failure state: crashed=%v failure=%v callbacks=%v", p.Crashed(), p.ProcessFailure(), processFailures)
	}
	p.Reload()
	if view.reloads != 2 || view.count(reloadScript) != 0 {
		t.Fatalf("reload after crash: reloads=%d evals=%v", view.reloads, view.evals)
	}

	// Navigation state and Focus delegate to the underlying webView.
	view.canGoBack, view.canGoForward, view.loading, view.title = true, false, true, "Interactive Demo"
	p.siteLoaded(app.WebLoad{Phase: app.WebLoadCommitted, URL: SiteOrigin + "site/sub.html"})
	p.Focus()
	if !p.CanGoBack() || p.CanGoForward() || !p.IsLoading() || p.Title() != "Interactive Demo" || p.CurrentPath() != "site/sub.html" || view.focused != 1 {
		t.Fatalf("delegated state mismatch: back=%v fwd=%v loading=%v title=%q path=%q focused=%d",
			p.CanGoBack(), p.CanGoForward(), p.IsLoading(), p.Title(), p.CurrentPath(), view.focused)
	}
}
