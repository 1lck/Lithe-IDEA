package webpreview

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/app"
)

// The site page shows an HTML file as the web engine draws it, with what it loads from its site:
// the folder Core names for the file (htmlPreview.site), the workspace when the file lies in one.
// Core decides each request of the page (htmlPreview.resolveRequest): the file itself, served
// from the editor's text so that unsaved edits show, a file of the site, a folder's index.html,
// or a refusal of a hidden file or a key. The page is the user's, not one of ours: its scripts
// run, it is sent none of the host's messages, and of what it posts the host takes only the
// scroll position its own reload script reports.
//
// The site has a scheme of its own, lithe-site, and the page is ephemeral: what it keeps (cookies,
// storage, caches, service workers) stays in memory, apart from the other previews and from the
// next site, and goes when the page closes. A platform without such a store refuses the page.
//
// The main frame stays on the site. A link the user follows elsewhere goes to Follow; a window the
// page opens loads in place of the page when it is on the site, and otherwise goes to Follow at
// most once per popupInterval, since Windows does not say whether the user asked for it. Frames
// may also load web pages and data and blob addresses.
//
// Each text SetDocument gives is shown at once when the main frame shows the file: the page
// loads again and is scrolled back where it was.

const (
	// SiteScheme is the scheme the site page is served from.
	SiteScheme = "lithe-site"
	// SiteOrigin is the root of the site; Windows serves it as
	// https://lithe-site.viva-app.invalid/site/, and reports navigations in this form.
	SiteOrigin = SiteScheme + "://site/"
	// SitePage is an HTML file with its site.
	SitePage = "site"

	// siteFileBytes bounds one file of the site; a larger one is answered 413.
	siteFileBytes = 64 << 20
	// popupInterval is the least time between two windows handed to Follow.
	popupInterval = time.Second
)

// directoryPage sends the browser on to the index.html of the folder it was served for. The
// engine does not say whether the address ended in a slash, so the page adds one when it did not.
var directoryPage = []byte(`<!doctype html><meta charset="utf-8"><script>(function(){var p=location.pathname;if(p.charAt(p.length-1)!=='/')p+='/';location.replace(p+'index.html'+location.search+location.hash)})()</script>`)

// reloadScript loads the page again, first posting where it is scrolled so that the host scrolls
// it back once it has loaded. It turns the engine's own restoring off: it comes late and would
// undo the host's.
const reloadScript = `(function(){try{history.scrollRestoration='manual'}catch(e){}try{window.viva.postMessage(JSON.stringify({type:'position',x:scrollX,y:scrollY}))}catch(e){}location.reload()})()`

// siteState is what the site page follows of its main frame.
type siteState struct {
	// shown is the decoded path, from the root, of the site page the main frame shows, and onSite
	// says the main frame shows one. loading says a page committed and has not finished loading.
	shown   string
	onSite  bool
	loading bool
	// version counts the texts SetDocument gave and served is the one the file was last served.
	version, served int
	// reloading says the host reloaded the page and it has not finished loading again; scroll is
	// where it was scrolled, for the page at scrollPath, once it said so.
	reloading  bool
	scroll     *sitePosition
	scrollPath string
	// loadError holds the failure reason when the last main-frame navigation failed.
	loadError string
	// popup is when a window was last handed to Follow.
	popup time.Time
}

// sitePosition is where the page was scrolled, in CSS pixels.
type sitePosition struct{ x, y float64 }

// sitePath is the decoded path, from the root, that an address of the site names, without its
// query or fragment. ok is false for an address off the site.
func sitePath(address string) (string, bool) {
	rest, ok := strings.CutPrefix(address, SiteOrigin)
	if !ok {
		return "", false
	}
	rest, _, _ = strings.Cut(rest, "#")
	rest, _, _ = strings.Cut(rest, "?")
	decoded, err := url.PathUnescape(rest)
	if err != nil {
		return "", false
	}
	return decoded, true
}

// documentPath is the decoded path of the file from the root.
func (p *Page) documentPath() string {
	decoded, _ := sitePath(SiteOrigin + p.config.Address)
	return decoded
}

// serveSite answers one request of the site page. The file asked for by its own path is served
// at once, from the text SetDocument gave last; every other request is put to Core on its own
// goroutine.
func (p *Page) serveSite(request app.WebRequest, respond func(app.WebResponse)) {
	route := strings.TrimPrefix(request.Path, "/")
	if route == p.documentPath() && p.document != nil {
		p.site.served = p.site.version
		respond(private(p.documentMIME, p.document))
		return
	}
	resolve := p.config.Request
	if resolve == nil {
		respond(notFound())
		return
	}
	document, mime := p.document, p.documentMIME
	go func() {
		ctx, cancel := context.WithTimeout(p.ctx, resolveTimeout)
		resource, err := resolve(ctx, route)
		cancel()
		if err != nil {
			if p.ctx.Err() == nil {
				p.log("request", err)
			}
			respond(notFound())
			return
		}
		respond(p.siteResponse(resource, document, mime))
	}()
}

// siteResponse is the answer to a request Core resolved to resource; document is the file's text
// when the request was made.
func (p *Page) siteResponse(resource core.HTMLPreviewResource, document []byte, mime string) app.WebResponse {
	switch resource.Kind {
	case "document":
		if document == nil {
			return notFound()
		}
		return private(mime, document)
	case "file":
		data, err := readFile(resource.Path, siteFileBytes, false)
		if err != nil {
			return failed(err)
		}
		return private(resource.MIME, data)
	case "directory":
		return private("text/html; charset=utf-8", directoryPage)
	case "denied":
		return app.WebResponse{Status: 403, Data: []byte("forbidden")}
	}
	return notFound()
}

// navigateSite keeps the main frame on the site: a navigation elsewhere the user started goes to
// Follow and the frame stays where it is. A frame may also load a web page, a data or a blob
// address.
func (p *Page) navigateSite(navigation app.WebNavigation) bool {
	if navigation.URL == "about:blank" || navigation.URL == "about:srcdoc" {
		return true
	}
	if _, ok := sitePath(navigation.URL); ok {
		return true
	}
	if !navigation.MainFrame {
		scheme, _, _ := strings.Cut(navigation.URL, ":")
		switch strings.ToLower(scheme) {
		case "http", "https", "data", "blob":
			return true
		}
		return false
	}
	if navigation.UserGesture && p.config.Follow != nil {
		p.config.Follow(navigation.URL)
	}
	return false
}

// newWindow loads a window the page opens on the site in place of the page, and hands one
// elsewhere to Follow, at most once per popupInterval. The engine opens no window.
func (p *Page) newWindow(address string) bool {
	if _, ok := sitePath(address); ok {
		if p.view != nil {
			p.view.Load(address)
		}
		return false
	}
	if address == "" || strings.HasPrefix(address, "about:") || p.config.Follow == nil {
		return false
	}
	now := p.clock()
	if !p.site.popup.IsZero() && now.Sub(p.site.popup) < popupInterval {
		return false
	}
	p.site.popup = now
	p.config.Follow(address)
	return false
}

// siteLoaded follows the main frame: which page it shows and whether it is loading. A page the
// host reloaded is scrolled back once it has loaded, and a page of the file that was served an
// older text than the last one loads again.
func (p *Page) siteLoaded(load app.WebLoad) {
	s := &p.site
	switch load.Phase {
	case app.WebLoadStarted:
		s.loading = true
		s.loadError = ""
	case app.WebLoadCommitted:
		s.shown, s.onSite = sitePath(load.URL)
		s.loading = true
		s.loadError = ""
	case app.WebLoadFinished:
		s.shown, s.onSite = sitePath(load.URL)
		s.loading = false
		if load.Code != app.WebLoadNoError && load.Code != app.WebLoadCancelled {
			reason := load.Description
			if reason == "" {
				reason = load.Code.String()
			}
			s.loadError = reason
			s.reloading, s.scroll = false, nil
			p.log("load", errors.New(reason))
		} else if load.Code == app.WebLoadNoError {
			s.loadError = ""
			if s.reloading && s.scroll != nil && s.onSite && s.scrollPath == s.shown && p.view != nil {
				p.view.Eval("scrollTo(" + strconv.FormatFloat(s.scroll.x, 'f', -1, 64) + "," + strconv.FormatFloat(s.scroll.y, 'f', -1, 64) + ")")
			}
			s.reloading, s.scroll = false, nil
			p.refresh()
		} else {
			s.reloading, s.scroll = false, nil
		}
	}
	if p.config.OnLoad != nil {
		p.config.OnLoad(load)
	}
}

// siteMessage takes in what the site page posted: only the position the reload script reports,
// while the host reloads the page.
func (p *Page) siteMessage(text string) {
	var position struct {
		Type string  `json:"type"`
		X    float64 `json:"x"`
		Y    float64 `json:"y"`
	}
	if !p.site.reloading || json.Unmarshal([]byte(text), &position) != nil || position.Type != "position" {
		return
	}
	p.site.scroll = &sitePosition{x: position.X, y: position.Y}
	p.site.scrollPath = p.site.shown
}

// refresh loads the file's page again when the main frame shows it, has finished loading, and
// was served an older text than the last one.
func (p *Page) refresh() {
	s := &p.site
	if p.view == nil || s.loading || s.reloading || !s.onSite || s.shown != p.documentPath() || s.served == s.version {
		return
	}
	p.reloadSite()
}

// reloadSite loads the main frame's page again, keeping where it is scrolled.
func (p *Page) reloadSite() {
	p.site.reloading, p.site.scroll = true, nil
	p.view.Eval(reloadScript)
}

// clock is the time a window is handed to Follow at.
func (p *Page) clock() time.Time {
	if p.now != nil {
		return p.now()
	}
	return time.Now()
}
