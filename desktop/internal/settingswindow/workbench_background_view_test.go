package settingswindow

import (
	"math"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

func TestCoverRegionCutsTheImageToTheAreaAroundItsMiddle(t *testing.T) {
	area := gfx.Rect{X: 5, Y: 7, Width: 160, Height: 100}
	wide := CoverRegion(400, 200, area)
	if math.Abs(float64(wide.X-40)) > 0.01 || wide.Y != 0 || math.Abs(float64(wide.Width-320)) > 0.01 || wide.Height != 200 {
		t.Fatalf("wide image = %+v, want 320×200 at x 40", wide)
	}
	tall := CoverRegion(100, 400, area)
	if tall.X != 0 || tall.Width != 100 || math.Abs(float64(tall.Height-62.5)) > 0.01 || math.Abs(float64(tall.Y-168.75)) > 0.01 {
		t.Fatalf("tall image = %+v, want 100×62.5 at y 168.75", tall)
	}
	whole := gfx.Rect{Width: 400, Height: 200}
	if got := CoverRegion(400, 200, gfx.Rect{}); got != whole {
		t.Fatalf("empty area = %+v, want the whole image %+v", got, whole)
	}
	if got := CoverRegion(0, 200, area); got != (gfx.Rect{Height: 200}) {
		t.Fatalf("empty image = %+v, want it unchanged", got)
	}
}

func TestAppearanceBackgroundRowsHandChoicesToTheWorkbench(t *testing.T) {
	state := WorkbenchBackground{Status: i18n.Shared(i18n.English, "native.noBackgroundImageSelected")}
	var chosen, removed int
	var strengths []string
	w := newWindow(NewController(Options{
		WorkbenchBackground:            func(i18n.Language) WorkbenchBackground { return state },
		ChooseWorkbenchBackground:      func() { chosen++ },
		RemoveWorkbenchBackground:      func() { removed++ },
		SetWorkbenchBackgroundStrength: func(value string) { strengths = append(strengths, value) },
	}), Values{Language: "en"})
	d := openWindow(t, w)

	if !d.text("No background image selected") {
		t.Fatal("the card does not say that no image is selected")
	}
	if d.has("Remove") {
		t.Fatal("the card offers to remove an image that is not there")
	}
	if d.has("Strong") {
		t.Fatal("the card offers a visibility choice without an image")
	}
	d.click("Choose Image…")
	if chosen != 1 {
		t.Fatalf("choose was handed over %d times, want once", chosen)
	}

	pix := slices.Repeat([]byte{0x30, 0x60, 0x90, 0xFF}, 4*2)
	state = WorkbenchBackground{
		Set: true, Name: "sunset.png", Width: 4, Height: 2,
		Status: "sunset.png, 4×2",
		Image:  gfx.Bitmap{Pix: pix, Width: 4, Height: 2, Stride: 16, ID: 1 << 62},
	}
	w.inv.Invalidate()
	d.pump()
	if !d.text("sunset.png, 4×2") {
		t.Fatal("the card does not name the image in use")
	}
	if !d.has("Strong") {
		t.Fatal("the card offers no visibility choice with an image")
	}
	d.click("Remove")
	if removed != 1 {
		t.Fatalf("remove was handed over %d times, want once", removed)
	}
	d.click("Strong")
	if !slices.Equal(strengths, []string{"strong"}) {
		t.Fatalf("strengths handed over = %q, want strong once", strengths)
	}
}
