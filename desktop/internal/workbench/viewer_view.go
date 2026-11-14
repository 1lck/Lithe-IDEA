package workbench

import (
	"fmt"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// viewerView is a viewer tab's body: the bar with the file's name, an image's zoom and the
// file's actions (viewer_image.go), over the image, the PDF, the hex lines or the offer to open
// the file in the system's application.
func (a *App) viewerView(c ui.C, p *project, t *viewerTab) {
	language := a.language()
	ui.Column(c.Key("viewer-" + strconv.Itoa(t.id))).Fill().Background(a.colors.Editor).Children(func() {
		bar := viewerBar{name: t.name, info: t.info(), path: t.path, close: func() { a.closeViewer(p, t.id) }}
		if t.kind == viewerImage {
			bar.zoom, bar.zoomTo = t.imageZoom(), func(request zoomRequest) { a.zoomViewer(t, request) }
		}
		a.viewerToolbar(c, bar)
		switch {
		case t.loading:
			ui.Row(c).Fill().Center().Children(func() { ui.Spinner(c) })
		case t.failure != "":
			ui.Row(c).Fill().Center().Pad(20).Children(func() {
				ui.Paragraph(c, i18n.SharedFormat(language, "desktop.viewer.failed", map[string]string{"reason": t.failure}), 4).Color(a.theme.Danger)
			})
		case t.tooLarge:
			a.panelMessage(c, i18n.Shared(language, "desktop.viewer.tooLarge"), a.colors.Subtle)
		case t.kind == viewerImage:
			a.viewerImageBody(c, p, t)
		case t.kind == viewerPDF:
			if entry := a.viewerWebPage(p, t); entry != nil {
				a.showPreviewPage(c, entry)
			} else {
				a.viewerExternalHint(c, t)
			}
		case t.kind == viewerExternal:
			a.viewerExternalHint(c, t)
		default:
			a.viewerHex(c, t)
		}
	})
}

// info is what the bar says of t: an image's dimensions, once known, and the file's size.
func (t *viewerTab) info() string {
	if t.loading || t.failure != "" {
		return ""
	}
	info := formatByteSize(uint64(max(t.size, 0)))
	if zoom := t.imageZoom(); zoom != nil && zoom.known() {
		info = strconv.Itoa(zoom.width) + " × " + strconv.Itoa(zoom.height) + " · " + info
	}
	return info
}

// imageZoom is the zoom of t's image, from its page or its canvas; nil while it is not shown.
func (t *viewerTab) imageZoom() *imageZoom {
	if t.kind != viewerImage || t.loading || t.failure != "" || t.tooLarge || t.webFailed {
		return nil
	}
	if t.web != nil {
		return &t.zoom
	}
	if n := t.canvas; n != nil && n.state == canvasReady {
		zoom := n.zoom()
		return &zoom
	}
	return nil
}

// zoomViewer applies what the bar asked to t's image, on its page or its canvas.
func (a *App) zoomViewer(t *viewerTab, request zoomRequest) {
	if t.web != nil {
		t.web.view.Send(zoomMessage(request))
		return
	}
	if t.canvas != nil && t.canvas.state == canvasReady {
		t.canvas.zoomTo(request)
	}
}

// viewerImageBody declares t's image: on its web page, or, where none can show it, drawn by Viva.
func (a *App) viewerImageBody(c ui.C, p *project, t *viewerTab) {
	if entry := a.viewerWebPage(p, t); entry != nil {
		a.showPreviewPage(c, entry)
		return
	}
	if t.webFailed {
		a.imageFailure(c, t.path)
		return
	}
	n := a.viewerCanvas(p, t)
	switch n.state {
	case canvasReady:
		a.imageCanvasView(c, t.name, n)
	case canvasFailed:
		a.imageFailure(c, t.path)
	default:
		ui.Row(c).Fill().Center().Children(func() { ui.Spinner(c) })
	}
}

// viewerExternalHint offers to open t in the system's application, with the bar's button.
func (a *App) viewerExternalHint(c ui.C, t *viewerTab) {
	ui.Column(c).Fill().Center().Gap(10).PadX(20).Children(func() {
		ui.Text(c, t.name).FontSize(14).Color(a.colors.Text)
		ui.Text(c, i18n.Shared(a.language(), "desktop.viewer.externalHint")).FontSize(12).Color(a.colors.Subtle)
	})
}

// viewerHex lists the hex lines, and says when the file goes on past them.
func (a *App) viewerHex(c ui.C, t *viewerTab) {
	language := a.language()
	ui.Scroll(c.Part("hex")).Fill().PadX(12).PadY(8).Children(func() {
		ui.Text(c, i18n.Shared(language, "desktop.viewer.binaryHint")).FontSize(12).Color(a.colors.Subtle)
		for i, line := range t.hex {
			ui.Text(c.KeyInt(i), line).Mono().FontSize(12).Color(a.colors.Text)
		}
		if t.truncated {
			ui.Text(c, i18n.Shared(language, "desktop.viewer.truncated")).FontSize(12).Color(a.colors.Subtle)
		}
	})
}

// formatByteSize is a size in bytes as the viewer bar shows it: bytes below a kilobyte, then
// one decimal of the largest unit that keeps the number at least one.
func formatByteSize(bytes uint64) string {
	if bytes < 1024 {
		return fmt.Sprintf("%d B", bytes)
	}
	value := float64(bytes)
	units := [...]string{"B", "KB", "MB", "GB", "TB"}
	unit := 0
	for value >= 1024 && unit < len(units)-1 {
		value /= 1024
		unit++
	}
	return fmt.Sprintf("%.1f %s", value, units[unit])
}
