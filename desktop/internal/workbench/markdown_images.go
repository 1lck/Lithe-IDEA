package workbench

import (
	"bytes"
	"context"
	"errors"
	"hash/fnv"
	"image"
	"image/draw"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/webpreview"
	"github.com/vivaui/viva/gfx"
)

// The Markdown page Viva draws shows the images a file links (![alt](destination)) as Core
// resolves them (markdown.resolveReference): an image file inside the workspace, or an http or
// https address fetched through the application's proxy, the same images a web page of the file
// shows. Viva lays an image out from the bitmap the preview hands it (MarkdownStyle.Image) and
// shows the alt text until it is loaded or when it cannot be: a reference Core does not load, a
// format the standard decoders do not read (SVG among them), an image over the size limits or a
// failed download. Images are loaded off the window thread, kept for the document shown, and the
// page is laid out again as each arrives. Downloads are shared with the web pages and kept for
// all of them (webpreview.Remote).

const (
	// markdownImageTimeout bounds one download.
	markdownImageTimeout = 15 * time.Second
	// markdownImageBytes bounds what one image may take to download.
	markdownImageBytes = 16 << 20
)

// markdownImage is one image of the document shown: loading until its load ends, then
// either its bitmap or failed.
type markdownImage struct {
	bitmap  gfx.Bitmap
	loading bool
	failed  bool
}

// markdownImageBitmap answers the page's question for one destination of d: the bitmap when it is
// loaded, and otherwise false after starting its load.
func (a *App) markdownImageBitmap(p *project, d *document, s *markdownPreviewState, destination string) (gfx.Bitmap, bool) {
	destination = strings.TrimSpace(destination)
	if destination == "" {
		return gfx.Bitmap{}, false
	}
	if s.images == nil {
		s.images = map[string]*markdownImage{}
	}
	if image := s.images[destination]; image != nil {
		return image.bitmap, !image.loading && !image.failed
	}
	kernel, ok := a.kernel.(markdownKernel)
	if !ok {
		return gfx.Bitmap{}, false
	}
	image := &markdownImage{loading: true}
	s.images[destination] = image
	path, root, remote := s.path, p.root, a.previewRemote()
	a.background(p, markdownImageTimeout, func(ctx context.Context) func(*App) {
		bitmap, err := loadMarkdownImage(ctx, kernel, path, root, destination, remote)
		return func(a *App) {
			// The file may have been renamed or closed while the image loaded.
			if d.markdown != s || s.images[destination] != image {
				return
			}
			image.loading = false
			if err != nil {
				image.failed = true
				return
			}
			image.bitmap = bitmap
			// The page makes room for the image the next time it is laid out.
			s.laidRevision = -1
		}
	})
	return gfx.Bitmap{}, false
}

// loadMarkdownImage resolves one image of a document through Core, reads or downloads it and
// decodes it.
func loadMarkdownImage(ctx context.Context, kernel markdownKernel, documentPath, workspaceRoot, destination string, remote *webpreview.Remote) (gfx.Bitmap, error) {
	resolved, err := kernel.ResolveMarkdownReference(ctx, documentPath, workspaceRoot, destination, core.MarkdownResource)
	if err != nil {
		return gfx.Bitmap{}, err
	}
	data, _, err := webpreview.LoadResource(ctx, resolved, remote)
	if err != nil {
		return gfx.Bitmap{}, err
	}
	hash := fnv.New64a()
	_, _ = hash.Write([]byte(resolved.Path + "\x00" + resolved.URL))
	return decodeImageData(data, hash.Sum64()&0x00ffffffffffffff|0x4d00000000000000)
}

// downloadMarkdownImage fetches an image address for webpreview.Remote, which asks without a
// deadline; the default transport follows the application's proxy policy (netproxy).
func downloadMarkdownImage(ctx context.Context, address string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, markdownImageTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode/100 != 2 {
		return nil, errors.New(response.Status)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, markdownImageBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > markdownImageBytes {
		return nil, errors.New("image is too large")
	}
	return data, nil
}

// decodeImageData decodes an image into premultiplied BGRA, refusing one over the viewer's
// pixel limit before decoding it.
func decodeImageData(data []byte, id uint64) (gfx.Bitmap, error) {
	config, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return gfx.Bitmap{}, err
	}
	if config.Width <= 0 || config.Height <= 0 || config.Width*config.Height > viewerImagePixels {
		return gfx.Bitmap{}, errors.New("image is too large to preview")
	}
	decoded, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return gfx.Bitmap{}, err
	}
	return bitmapOf(decoded, id), nil
}

// bitmapOf converts an image to the canvas's premultiplied BGRA.
func bitmapOf(decoded image.Image, id uint64) gfx.Bitmap {
	bounds := decoded.Bounds()
	rgba := image.NewRGBA(image.Rect(0, 0, bounds.Dx(), bounds.Dy()))
	draw.Draw(rgba, rgba.Bounds(), decoded, bounds.Min, draw.Src)
	// image.RGBA is premultiplied RGBA; the canvas takes premultiplied BGRA.
	pix := rgba.Pix
	for i := 0; i+3 < len(pix); i += 4 {
		pix[i], pix[i+2] = pix[i+2], pix[i]
	}
	return gfx.Bitmap{Pix: pix, Width: rgba.Rect.Dx(), Height: rgba.Rect.Dy(), Stride: rgba.Stride, ID: id, Version: 1}
}
