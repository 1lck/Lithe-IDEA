package pluginview

import (
	"bytes"
	"errors"
	"fmt"
	"hash/fnv"
	"image/png"
	"io"
	"os"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/bgra"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/vivaui/viva/gfx"
)

// A canvas image is a PNG file of the plugin's installed package, named by a package-relative
// path. The host reads it read-only, under the same rules as the package's icons: the path
// must stay inside the package, through real directories, to a regular file. Images are
// loaded off the window thread the first time a scene draws them and kept until the view
// closes; the view draws without an image until it arrives, and without one that cannot be
// read, whose failure the host logs once.
const (
	// imageBytes bounds the size of one image file.
	imageBytes = 256 << 10
	// imageSide bounds the width and the height of one image.
	imageSide = 1024
)

// Images loads and keeps the canvas images of one plugin view.
type Images struct {
	dir    string
	wake   func()
	failed func(error)

	mu     sync.Mutex
	images map[string]*picture
	closed bool
}

// picture is one image: loading until its load ends, then its bitmap or failed.
type picture struct {
	bitmap gfx.Bitmap
	ready  bool
}

// NewImages keeps the images of the package installed in packageDir. wake asks for a frame
// when an image arrives; failed logs an image that cannot be read, naming its path. Both run
// on the loading goroutine, so they must be safe to call from any goroutine.
func NewImages(packageDir string, wake func(), failed func(error)) *Images {
	return &Images{dir: packageDir, wake: wake, failed: failed, images: map[string]*picture{}}
}

// Close drops the kept images; loads still under way end without effect.
func (i *Images) Close() {
	if i == nil {
		return
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	i.images, i.closed = map[string]*picture{}, true
}

// bitmap is the image at src once it is loaded; the first ask starts loading it.
func (i *Images) bitmap(src string) (gfx.Bitmap, bool) {
	if i == nil || src == "" {
		return gfx.Bitmap{}, false
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	if p := i.images[src]; p != nil {
		return p.bitmap, p.ready
	}
	if i.closed {
		return gfx.Bitmap{}, false
	}
	p := &picture{}
	i.images[src] = p
	go i.load(src, p)
	return gfx.Bitmap{}, false
}

// load reads one image and hands it to the view. An image that cannot be read stays loading,
// so it is read and logged once while the view shows; the view draws without it.
func (i *Images) load(src string, p *picture) {
	bitmap, err := loadImage(i.dir, src)
	i.mu.Lock()
	kept := i.images[src] == p
	if kept && err == nil {
		p.bitmap, p.ready = bitmap, true
	}
	i.mu.Unlock()
	switch {
	case err != nil && i.failed != nil:
		i.failed(fmt.Errorf("pluginview: canvas image %q: %w", src, err))
	case kept && err == nil && i.wake != nil:
		i.wake()
	}
}

// loadImage reads and decodes the PNG at the package-relative path src, refusing a file
// or an image over the limits before decoding it.
func loadImage(dir, src string) (gfx.Bitmap, error) {
	path, err := pluginhost.ResolvePackagePath(dir, src)
	if err != nil {
		return gfx.Bitmap{}, err
	}
	file, err := os.Open(path)
	if err != nil {
		return gfx.Bitmap{}, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, imageBytes+1))
	if err != nil {
		return gfx.Bitmap{}, err
	}
	if len(data) > imageBytes {
		return gfx.Bitmap{}, errors.New("pluginview: image file is too large")
	}
	config, err := png.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return gfx.Bitmap{}, err
	}
	if config.Width <= 0 || config.Height <= 0 || config.Width > imageSide || config.Height > imageSide {
		return gfx.Bitmap{}, errors.New("pluginview: image is too large")
	}
	decoded, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		return gfx.Bitmap{}, err
	}
	return bgra.Bitmap(decoded, imageID(dir, src)), nil
}

// imageID names an image to the canvas, apart from the other bitmaps the window draws.
func imageID(dir, src string) uint64 {
	hash := fnv.New64a()
	_, _ = hash.Write([]byte(dir + "\x00" + src))
	return hash.Sum64()&0x00ffffffffffffff | 0x50<<56
}
