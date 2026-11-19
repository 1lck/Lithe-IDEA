package pluginview

import (
	"bytes"
	"errors"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

// imageWait bounds how long a test waits for an image to load; a load reads one small file.
const imageWait = 10 * time.Second

// writePNG writes a width × height PNG of one color at rel inside dir.
func writePNG(t *testing.T, dir, rel string, width, height int, fill color.NRGBA) {
	t.Helper()
	picture := image.NewNRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			picture.SetNRGBA(x, y, fill)
		}
	}
	var data bytes.Buffer
	if err := png.Encode(&data, picture); err != nil {
		t.Fatal(err)
	}
	writeFile(t, dir, rel, data.Bytes())
}

func writeFile(t *testing.T, dir, rel string, data []byte) {
	t.Helper()
	path := filepath.Join(dir, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

// loader is a package's images with the wake and failure they report, which arrive on the
// loading goroutine.
type loader struct {
	t      *testing.T
	images *Images
	woken  chan struct{}
	failed chan error
}

func newLoader(t *testing.T, dir string) *loader {
	l := &loader{t: t, woken: make(chan struct{}, 4), failed: make(chan error, 4)}
	l.images = NewImages(dir, func() { l.woken <- struct{}{} }, func(err error) { l.failed <- err })
	t.Cleanup(l.images.Close)
	return l
}

// loaded asks for src and waits until it arrives.
func (l *loader) loaded(src string) {
	l.t.Helper()
	if _, ready := l.images.bitmap(src); ready {
		l.t.Fatalf("%s was ready before it loaded", src)
	}
	select {
	case <-l.woken:
	case err := <-l.failed:
		l.t.Fatalf("loading %s failed: %v", src, err)
	case <-time.After(imageWait):
		l.t.Fatalf("%s did not load within %v", src, imageWait)
	}
}

// refused asks for src and waits for the failure it reports.
func (l *loader) refused(src string) error {
	l.t.Helper()
	l.images.bitmap(src)
	select {
	case err := <-l.failed:
		if !strings.Contains(err.Error(), src) {
			l.t.Errorf("failure %q does not name the image", err)
		}
		return err
	case <-l.woken:
		l.t.Fatalf("%s loaded, want it refused", src)
	case <-time.After(imageWait):
		l.t.Fatalf("%s reported nothing within %v", src, imageWait)
	}
	return nil
}

func TestImagesLoadAPackagePNGOnce(t *testing.T) {
	dir := t.TempDir()
	writePNG(t, dir, "media/dot.png", 2, 1, color.NRGBA{R: 255, A: 255})
	l := newLoader(t, dir)
	l.loaded("media/dot.png")
	bitmap, ready := l.images.bitmap("media/dot.png")
	if !ready || bitmap.Width != 2 || bitmap.Height != 1 {
		t.Fatalf("bitmap = %dx%d, ready %v", bitmap.Width, bitmap.Height, ready)
	}
	if got := bitmap.Pix[:4]; !bytes.Equal(got, []byte{0, 0, 255, 255}) {
		t.Fatalf("red pixel = %v, want BGRA", got)
	}
	if bitmap.ID>>56 != 0x50 || bitmap.ID != imageID(dir, "media/dot.png") {
		t.Fatalf("bitmap ID = %#x", bitmap.ID)
	}
	if len(l.woken) != 0 {
		t.Fatal("asking for a loaded image loaded it again")
	}
}

func TestImagesRefuseWhatThePackageRulesOrTheLimitsExclude(t *testing.T) {
	dir := t.TempDir()
	writePNG(t, dir, "wide.png", imageSide+1, 1, color.NRGBA{A: 255})
	writeFile(t, dir, "huge.png", make([]byte, imageBytes+1))
	writeFile(t, dir, "notes.png", []byte("not a picture"))
	writePNG(t, filepath.Dir(dir), "outside.png", 1, 1, color.NRGBA{A: 255})
	l := newLoader(t, dir)
	for _, tc := range []struct {
		src  string
		want string
	}{
		{"wide.png", "image is too large"},
		{"huge.png", "image file is too large"},
		{"notes.png", "png"},
		{"missing.png", "does not exist"},
	} {
		if err := l.refused(tc.src); err != nil && !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: %v, want %q", tc.src, err, tc.want)
		}
	}
	if err := l.refused("../outside.png"); err != nil && !errors.Is(err, pluginhost.ErrPackagePath) {
		t.Errorf("a path out of the package: %v, want a package path error", err)
	}
	if err := os.Symlink(filepath.Join(filepath.Dir(dir), "outside.png"), filepath.Join(dir, "link.png")); err != nil {
		t.Fatal(err)
	}
	if err := l.refused("link.png"); err != nil && !errors.Is(err, pluginhost.ErrPackageSymlink) {
		t.Errorf("a link out of the package: %v, want a symbolic link error", err)
	}
	if _, ready := l.images.bitmap("wide.png"); ready {
		t.Fatal("a refused image was drawn")
	}
}

func TestImagesCloseDropsTheLoadedImages(t *testing.T) {
	dir := t.TempDir()
	writePNG(t, dir, "dot.png", 1, 1, color.NRGBA{G: 255, A: 255})
	l := newLoader(t, dir)
	l.loaded("dot.png")
	l.images.Close()
	if _, ready := l.images.bitmap("dot.png"); ready {
		t.Fatal("a closed view still draws its image")
	}
	var none *Images
	none.Close()
	if _, ready := none.bitmap("dot.png"); ready {
		t.Fatal("no images drew an image")
	}
	if _, ready := l.images.bitmap(""); ready {
		t.Fatal("an image without a path was drawn")
	}
}

func TestImageIDsDifferByPackageAndPath(t *testing.T) {
	a, b, c := imageID("/p", "a.png"), imageID("/p", "b.png"), imageID("/q", "a.png")
	if a == b || a == c || b == c {
		t.Fatalf("image IDs collide: %#x %#x %#x", a, b, c)
	}
}
