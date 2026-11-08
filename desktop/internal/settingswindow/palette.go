package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/ui"
)

// palette is the settings window's own colors. The window keeps them apart from the
// workbench theme for the same reason the log window does: it is a separate native
// window that must read the same whatever the main window shows, and its values are the
// ones the log window and the macOS client use, so the three look like one product.
type palette struct {
	// window is the content area and the footer; sidebar is the column of pages beside it
	// and titleBar the strip the system's window buttons sit in.
	window, sidebar, titleBar ui.Color
	// card is the fill of a settings card.
	card ui.Color
	// line separates the regions and outlines a card; border outlines a control.
	line, border ui.Color
	// hover is a row or a quiet button under the pointer.
	hover ui.Color
	// highlight is the background of selected text in a field.
	highlight ui.Color
	// selection is the selected page while the list has the keyboard focus and
	// selectionIdle while it has not.
	selection, selectionIdle ui.Color
	// text is ordinary text, muted secondary text and subtle the hints and inactive icons.
	text, muted, subtle ui.Color
	// accent is the primary button and the focus ring; danger an error.
	accent, danger ui.Color
	// white is the glyph on a colored tile and the text on the primary button.
	white ui.Color
}

func lightPalette() palette {
	return palette{
		window: ui.RGB24(0xffffff), sidebar: ui.RGB24(0xececee), titleBar: ui.RGB24(0xe8ebef),
		card: ui.RGB24(0xf7f8fa),
		line: ui.RGB24(0xd8dae0), border: ui.RGB24(0xc9ccd6),
		hover:     ui.RGB24(0xf2f3f5),
		highlight: ui.RGB24(0xddf4ff),
		selection: ui.RGB24(0xD0DFFE), selectionIdle: ui.RGB24(0xE9EAEE),
		text: ui.RGB24(0x1f2328), muted: ui.RGB24(0x59636e), subtle: ui.RGB24(0x8c959f),
		accent: ui.RGB24(0x3871e1), danger: ui.RGB24(0xc72d2d),
		white: ui.RGB24(0xffffff),
	}
}

func darkPalette() palette {
	return palette{
		window: ui.RGB24(0x191a1c), sidebar: ui.RGB24(0x232427), titleBar: ui.RGB24(0x28292c),
		card: ui.RGB24(0x2b2d30),
		line: ui.RGB24(0x2e3036), border: ui.RGB24(0x4e5157),
		hover:     ui.RGB24(0x303136),
		highlight: ui.RGB24(0x1f2a3a),
		selection: ui.RGB24(0x2A4371), selectionIdle: ui.RGB24(0x33353B),
		text: ui.RGB24(0xdfe1e5), muted: ui.RGB24(0x8c8d8e), subtle: ui.RGB24(0x727375),
		accent: ui.RGB24(0x3871e1), danger: ui.RGB24(0xea5454),
		white: ui.RGB24(0xffffff),
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
func (p palette) selectionColor(focused bool) ui.Color {
	if focused {
		return p.selection
	}
	return p.selectionIdle
}

// windowTheme maps the palette onto the theme the Viva controls paint with, so a field, a
// select, a segmented control or a button in the window takes the settings window's
// colors in the compact density the other tool windows use.
func windowTheme(dark bool, p palette) ui.Theme {
	theme := ui.LightTheme()
	if dark {
		theme = ui.DarkTheme()
	}
	theme.Metrics = theme.Metrics.WithDensity(ui.DensityCompact)
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
	color ui.Color
	icon  ui.Icon
}

// tiles are the tiles of the groups and pages on the top level, by page. A page inside a
// group has none and its entry is the zero tile. The colors are the same in both looks
// (a white glyph needs a mid-tone ground to read on in either), and are mid-tones in
// the family of the colors the log window gives its channel chips.
var tiles = [pageCount]tile{
	pageAppearance:     {color: ui.RGB24(0xa371f7), icon: icons.LayoutGrid},
	pagePlugins:        {color: ui.RGB24(0xe16f24), icon: icons.Cpu},
	pageVersionControl: {color: ui.RGB24(0xcf222e), icon: icons.GitBranch},
	pageBuild:          {color: ui.RGB24(0x2da44e), icon: icons.Play},
	pageLanguages:      {color: ui.RGB24(0x2f81f7), icon: icons.FileCode},
	pageTools:          {color: ui.RGB24(0x6e7681), icon: icons.Settings},
	pageAI:             {color: ui.RGB24(0x8957e5), icon: icons.Sparkles},
}
