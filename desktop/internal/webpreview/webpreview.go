// Package webpreview opens the pages the editor area shows in a web view: the rendered page of a
// Markdown file, the viewer of an image or an SVG file, a PDF document, and an HTML file with its
// site (site.go).
//
// The pages and the scripts they use are embedded in the application and served through the
// "lithe-preview" scheme, one scheme server per page. What a page is served of the user's files
// is decided by the host, never by the page: the images of a Markdown document are the ones Core
// resolves for it (markdown.resolveReference), and a viewer is served the one file or buffer it
// shows. Navigation leaves the page's origin only when the user follows a link, and then the host
// opens the link elsewhere; a page opens no window and downloads nothing.
//
// Nothing is written: the pages are read from the binary, the user's files are read and answered
// with Cache-Control: no-store, and these pages are not ephemeral, since an ephemeral WebView2
// page leaves a profile folder behind for each page. The site page is the exception: it runs the
// user's own scripts, so what they keep must stay apart from every other page.
//
// Note: the decision is recorded in
// .agents/notes/implemented/architecture/2026-11-14-web-view-previews.md
package webpreview

import (
	"context"
	"embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io/fs"
	"net/url"
	"path"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

const (
	// SchemeName is the scheme the pages are served from.
	SchemeName = "lithe-preview"
	// Origin is where the pages are; Windows serves it as https://lithe-preview.viva-app.invalid/preview/,
	// and reports navigations in this form.
	Origin = SchemeName + "://preview/"
)

// The pages a web view loads.
const (
	// MarkdownPage is the rendered page of a Markdown file.
	MarkdownPage = "markdown.html"
	// ImagePage is the viewer of an image file or an SVG buffer.
	ImagePage = "image.html"
	// PDFPage is a PDF file, shown by the web engine's own viewer.
	PDFPage = "file"
)

// webView is the engine's page; *app.WebView is one, and tests stand in for it.
type webView interface {
	ID() gfx.NativeViewID
	Load(url string)
	Reload()
	Back()
	Forward()
	CanGoBack() bool
	CanGoForward() bool
	IsLoading() bool
	Title() string
	IsCrashed() bool
	ProcessFailure() app.WebProcessFailure
	Eval(script string)
	PostMessage(text string)
	Focus()
	Close()
}

const (
	// fileRoute serves the viewer's file; a name may follow it, for the PDF viewer's title.
	fileRoute = "file"
	// documentRoute serves the buffer an SVG viewer shows.
	documentRoute = "document"
	// resourceRoute serves an image of a Markdown page by its src, base64url-encoded.
	resourceRoute = "res/"
	// maxReference bounds the src a resource request may carry.
	maxReference = 8 << 10
	// resourceBytes bounds one image of a Markdown page.
	resourceBytes = 16 << 20
	// resolveTimeout bounds Core's answer for one image.
	resolveTimeout = 5 * time.Second
)

//go:embed assets
var assets embed.FS

// Heading is one heading of a rendered Markdown page.
type Heading struct {
	Level int    `json:"level"`
	Text  string `json:"text"`
	// Line is the heading's source line, from 1.
	Line int `json:"line"`
}

// Message is what a page posts. Type says which fields it carries:
//
//   - "ready": the page's script runs and takes messages; it is posted again after a reload.
//   - "rendered" (Markdown): Revision was laid out, with its Headings.
//   - "scrolled" (Markdown): the user scrolled the page to source Line, fractional.
//   - "link" (Markdown): the user followed Href, which is not an anchor of the page.
//   - "outline" (Markdown): the user opened or closed the page's outline in the page, as Open
//     says.
//   - "scale" (image): the image is shown at Scale, Fit is its fitted scale and Width and Height
//     its own size.
//   - "failed" (image): the image could not be loaded.
type Message struct {
	Type     string    `json:"type"`
	Revision int       `json:"revision"`
	Headings []Heading `json:"headings"`
	Line     float64   `json:"line"`
	Href     string    `json:"href"`
	Open     bool      `json:"open"`
	Scale    float64   `json:"scale"`
	Fit      float64   `json:"fit"`
	Width    int       `json:"width"`
	Height   int       `json:"height"`
}

// Config is one page to open.
type Config struct {
	// Host opens the web view.
	Host *app.WebHost
	// Page is MarkdownPage, ImagePage, PDFPage or SitePage.
	Page string
	// File is the file a viewer shows: an image for ImagePage without a document, a PDF for
	// PDFPage. FileLimit bounds what is read of it.
	File      string
	FileLimit int64
	// Resolve answers what an image src of a Markdown page points at; nil serves no image.
	Resolve func(ctx context.Context, reference string) (core.MarkdownReference, error)
	// Remote fetches the http and https images Resolve answers with; nil fetches none.
	Remote *Remote
	// OnMessage receives what the page posts, on the window's thread.
	OnMessage func(Message)
	// Follow receives the address of a navigation the user started away from the page, such as
	// a link in a PDF, on the window's thread. The page stays where it is.
	Follow func(address string)
	// Address is the HTML file's address from the root of its site, as Core gives it
	// (core.HTMLPreviewSite), for SitePage.
	Address string
	// Request answers what a request of the site page serves, from its decoded path from the
	// root (core.Client.ResolveHTMLPreviewRequest); nil serves the file alone.
	Request func(ctx context.Context, path string) (core.HTMLPreviewResource, error)
	// OnLoad reports navigation steps of the page when set.
	OnLoad func(app.WebLoad)
	// OnProcessFailed reports when the page's web process terminates or crashes.
	OnProcessFailed func(app.WebProcessFailure)
	// Log reports a failure of the page's resources to the client's log. Only tests leave it
	// nil, and then a failure is not recorded: the page never writes logs of its own.
	Log func(stage string, err error)
}

// Page is one open page.
type Page struct {
	view   webView
	config Config
	ctx    context.Context
	cancel context.CancelFunc
	ready  bool
	// document and documentMIME are what documentRoute serves, or the site page's file.
	document     []byte
	documentMIME string
	// site is what the site page follows of its main frame; now, when set, is its clock.
	site siteState
	now  func() time.Time
}

// Open opens a page. It fails with app.ErrUnsupported where the platform has no web engine.
func Open(config Config) (*Page, error) {
	if config.Host == nil {
		return nil, errors.New("webpreview: no web host")
	}
	switch config.Page {
	case MarkdownPage, ImagePage, PDFPage, SitePage:
	default:
		return nil, errors.New("webpreview: unknown page " + config.Page)
	}
	ctx, cancel := context.WithCancel(context.Background())
	p := &Page{config: config, ctx: ctx, cancel: cancel}
	web := app.WebViewConfig{
		URL:                 p.address(),
		Scheme:              &app.WebScheme{Name: SchemeName, ServeAsync: p.serve},
		OnMessage:           p.receive,
		OnLoad:              config.OnLoad,
		OnProcessFailed:     p.processFailed,
		Navigate:            p.navigate,
		BridgeMainFrameOnly: true,
	}
	if config.Page == SitePage {
		web.Scheme = &app.WebScheme{Name: SiteScheme, ServeAsync: p.serveSite}
		web.Navigate = p.navigateSite
		web.NewWindow = p.newWindow
		web.OnLoad = p.siteLoaded
		web.Ephemeral = true
	}
	view, err := config.Host.Open(web)
	if err != nil {
		cancel()
		return nil, err
	}
	p.view = view
	return p, nil
}

// ID names the page for ui.Element.NativeView.
func (p *Page) ID() gfx.NativeViewID { return p.view.ID() }

// Ready reports whether the page's script takes messages. The site page's scripts are the
// user's, so it never is.
func (p *Page) Ready() bool { return p.ready }

// Send posts a message to the page as JSON. It is dropped until the page is ready: the host sends
// what the page shows when the page says it is ready.
func (p *Page) Send(message any) {
	if !p.ready {
		return
	}
	text, err := json.Marshal(message)
	if err != nil {
		p.log("message", err)
		return
	}
	p.view.PostMessage(string(text))
}

// SetDocument replaces the buffer an SVG viewer is served, which the page loads when told to, or
// the site page's file, which the page shows at once when it shows the file.
func (p *Page) SetDocument(data []byte, mime string) {
	p.document, p.documentMIME = data, mime
	if p.config.Page == SitePage {
		p.site.version++
		p.refresh()
	}
}

// Reload loads the page again; the site page keeps where it is scrolled unless it crashed,
// failed to load, or is off the site.
func (p *Page) Reload() {
	if p.view == nil {
		return
	}
	if p.config.Page == SitePage {
		if p.view.IsCrashed() || p.site.loadError != "" || !p.site.onSite {
			p.site.reloading, p.site.scroll, p.site.loadError = false, nil, ""
			p.view.Reload()
			return
		}
		p.reloadSite()
		return
	}
	p.view.Reload()
}

// Back and Forward move through the page's history.
func (p *Page) Back() {
	if p.view != nil {
		p.view.Back()
	}
}

func (p *Page) Forward() {
	if p.view != nil {
		p.view.Forward()
	}
}

// CanGoBack and CanGoForward report whether the page's history has an entry each way.
func (p *Page) CanGoBack() bool    { return p.view != nil && p.view.CanGoBack() }
func (p *Page) CanGoForward() bool { return p.view != nil && p.view.CanGoForward() }

// IsLoading reports whether the page is currently loading a navigation.
func (p *Page) IsLoading() bool { return p.view != nil && p.view.IsLoading() }

// Title returns the page's current document title.
func (p *Page) Title() string {
	if p.view == nil {
		return ""
	}
	return p.view.Title()
}

// Crashed reports whether the page's web process is gone.
func (p *Page) Crashed() bool { return p.view != nil && p.view.IsCrashed() }

// ProcessFailure names why the page's web process is gone, or WebProcessNoFailure.
func (p *Page) ProcessFailure() app.WebProcessFailure {
	if p.view == nil {
		return app.WebProcessNoFailure
	}
	return p.view.ProcessFailure()
}

// LoadFailure returns the last main-frame navigation error of a site page, or empty.
func (p *Page) LoadFailure() string { return p.site.loadError }

// CurrentPath returns the decoded site path currently shown by a site page, or empty.
func (p *Page) CurrentPath() string {
	if p.config.Page != SitePage || !p.site.onSite {
		return ""
	}
	return p.site.shown
}

// Focus gives the page the keyboard.
func (p *Page) Focus() {
	if p.view != nil {
		p.view.Focus()
	}
}

func (p *Page) processFailed(failure app.WebProcessFailure) {
	p.log("process", errors.New(failure.String()))
	p.site.loading = false
	p.site.reloading, p.site.scroll = false, nil
	if p.config.OnProcessFailed != nil {
		p.config.OnProcessFailed(failure)
	}
}

// FileURL is the address of the viewer's file, ending in its name.
func (p *Page) FileURL() string {
	return Origin + fileRoute + "/" + url.PathEscape(filepath.Base(p.config.File))
}

// address is where the page is loaded from: the page itself, or the file for the PDF page and
// the site page.
func (p *Page) address() string {
	switch p.config.Page {
	case PDFPage:
		return p.FileURL()
	case SitePage:
		return SiteOrigin + p.config.Address
	}
	return Origin + p.config.Page
}

// Close closes the page and stops the reads it started. Closing twice is harmless.
func (p *Page) Close() {
	if p.view == nil {
		return
	}
	p.cancel()
	p.view.Close()
	p.view = nil
	p.ready = false
}

// receive decodes what the page posted and hands it to the host.
func (p *Page) receive(text string) {
	if p.config.Page == SitePage {
		p.siteMessage(text)
		return
	}
	var message Message
	if err := json.Unmarshal([]byte(text), &message); err != nil || message.Type == "" {
		return
	}
	if message.Type == "ready" {
		p.ready = true
	}
	if p.config.OnMessage != nil {
		p.config.OnMessage(message)
	}
}

// navigate keeps the page where it is: the main frame stays at the page's own address, a jump to
// one of its anchors aside. A frame inside the PDF page is the engine's viewer; the other pages
// allow no frame (their policy says frame-src 'none').
func (p *Page) navigate(navigation app.WebNavigation) bool {
	if navigation.URL == "about:blank" {
		return true
	}
	if strings.HasPrefix(navigation.URL, Origin) && navigation.MainFrame {
		// A link the page's script did not take, such as a relative one, would load a missing
		// page in place of this one.
		address, _, _ := strings.Cut(navigation.URL, "#")
		return address == p.address()
	}
	if !navigation.MainFrame {
		return p.config.Page == PDFPage
	}
	if navigation.UserGesture && p.config.Follow != nil {
		p.config.Follow(navigation.URL)
	}
	return false
}

// serve answers one request of the page. The embedded files are answered at once; the user's
// files are read on their own goroutine.
func (p *Page) serve(request app.WebRequest, respond func(app.WebResponse)) {
	route := strings.TrimPrefix(request.Path, "/")
	switch {
	case route == fileRoute || strings.HasPrefix(route, fileRoute+"/"):
		if p.config.File == "" || p.config.Page == MarkdownPage {
			respond(notFound())
			return
		}
		file, limit := p.config.File, p.config.FileLimit
		go func() {
			data, err := readFile(file, limit, true)
			if err != nil {
				p.log("file", err)
				respond(failed(err))
				return
			}
			respond(private(mimeOf(file), data))
		}()
	case route == documentRoute:
		if p.document == nil {
			respond(notFound())
			return
		}
		respond(private(p.documentMIME, p.document))
	case strings.HasPrefix(route, resourceRoute):
		reference, ok := decodeReference(strings.TrimPrefix(route, resourceRoute))
		if !ok || p.config.Resolve == nil || p.config.Page != MarkdownPage {
			respond(notFound())
			return
		}
		go p.serveResource(reference, respond)
	default:
		respond(asset(route))
	}
}

// serveResource answers an image of a Markdown page: the file or the address Core resolved its
// src to, if Core allows it.
func (p *Page) serveResource(reference string, respond func(app.WebResponse)) {
	ctx, cancel := context.WithTimeout(p.ctx, resolveTimeout)
	resolved, err := p.config.Resolve(ctx, reference)
	cancel()
	if err != nil {
		if p.ctx.Err() == nil {
			p.log("resolve", err)
		}
		respond(notFound())
		return
	}
	data, mime, err := LoadResource(p.ctx, resolved, p.config.Remote)
	if err != nil {
		respond(failed(err))
		return
	}
	respond(private(mime, data))
}

// ErrNotLoaded is a reference Core resolved to nothing a page loads.
var ErrNotLoaded = errors.New("webpreview: the reference is not loaded")

// LoadResource reads what Core resolved an image of a Markdown document to, for the page and the
// native preview alike: the file, read without following a link put in its place since Core
// checked it, or the address, through remote. It answers the bytes and their type.
func LoadResource(ctx context.Context, resolved core.MarkdownReference, remote *Remote) ([]byte, string, error) {
	switch resolved.Kind {
	case "file":
		data, err := readFile(resolved.Path, resourceBytes, false)
		return data, resolved.MIME, err
	case "remote":
		if remote == nil {
			return nil, "", ErrNotLoaded
		}
		return remote.Get(ctx, resolved.URL)
	}
	return nil, "", ErrNotLoaded
}

func (p *Page) log(stage string, err error) {
	if p.config.Log != nil {
		p.config.Log(stage, err)
	}
}

// decodeReference is the src a resource route carries.
func decodeReference(encoded string) (string, bool) {
	if encoded == "" || len(encoded) > maxReference*4/3+4 {
		return "", false
	}
	raw, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || len(raw) == 0 || len(raw) > maxReference || !utf8.Valid(raw) {
		return "", false
	}
	return string(raw), true
}

// asset answers an embedded file of the pages.
func asset(route string) app.WebResponse {
	clean := path.Clean("/" + route)[1:]
	if clean == "" || clean != route {
		return notFound()
	}
	data, err := fs.ReadFile(assets, "assets/"+clean)
	if err != nil {
		return notFound()
	}
	return app.WebResponse{MIME: mimeOf(clean), Data: data, Headers: map[string]string{
		"Access-Control-Allow-Origin": "",
		"X-Content-Type-Options":      "nosniff",
	}}
}

// private answers one of the user's files: not cached, not readable by another origin, and of the
// type named, never sniffed.
func private(mime string, data []byte) app.WebResponse {
	return app.WebResponse{MIME: mime, Data: data, Headers: map[string]string{
		"Access-Control-Allow-Origin": "",
		"Cache-Control":               "no-store",
		"X-Content-Type-Options":      "nosniff",
	}}
}

func notFound() app.WebResponse { return app.WebResponse{Status: 404, Data: []byte("not found")} }

// failed answers a read that did not succeed: too large, missing, or not a regular file.
func failed(err error) app.WebResponse {
	if errors.Is(err, errTooLarge) {
		return app.WebResponse{Status: 413, Data: []byte("too large")}
	}
	return notFound()
}

// mimeOf is the type a file is served as, by its name.
func mimeOf(name string) string {
	switch strings.ToLower(path.Ext(filepath.ToSlash(name))) {
	case ".html":
		return "text/html; charset=utf-8"
	case ".js":
		return "text/javascript; charset=utf-8"
	case ".css":
		return "text/css; charset=utf-8"
	case ".woff2":
		return "font/woff2"
	case ".svg":
		return "image/svg+xml"
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	case ".bmp":
		return "image/bmp"
	case ".ico":
		return "image/x-icon"
	case ".avif":
		return "image/avif"
	case ".tif", ".tiff":
		return "image/tiff"
	case ".heic":
		return "image/heic"
	case ".heif":
		return "image/heif"
	case ".pdf":
		return "application/pdf"
	}
	return "application/octet-stream"
}
