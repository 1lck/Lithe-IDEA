package workbench

import (
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

// themeChoice is the look the user picked in the settings; themeSystem follows the
// system's light or dark appearance.
type themeChoice string

const (
	themeSystem themeChoice = ""
	themeLight  themeChoice = "light"
	themeDark   themeChoice = "dark"
)

// palette is the workbench's own surfaces on top of a Viva theme: an IDE has more
// layers than a document page (window chrome, tool windows, the editor), so they are
// named here once and every screen takes its colors from it.
type palette struct {
	// Chrome is the title bar, the tool stripes and the status bar.
	Chrome ui.Color
	// Panel is the background of a tool window and of the start screen's sidebar.
	Panel ui.Color
	// Editor is the editor area and the start screen's content.
	Editor ui.Color
	// Line separates the chrome, panels and editor.
	Line ui.Color
	// Hover is a quiet button or row under the pointer.
	Hover ui.Color
	// Active is a stripe button whose tool window is open, and a pressed quiet button.
	Active ui.Color
	// Selection is the selected row of a list or tree.
	Selection ui.Color
	// Text is ordinary text; Subtle is secondary text and inactive icons.
	Text   ui.Color
	Subtle ui.Color
	// Accent marks the drop place of a dragged button, links and the brand.
	Accent ui.Color
	// Success and Warning tint status marks.
	Success ui.Color
	Warning ui.Color
	// Dark is set in the dark look, for the few colors that are not a theme surface, such
	// as the commit graph's lane colors.
	Dark bool
}

// look resolves the user's theme choice into the Viva theme the frame is laid out
// with and the workbench palette that goes with it.
func look(choice themeChoice) (ui.Theme, palette) {
	dark := choice == themeDark
	if choice == themeSystem {
		dark = app.SystemAppearance() == app.AppearanceDark
	}
	if dark {
		return darkLook()
	}
	return lightLook()
}

func lightLook() (ui.Theme, palette) {
	accent := ui.RGB24(0x3574F0)
	p := palette{
		Chrome:    ui.RGB24(0xF7F8FA),
		Panel:     ui.RGB24(0xF7F8FA),
		Editor:    ui.RGB24(0xFFFFFF),
		Line:      ui.RGB24(0xEBECF0),
		Hover:     ui.RGB24(0xEBECF0),
		Active:    ui.RGB24(0xDFE1E5),
		Selection: ui.RGB24(0xD5E1FF),
		Text:      ui.RGB24(0x1E1F22),
		Subtle:    ui.RGB24(0x6C707E),
		Accent:    accent,
		Success:   ui.RGB24(0x208A3C),
		Warning:   ui.RGB24(0xC27D04),
	}
	theme := ui.LightTheme()
	theme.Background = p.Editor
	theme.Foreground = p.Text
	theme.CardForeground = p.Text
	theme.PopoverForeground = p.Text
	theme.MutedForeground = p.Subtle
	theme.Border = ui.RGB24(0xDFE1E5)
	theme.Hover = p.Hover
	theme.Input = ui.RGB24(0xC9CCD6)
	theme.Primary = accent
	theme.PrimaryForeground = ui.RGB24(0xFFFFFF)
	theme.Selection = p.Selection
	theme.Ring = accent
	theme.Success = p.Success
	theme.Metrics = theme.Metrics.WithDensity(ui.DensityCompact)
	theme.Metrics.FontSizeS = 12
	return theme, p
}

func darkLook() (ui.Theme, palette) {
	accent := ui.RGB24(0x3574F0)
	p := palette{
		Chrome:    ui.RGB24(0x2B2D30),
		Panel:     ui.RGB24(0x2B2D30),
		Editor:    ui.RGB24(0x1E1F22),
		Line:      ui.RGB24(0x1E1F22),
		Hover:     ui.RGB24(0x393B40),
		Active:    ui.RGB24(0x43454A),
		Selection: ui.RGB24(0x2E436E),
		Text:      ui.RGB24(0xDFE1E5),
		Subtle:    ui.RGB24(0x868A91),
		Accent:    ui.RGB24(0x548AF7),
		Success:   ui.RGB24(0x5FB865),
		Warning:   ui.RGB24(0xE0A33B),
		Dark:      true,
	}
	theme := ui.DarkTheme()
	theme.Background = p.Editor
	theme.Foreground = p.Text
	theme.Card = p.Panel
	theme.CardForeground = p.Text
	theme.Popover = ui.RGB24(0x2B2D30)
	theme.PopoverForeground = p.Text
	theme.MutedForeground = p.Subtle
	theme.Border = ui.RGB24(0x393B40)
	theme.Hover = p.Hover
	theme.Input = ui.RGB24(0x4E5157)
	theme.Primary = accent
	theme.PrimaryForeground = ui.RGB24(0xFFFFFF)
	theme.Selection = p.Selection
	theme.Ring = p.Accent
	theme.Success = p.Success
	theme.Metrics = theme.Metrics.WithDensity(ui.DensityCompact)
	theme.Metrics.FontSizeS = 12
	return theme, p
}

// nativeAppearance is the appearance the system parts of the window (traffic lights,
// file dialogs) are pinned to for a theme choice.
func nativeAppearance(choice themeChoice) app.Appearance {
	switch choice {
	case themeLight:
		return app.AppearanceLight
	case themeDark:
		return app.AppearanceDark
	}
	return app.AppearanceUnknown
}
