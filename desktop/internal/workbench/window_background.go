package workbench

import (
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// This file keeps the window's background color between runs (matrix id windows-startup-feedback):
// the editor color the last paint used is stored in the client's own data directory as
// window-background.json, and a window's configuration starts with it, so the first frame has the
// theme's color instead of a white flash. Without the file the dark theme's color is used. The
// file is written only when the color changes, never by the install.

// windowBackgroundFile is the name of the stored background in the client's data directory.
const windowBackgroundFile = "window-background.json"

// storedWindowBackground is the stored color: four channels, as the toolkit takes them.
type storedWindowBackground struct {
	Red   float32 `json:"red"`
	Green float32 `json:"green"`
	Blue  float32 `json:"blue"`
	Alpha float32 `json:"alpha"`
}

// startupBackground is the background a window starts with: the stored one when it is valid, else
// the dark theme's editor color.
func (a *App) startupBackground() app.Color {
	if a.store != nil {
		var stored storedWindowBackground
		if found, err := a.store.Load(windowBackgroundFile, &stored); err == nil && found && stored.Alpha > 0 {
			return app.Color{Red: float64(stored.Red), Green: float64(stored.Green), Blue: float64(stored.Blue), Alpha: float64(stored.Alpha)}
		}
	}
	_, dark := look(themeDark)
	return appColor(dark.Editor)
}

// rememberWindowBackground stores color as the background of the next launch when it differs from
// the one stored last. A failed write is not reported: the next launch simply uses the default.
func (a *App) rememberWindowBackground(color gfx.Color) {
	if a.store == nil || color == a.savedBackground {
		return
	}
	a.savedBackground = color
	_ = a.store.Save(windowBackgroundFile, storedWindowBackground{Red: color.Red, Green: color.Green, Blue: color.Blue, Alpha: color.Alpha})
}

// appColor converts a toolkit color to the window configuration's color.
func appColor(c gfx.Color) app.Color {
	return app.Color{Red: float64(c.Red), Green: float64(c.Green), Blue: float64(c.Blue), Alpha: float64(c.Alpha)}
}
