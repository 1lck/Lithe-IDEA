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
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/vivaui/viva/gfx"
)

// The Markdown preview shows the images a file links (![alt](destination)): a path relative to
// the file, or an http or https address fetched through the application's proxy. Viva lays an
// image out from the bitmap the preview hands it (MarkdownStyle.Image) and shows the alt text
// until it is loaded or when it cannot be: a missing file, a format the standard decoders do not
// read (SVG among them), an image over the size limits or a failed download. Images are loaded
// off the window thread, kept for the document shown, and the page is laid out again as each
// arrives.

const (
	// markdownImageTimeout bounds one download.
	markdownImageTimeout = 15 * time.Second
	// markdownImageBytes bounds what one image may take to read or download.
	markdownImageBytes = 16 << 20
)

// markdownImage is one image of the document shown: loading until its load ends, then
// either its bitmap or failed.
type markdownImage struct {
	bitmap  gfx.Bitmap
	loading bool
	failed  bool
}

// markdownImageSource is where an image's destination points: a file or an address. Other
// schemes are not read.
func markdownImageSource(documentPath, destination string) (key string, remote bool, ok bool) {
	destination = strings.TrimSpace(destination)
	if destination == "" || strings.HasPrefix(destination, "#") {
		return "", false, false
	}
	if parsed, err := url.Parse(destination); err == nil && parsed.Scheme != "" && len(parsed.Scheme) > 1 {
		switch strings.ToLower(parsed.Scheme) {
		case "http", "https":
			return destination, true, true
		case "file":
			return filepath.Clean(parsed.Path), false, true
		}
		return "", false, false
	}
	target := markdownLinkTargetOf(documentPath, destination)
	if target.path == "" {
		return "", false, false
	}
	return target.path, false, true
}

// markdownImageBitmap answers the view's question for one destination: the bitmap when it is
// loaded, and otherwise false after starting its load.
func (a *App) markdownImageBitmap(destination string) (gfx.Bitmap, bool) {
	s := &a.editor.markdown
	key, remote, ok := markdownImageSource(s.path, destination)
	if !ok {
		return gfx.Bitmap{}, false
	}
	if s.images == nil {
		s.images = map[string]*markdownImage{}
	}
	if image := s.images[key]; image != nil {
		return image.bitmap, !image.loading && !image.failed
	}
	image := &markdownImage{loading: true}
	s.images[key] = image
	documentID := s.documentID
	go func() {
		bitmap, err := loadMarkdownImage(key, remote)
		a.post(func(a *App) {
			s := &a.editor.markdown
			if s.documentID != documentID || s.images[key] != image {
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
		})
	}()
	return gfx.Bitmap{}, false
}

// loadMarkdownImage reads or downloads one image and decodes it.
func loadMarkdownImage(key string, remote bool) (gfx.Bitmap, error) {
	var data []byte
	var err error
	if remote {
		data, err = downloadMarkdownImage(key)
	} else {
		data, err = readBounded(key, markdownImageBytes)
	}
	if err != nil {
		return gfx.Bitmap{}, err
	}
	hash := fnv.New64a()
	_, _ = hash.Write([]byte(key))
	return decodeImageData(data, hash.Sum64()&0x00ffffffffffffff|0x4d00000000000000)
}

// downloadMarkdownImage fetches an image address; the default transport follows the
// application's proxy policy (netproxy).
func downloadMarkdownImage(address string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), markdownImageTimeout)
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

// readBounded reads a file of at most limit bytes.
func readBounded(path string, limit int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
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
