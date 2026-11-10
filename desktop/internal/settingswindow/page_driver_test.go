package settingswindow

import (
	"testing"
	"time"

	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// windowDriver drives a settings window's Page headlessly and addresses controls by their
// accessible name (Hit.Label), as a user or assistive technology would.
type windowDriver struct {
	t      *testing.T
	w      *window
	driver *app.Driver
}

// openWindow opens w in a headless driver and closes it with the test.
func openWindow(t *testing.T, w *window, adjust ...func(*app.Config)) *windowDriver {
	t.Helper()
	config := w.config()
	for _, fn := range adjust {
		fn(&config)
	}
	driver, err := app.NewDriver(config, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(driver.Close)
	return &windowDriver{t: t, w: w, driver: driver}
}

// find returns the front-most control labeled label.
func (d *windowDriver) find(label string) (gfx.Hit, bool) {
	hits := d.driver.Snapshot().Hits
	for i := len(hits) - 1; i >= 0; i-- {
		if hit := hits[i]; hit.Label == label && !hit.IsLabel && !hit.Backdrop && !hit.ID.IsZero() {
			return hit, true
		}
	}
	return gfx.Hit{}, false
}

func (d *windowDriver) hit(label string) gfx.Hit {
	d.t.Helper()
	hit, ok := d.find(label)
	if !ok {
		d.t.Fatalf("no control labeled %q", label)
	}
	return hit
}

func (d *windowDriver) has(label string) bool {
	_, ok := d.find(label)
	return ok
}

func (d *windowDriver) click(label string) {
	d.t.Helper()
	d.clickHit(d.hit(label))
}

func (d *windowDriver) clickHit(hit gfx.Hit) {
	d.t.Helper()
	if err := d.driver.Click(hit.Bounds.X+hit.Bounds.Width/2, hit.Bounds.Y+hit.Bounds.Height/2); err != nil {
		d.t.Fatal(err)
	}
}

func (d *windowDriver) key(key gfx.Key) {
	d.t.Helper()
	if err := d.driver.Key(key, 0); err != nil {
		d.t.Fatal(err)
	}
}

func (d *windowDriver) typeText(value string) {
	d.t.Helper()
	if err := d.driver.Type(value); err != nil {
		d.t.Fatal(err)
	}
}

// pump paints again after background work finished or the model changed.
func (d *windowDriver) pump() {
	d.t.Helper()
	if err := d.driver.Pump(); err != nil {
		d.t.Fatal(err)
	}
}

// text reports whether a label of the frame has exactly value.
func (d *windowDriver) text(value string) bool {
	for _, label := range d.driver.Snapshot().Labels {
		if label.Value == value {
			return true
		}
	}
	return false
}

// until pumps the window until cond holds, within a bounded time. It wakes the window each
// round itself: the headless Driver binds its Invalidator after the first paint, so a request
// that finished during the first paint wakes nobody.
func (d *windowDriver) until(what string, cond func() bool) {
	d.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			d.t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
		d.w.inv.Invalidate()
		d.pump()
	}
}

// focusedLabel is the accessible name of the control with the focus.
func (d *windowDriver) focusedLabel() string {
	snapshot := d.driver.Snapshot()
	for _, hit := range snapshot.Hits {
		if hit.ID == snapshot.Focused && !hit.IsLabel && !hit.Backdrop {
			return hit.Label
		}
	}
	return ""
}
