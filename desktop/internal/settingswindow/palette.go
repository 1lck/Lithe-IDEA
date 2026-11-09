package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
)

// palette is the settings window's own colors. The window keeps them apart from the
// workbench theme for the same reason the log window does: it is a separate native
// window that must read the same whatever the main window shows, and its values are the
// ones the log window and the macOS client use, so the three look like one product.
type palette struct {
	// window is the content area and the footer; sidebar is the column of pages beside it
	// and titleBar the strip the system's window buttons sit in.
	window, sidebar, titleBar gfx.Color
	// card is the fill of a settings card.
	card gfx.Color
	// line separates the regions and outlines a card; border outlines a control.
	line, border gfx.Color
	// hover is a row or a quiet button under the pointer.
	hover gfx.Color
	// highlight is the background of selected text in a field.
	highlight gfx.Color
	// selection is the selected page while the list has the keyboard focus and
	// selectionIdle while it has not.
	selection, selectionIdle gfx.Color
	// text is ordinary text, muted secondary text and subtle the hints and inactive icons.
	text, muted, subtle gfx.Color
	// accent is the primary button and the focus ring; danger an error.
	accent, danger gfx.Color
	// white is the glyph on a colored tile and the text on the primary button.
	white gfx.Color
}

func lightPalette() palette {
	return palette{
		window: gfx.RGB24(0xffffff), sidebar: gfx.RGB24(0xececee), titleBar: gfx.RGB24(0xe8ebef),
		card: gfx.RGB24(0xf7f8fa),
		line: gfx.RGB24(0xd8dae0), border: gfx.RGB24(0xc9ccd6),
		hover:     gfx.RGB24(0xf2f3f5),
		highlight: gfx.RGB24(0xddf4ff),
		selection: gfx.RGB24(0xD0DFFE), selectionIdle: gfx.RGB24(0xE9EAEE),
		text: gfx.RGB24(0x1f2328), muted: gfx.RGB24(0x59636e), subtle: gfx.RGB24(0x8c959f),
		accent: gfx.RGB24(0x3871e1), danger: gfx.RGB24(0xc72d2d),
		white: gfx.RGB24(0xffffff),
	}
}

func darkPalette() palette {
	return palette{
		window: gfx.RGB24(0x191a1c), sidebar: gfx.RGB24(0x232427), titleBar: gfx.RGB24(0x28292c),
		card: gfx.RGB24(0x2b2d30),
		line: gfx.RGB24(0x2e3036), border: gfx.RGB24(0x4e5157),
		hover:     gfx.RGB24(0x303136),
		highlight: gfx.RGB24(0x1f2a3a),
		selection: gfx.RGB24(0x2A4371), selectionIdle: gfx.RGB24(0x33353B),
		text: gfx.RGB24(0xdfe1e5), muted: gfx.RGB24(0x8c8d8e), subtle: gfx.RGB24(0x727375),
		accent: gfx.RGB24(0x3871e1), danger: gfx.RGB24(0xea5454),
		white: gfx.RGB24(0xffffff),
	}
}

// paletteFor returns the palette of the light or the dark look.
func paletteFor(dark bool) palette {
	if dark {
		return darkPalette()
	}
	return lightPalette()
}

// selectionColor is the fill of the selected page: the accent tint while the list of
// pages has the keyboard focus and the neutral one otherwise, as the macOS client's
// lists draw their selection.
func (p palette) selectionColor(focused bool) gfx.Color {
	if focused {
		return p.selection
	}
	return p.selectionIdle
}

// windowTheme maps the palette onto the theme the Viva controls paint with, so a field, a
// select, a segmented control or a button in the window takes the settings window's
// colors in the compact density the other tool windows use.
func windowTheme(dark bool, p palette) gfx.Theme {
	theme := gfx.LightTheme()
	if dark {
		theme = gfx.DarkTheme()
	}
	theme.Metrics = theme.Metrics.WithDensity(gfx.DensityCompact)
	theme.Background, theme.Foreground = p.window, p.text
	theme.Card, theme.CardForeground, theme.CardElevated = p.card, p.text, p.window
	theme.Popover, theme.PopoverForeground = p.window, p.text
	theme.Muted, theme.MutedForeground = p.hover, p.muted
	theme.Border, theme.Input, theme.Hover = p.line, p.border, p.hover
	theme.Primary, theme.PrimaryForeground = p.accent, p.white
	theme.Selection, theme.Ring, theme.Danger = p.highlight, p.accent, p.danger
	return theme
}

// tile is the rounded square in front of a page of the sidebar's top level: a glyph in
// white on a color that names the kind of settings.
type tile struct {
	color gfx.Color
	icon  gfx.Icon
}

// tiles are the tiles of the groups and pages on the top level, by page. A page inside a
// group has none and its entry is the zero tile. The colors are the same in both looks
// (a white glyph needs a mid-tone ground to read on in either), and are mid-tones in
// the family of the colors the log window gives its channel chips.
var tiles = [pageCount]tile{
	pageAppearance:     {color: gfx.RGB24(0xa371f7), icon: icons.LayoutGrid},
	pagePlugins:        {color: gfx.RGB24(0xe16f24), icon: icons.Cpu},
	pageVersionControl: {color: gfx.RGB24(0xcf222e), icon: icons.GitBranch},
	pageBuild:          {color: gfx.RGB24(0x2da44e), icon: icons.Play},
	pageLanguages:      {color: gfx.RGB24(0x2f81f7), icon: icons.FileCode},
	pageTools:          {color: gfx.RGB24(0x6e7681), icon: icons.Settings},
	pageAI:             {color: gfx.RGB24(0x8957e5), icon: icons.Sparkles},
}
