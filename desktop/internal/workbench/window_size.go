package workbench

import (
	"math"

	"github.com/vivaui/viva/gfx"
)

const (
	// Default and smallest workbench window dimensions in logical pixels.
	defaultWindowWidth  = 1280
	defaultWindowHeight = 800
	minWindowWidth      = 900
	minWindowHeight     = 600
)

// windowGeometry is the floating content size (in logical pixels) and maximized state of the
// workbench window. When maximized is true, width and height stay the restored floating size.
type windowGeometry struct {
	width     int
	height    int
	maximized bool
}

// openingWindowGeometry resolves the size and maximized state a workbench window opens with
// from saved settings: missing or non-positive dimensions fall back to the default size, and
// dimensions below the minimum are raised to minWindowWidth × minWindowHeight.
func openingWindowGeometry(saved settings) windowGeometry {
	width, height := saved.WindowWidth, saved.WindowHeight
	if width <= 0 || height <= 0 {
		width, height = defaultWindowWidth, defaultWindowHeight
	}
	return windowGeometry{
		width:     max(width, minWindowWidth),
		height:    max(height, minWindowHeight),
		maximized: saved.WindowMaximized,
	}
}

// windowGeometryState tracks the live geometry of one workbench window across its project
// tabs. Live resize and maximize callbacks only update current in memory; nothing is written
// per frame. Changes from saved are persisted when settings are saved or when the window
// closes.
type windowGeometryState struct {
	current   windowGeometry
	saved     windowGeometry
	persisted bool
}

func newWindowGeometryState(saved settings) windowGeometryState {
	initial := openingWindowGeometry(saved)
	return windowGeometryState{
		current:   initial,
		saved:     initial,
		persisted: (saved.WindowWidth > 0 && saved.WindowHeight > 0) || saved.WindowMaximized,
	}
}

// framed records the floating content size reported by Viva's OnFrameChange. Viva suppresses
// frame reports while the window is fullscreen, maximized, or minimized.
func (g *windowGeometryState) framed(frame gfx.Rect) {
	width := int(math.Round(float64(frame.Width)))
	height := int(math.Round(float64(frame.Height)))
	if width <= 0 || height <= 0 {
		return
	}
	g.current.width = width
	g.current.height = height
}

// setMaximized records the maximized state reported by Viva's OnMaximize.
func (g *windowGeometryState) setMaximized(maximized bool) {
	g.current.maximized = maximized
}

// applyWindowGeometry writes the window's current geometry into dst when the user changed it
// since the last save or a geometry was already persisted.
func (s *windowSessions) applyWindowGeometry(dst *settings) (windowGeometry, bool) {
	if s == nil {
		return windowGeometry{}, false
	}
	if !s.geometry.persisted && s.geometry.current == s.geometry.saved {
		return windowGeometry{}, false
	}
	geo := s.geometry.current
	dst.WindowWidth = geo.width
	dst.WindowHeight = geo.height
	dst.WindowMaximized = geo.maximized
	return geo, true
}

// noteSavedWindowGeometry records that geo was persisted and mirrors it onto every project tab
// so no tab writes an older geometry back later.
func (s *windowSessions) noteSavedWindowGeometry(geo windowGeometry) {
	if s == nil {
		return
	}
	s.geometry.saved = geo
	s.geometry.persisted = true
	for _, tab := range s.everyOne() {
		tab.settings.WindowWidth = geo.width
		tab.settings.WindowHeight = geo.height
		tab.settings.WindowMaximized = geo.maximized
	}
}

// saveWindowGeometry persists the window's final size and maximized state when they changed
// since the last save.
func (s *windowSessions) saveWindowGeometry() {
	if s == nil || s.geometry.current == s.geometry.saved {
		return
	}
	target := s.active
	if target == nil && len(s.list) > 0 {
		target = s.list[0]
	}
	if target == nil {
		return
	}
	target.saveSettings()
}
