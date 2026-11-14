package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logwindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/nativeterm"
	"github.com/1lck/Lithe-IDEA/desktop/internal/termview"
	"github.com/vivaui/viva/gfx"
	"sync"
)

// terminalMessages are the terminal's words in the window's current language.
func (a *App) terminalMessages() termview.Messages {
	t := a.text.Terminal
	return termview.Messages{
		Label:              t.Label,
		ScrollbarLabel:     t.ScrollbarLabel,
		SessionEnded:       t.SessionEnded,
		SessionEndedStatus: t.SessionEndedStatus,
		RestartHint:        t.RestartHint,
		StartFailed:        t.StartFailed,
	}
}

// terminalFailed records a failure of the terminal in the client's log. A shell that cannot
// start is worth a warning; a write to a shell that has already ended is only debug noise.
func (a *App) terminalFailed(f termview.Failure) {
	level := core.LevelDebug
	if f.Warn {
		level = core.LevelWarn
	}
	fields := map[string]any{}
	if f.Err != nil {
		fields = logwindow.ErrorFields(f.Err)
	}
	if f.Stage != "" {
		fields["stage"] = f.Stage
	}
	a.emit(level, f.Event, fields)
}

// terminalLook is the terminal's colors for the frame being painted: the ground and the
// default ink come from the workbench theme, so the terminal sits in the editor's color. The
// cursor and the selection are the macOS client's (MacTerminalTransport.swift), so both
// clients show the same terminal.
func (a *App) terminalLook() termview.Look {
	look := termview.Look{
		Dark:       a.colors.Dark,
		Background: a.colors.Editor,
		// The editor color is clear behind a background image; the terminal measures its ink
		// and answers color queries against the opaque one.
		Solid:      a.colors.Ground,
		Foreground: a.colors.Text,
		Cursor:     gfx.Color{Red: 0.18, Green: 0.43, Blue: 0.79, Alpha: 1},
		Selection:  gfx.Color{Red: 0.69, Green: 0.82, Blue: 0.98, Alpha: 1},
	}
	if look.Dark {
		look.Cursor = gfx.Color{Red: 0.35, Green: 0.67, Blue: 0.98, Alpha: 1}
		look.Selection = gfx.Color{Red: 0.16, Green: 0.31, Blue: 0.48, Alpha: 1}
	}
	look.Native = nativeTerminalColors()
	return look
}

// nativeTerminalColors is the system terminal profile's ANSI colors, read once (nativeterm), in
// the form the terminal view takes; nil where the system keeps none. The same pointer is
// returned every time, so the view sees an unchanged look and keeps its palette.
var nativeTerminalColors = sync.OnceValue(func() *[16]termview.NativeColor {
	colors := nativeterm.ANSI()
	if colors == nil {
		return nil
	}
	var native [16]termview.NativeColor
	for index := range native {
		native[index] = termview.NativeColor{RGB: colors.ANSI[index], Set: colors.Set[index]}
	}
	return &native
})

// pumpTerminal feeds the output the shells produced since the last frame into the open
// project's screens. It runs in OnWake, before the frame the output shows in. Every
// terminal is pumped, not only the ones on show: a shell that is behind another tab keeps
// running, and its output must not pile up unread.
func (a *App) pumpTerminal() {
	p := a.project
	if p == nil {
		return
	}
	for _, t := range p.terms.list {
		t.view.Pump()
	}
}

// focusedTerminal is the open project's terminal that owns the hit id, and nil when none
// does. A key, a scroll or a text input is a terminal's only while the hit it targets is
// that terminal's.
func (a *App) focusedTerminal(id gfx.ID) *termview.View {
	p := a.project
	if p == nil {
		return nil
	}
	for _, t := range p.terms.list {
		if t.view.Owns(id) {
			return t.view
		}
	}
	return nil
}
