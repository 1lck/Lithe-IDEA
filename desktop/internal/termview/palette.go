package termview

import (
	"math"

	"github.com/1lck/Lithe-IDEA/desktop/internal/term"
	"github.com/vivaui/viva/gfx"
)

// The 16 ANSI colors of the terminal, one table per look. They are the colors the macOS
// terminal draws with, so the same program looks the same on both clients.
var (
	darkANSI = ansiTable([16]uint32{
		0x000000, 0x990001, 0x00A603, 0x999900, 0x5594FA, 0xB200B2, 0x00A5B2, 0xBFBFBF,
		0x8A898A, 0xE50001, 0x00D800, 0xE5E500, 0x3399FF, 0xE500E5, 0x00E5E5, 0xE5E5E5,
	})
	lightANSI = ansiTable([16]uint32{
		0x1F2328, 0xCF222E, 0x1A7F37, 0x9A6700, 0x0969DA, 0x8250DF, 0x0A6670, 0x59636E,
		0x59636E, 0xA40E26, 0x116329, 0x7D4E00, 0x0550AE, 0x6639BA, 0x055B63, 0x3D444D,
	})
)

// ansiTable splits 0xRRGGBB values into the channels term.Resolve reads, so the tables above
// can be written the way a design tool shows them.
func ansiTable(colors [16]uint32) [16][3]uint8 {
	var table [16][3]uint8
	for index, color := range colors {
		table[index] = [3]uint8{uint8(color >> 16), uint8(color >> 8), uint8(color)}
	}
	return table
}

// newPalette resolves a look into the colors rows are prepared with. epoch must differ from
// the epoch of every palette built before it, so a cached row is never reused in new colors.
func newPalette(look Look, epoch uint32) palette {
	pal := palette{
		dark:      look.Dark,
		terminal:  look.Background,
		termFG:    look.Foreground,
		cursor:    look.Cursor,
		selection: look.Selection,
		epoch:     epoch,
	}
	if look.Dark {
		pal.ansi = darkANSI
	} else {
		pal.ansi = lightANSI
	}
	if look.Native != nil {
		background := rgb8(look.Background)
		for index, native := range look.Native {
			if native.Set && contrastRatio(native.RGB, background) >= nativeContrast {
				pal.ansi[index] = native.RGB
			}
		}
	}
	return pal
}

// nativeContrast is the least contrast, by WCAG 2's ratio, a color of the system terminal's
// profile needs against the background to replace the built-in one: the AA level for text.
const nativeContrast = 4.5

// contrastRatio is WCAG 2's contrast ratio of two sRGB colors, from 1 to 21.
func contrastRatio(a, b [3]uint8) float64 {
	la, lb := relativeLuminance(a), relativeLuminance(b)
	if la < lb {
		la, lb = lb, la
	}
	return (la + 0.05) / (lb + 0.05)
}

// relativeLuminance is WCAG 2's relative luminance of an sRGB color.
func relativeLuminance(color [3]uint8) float64 {
	linear := func(channel uint8) float64 {
		value := float64(channel) / 255
		if value <= 0.04045 {
			return value / 12.92
		}
		return math.Pow((value+0.055)/1.055, 2.4)
	}
	return 0.2126*linear(color[0]) + 0.7152*linear(color[1]) + 0.0722*linear(color[2])
}

// termColor resolves a terminal color; fallback stands in for the default.
func (pal *palette) termColor(color term.Color, fallback gfx.Color) gfx.Color {
	switch color.Kind() {
	case term.PaletteColor:
		red, green, blue := term.Resolve(color.Index(), &pal.ansi)
		return gfx.RGB(red, green, blue)
	case term.TrueColor:
		return gfx.RGB(color.Components())
	}
	return fallback
}

// brighten maps one of the eight base palette colors to its bright variant. The
// 256-color cube and true color are exactly what the program asked for and are
// left alone. Programs mark a directory, an address or a heading with bold and one of the
// base colors (ls writes 01;34), and terminals have long drawn that in the bright variant.
func brighten(color term.Color) term.Color {
	if color.Kind() == term.PaletteColor && color.Index() < 8 {
		return term.Indexed(color.Index() + 8)
	}
	return color
}

// withAlpha is the color with its alpha multiplied by alpha, so a color that is already
// translucent stays proportionally so.
func withAlpha(color gfx.Color, alpha float32) gfx.Color {
	color.Alpha *= alpha
	return color
}

// rgb8 is the 8-bit channels of a color, the inverse of ui.RGB: each channel is clamped to
// 0 to 1 and rounded to the nearest of 255 steps.
func rgb8(color gfx.Color) [3]uint8 {
	channel := func(value float32) uint8 { return uint8(min(max(value, 0), 1)*255 + 0.5) }
	return [3]uint8{channel(color.Red), channel(color.Green), channel(color.Blue)}
}

// applyLook gives the view the palette of look when it differs from the one in use. A new
// palette starts a new epoch, so every prepared row is built again in the new colors, and
// the screen is told the default colors it answers a program's color query with (OSC 10
// and 11): programs such as Codex or Helix pick a light or dark theme from that answer.
func (v *View) applyLook(look Look) {
	if v.hasLook && look == v.look {
		return
	}
	v.pal = newPalette(look, v.pal.epoch+1)
	v.screen.SetDefaultColors(rgb8(look.Foreground), rgb8(look.Background))
	v.look, v.hasLook = look, true
}
