package workbench

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// pngOf encodes an opaque width×height PNG.
func pngOf(t *testing.T, width, height int) []byte {
	t.Helper()
	picture := image.NewRGBA(image.Rect(0, 0, width, height))
	for x := range width {
		for y := range height {
			picture.Set(x, y, color.RGBA{R: 200, G: 40, B: 10, A: 255})
		}
	}
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, picture); err != nil {
		t.Fatal(err)
	}
	return encoded.Bytes()
}

// TestMarkdownPreviewShowsRelativeAndRemoteImages: the page beside the source loads, as Core
// resolves them, an image beside the file and one served over http, and gives up on a missing
// download, a format it cannot decode, an image outside the workspace and another scheme, which
// keep their alt text.
func TestMarkdownPreviewShowsRelativeAndRemoteImages(t *testing.T) {
	remote := pngOf(t, 3, 2)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/remote.png" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(remote)
	}))
	t.Cleanup(server.Close)

	h := newHarness(t, &testKernel{Client: core.NewClient()})
	outside := t.TempDir()
	root := filepath.Join(outside, "work")
	if err := os.MkdirAll(filepath.Join(root, "img"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "img", "local.png"), pngOf(t, 4, 5), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outside, "outside.png"), pngOf(t, 2, 2), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "logo.svg"), []byte(`<svg xmlns="http://www.w3.org/2000/svg"/>`), 0o600); err != nil {
		t.Fatal(err)
	}
	readme := filepath.Join(root, "README.md")
	text := "# Pictures\n\n![local](img/local.png)\n\n![remote](" + server.URL + "/remote.png)\n\n![gone](" + server.URL +
		"/gone.png)\n\n![vector](logo.svg)\n\n![escape](../outside.png)\n\n![other](ftp://example.com/a.png)\n"
	if err := os.WriteFile(readme, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.openFile(h.app.project, readme)
	h.settle()
	p := h.app.project
	d := p.docs.byPath(readme)
	if d == nil || d.markdown == nil {
		t.Fatal("the Markdown file did not open beside its page")
	}
	s := d.markdown
	loaded := func() bool {
		if len(s.images) != 6 {
			return false
		}
		for _, image := range s.images {
			if image.loading {
				return false
			}
		}
		return true
	}
	awaitStateWithin(t, h, 20*time.Second, "the images to load", loaded)

	local := s.images["img/local.png"]
	if local == nil || local.failed || local.bitmap.Width != 4 || local.bitmap.Height != 5 {
		t.Fatalf("the image beside the file is %+v", local)
	}
	if over := s.images[server.URL+"/remote.png"]; over == nil || over.failed || over.bitmap.Width != 3 || over.bitmap.Height != 2 {
		t.Fatalf("the downloaded image is %+v", over)
	}
	for _, destination := range []string{server.URL + "/gone.png", "logo.svg", "../outside.png", "ftp://example.com/a.png"} {
		if image := s.images[destination]; image == nil || !image.failed {
			t.Fatalf("the image %q is %+v, want failed", destination, image)
		}
	}
	if _, ok := h.app.markdownImageBitmap(p, d, s, "img/local.png"); !ok {
		t.Fatal("the loaded image is not handed to the view")
	}
	if _, ok := h.app.markdownImageBitmap(p, d, s, server.URL+"/gone.png"); ok {
		t.Fatal("a failed image is handed to the view")
	}
	h.settle()
	for _, alt := range []string{"gone", "vector", "escape", "other"} {
		if !h.shows(alt) {
			t.Fatalf("the alt text %q of an image that cannot be shown is missing: %v", alt, h.driver.Snapshot().Labels)
		}
	}
}
