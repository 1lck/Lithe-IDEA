package settingswindow

import (
	"testing"
)

// TestWindowOpensAtTheSizeTheUserLastGaveIt covers where a new window takes its size: the one
// kept from the last window, the default 1270×700 when none is kept or the kept one is
// unusable, and never under the smallest.
func TestWindowOpensAtTheSizeTheUserLastGaveIt(t *testing.T) {
	for _, test := range []struct {
		name          string
		width, height int
		want          windowSize
	}{
		{"none kept", 0, 0, windowSize{1270, 700}},
		{"kept", 1100, 760, windowSize{1100, 760}},
		{"one side missing", 1100, 0, windowSize{windowWidth, windowHeight}},
		{"negative", -1, 760, windowSize{windowWidth, windowHeight}},
		{"under the smallest", 640, 480, windowSize{windowMinWidth, windowMinHeight}},
	} {
		t.Run(test.name, func(t *testing.T) {
			w := newWindow(NewController(Options{}), Values{WindowWidth: test.width, WindowHeight: test.height})
			d := openWindow(t, w)
			shot := d.driver.Snapshot()
			if shot.Width != test.want.width || shot.Height != test.want.height {
				t.Fatalf("window opened at %dx%d, want %dx%d", shot.Width, shot.Height, test.want.width, test.want.height)
			}
		})
	}
}

// TestClosingKeepsTheSizeTheUserGaveTheWindow covers the report a closing window makes: the
// last size of a live resize, once, and nothing when the window was only moved or ends at the
// size it opened at.
func TestClosingKeepsTheSizeTheUserGaveTheWindow(t *testing.T) {
	type report struct{ width, height, count int }
	open := func(t *testing.T, current Values) (*windowDriver, *report) {
		t.Helper()
		got := &report{}
		c := NewController(Options{WindowResized: func(width, height int) {
			got.width, got.height = width, height
			got.count++
		}})
		return openWindow(t, newWindow(c, current)), got
	}

	t.Run("resized", func(t *testing.T) {
		d, got := open(t, Values{})
		for _, size := range [][2]int{{1000, 690}, {1100, 760}, {1180, 820}} {
			if err := d.driver.Resize(size[0], size[1]); err != nil {
				t.Fatal(err)
			}
		}
		if got.count != 0 {
			t.Fatalf("the window reported its size %d times while it was being resized", got.count)
		}
		d.driver.Close()
		if got.count != 1 || got.width != 1180 || got.height != 820 {
			t.Fatalf("closing reported %+v, want 1180x820 once", *got)
		}
	})
	t.Run("moved only", func(t *testing.T) {
		d, got := open(t, Values{WindowWidth: 1100, WindowHeight: 760})
		if err := d.driver.MoveWindow(40, 60); err != nil {
			t.Fatal(err)
		}
		d.driver.Close()
		if got.count != 0 {
			t.Fatalf("a window that was only moved reported its size: %+v", *got)
		}
	})
	t.Run("back to where it opened", func(t *testing.T) {
		d, got := open(t, Values{WindowWidth: 1100, WindowHeight: 760})
		if err := d.driver.Resize(1000, 700); err != nil {
			t.Fatal(err)
		}
		if err := d.driver.Resize(1100, 760); err != nil {
			t.Fatal(err)
		}
		d.driver.Close()
		if got.count != 0 {
			t.Fatalf("a window back at the size it opened at reported it: %+v", *got)
		}
	})
}

// TestResizedWindowGivesTheSizeBeforeTheWindowCloses covers the owner that closes the window
// as it closes itself: it reads the size the user gave the open window before the close,
// because the window's own report comes after it.
func TestResizedWindowGivesTheSizeBeforeTheWindowCloses(t *testing.T) {
	c := NewController(Options{})
	if _, _, ok := c.ResizedWindow(); ok {
		t.Fatal("a controller with no window reported a size")
	}
	w := newWindow(c, Values{})
	d := openWindow(t, w)
	c.mu.Lock()
	c.current = w
	c.mu.Unlock()
	if _, _, ok := c.ResizedWindow(); ok {
		t.Fatal("a window at the size it opened at reported a size")
	}
	if err := d.driver.Resize(1150, 780); err != nil {
		t.Fatal(err)
	}
	if width, height, ok := c.ResizedWindow(); !ok || width != 1150 || height != 780 {
		t.Fatalf("ResizedWindow() = %d, %d, %v, want 1150, 780, true", width, height, ok)
	}
	d.driver.Close()
	if _, _, ok := c.ResizedWindow(); ok {
		t.Fatal("a closed window still reported a size")
	}
}
