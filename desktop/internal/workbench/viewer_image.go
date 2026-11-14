package workbench

import (
	"image"
	"image/color"
	"math"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The image viewer of an image file's tab and of an SVG file's picture keeps the rules of the
// macOS viewer it replaces: a 34px bar with the file's icon and name and the image's zoom (zoom
// out, the percentage, which resets the zoom to 100%, and zoom in), over the image centered with
// imagePadding around it on a checkerboard of 16px squares that stays in place as the image
// scrolls. The image follows its fitted scale, which never enlarges it, until the user zooms;
// zoom runs from the lesser of 25% and the fitted scale to 400%, by steps of 25% around the
// middle of the view, or around the pointer for Control and the wheel; a drag pans the image.
//
// A web page applies the rules where one shows the image (viewer_web.go, svg_preview.go, and
// the image page of package webpreview), and the canvas below where none can.

const (
	imagePadding  = 24
	imageMaxScale = 4.0
	imageZoomStep = 0.25
	// imageMinFit is the smallest fitted scale, for a view too small for the image.
	imageMinFit = 0.01
	// imageWheelZoom is how far a point of the wheel with Control held zooms: by
	// exp(-delta*imageWheelZoom).
	imageWheelZoom = 0.01
	// checkerSquare is the side of a square of the checkerboard, and checkerTile how many
	// squares a side of the bitmap it is drawn from holds.
	checkerSquare = 16
	checkerTile   = 16
	// checkerBitmapID names the checkerboard's bitmap; its version counts the times it was made.
	checkerBitmapID = 0x4368656b00000000
)

// imageZoom is the zoom of an image as its bar shows it.
type imageZoom struct {
	// shown is the scale the image is drawn at and fit its fitted scale.
	shown, fit float64
	// width and height are the image's own size, 0 until it is known.
	width, height int
}

// known reports whether the image is shown and its zoom can be changed.
func (z imageZoom) known() bool { return z.width > 0 && z.height > 0 }

// zoomRequest is a zoom the bar asks for: by a step, to a scale, or with neither the fitted one.
type zoomRequest struct {
	by, to float64
}

// imageFitScale is the scale that fits a width×height image in a view of viewWidth×viewHeight
// with imagePadding around it, never above its own size.
func imageFitScale(viewWidth, viewHeight float32, width, height int) float64 {
	if width <= 0 || height <= 0 {
		return 1
	}
	horizontal := float64(max(1, viewWidth-2*imagePadding)) / float64(width)
	vertical := float64(max(1, viewHeight-2*imagePadding)) / float64(height)
	return max(imageMinFit, min(horizontal, vertical, 1))
}

// clampImageScale bounds a scale the user chose: from the lesser of a step and the fitted scale,
// so that a large image can still be seen whole, to imageMaxScale.
func clampImageScale(scale, fit float64) float64 {
	return min(imageMaxScale, max(min(imageZoomStep, fit), scale))
}

// zoomPercent is the zoom as the bar writes it: a whole percentage, at least 1.
func zoomPercent(scale float64) string {
	return strconv.Itoa(max(1, int(math.Round(scale*100)))) + "%"
}

// viewerBar is what the bar over an image, an SVG or another file shows.
type viewerBar struct {
	// name is the file's name and info what it is: its size, and an image's dimensions.
	name, info string
	// zoom is the image's, nil for a file without one; zoomTo takes what its buttons ask.
	zoom   *imageZoom
	zoomTo func(zoomRequest)
	// path is the file the actions open in the system's application and reveal, close closes
	// its tab; a bar without path has neither.
	path  string
	close func()
}

// viewerToolbar declares the bar over a viewer and the line under it.
func (a *App) viewerToolbar(c ui.C, bar viewerBar) {
	language := a.language()
	ui.Row(c.Part("viewer-bar")).FillWidth().Height(34).Shrink(0).PadX(12).Gap(8).Items(ui.Center).Background(a.colors.Panel).Children(func() {
		ui.Icon(c, fileicons.ForFile(bar.name, a.colors.Dark)).Size(14, 14).Shrink(0)
		ui.Text(c, bar.name).FontSize(12).Weight(gfx.WeightMedium).Color(a.colors.Text).Shrink(1).MinWidth(0).Ellipsis()
		if bar.info != "" {
			ui.Text(c, bar.info).FontSize(12).Color(a.colors.Subtle).Shrink(2).MinWidth(0).Ellipsis()
		}
		ui.Row(c).Grow(1).MinWidth(0)
		if bar.zoom != nil && bar.zoom.known() {
			a.viewerZoom(c, *bar.zoom, bar.zoomTo)
		}
		if bar.path == "" {
			return
		}
		if ui.Button(c.Part("open"), i18n.Shared(language, "desktop.viewer.openExternally")).Ghost().Small().Shrink(0).Clicked() {
			path := bar.path
			c.After(func() {
				if err := app.OpenPath(path); err != nil {
					a.notifyError(i18n.SharedFormat(language, "desktop.viewer.openFailed", map[string]string{"reason": err.Error()}))
				}
			})
		}
		if a.viewerIconButton(c.Part("reveal"), revealLabel(language), icons.Folder) {
			path := bar.path
			c.After(func() { a.revealPath(path) })
		}
		if a.viewerIconButton(c.Part("close"), i18n.Shared(language, "desktop.viewer.close"), icons.X) && bar.close != nil {
			c.After(bar.close)
		}
	})
	ui.Row(c).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
}

// viewerZoom declares the zoom buttons of the bar: zoom out, the percentage, which resets the zoom
// to 100%, and zoom in.
func (a *App) viewerZoom(c ui.C, zoom imageZoom, zoomTo func(zoomRequest)) {
	language := a.language()
	if a.viewerIconButton(c.Part("zoom-out"), i18n.Shared(language, "desktop.viewer.zoomOut"), icons.ZoomOut) {
		zoomTo(zoomRequest{by: -imageZoomStep})
	}
	k := c.Part("zoom")
	percent := zoomPercent(zoom.shown)
	button := ui.Row(k).Size(44, 28).Shrink(0).Center().Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(k), i18n.Shared(language, "desktop.viewer.zoom"), gfx.HitOptions{
			Role: gfx.RoleButton, Value: percent, Hint: i18n.Shared(language, "desktop.viewer.resetZoomHint"), Cursor: gfx.PointerCursorHand,
		}).
		Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active)).
		Tooltip(i18n.Shared(language, "desktop.viewer.resetZoom"))
	button.Children(func() {
		ui.Text(k, percent).FontSize(11).Weight(gfx.WeightMedium).Mono().Color(a.colors.Text)
	})
	if button.Clicked() {
		zoomTo(zoomRequest{to: 1})
	}
	if a.viewerIconButton(c.Part("zoom-in"), i18n.Shared(language, "desktop.viewer.zoomIn"), icons.ZoomIn) {
		zoomTo(zoomRequest{by: imageZoomStep})
	}
}

// viewerIconButton declares one icon button of the bar and reports whether it was clicked.
func (a *App) viewerIconButton(c ui.C, label string, icon gfx.Icon) bool {
	return ui.Button(c, label).Icon(icon).IconOnly().Ghost().Size(shellHideSize, shellHideSize).Shrink(0).Tooltip(label).Clicked()
}

// imageFailure declares what stands for an image that could not be shown: a broken picture,
// the message, and the file's path.
func (a *App) imageFailure(c ui.C, path string) {
	ui.Column(c.Part("image-failed")).Fill().Center().Gap(10).PadX(20).Children(func() {
		ui.Icon(c, icons.ImageOff).Size(28, 28).Color(a.colors.Subtle)
		ui.Text(c, i18n.Shared(a.language(), "desktop.viewer.imageFailed")).FontSize(13).Color(a.colors.Text)
		ui.Paragraph(c, path, 2).FontSize(11).TextCenter().Color(a.colors.Subtle)
	})
}

// canvasState is how far the decoding of a native image went.
type canvasState int

const (
	canvasIdle canvasState = iota
	canvasDecoding
	canvasReady
	canvasFailed
)

// imageCanvas is an image Viva draws, where no web page shows it: the decoded bitmap at the zoom
// the user chose, scrolled and panned.
type imageCanvas struct {
	state  canvasState
	bitmap gfx.Bitmap
	// scale is the scale the user chose, 0 while the image follows its fitted scale.
	scale float64
	// x and y are how far the image is scrolled right and down; view is where the canvas was
	// painted last.
	x, y float32
	view gfx.Rect
	// dragging says a press pans the image: from is where it went down, and fromX and fromY
	// the scroll then.
	dragging     bool
	from         [2]float32
	fromX, fromY float32
	input        ui.Handlers
	draw         func(*ui.DrawContext)
}

// fit is the image's fitted scale in the view it was painted in last, current the scale it is
// drawn at.
func (n *imageCanvas) fit() float64 {
	return imageFitScale(n.view.Width, n.view.Height, n.bitmap.Width, n.bitmap.Height)
}

func (n *imageCanvas) current() float64 {
	if n.scale == 0 {
		return n.fit()
	}
	return n.scale
}

// place is where the image goes in the view at scale: centered in the content, which is the
// image with imagePadding around it or the view where that is smaller, scrolled by x and y,
// which it bounds to the content.
func (n *imageCanvas) place(scale float64) gfx.Rect {
	view := n.view
	width := float32(float64(n.bitmap.Width) * scale)
	height := float32(float64(n.bitmap.Height) * scale)
	contentWidth := max(view.Width, width+2*imagePadding)
	contentHeight := max(view.Height, height+2*imagePadding)
	n.x = min(max(n.x, 0), contentWidth-view.Width)
	n.y = min(max(n.y, 0), contentHeight-view.Height)
	return gfx.Rect{X: view.X + (contentWidth-width)/2 - n.x, Y: view.Y + (contentHeight-height)/2 - n.y, Width: width, Height: height}
}

// zoomAt sets the scale, 0 for the fitted one, keeping the image's point under (x, y) in place.
func (n *imageCanvas) zoomAt(scale float64, x, y float32) {
	before := n.place(n.current())
	fx, fy := float32(0.5), float32(0.5)
	if before.Width > 0 {
		fx = (x - before.X) / before.Width
	}
	if before.Height > 0 {
		fy = (y - before.Y) / before.Height
	}
	if scale != 0 {
		scale = clampImageScale(scale, n.fit())
	}
	n.scale = scale
	after := n.place(n.current())
	n.x += after.X + fx*after.Width - x
	n.y += after.Y + fy*after.Height - y
	n.place(n.current())
}

// zoomTo applies what the bar asked, around the middle of the view.
func (n *imageCanvas) zoomTo(request zoomRequest) {
	x, y := n.view.X+n.view.Width/2, n.view.Y+n.view.Height/2
	switch {
	case request.to > 0:
		n.zoomAt(request.to, x, y)
	case request.by != 0:
		n.zoomAt(n.current()+request.by, x, y)
	default:
		n.zoomAt(0, x, y)
	}
}

// zoom is the canvas's zoom as the bar shows it.
func (n *imageCanvas) zoom() imageZoom {
	return imageZoom{shown: n.current(), fit: n.fit(), width: n.bitmap.Width, height: n.bitmap.Height}
}

// makeImageCanvas gives n its handlers: the wheel scrolls the image (sideways with Shift) and
// zooms it with Control, and a press drags it.
func (a *App) makeImageCanvas(n *imageCanvas) {
	n.input = ui.Handlers{
		Scroll: func(event gfx.ScrollEvent) gfx.EventResult {
			if n.state != canvasReady {
				return gfx.EventResult{}
			}
			if event.Modifiers&gfx.ModifierControl != 0 {
				n.zoomAt(n.current()*math.Exp(-float64(event.DeltaY)*imageWheelZoom), event.X, event.Y)
				return gfx.EventResult{Handled: true, Repaint: true}
			}
			dx, dy := event.DeltaX, event.DeltaY
			if event.Modifiers&gfx.ModifierShift != 0 && dx == 0 {
				dx, dy = dy, 0
			}
			if !event.Precise {
				dx, dy = dx*3, dy*3
			}
			n.x, n.y = n.x+dx, n.y+dy
			n.place(n.current())
			return gfx.EventResult{Handled: true, Repaint: true}
		},
		Pointer: func(event gfx.PointerEvent) gfx.EventResult {
			switch event.Kind {
			case gfx.PointerDown:
				if event.Button != gfx.PointerButtonPrimary || n.state != canvasReady {
					return gfx.EventResult{}
				}
				n.dragging, n.from, n.fromX, n.fromY = true, [2]float32{event.X, event.Y}, n.x, n.y
				return gfx.EventResult{Handled: true}
			case gfx.PointerMove:
				if !n.dragging {
					return gfx.EventResult{}
				}
				n.x, n.y = n.fromX-(event.X-n.from[0]), n.fromY-(event.Y-n.from[1])
				n.place(n.current())
				return gfx.EventResult{Handled: true, Repaint: true}
			case gfx.PointerUp, gfx.PointerExit:
				if n.dragging && (event.Kind == gfx.PointerUp || !event.Captured) {
					n.dragging = false
				}
			}
			return gfx.EventResult{}
		},
	}
	n.draw = func(d *ui.DrawContext) { a.paintImageCanvas(d, n) }
}

// imageCanvasView declares the canvas filling c.
func (a *App) imageCanvasView(c ui.C, label string, n *imageCanvas) {
	ui.Control(c.Part("image-canvas"), label, &n.input).Fill().Clip().Draw(n.draw)
}

// paintImageCanvas draws the checkerboard and the image at its scale.
func (a *App) paintImageCanvas(d *ui.DrawContext, n *imageCanvas) {
	if n.view != d.Rect {
		// The bar was declared with the zoom of the last view: it is declared again for this one.
		n.view = d.Rect
		a.invalidator.Invalidate()
	}
	a.paintChecker(d.Canvas, d.Rect)
	if n.state != canvasReady {
		return
	}
	if n.scale != 0 {
		n.scale = clampImageScale(n.scale, n.fit())
	}
	d.Canvas.DrawBitmap(n.bitmap, n.place(n.current()))
}

// checker is the bitmap the checkerboard is drawn from, made for the editor's color and the
// display's scale.
type checker struct {
	bitmap gfx.Bitmap
	color  gfx.Color
	scale  float32
	made   uint32
}

// paintChecker fills r with the checkerboard, its squares from r's corner: the editor's color
// lightened and darkened by 7% in turn, as the web page draws it.
func (a *App) paintChecker(canvas *gfx.Canvas, r gfx.Rect) {
	scale := max(canvas.PixelScale(), 1)
	tile := &a.checker
	if tile.bitmap.Width == 0 || tile.color != a.colors.Editor || tile.scale != scale {
		tile.made++
		tile.bitmap = checkerBitmap(a.colors.Editor, scale, tile.made)
		tile.color, tile.scale = a.colors.Editor, scale
	}
	side := float32(checkerSquare * checkerTile)
	canvas.Clip(r)
	for y := r.Y; y < r.Y+r.Height; y += side {
		for x := r.X; x < r.X+r.Width; x += side {
			canvas.DrawBitmap(tile.bitmap, gfx.Rect{X: x, Y: y, Width: side, Height: side})
		}
	}
	canvas.Unclip()
}

// checkerBitmap is checkerTile squares a side of the checkerboard over surface, at the display's
// scale, opaque: a square is surface with 7% of black over it where its row and column add up to
// an odd number, and with 7% of white elsewhere.
func checkerBitmap(surface gfx.Color, scale float32, version uint32) gfx.Bitmap {
	square := max(1, int(math.Round(float64(checkerSquare*scale))))
	side := square * checkerTile
	blend := func(over float32) color.RGBA {
		mix := func(channel float32) uint8 {
			return uint8(math.Round(float64((channel*0.93 + over*0.07) * 255)))
		}
		return color.RGBA{R: mix(surface.Red), G: mix(surface.Green), B: mix(surface.Blue), A: 255}
	}
	light, dark := blend(1), blend(0)
	picture := image.NewRGBA(image.Rect(0, 0, side, side))
	for y := range side {
		for x := range side {
			if (x/square+y/square)%2 == 1 {
				picture.SetRGBA(x, y, dark)
			} else {
				picture.SetRGBA(x, y, light)
			}
		}
	}
	bitmap := bitmapOf(picture, checkerBitmapID)
	bitmap.Version = version
	return bitmap
}
