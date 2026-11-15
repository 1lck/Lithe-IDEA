package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/webpreview"
)

// Where the system has a web engine, a viewer tab shows an image or a PDF in a web view: an image
// in the image page of package webpreview, which keeps the viewer's rules (viewer_image.go) and
// decodes every format the engine knows, and a PDF in the engine's own PDF viewer. A link the
// user follows in a PDF is resolved by Core as a Markdown link is (followDocumentLink). An image
// the page cannot decode shows the viewer's failure, with the actions of its bar.

// The messages the image page takes besides previewTheme.
type (
	imagePageShow struct {
		Type string `json:"type"`
		Src  string `json:"src"`
		SVG  bool   `json:"svg"`
		Keep bool   `json:"keep"`
	}
	imagePageZoom struct {
		Type string  `json:"type"`
		By   float64 `json:"by,omitempty"`
		To   float64 `json:"to,omitempty"`
	}
)

// zoomMessage is the image page's message for what the bar asked.
func zoomMessage(request zoomRequest) imagePageZoom {
	return imagePageZoom{Type: "zoom", By: request.by, To: request.to}
}

// viewerWebPage is the page of t, an image or a PDF, opened the first time it is shown and again
// after it was closed. It is nil while the viewer is native and once the page failed to show the
// image.
func (a *App) viewerWebPage(p *project, t *viewerTab) *previewPage {
	if t.web != nil && !t.web.closed {
		return t.web
	}
	t.web = nil
	if t.webFailed {
		return nil
	}
	config := webpreview.Config{File: t.path}
	switch t.kind {
	case viewerImage:
		config.Page, config.FileLimit = webpreview.ImagePage, viewerImageBytes
	case viewerPDF:
		config.Page, config.FileLimit = webpreview.PDFPage, viewerPDFBytes
	default:
		return nil
	}
	var entry *previewPage
	config.OnMessage = func(message webpreview.Message) {
		if entry != nil && t.web == entry {
			a.viewerWebMessage(t, entry, message)
		}
	}
	config.Follow = func(address string) {
		if entry != nil && t.web == entry {
			a.followDocumentLink(p, t.path, address, nil)
		}
	}
	entry = a.openPreviewPage(config, func() bool {
		return a.project == p && p.viewers.find(t.id) == t && t.web == entry
	})
	t.web = entry
	return entry
}

// viewerWebMessage takes in what t's image page posted.
func (a *App) viewerWebMessage(t *viewerTab, entry *previewPage, message webpreview.Message) {
	switch message.Type {
	case "ready":
		// A page that loads, or loads again, is given the window's look and the image.
		entry.view.Send(previewTheme{Type: "setup", Theme: a.previewTheme(entry)})
		entry.view.Send(imagePageShow{Type: "show", Src: entry.view.FileURL()})
	case "scale":
		t.zoom = imageZoom{shown: message.Scale, fit: message.Fit, width: message.Width, height: message.Height}
	case "failed":
		// The page closes at the end of the next paint, which no longer declares it.
		t.webFailed, t.zoom, t.web = true, imageZoom{}, nil
	}
	a.invalidator.Invalidate()
}
