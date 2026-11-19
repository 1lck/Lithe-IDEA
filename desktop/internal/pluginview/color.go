package pluginview

import (
	"strconv"

	"github.com/vivaui/viva/gfx"
)

// Palette is the host theme a view is drawn in. Every $token of
// plugin-ui.schema.json#/$defs/color resolves to one of these colors, so a view
// follows the host's light and dark themes without knowing either.
type Palette struct {
	// Dark picks the dark side of a {light, dark} color pair.
	Dark          bool
	Text          gfx.Color
	TextSecondary gfx.Color
	TextMuted     gfx.Color
	Accent        gfx.Color
	Success       gfx.Color
	Warning       gfx.Color
	Error         gfx.Color
	Surface       gfx.Color
	Background    gfx.Color
	Sidebar       gfx.Color
	Line          gfx.Color
	Hover         gfx.Color
	Selection     gfx.Color
	Badge         gfx.Color
	// Popover and PopoverText draw the host's own canvas tooltip bubble.
	Popover     gfx.Color
	PopoverText gfx.Color
}

// token is the palette color a $token names; ok is false for a name the schema does not list.
func (p *Palette) token(name string) (gfx.Color, bool) {
	switch name {
	case "text":
		return p.Text, true
	case "textSecondary":
		return p.TextSecondary, true
	case "textMuted":
		return p.TextMuted, true
	case "accent":
		return p.Accent, true
	case "success":
		return p.Success, true
	case "warning":
		return p.Warning, true
	case "error":
		return p.Error, true
	case "surface":
		return p.Surface, true
	case "background":
		return p.Background, true
	case "sidebar":
		return p.Sidebar, true
	case "line":
		return p.Line, true
	case "hover":
		return p.Hover, true
	case "selection":
		return p.Selection, true
	case "badge":
		return p.Badge, true
	}
	return gfx.Color{}, false
}

// Tone is the text color of a host-control tone ("secondary", "muted", "accent",
// "success", "warning", "error"); fallback is used for no tone.
func (p *Palette) Tone(tone string, fallback gfx.Color) gfx.Color {
	switch tone {
	case "secondary":
		return p.TextSecondary
	case "muted":
		return p.TextMuted
	case "accent":
		return p.Accent
	case "success":
		return p.Success
	case "warning":
		return p.Warning
	case "error":
		return p.Error
	}
	return fallback
}

// plain resolves #RRGGBB, #RRGGBBAA or a $token. ok is false for anything else,
// which Core refuses, so the caller draws nothing rather than a guessed color.
func (p *Palette) plain(value string) (gfx.Color, bool) {
	if len(value) > 1 && value[0] == '$' {
		return p.token(value[1:])
	}
	if len(value) != 7 && len(value) != 9 || value[0] != '#' {
		return gfx.Color{}, false
	}
	channels, err := strconv.ParseUint(value[1:], 16, 32)
	if err != nil {
		return gfx.Color{}, false
	}
	alpha := uint64(255)
	if len(value) == 9 {
		alpha = channels & 0xff
		channels >>= 8
	}
	return gfx.RGBA(uint8(channels>>16), uint8(channels>>8), uint8(channels), float32(alpha)/255), true
}

// Solid is the single color of c: a plain color, the side of a pair that matches
// the theme, or the first stop of a gradient where only one color can be drawn
// (a stroke, text). ok is false for a missing or unreadable color.
func (p *Palette) Solid(c *Color) (gfx.Color, bool) {
	switch {
	case c == nil:
		return gfx.Color{}, false
	case len(c.Stops) > 0:
		return p.plain(c.Stops[0].Color)
	case c.Light != "" || c.Dark != "":
		if p.Dark {
			return p.plain(c.Dark)
		}
		return p.plain(c.Light)
	}
	return p.plain(c.Plain)
}

// Stops are the resolved stops of a gradient color, nil when c is not one.
func (p *Palette) Stops(c *Color, opacity float32) []gfx.GradientStop {
	if c == nil || len(c.Stops) < 2 {
		return nil
	}
	stops := make([]gfx.GradientStop, 0, len(c.Stops))
	for _, stop := range c.Stops {
		color, ok := p.plain(stop.Color)
		if !ok {
			return nil
		}
		stops = append(stops, gfx.Stop(float32(stop.At), fade(color, opacity)))
	}
	return stops
}

// fade multiplies a color's alpha by opacity.
func fade(color gfx.Color, opacity float32) gfx.Color {
	if opacity >= 1 {
		return color
	}
	return color.WithAlpha(color.Alpha * max(opacity, 0))
}
