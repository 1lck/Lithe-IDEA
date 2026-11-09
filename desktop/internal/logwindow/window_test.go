package logwindow

import (
	"sync/atomic"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/flex"
)

func TestOpenWindowRepaintsWhenLanguageAndAppearanceChange(t *testing.T) {
	fixture := newExportFixture(t)
	var current atomic.Pointer[i18n.Messages]
	var dark atomic.Bool
	current.Store(i18n.For(i18n.English))
	controller := NewController(WindowOptions{Text: current.Load, Dark: dark.Load})
	w := &window{ctrl: controller, model: fixture.model, filterRevision: -1, anchors: map[menuKind]flex.Box{}}
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
