package workbench

import (
	"bytes"
	"encoding/binary"
	"errors"
	"hash/crc32"
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// writeBackgroundPNG writes a width × height PNG named name into dir, filled with a gradient so
// the copy can be told from another image, and returns its path and bytes.
func writeBackgroundPNG(t *testing.T, dir, name string, width, height int) (string, []byte) {
	t.Helper()
	picture := image.NewNRGBA(image.Rect(0, 0, width, height))
	for y := range height {
		for x := range width {
			picture.SetNRGBA(x, y, color.NRGBA{R: uint8(x), G: uint8(y), B: 0x80, A: 0xFF})
		}
	}
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, picture); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, encoded.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	return path, encoded.Bytes()
}

// pixelBombPNG is a valid PNG header that claims a width × height truecolor image and carries no
// pixels: decoding it would allocate the whole image.
func pixelBombPNG(width, height uint32) []byte {
	var out bytes.Buffer
	out.WriteString("\x89PNG\r\n\x1a\n")
	header := make([]byte, 13)
	binary.BigEndian.PutUint32(header[0:4], width)
	binary.BigEndian.PutUint32(header[4:8], height)
	header[8], header[9] = 8, 2 // eight bits per sample, truecolor
	chunk := append([]byte("IHDR"), header...)
	binary.Write(&out, binary.BigEndian, uint32(len(header)))
	out.Write(chunk)
	binary.Write(&out, binary.BigEndian, crc32.ChecksumIEEE(chunk))
	return out.Bytes()
}

// newBackgroundHarness makes a dark Chinese window over the data folder dir, whose settings
// file the caller may have written; without one it writes the dark theme.
func newBackgroundHarness(t *testing.T, dir string) *harness {
	t.Helper()
	path := filepath.Join(dir, settingsFile)
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		if err := os.WriteFile(path, []byte(`{"theme":"dark"}`), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return newHarnessWithOptions(t, Options{
		Kernel:    &testKernel{Client: core.NewClient()},
		Store:     store.At(dir),
		Languages: []string{"zh-Hans"},
	})
}

// chooseBackground makes the picker answer path and lets the choice be checked, copied and
// decoded: one settle runs the picker and starts the decode, the next shows its result.
func (h *harness) chooseBackground(path string) {
	h.t.Helper()
	h.app.chooseBackgroundImage = func(app.OpenFileOptions) ([]string, error) { return []string{path}, nil }
	h.app.chooseBackground()
	h.settle()
	h.settle()
}

// backdropLabel is the window's background image in the last frame, if it was painted.
func (h *harness) backdropLabel() (app.Label, bool) {
	b := h.app.backdrop
	b.mu.Lock()
	id := b.id
	b.mu.Unlock()
	if id == 0 {
		return app.Label{}, false
	}
	for _, label := range h.driver.Snapshot().Labels {
		if label.BitmapID == id {
			return label, true
		}
	}
	return app.Label{}, false
}

// veilAlpha is the opacity of the ground painted over the whole window in the last frame, or
// -1 when the ground covers it opaquely or not at all.
func (h *harness) veilAlpha() float32 {
	snapshot := h.driver.Snapshot()
	window := gfx.Rect{Width: float32(snapshot.Width), Height: float32(snapshot.Height)}
	ground := h.app.colors.Ground
	for _, primitive := range snapshot.Primitives {
		c := primitive.Color
		if primitive.Kind != app.RectanglePrimitive || primitive.Bounds != window || c.Alpha >= 1 {
			continue
		}
		if near(c.Red, ground.Red) && near(c.Green, ground.Green) && near(c.Blue, ground.Blue) {
			return c.Alpha
		}
	}
	return -1
}

func near(a, b float32) bool { return math.Abs(float64(a-b)) < 0.002 }

// frontLabeled is where the front-most control named label was laid out in the last frame:
// a popover's buttons are declared after the workbench under it, whose controls may share
// their names.
func (h *harness) frontLabeled(label string) gfx.Rect {
	h.t.Helper()
	hits := h.driver.Snapshot().Hits
	for i := len(hits) - 1; i >= 0; i-- {
		if hit := hits[i]; hit.Label == label && !hit.IsLabel && !hit.Backdrop {
			return hit.Bounds
		}
	}
	h.t.Fatalf("no control named %q is shown", label)
	return gfx.Rect{}
}

// savedBackgroundSetting is the background the settings file keeps.
func (h *harness) savedBackgroundSetting() savedBackground {
	h.t.Helper()
	var saved settings
	if _, err := h.store.Load(settingsFile, &saved); err != nil {
		h.t.Fatal(err)
	}
	return saved.WorkbenchBackground
}

func TestChosenBackgroundIsCopiedAndPaintedBehindTheOpenProject(t *testing.T) {
	dir := t.TempDir()
	h := newBackgroundHarness(t, dir)
	path, original := writeBackgroundPNG(t, t.TempDir(), "sunset.png", 400, 200)

	h.chooseBackground(path)
	shown := h.app.backgroundSnapshot(h.app.language())
	if !shown.Set || shown.Name != "sunset.png" || shown.Width != 400 || shown.Height != 200 || shown.Loading || shown.Failure != "" {
		t.Fatalf("chosen background = %+v, want sunset.png decoded at 400×200", shown)
	}
	if shown.Image.Width != 400 || len(shown.Image.Pix) != 400*200*4 {
		t.Fatalf("snapshot image = %d×%d with %d bytes, want the decoded 400×200", shown.Image.Width, shown.Image.Height, len(shown.Image.Pix))
	}
	copied, err := os.ReadFile(h.store.Path(backgroundFile))
	if err != nil || !bytes.Equal(copied, original) {
		t.Fatalf("copy in the data folder = %d bytes, %v; want the chosen file's %d bytes", len(copied), err, len(original))
	}
	if saved := h.savedBackgroundSetting(); saved != (savedBackground{Name: "sunset.png"}) {
		t.Fatalf("saved background = %+v, want the name and the default strength", saved)
	}
	if _, painted := h.backdropLabel(); painted {
		t.Fatal("the welcome page painted the background image")
	}

	h.open(t.TempDir())
	label, painted := h.backdropLabel()
	if !painted {
		t.Fatal("the open project's workbench did not paint the background image")
	}
	snapshot := h.driver.Snapshot()
	window := gfx.Rect{Width: float32(snapshot.Width), Height: float32(snapshot.Height)}
	if label.Layer != 0 || label.Bounds != window {
		t.Fatalf("background image layer %d at %+v, want layer 0 over the window %+v", label.Layer, label.Bounds, window)
	}
	crop := settingswindow.CoverRegion(400, 200, window)
	if math.Abs(float64(label.BitmapWidth)-float64(crop.Width)) > 1 || math.Abs(float64(label.BitmapHeight)-float64(crop.Height)) > 1 {
		t.Fatalf("background image shows %d×%d pixels, want the cover crop %.1f×%.1f", label.BitmapWidth, label.BitmapHeight, crop.Width, crop.Height)
	}
	if alpha := h.veilAlpha(); !near(alpha, bgMedium.opacity()) {
		t.Fatalf("veil alpha = %v, want the medium strength's %v", alpha, bgMedium.opacity())
	}

	h.app.setBackgroundStrength(bgStrong)
	h.settle()
	if alpha := h.veilAlpha(); !near(alpha, bgStrong.opacity()) {
		t.Fatalf("veil alpha after choosing strong = %v, want %v", alpha, bgStrong.opacity())
	}
	if saved := h.savedBackgroundSetting(); saved != (savedBackground{Name: "sunset.png", Strength: "strong"}) {
		t.Fatalf("saved background = %+v, want sunset.png at strong", saved)
	}
}

func TestBackgroundIsRestoredAfterRestartAndRemovedWithItsCopy(t *testing.T) {
	dir := t.TempDir()
	first := newBackgroundHarness(t, dir)
	path, _ := writeBackgroundPNG(t, t.TempDir(), "forest.png", 64, 48)
	first.chooseBackground(path)
	first.app.setBackgroundStrength(bgSubtle)
	first.settle()
	// The original is gone: the background lives on in the data folder's copy.
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}

	h := newBackgroundHarness(t, dir)
	h.settle()
	shown := h.app.backgroundSnapshot(h.app.language())
	if !shown.Set || shown.Name != "forest.png" || shown.Strength != "subtle" || shown.Width != 64 || shown.Loading {
		t.Fatalf("restored background = %+v, want forest.png decoded at the subtle strength", shown)
	}
	h.open(t.TempDir())
	if _, painted := h.backdropLabel(); !painted {
		t.Fatal("the restored background is not painted")
	}
	if alpha := h.veilAlpha(); !near(alpha, bgSubtle.opacity()) {
		t.Fatalf("veil alpha = %v, want the subtle strength's %v", alpha, bgSubtle.opacity())
	}

	h.app.removeBackground()
	h.settle()
	if _, painted := h.backdropLabel(); painted {
		t.Fatal("the removed background is still painted")
	}
	if alpha := h.veilAlpha(); alpha != -1 {
		t.Fatalf("veil alpha after removing = %v, want the opaque page", alpha)
	}
	if _, err := os.Stat(h.store.Path(backgroundFile)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("copy after removing: %v, want it deleted", err)
	}
	if saved := h.savedBackgroundSetting(); saved != (savedBackground{}) {
		t.Fatalf("saved background after removing = %+v, want none", saved)
	}
	language := h.app.language()
	if status := h.app.backgroundSnapshot(language).Status; status != i18n.Shared(language, "native.noBackgroundImageSelected") {
		t.Fatalf("status after removing = %q, want that no image is selected", status)
	}
}

func TestUnusableChoiceLeavesTheBackgroundAsItWas(t *testing.T) {
	h := newBackgroundHarness(t, t.TempDir())
	path, original := writeBackgroundPNG(t, t.TempDir(), "kept.png", 32, 32)
	h.chooseBackground(path)
	language := h.app.language()
	unchanged := func(what string) {
		t.Helper()
		shown := h.app.backgroundSnapshot(language)
		if !shown.Set || shown.Name != "kept.png" || shown.Loading {
			t.Fatalf("after %s the background is %+v, want kept.png", what, shown)
		}
		copied, err := os.ReadFile(h.store.Path(backgroundFile))
		if err != nil || !bytes.Equal(copied, original) {
			t.Fatalf("after %s the copy is %d bytes, %v; want kept.png's", what, len(copied), err)
		}
	}

	others := t.TempDir()
	text := filepath.Join(others, "notes.png")
	if err := os.WriteFile(text, []byte("not an image"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.chooseBackground(text)
	unchanged("a file that is not an image")
	if want := backgroundFailureText(language, image.ErrFormat); h.app.notice != want {
		t.Fatalf("notice = %q, want %q", h.app.notice, want)
	}

	h.app.notice = ""
	h.app.chooseBackgroundImage = func(app.OpenFileOptions) ([]string, error) { return nil, app.ErrCanceled }
	h.app.chooseBackground()
	h.settle()
	unchanged("a canceled picker")
	if h.app.notice != "" {
		t.Fatalf("a canceled picker told %q", h.app.notice)
	}

	bomb := filepath.Join(others, "bomb.png")
	if err := os.WriteFile(bomb, pixelBombPNG(9000, 9000), 0o600); err != nil {
		t.Fatal(err)
	}
	h.chooseBackground(bomb)
	unchanged("an image with too many pixels")
	if want := backgroundFailureText(language, errBackgroundPixels); h.app.notice != want {
		t.Fatalf("notice = %q, want %q", h.app.notice, want)
	}

	large := filepath.Join(others, "large.png")
	if err := os.WriteFile(large, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(large, backgroundMaxBytes+1); err != nil {
		t.Fatal(err)
	}
	h.chooseBackground(large)
	unchanged("a file that is too large")
	if want := backgroundFailureText(language, errBackgroundBytes); h.app.notice != want {
		t.Fatalf("notice = %q, want %q", h.app.notice, want)
	}
}

func TestDamagedBackgroundCopyIsSwitchedOff(t *testing.T) {
	dir := t.TempDir()
	saved := `{"theme":"dark","workbenchBackground":{"name":"old.png","strength":"strong"}}`
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(saved), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, backgroundFile), []byte("damaged"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newBackgroundHarness(t, dir)
	h.settle()
	shown := h.app.backgroundSnapshot(h.app.language())
	if shown.Set || shown.Failure == "" {
		t.Fatalf("background over a damaged copy = %+v, want it off with the reason", shown)
	}
	if h.app.notice != shown.Failure {
		t.Fatalf("notice = %q, want the failure %q told once", h.app.notice, shown.Failure)
	}
	if _, err := os.Stat(filepath.Join(dir, backgroundFile)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("damaged copy: %v, want it deleted", err)
	}
	if got := h.savedBackgroundSetting(); got != (savedBackground{}) {
		t.Fatalf("saved background = %+v, want it cleared", got)
	}
}

func TestMissingBackgroundCopyShowsNoImageQuietly(t *testing.T) {
	dir := t.TempDir()
	saved := `{"theme":"dark","workbenchBackground":{"name":"gone.png"}}`
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(saved), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newBackgroundHarness(t, dir)
	h.settle()
	shown := h.app.backgroundSnapshot(h.app.language())
	if shown.Set || shown.Failure != "" || h.app.notice != "" {
		t.Fatalf("background without its copy = %+v, notice %q; want none and nothing told", shown, h.app.notice)
	}
}

func TestScaleToBGRAPremultipliesAndAveragesDown(t *testing.T) {
	offset := image.NewNRGBA(image.Rect(10, 10, 30, 20))
	for y := 10; y < 20; y++ {
		for x := 10; x < 30; x++ {
			offset.SetNRGBA(x, y, color.NRGBA{R: 200, G: 100, B: 50, A: 255})
		}
	}
	pix, width, height, err := scaleToBGRA(offset, 256)
	if err != nil || width != 20 || height != 10 {
		t.Fatalf("small image = %d×%d, %v; want its own 20×10", width, height, err)
	}
	if got := pix[:4]; !slices.Equal(got, []byte{50, 100, 200, 255}) {
		t.Fatalf("first pixel = %v, want BGRA 50 100 200 255", got)
	}

	_, width, height, err = scaleToBGRA(image.NewNRGBA(image.Rect(0, 0, 512, 100)), 256)
	if err != nil || width != 256 || height != 50 {
		t.Fatalf("wide image = %d×%d, %v; want 256×50", width, height, err)
	}

	halves := image.NewNRGBA(image.Rect(0, 0, 2, 1))
	halves.SetNRGBA(0, 0, color.NRGBA{R: 255, A: 255})
	halves.SetNRGBA(1, 0, color.NRGBA{B: 255, A: 255})
	pix, width, height, err = scaleToBGRA(halves, 1)
	if err != nil || width != 1 || height != 1 || !slices.Equal(pix, []byte{127, 0, 127, 255}) {
		t.Fatalf("red and blue to one pixel = %v at %d×%d, %v; want their average", pix, width, height, err)
	}

	translucent := image.NewNRGBA(image.Rect(0, 0, 1, 1))
	translucent.SetNRGBA(0, 0, color.NRGBA{R: 255, A: 128})
	pix, _, _, err = scaleToBGRA(translucent, 1)
	if err != nil || !slices.Equal(pix, []byte{0, 0, 128, 128}) {
		t.Fatalf("half-transparent red = %v, %v; want premultiplied 0 0 128 128", pix, err)
	}

	if _, _, _, err := scaleToBGRA(image.NewNRGBA(image.Rectangle{}), 256); !errors.Is(err, image.ErrFormat) {
		t.Fatalf("empty image: %v, want image.ErrFormat", err)
	}
}

func TestBackgroundLimitsAreCheckedBeforeDecoding(t *testing.T) {
	if err := checkBackgroundHeader(pixelBombPNG(9000, 9000)); !errors.Is(err, errBackgroundPixels) {
		t.Fatalf("header claiming 9000×9000: %v, want errBackgroundPixels", err)
	}
	if err := checkBackgroundHeader(pixelBombPNG(4000, 3000)); err != nil {
		t.Fatalf("header claiming 4000×3000: %v, want it accepted", err)
	}
	large := filepath.Join(t.TempDir(), "large.png")
	if err := os.WriteFile(large, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(large, backgroundMaxBytes+1); err != nil {
		t.Fatal(err)
	}
	if _, err := readBackgroundFile(large); !errors.Is(err, errBackgroundBytes) {
		t.Fatalf("file one byte over the limit: %v, want errBackgroundBytes", err)
	}
}

func TestStripeBackgroundButtonOpensThePopoverThatChoosesTheImage(t *testing.T) {
	h := newBackgroundHarness(t, t.TempDir())
	h.open(t.TempDir())
	language := h.app.language()
	button := center(h.button(itemBackground))
	if err := h.driver.Click(button.X, button.Y); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if !h.app.backdropOpen {
		t.Fatal("the background button did not open its popover")
	}
	if !h.shows(i18n.Shared(language, "native.noBackgroundImageSelected")) {
		t.Fatal("the popover does not say that no image is selected")
	}
	strong := i18n.Shared(language, "desktop.workbenchBackground.strong")
	if slices.ContainsFunc(h.driver.Snapshot().Hits, func(hit gfx.Hit) bool { return hit.Label == strong && !hit.IsLabel }) {
		t.Fatal("the popover offers a visibility choice without an image")
	}

	path, _ := writeBackgroundPNG(t, t.TempDir(), "lake.png", 40, 30)
	h.app.chooseBackgroundImage = func(app.OpenFileOptions) ([]string, error) { return []string{path}, nil }
	choose := center(h.frontLabeled(i18n.Shared(language, "native.chooseImage")))
	if err := h.driver.Click(choose.X, choose.Y); err != nil {
		t.Fatal(err)
	}
	h.settle()
	h.settle()
	h.settle()
	if shown := h.app.backgroundSnapshot(language); !shown.Set || shown.Name != "lake.png" || shown.Loading {
		t.Fatalf("background chosen in the popover = %+v, want lake.png", shown)
	}
	if _, painted := h.backdropLabel(); !painted {
		t.Fatal("the image chosen in the popover is not painted")
	}
	pick := center(h.frontLabeled(strong))
	if err := h.driver.Click(pick.X, pick.Y); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if saved := h.savedBackgroundSetting(); saved.Strength != bgStrong.saved() {
		t.Fatalf("strength saved from the popover = %q, want %q", saved.Strength, bgStrong.saved())
	}

	closeButton := center(h.frontLabeled(i18n.Shared(language, "desktop.workbenchBackground.close")))
	if err := h.driver.Click(closeButton.X, closeButton.Y); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if h.app.backdropOpen {
		t.Fatal("the close button left the popover open")
	}
}

func TestBackgroundSavedAsAnOpenToolWindowTakesNoSlot(t *testing.T) {
	c := newChromeState()
	layout := defaultLayout()
	layout.Open = append(layout.Open, itemBackground)
	c.apply(layout)
	index := c.index[itemBackground]
	if c.isOpen(index) {
		t.Fatal("the background button is open as a tool window")
	}
	if slices.Contains(c.open[:], index) {
		t.Fatalf("open slots = %v, want none holding the background button", c.open)
	}
}
