package workbench

import (
	"bytes"
	"image"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/webpreview"
	"github.com/vivaui/viva/gfx"
)

// writePNG writes a white width×height PNG at path.
func writePNG(t *testing.T, path string, width, height int) {
	t.Helper()
	picture := image.NewNRGBA(image.Rect(0, 0, width, height))
	for i := range picture.Pix {
		picture.Pix[i] = 0xff
	}
	var data bytes.Buffer
	if err := png.Encode(&data, picture); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
}

// openViewerFile opens root as the project and path in it, and returns path's viewer tab once
// its file was read.
func openViewerFile(t *testing.T, h *harness, root, path string) *viewerTab {
	t.Helper()
	h.open(root)
	h.app.openFile(h.app.project, path)
	h.await("the viewer tab's file", func() bool {
		v := h.app.project.viewers.byPath(path)
		return v != nil && !v.loading
	})
	h.settle()
	v := h.app.project.viewers.byPath(path)
	if v == nil {
		t.Fatal("the viewer tab did not open")
	}
	return v
}

// hitOf is the control named label laid out in the last frame.
func hitOf(h *harness, label string) gfx.Hit {
	h.t.Helper()
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == label && !hit.IsLabel {
			return hit
		}
	}
	h.t.Fatalf("no control named %q is shown", label)
	return gfx.Hit{}
}

// TestViewerShowsAnImageOnTheImagePage: an image opens on the image page, which is given the
// window's look and the file's address; the bar shows the zoom and the dimensions the page
// reports and sends the page what its buttons ask; an image the page cannot decode shows the
// viewer's failure with the file's actions, and its page closes.
func TestViewerShowsAnImageOnTheImagePage(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	pages := fakePreviews(h)
	root := t.TempDir()
	path := filepath.Join(root, "photo.png")
	writePNG(t, path, 40, 20)
	v := openViewerFile(t, h, root, path)
	if len(*pages) != 1 {
		t.Fatalf("the image opened %d web pages, want 1", len(*pages))
	}
	page := (*pages)[0]
	if page.config.Page != webpreview.ImagePage || page.config.File != path || page.config.FileLimit != viewerImageBytes {
		t.Fatalf("the image's page is %q of %q up to %d bytes", page.config.Page, page.config.File, page.config.FileLimit)
	}
	language := h.app.language()
	zoomIn := i18n.Shared(language, "desktop.viewer.zoomIn")
	if controlShown(h, zoomIn) {
		t.Fatal("the bar offers to zoom before the page reported the image")
	}
	if !controlShown(h, i18n.Shared(language, "desktop.viewer.openExternally")) || !controlShown(h, i18n.Shared(language, "desktop.viewer.close")) {
		t.Fatal("the bar does not offer the file's actions")
	}

	page.load()
	if setups := sentOf[previewTheme](page); len(setups) != 1 || setups[0].Type != "setup" || len(setups[0].Theme.Variables) == 0 {
		t.Fatalf("the page was given the look %+v", setups)
	}
	if shows := sentOf[imagePageShow](page); len(shows) != 1 || shows[0] != (imagePageShow{Type: "show", Src: webpreview.Origin + "file/photo.png"}) {
		t.Fatalf("the page was told to show %+v", shows)
	}

	page.config.OnMessage(webpreview.Message{Type: "scale", Scale: 0.5, Fit: 0.5, Width: 40, Height: 20})
	h.settle()
	zoomLabel := i18n.Shared(language, "desktop.viewer.zoom")
	if value := hitOf(h, zoomLabel).Value; value != "50%" {
		t.Fatalf("the bar shows the zoom %q, want 50%%", value)
	}
	if !h.shows("40 × 20 · " + formatByteSize(uint64(v.size))) {
		t.Fatal("the bar does not show the image's dimensions and size")
	}
	h.click(center(h.hitLabeled(zoomIn)))
	h.settle()
	h.click(center(h.hitLabeled(zoomLabel)))
	h.settle()
	h.click(center(h.hitLabeled(i18n.Shared(language, "desktop.viewer.zoomOut"))))
	h.settle()
	want := []imagePageZoom{{Type: "zoom", By: imageZoomStep}, {Type: "zoom", To: 1}, {Type: "zoom", By: -imageZoomStep}}
	if zooms := sentOf[imagePageZoom](page); !slices.Equal(zooms, want) {
		t.Fatalf("the bar sent %+v, want %+v", zooms, want)
	}

	page.config.OnMessage(webpreview.Message{Type: "failed"})
	h.settle()
	if !page.closed || len(*pages) != 1 || v.web != nil {
		t.Fatalf("after the failure the page closed %v and %d pages opened", page.closed, len(*pages))
	}
	if !h.shows(i18n.Shared(language, "desktop.viewer.imageFailed")) || controlShown(h, zoomIn) {
		t.Fatal("the viewer does not show the failure in place of the zoom")
	}
	if !controlShown(h, i18n.Shared(language, "desktop.viewer.openExternally")) {
		t.Fatal("the failure does not offer to open the file in the system's application")
	}
}

// TestViewerShowsAPDFInTheEnginesViewer: a PDF opens in the engine's own viewer, a link the
// user follows in it opens as Core resolves it, and the page closes with its tab.
func TestViewerShowsAPDFInTheEnginesViewer(t *testing.T) {
	var opened []string
	previous := openURL
	openURL = func(address string) error { opened = append(opened, address); return nil }
	t.Cleanup(func() { openURL = previous })

	h := newHarness(t, &testKernel{Client: core.NewClient()})
	pages := fakePreviews(h)
	root := t.TempDir()
	path := filepath.Join(root, "manual.pdf")
	if err := os.WriteFile(path, []byte("%PDF-1.4\n%%EOF\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	v := openViewerFile(t, h, root, path)
	if v.kind != viewerPDF || len(*pages) != 1 {
		t.Fatalf("the PDF opened as %v with %d pages", v.kind, len(*pages))
	}
	page := (*pages)[0]
	if page.config.Page != webpreview.PDFPage || page.config.File != path || page.config.FileLimit != viewerPDFBytes {
		t.Fatalf("the PDF's page is %q of %q up to %d bytes", page.config.Page, page.config.File, page.config.FileLimit)
	}
	language := h.app.language()
	if controlShown(h, i18n.Shared(language, "desktop.viewer.zoomIn")) || !h.shows(formatByteSize(uint64(v.size))) {
		t.Fatal("the PDF's bar offers zoom or does not show the file's size")
	}

	page.config.Follow("https://example.com/manual")
	h.await("the followed link", func() bool { return len(opened) == 1 })
	if opened[0] != "https://example.com/manual" {
		t.Fatalf("opened %v", opened)
	}

	h.click(center(h.hitLabeled(i18n.Shared(language, "desktop.viewer.close"))))
	h.settle()
	h.settle()
	if h.app.project.viewers.byPath(path) != nil || !page.closed {
		t.Fatalf("after the close the tab is open %v and the page closed %v", h.app.project.viewers.byPath(path) != nil, page.closed)
	}
}

// TestViewerDrawsTheImageItselfWithoutAWebEngine: where no page can be opened, Viva draws the
// image at its fitted scale, and the bar and Control with the wheel zoom it.
func TestViewerDrawsTheImageItselfWithoutAWebEngine(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "photo.png")
	writePNG(t, path, 4000, 2000)
	v := openViewerFile(t, h, root, path)
	h.await("the decoded image", func() bool { return v.canvas != nil && v.canvas.state == canvasReady })
	h.settle()
	n := v.canvas
	if n.view.Width <= 0 || n.bitmap.Width != 4000 || n.bitmap.Height != 2000 {
		t.Fatalf("the canvas was painted in %+v with a %d×%d bitmap", n.view, n.bitmap.Width, n.bitmap.Height)
	}
	fit := imageFitScale(n.view.Width, n.view.Height, 4000, 2000)
	language := h.app.language()
	zoomLabel := i18n.Shared(language, "desktop.viewer.zoom")
	if fit >= 1 || n.scale != 0 || hitOf(h, zoomLabel).Value != zoomPercent(fit) {
		t.Fatalf("the image is at %v and the bar says %q, want its fitted scale %v", n.current(), hitOf(h, zoomLabel).Value, fit)
	}

	h.click(center(h.hitLabeled(i18n.Shared(language, "desktop.viewer.zoomIn"))))
	h.settle()
	if want := clampImageScale(fit+imageZoomStep, fit); math.Abs(n.scale-want) > 1e-9 {
		t.Fatalf("zoom in gave %v, want %v", n.scale, want)
	}
	h.click(center(h.hitLabeled(zoomLabel)))
	h.settle()
	if n.scale != 1 || hitOf(h, zoomLabel).Value != "100%" {
		t.Fatalf("the reset gave %v", n.scale)
	}
	middle := center(n.view)
	if err := h.driver.Scroll(gfx.ScrollEvent{X: middle.X, Y: middle.Y, DeltaY: -50, Modifiers: gfx.ModifierControl, Precise: true}); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if want := math.Exp(0.5); math.Abs(n.scale-want) > 1e-6 {
		t.Fatalf("Control and the wheel zoomed to %v, want %v", n.scale, want)
	}
}

// TestViewerSaysWhenAFileIsTooLargeToShow: an image over viewerImageBytes is neither decoded nor
// given a page, and the viewer says so over the bar's actions.
func TestViewerSaysWhenAFileIsTooLargeToShow(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	pages := fakePreviews(h)
	root := t.TempDir()
	path := filepath.Join(root, "poster.png")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	err = file.Truncate(viewerImageBytes + 1)
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		t.Fatal(err)
	}
	v := openViewerFile(t, h, root, path)
	language := h.app.language()
	if !v.tooLarge || len(*pages) != 0 || v.canvas != nil {
		t.Fatalf("the file is too large %v, with %d pages and a canvas %v", v.tooLarge, len(*pages), v.canvas != nil)
	}
	if !h.showsWrapped(i18n.Shared(language, "desktop.viewer.tooLarge")) || !controlShown(h, i18n.Shared(language, "desktop.viewer.openExternally")) {
		t.Fatal("the viewer does not say the file is too large or offer to open it")
	}
}

// TestImageFitScaleKeepsThePaddingAndNeverEnlarges: the fitted scale leaves imagePadding on each
// side, never goes above the image's size or below imageMinFit, and the user's zoom runs from the
// lesser of a step and the fitted scale to imageMaxScale.
func TestImageFitScaleKeepsThePaddingAndNeverEnlarges(t *testing.T) {
	for _, c := range []struct {
		viewWidth, viewHeight float32
		width, height         int
		want                  float64
	}{
		{848, 648, 400, 300, 1},
		{448, 348, 800, 600, 0.5},
		{448, 1000, 800, 100, 0.5},
		{10, 10, 100, 100, imageMinFit},
		{100, 100, 0, 0, 1},
	} {
		if got := imageFitScale(c.viewWidth, c.viewHeight, c.width, c.height); math.Abs(got-c.want) > 1e-9 {
			t.Errorf("imageFitScale(%v, %v, %d, %d) = %v, want %v", c.viewWidth, c.viewHeight, c.width, c.height, got, c.want)
		}
	}
	for _, c := range []struct{ scale, fit, want float64 }{
		{0.1, 0.5, imageZoomStep},
		{0.1, 0.05, 0.1},
		{0.01, 0.05, 0.05},
		{9, 1, imageMaxScale},
		{1.5, 1, 1.5},
	} {
		if got := clampImageScale(c.scale, c.fit); got != c.want {
			t.Errorf("clampImageScale(%v, %v) = %v, want %v", c.scale, c.fit, got, c.want)
		}
	}
	for scale, want := range map[float64]string{1: "100%", 0.255: "26%", 0.001: "1%", 4: "400%"} {
		if got := zoomPercent(scale); got != want {
			t.Errorf("zoomPercent(%v) = %q, want %q", scale, got, want)
		}
	}
}

// TestImageCanvasZoomsAroundThePointAndPansWithinTheImage: a zoom keeps the image's point under
// the pointer in place, a drag pans the image, and the scroll never leaves the image and its
// padding.
func TestImageCanvasZoomsAroundThePointAndPansWithinTheImage(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	n := &imageCanvas{state: canvasReady, bitmap: gfx.Bitmap{Width: 400, Height: 200}, view: gfx.Rect{X: 10, Y: 20, Width: 300, Height: 200}}
	h.app.makeImageCanvas(n)
	before := n.place(n.current())
	if math.Abs(n.fit()-0.63) > 1e-9 || before.X != 34 || before.Y != 57 {
		t.Fatalf("the fitted image is at %+v with the scale %v", before, n.fit())
	}
	const x, y = 100, 90
	fx, fy := (x-before.X)/before.Width, (y-before.Y)/before.Height
	n.zoomAt(2, x, y)
	after := n.place(n.current())
	if n.scale != 2 || math.Abs(float64((x-after.X)/after.Width-fx)) > 1e-4 || math.Abs(float64((y-after.Y)/after.Height-fy)) > 1e-4 {
		t.Fatalf("the zoom moved the point under the pointer: %+v", after)
	}

	scrolled := [2]float32{n.x, n.y}
	n.input.Pointer(gfx.PointerEvent{Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, X: 100, Y: 100})
	n.input.Pointer(gfx.PointerEvent{Kind: gfx.PointerMove, X: 60, Y: 80})
	n.input.Pointer(gfx.PointerEvent{Kind: gfx.PointerUp, Button: gfx.PointerButtonPrimary, X: 60, Y: 80})
	if n.x != scrolled[0]+40 || n.y != scrolled[1]+20 || n.dragging {
		t.Fatalf("the drag scrolled to %v, %v from %v", n.x, n.y, scrolled)
	}
	n.input.Pointer(gfx.PointerEvent{Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, X: 0, Y: 0})
	n.input.Pointer(gfx.PointerEvent{Kind: gfx.PointerMove, X: 5000, Y: 5000})
	if n.x != 0 || n.y != 0 {
		t.Fatalf("the drag scrolled past the image's corner to %v, %v", n.x, n.y)
	}
	n.input.Pointer(gfx.PointerEvent{Kind: gfx.PointerMove, X: -5000, Y: -5000})
	if want := [2]float32{800 + 2*imagePadding - 300, 400 + 2*imagePadding - 200}; n.x != want[0] || n.y != want[1] {
		t.Fatalf("the drag scrolled past the image's far corner to %v, %v, want %v", n.x, n.y, want)
	}

	n.zoomTo(zoomRequest{})
	if n.scale != 0 || n.x != 0 || n.y != 0 {
		t.Fatalf("back at its fitted scale the image is at %v, scrolled %v, %v", n.scale, n.x, n.y)
	}
}

// TestCheckerboardIsTheMacOSViewers: squares of 16 points at the display's scale, the editor's
// color lightened and darkened by 7% in turn, opaque.
func TestCheckerboardIsTheMacOSViewers(t *testing.T) {
	surface := gfx.Color{Red: 0.2, Green: 0.4, Blue: 0.6, Alpha: 1}
	bitmap := checkerBitmap(surface, 2, 3)
	if side := checkerSquare * 2 * checkerTile; bitmap.Width != side || bitmap.Height != side || bitmap.Version != 3 {
		t.Fatalf("the tile is %d×%d version %d", bitmap.Width, bitmap.Height, bitmap.Version)
	}
	pixel := func(x, y int) [4]byte {
		i := y*bitmap.Stride + x*4
		return [4]byte(bitmap.Pix[i : i+4])
	}
	light, dark := pixel(0, 0), pixel(32, 0)
	if light == dark || pixel(31, 31) != light || pixel(32, 32) != light || pixel(0, 32) != dark || light[3] != 0xff || dark[3] != 0xff {
		t.Fatalf("the squares are %v and %v", light, dark)
	}
	if got, want := int(light[1]), int(math.Round((0.4*0.93+0.07)*255)); got != want {
		t.Fatalf("the light square's green is %d, want %d", got, want)
	}
	if got, want := int(dark[1]), int(math.Round(0.4*0.93*255)); got != want {
		t.Fatalf("the dark square's green is %d, want %d", got, want)
	}
}
