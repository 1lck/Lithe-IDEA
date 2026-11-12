package workbench

import (
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
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
	Chrome gfx.Color
	// Panel is the background of a tool window and of the start screen's sidebar.
	Panel gfx.Color
	// Editor is the editor area and the start screen's content.
	Editor gfx.Color
	// Line separates the chrome, panels and editor.
	Line gfx.Color
	// Hover is a quiet button or row under the pointer.
	Hover gfx.Color
	// Active is a stripe button whose tool window is open, and a pressed quiet button.
	Active gfx.Color
	// Selection is the selected row of a list or tree.
	Selection gfx.Color
	// Text is ordinary text; Subtle is secondary text and inactive icons.
	Text   gfx.Color
	Subtle gfx.Color
	// Accent marks the drop place of a dragged button, links and the brand.
	Accent gfx.Color
	// Success and Warning tint status marks.
	Success gfx.Color
	Warning gfx.Color
	// Deleted is the name of a file a change deletes. It is red rather than the gray of
	// secondary text, which on the dark editor reads as dimmed instead of deleted.
	Deleted gfx.Color
	// Git* are the file-status colors of a change list, aligned with IDEA's expUI
	// schemes: modifications and renames are blue, a staged modification is the paler
	// blue of the index, additions are green, an untracked file is warm red, and a
	// deleted file is grey. Red stays with Deleted, which diff rows and deletion counts
	// keep using.
	GitModified       gfx.Color
	GitModifiedStaged gfx.Color
	GitRenamed        gfx.Color
	GitAdded          gfx.Color
	GitFileDeleted    gfx.Color
	GitUntracked      gfx.Color
	// Gutter* mark the editor's change bar. They are lighter than the file-name colors
	// so a one-line mark does not read as loud as the text beside it.
	GutterAdded    gfx.Color
	GutterModified gfx.Color
	GutterDeleted  gfx.Color
	// Dark is set in the dark look, for the few colors that are not a theme surface, such
	// as the commit graph's lane colors.
	Dark bool
}

// look resolves the user's theme choice into the Viva theme the frame is laid out
// with and the workbench palette that goes with it.
func look(choice themeChoice) (gfx.Theme, palette) {
	dark := choice == themeDark
	if choice == themeSystem {
		dark = app.SystemAppearance() == app.AppearanceDark
	}
	if dark {
		return darkLook()
	}
	return lightLook()
}

func lightLook() (gfx.Theme, palette) {
	accent := gfx.RGB24(0x3574F0)
	p := palette{
		Chrome:    gfx.RGB24(0xF7F8FA),
		Panel:     gfx.RGB24(0xF7F8FA),
		Editor:    gfx.RGB24(0xFFFFFF),
		Line:      gfx.RGB24(0xEBECF0),
		Hover:     gfx.RGB24(0xEBECF0),
		Active:    gfx.RGB24(0xDFE1E5),
		Selection: gfx.RGB24(0xD5E1FF),
		Text:      gfx.RGB24(0x1E1F22),
		Subtle:    gfx.RGB24(0x6C707E),
		Accent:    accent,
		Success:   gfx.RGB24(0x208A3C),
		Warning:   gfx.RGB24(0xC27D04),
		Deleted:   gfx.RGB24(0xDB3B4B),

		GitModified:       gfx.RGB24(0x0033B3),
		GitModifiedStaged: gfx.RGB24(0x2652BE),
		GitRenamed:        gfx.RGB24(0x0033B3),
		GitAdded:          gfx.RGB24(0x067D17),
		GitFileDeleted:    gfx.RGB24(0x6C707E),
		GitUntracked:      gfx.RGB24(0xB23247),
		GutterAdded:       gfx.RGB24(0x7FC784),
		GutterModified:    gfx.RGB24(0x88ADF7),
		GutterDeleted:     gfx.RGB24(0x767A8A),
	}
	theme := gfx.LightTheme()
	theme.Background = p.Editor
	theme.Foreground = p.Text
	theme.CardForeground = p.Text
	theme.PopoverForeground = p.Text
	theme.MutedForeground = p.Subtle
	theme.Border = gfx.RGB24(0xDFE1E5)
	theme.Hover = p.Hover
	theme.Input = gfx.RGB24(0xC9CCD6)
	theme.Primary = accent
	theme.PrimaryForeground = gfx.RGB24(0xFFFFFF)
	theme.Selection = p.Selection
	theme.Ring = accent
	theme.Success = p.Success
	theme.Metrics = theme.Metrics.WithDensity(gfx.DensityCompact)
	theme.Metrics.FontSizeS = 12
	return theme, p
}

func darkLook() (gfx.Theme, palette) {
	accent := gfx.RGB24(0x3574F0)
	p := palette{
		Chrome:    gfx.RGB24(0x2B2D30),
		Panel:     gfx.RGB24(0x2B2D30),
		Editor:    gfx.RGB24(0x1E1F22),
		Line:      gfx.RGB24(0x1E1F22),
		Hover:     gfx.RGB24(0x393B40),
		Active:    gfx.RGB24(0x43454A),
		Selection: gfx.RGB24(0x2E436E),
		Text:      gfx.RGB24(0xDFE1E5),
		Subtle:    gfx.RGB24(0x868A91),
		Accent:    gfx.RGB24(0x548AF7),
		Success:   gfx.RGB24(0x5FB865),
		Warning:   gfx.RGB24(0xE0A33B),
		Deleted:   gfx.RGB24(0xDB5C5C),
		Dark:      true,

		GitModified:       gfx.RGB24(0x70AEFF),
		GitModifiedStaged: gfx.RGB24(0x85BAFF),
		GitRenamed:        gfx.RGB24(0x70AEFF),
		GitAdded:          gfx.RGB24(0x73BD79),
		GitFileDeleted:    gfx.RGB24(0x6F737A),
		GitUntracked:      gfx.RGB24(0xE88F89),
		GutterAdded:       gfx.RGB24(0x549159),
		GutterModified:    gfx.RGB24(0x375FAD),
		GutterDeleted:     gfx.RGB24(0x868A91),
	}
	theme := gfx.DarkTheme()
	theme.Background = p.Editor
	theme.Foreground = p.Text
	theme.Card = p.Panel
	theme.CardForeground = p.Text
	theme.Popover = gfx.RGB24(0x2B2D30)
	theme.PopoverForeground = p.Text
	theme.MutedForeground = p.Subtle
	theme.Border = gfx.RGB24(0x393B40)
	theme.Hover = p.Hover
	theme.Input = gfx.RGB24(0x4E5157)
	theme.Primary = accent
	theme.PrimaryForeground = gfx.RGB24(0xFFFFFF)
	theme.Selection = p.Selection
	theme.Ring = p.Accent
	theme.Success = p.Success
	theme.Metrics = theme.Metrics.WithDensity(gfx.DensityCompact)
	theme.Metrics.FontSizeS = 12
	return theme, p
}

// gitStatusColor is the IDEA-aligned color of a changed file's name. staged picks the
// index side of the change, so a staged modification shows the paler blue instead of
// the worktree blue. Unknown letters keep the ordinary text color.
func (p palette) gitStatusColor(side byte, staged bool) gfx.Color {
	switch side {
	case 'A', 'C':
		return p.GitAdded
	case 'D':
		return p.GitFileDeleted
	case 'R':
		return p.GitRenamed
	case 'M':
		if staged {
			return p.GitModifiedStaged
		}
		return p.GitModified
	case 'T':
		return p.GitModified
	}
	return p.Text
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
