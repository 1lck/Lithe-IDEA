package workbench

import (
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The small page elements the Git pages share.

// gitIconButton declares an icon button of a tool window's toolbar and reports a click on it.
// on shows it pressed, for the buttons that toggle a view; a disabled one is dimmed and takes
// no click. label is its name for assistive technology and its hover hint.
func (a *App) gitIconButton(c ui.C, label string, icon gfx.Icon, on, disabled bool) bool {
	button := ui.Button(c, label).Icon(icon).IconOnly().Ghost().Size(shellHideSize, shellHideSize).Disabled(disabled)
	if on {
		button = button.Background(a.colors.Active)
	}
	return !disabled && button.Clicked()
}

// gitEmpty declares the message that stands for an empty pane.
func (a *App) gitEmpty(c ui.C, message string) {
	ui.Column(c).Fill().Center().PadX(shellContentPad).Children(func() {
		ui.Paragraph(c, message, 3).TextCenter().Color(a.colors.Subtle)
	})
}
