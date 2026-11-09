// Package sheet supplies the modal surface used by full-sized workbench sheets.
package sheet

import (
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// Options describe the surface and its modal focus ownership. Width and Height
// are maximum logical sizes; the sheet shrinks to a smaller parent window.
type Options struct {
	Width, Height                float32
	Background                   gfx.Color
	Scope, Dismiss, InitialFocus gfx.ID
	DismissLabel                 string
}

const cornerRadius = 12

// PaintLeadingBackground fills a full-height leading column while preserving
// only the sheet's upper-left corner. Its lower edge meets the footer squarely.
func PaintLeadingBackground(d *ui.DrawContext, color gfx.Color) {
	r := d.Rect
	radius := min(cornerRadius, r.Width/2, r.Height/2)
	d.Canvas.Rounded(r, radius, color)
	d.Canvas.Fill(gfx.Rect{X: r.X + radius, Y: r.Y, Width: r.Width - radius, Height: r.Height}, color)
	d.Canvas.Fill(gfx.Rect{X: r.X, Y: r.Y + r.Height - radius, Width: r.Width, Height: radius}, color)
}

// PaintFooterBackground keeps the lower corners rounded and the upper edge
// square where it meets the sheet body.
func PaintFooterBackground(d *ui.DrawContext, color gfx.Color) {
	r := d.Rect
	radius := min(cornerRadius, r.Width/2, r.Height/2)
	d.Canvas.Rounded(r, radius, color)
	d.Canvas.Fill(gfx.Rect{X: r.X, Y: r.Y, Width: r.Width, Height: r.Height - radius}, color)
}

// Draw paints a centered sheet above its blocked parent. The caller declares
// the surface's contents and owns its actions. Focus and Escape stay with the
// sheet until it closes; a deeper modal can take ownership normally.
func Draw(f *ui.Frame, options Options, contents func()) bool {
	bounds := f.Bounds()
	width := min(options.Width, max(bounds.Width-32, 1))
	height := min(options.Height, max(bounds.Height-32, 1))
	f.Popup().At(0, 0).Fill().
		Draw(func(d *ui.DrawContext) { d.Canvas.PushFocusScope(options.Scope) }).
		DrawOver(func(d *ui.DrawContext) {
			d.Canvas.TrapFocus(options.Scope)
			d.Canvas.SetInitialFocus(options.InitialFocus)
			d.Canvas.SetEscapeTarget(options.Dismiss)
			d.Canvas.PopFocusScope()
		}).Children(func() {
		f.Stack().Fill().Center().Children(func() {
			f.Row().Fill().Background(gfx.RGB24(0).WithAlpha(0.45)).
				HitWith(options.Dismiss, options.DismissLabel, gfx.HitOptions{Role: gfx.RoleButton, SkipFocus: true, Backdrop: true})
			f.Column().Width(width).Height(height).Self(ui.Center).Radius(cornerRadius).Clip().Background(options.Background).
				Draw(func(d *ui.DrawContext) { d.Canvas.Block(d.Rect) }).Children(contents)
		})
	})
	return f.Canvas().Clicked(options.Dismiss)
}
