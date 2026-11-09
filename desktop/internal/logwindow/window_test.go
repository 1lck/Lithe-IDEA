package logwindow

import (
	"sync/atomic"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

func TestOpenWindowRepaintsWhenLanguageAndAppearanceChange(t *testing.T) {
	fixture := newExportFixture(t)
	var current atomic.Pointer[i18n.Messages]
	var dark atomic.Bool
	current.Store(i18n.For(i18n.English))
	controller := NewController(WindowOptions{Text: current.Load, Dark: dark.Load})
	w := &window{ctrl: controller, model: fixture.model, filterRevision: -1, anchors: map[menuKind]ui.Box{}}
	controller.current = w
	driver, err := app.NewDriver(w.config(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(driver.Close)
	current.Store(i18n.For(i18n.Chinese))
	dark.Store(true)
	controller.Invalidate()
	if err := driver.Pump(); err != nil {
		t.Fatal(err)
	}
	if w.text != i18n.For(i18n.Chinese) {
		t.Fatal("the open log window did not repaint with the new language")
	}
	if !w.pal.dark {
		t.Fatal("the open log window did not repaint with the new appearance")
	}
}

// TestWindowControlsFollowTheTitleBar covers the buttons Viva draws in the custom title bar on
// Windows and Linux: unstyled, they took Viva's ink for its default dark clear color and were
// white on the light title bar. They must take the ink of the title bar and the language of
// the window, and follow both when they change.
func TestWindowControlsFollowTheTitleBar(t *testing.T) {
	fixture := newExportFixture(t)
	var current atomic.Pointer[i18n.Messages]
	var dark atomic.Bool
	current.Store(i18n.For(i18n.English))
	controller := NewController(WindowOptions{Text: current.Load, Dark: dark.Load})
	w := &window{ctrl: controller, model: fixture.model, filterRevision: -1, anchors: map[menuKind]ui.Box{}}
	controller.current = w
	config := w.config()
	if config.WindowControls == nil {
		t.Fatal("the log window leaves its window buttons to Viva's default ink")
	}
	driver, err := app.NewDriver(config, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(driver.Close)
	check := func(look string, ink gfx.Color, minimize string) {
		t.Helper()
		style := config.WindowControls()
		if style.Foreground != ink || style.Minimize != minimize {
			t.Fatalf("%s look: glyph color %v and minimize name %q, want %v and %q", look, style.Foreground, style.Minimize, ink, minimize)
		}
	}
	check("light", lightPalette().tx, "Minimize")
	current.Store(i18n.For(i18n.Chinese))
	dark.Store(true)
	controller.Invalidate()
	if err := driver.Pump(); err != nil {
		t.Fatal(err)
	}
	check("dark", darkPalette().tx, "最小化")
}
