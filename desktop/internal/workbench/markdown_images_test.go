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

// TestMarkdownPreviewShowsRelativeAndRemoteImages: the preview loads an image beside the file
// and one served over http, and gives up on a missing download and a format it cannot decode,
// which keep their alt text.
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
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "img"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "img", "local.png"), pngOf(t, 4, 5), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "logo.svg"), []byte(`<svg xmlns="http://www.w3.org/2000/svg"/>`), 0o600); err != nil {
		t.Fatal(err)
	}
	readme := filepath.Join(root, "README.md")
	text := "# Pictures\n\n![local](img/local.png)\n\n![remote](" + server.URL + "/remote.png)\n\n![gone](" + server.URL + "/gone.png)\n\n![vector](logo.svg)\n"
	if err := os.WriteFile(readme, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	h.app.openFile(h.app.project, readme)
	h.settle()
	h.app.reduceChrome(core.SetChromeOpen(itemMarkdown, true))
	h.settle()

	s := &h.app.editor.markdown
	loaded := func() bool {
		if len(s.images) != 4 {
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

	local := s.images[filepath.Join(root, "img", "local.png")]
	if local == nil || local.failed || local.bitmap.Width != 4 || local.bitmap.Height != 5 {
		t.Fatalf("the image beside the file is %+v", local)
	}
	if over := s.images[server.URL+"/remote.png"]; over == nil || over.failed || over.bitmap.Width != 3 || over.bitmap.Height != 2 {
		t.Fatalf("the downloaded image is %+v", over)
	}
	if gone := s.images[server.URL+"/gone.png"]; gone == nil || !gone.failed {
		t.Fatalf("a failed download is %+v, want failed", gone)
	}
	if vector := s.images[filepath.Join(root, "logo.svg")]; vector == nil || !vector.failed {
		t.Fatalf("an SVG is %+v, want failed", vector)
	}
	if _, ok := h.app.markdownImageBitmap("img/local.png"); !ok {
		t.Fatal("the loaded image is not handed to the view")
	}
	if _, ok := h.app.markdownImageBitmap(server.URL + "/gone.png"); ok {
		t.Fatal("a failed image is handed to the view")
	}
	h.settle()
	for _, alt := range []string{"gone", "vector"} {
		if !h.shows(alt) {
			t.Fatalf("the alt text %q of an image that cannot be shown is missing: %v", alt, h.driver.Snapshot().Labels)
		}
	}
}

// TestMarkdownImageSourceReadsOnlyFilesAndWebAddresses: only relative paths, file URLs and
// http(s) addresses are loaded; anchors and other schemes are not.
func TestMarkdownImageSourceReadsOnlyFilesAndWebAddresses(t *testing.T) {
	document := filepath.Join("work", "README.md")
	if key, remote, ok := markdownImageSource(document, "img/a.png"); !ok || remote || key != filepath.Join("work", "img", "a.png") {
		t.Fatalf("relative = %q %v %v", key, remote, ok)
	}
	if key, remote, ok := markdownImageSource(document, "https://example.com/a.png"); !ok || !remote || key != "https://example.com/a.png" {
		t.Fatalf("https = %q %v %v", key, remote, ok)
	}
	for _, destination := range []string{"", "#top", "ftp://example.com/a.png", "data:image/png;base64,AAAA"} {
		if _, _, ok := markdownImageSource(document, destination); ok {
			t.Fatalf("%q was loaded", destination)
		}
	}
}
