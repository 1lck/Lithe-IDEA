package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logwindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/termview"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
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
		Foreground: a.colors.Text,
		Cursor:     gfx.Color{Red: 0.18, Green: 0.43, Blue: 0.79, Alpha: 1},
		Selection:  gfx.Color{Red: 0.69, Green: 0.82, Blue: 0.98, Alpha: 1},
	}
	if look.Dark {
		look.Cursor = gfx.Color{Red: 0.35, Green: 0.67, Blue: 0.98, Alpha: 1}
		look.Selection = gfx.Color{Red: 0.16, Green: 0.31, Blue: 0.48, Alpha: 1}
	}
	return look
}

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

// terminalPointer gives a pointer event to the open project's terminals. A terminal tells
// the events that are its own, which include the moves and the release of a selection or
// a scrollbar drag that left its hit, so the window does not route by target here: the
// first terminal that takes the event gets it.
func (a *App) terminalPointer(event gfx.PointerEvent) (gfx.EventResult, bool) {
	p := a.project
	if p == nil {
		return gfx.EventResult{}, false
	}
	for _, t := range p.terms.list {
		if result, handled := t.view.Pointer(event); handled {
			return result, true
		}
	}
	return gfx.EventResult{}, false
}

// onScroll gives a wheel turn over a terminal to the terminal, which scrolls its history
// or reports the wheel to a program that asked for the mouse. A sideways swipe over the
// project tree scrolls it sideways, which Viva's scroll areas do not, and any wheel over an editor group's strip of tabs that does not fit scrolls
// the strip; anything else scrolls the view under the pointer.
func (a *App) onScroll(event gfx.ScrollEvent) gfx.EventResult {
	if result, ok := a.pageWheel(event); ok {
		return result
	}
	if t := a.focusedTerminal(event.Target); t != nil {
		if result, ok := t.Scroll(event); ok {
			return result
		}
	}
	if v := a.focusedDocument(event.Target); v != nil {
		a.pluginSemanticsScrolled(event.Target)
		if result, ok := v.Scroll(event); ok {
			return result
		}
	}
	if result, ok := a.term.stripWheel(event); ok {
		return result
	}
	return a.view.Wheel(event)
}

// textInput answers Config.TextInput: the platform asks which editor belongs to the focused
// control. A terminal's grid takes typed text and input method composition itself; every
// other control is a field the window declared or one of a Git page.
func (a *App) textInput(ctx app.TextInputContext) *app.TextInput {
	if input := a.pageTextInput(ctx); input != nil {
		return input
	}
	if t := a.focusedTerminal(ctx.ID); t != nil {
		return t.TextInput(ctx)
	}
	if v := a.focusedDocument(ctx.ID); v != nil {
		return v.TextInput(ctx)
	}
	if input := a.agentTextInput(ctx); input != nil {
		return input
	}
	return a.fields(ctx)
}
