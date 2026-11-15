// Package windowcontrols styles the minimize, maximize and close buttons that Viva draws in
// a custom title bar on Windows and Linux (macOS keeps its own traffic lights).
//
// Without a style Viva takes the glyph color from the window's clear color, which is dark
// by default and is not the color of the title bar the buttons stand on: in the light look
// the glyphs were white on a light title bar and could not be seen. Every window of the
// client therefore styles its buttons from the ink of its own title bar.
package windowcontrols

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

const (
	// hoverAlpha and pressedAlpha are the opacity of the ink behind a button under the
	// pointer and while it is held down: the tints Viva itself uses, taken from the
	// title bar's ink instead of the clear color.
	hoverAlpha   = 0.10
	pressedAlpha = 0.18
)

// Style is the buttons' style on a title bar whose text is ink: the glyphs in ink, the
// hover and press tints ink at low opacity, and the names in the user's language. The
// close button keeps Viva's red. A zero ink (a window that has not painted yet) leaves
// the colors to Viva.
func Style(ink gfx.Color, text *i18n.Messages) app.WindowControlsStyle {
	var style app.WindowControlsStyle
	if ink != (gfx.Color{}) {
		style.Foreground = ink
		style.Hover = ink.WithAlpha(hoverAlpha)
		style.Pressed = ink.WithAlpha(pressedAlpha)
	}
	if text != nil {
		style.Minimize = text.Window.Minimize
		style.Maximize = text.Window.Maximize
		style.Restore = text.Window.Restore
		style.CloseName = text.Window.Close
	}
	return style
}
