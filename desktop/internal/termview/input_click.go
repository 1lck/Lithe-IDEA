package termview

import (
	"bytes"

	"github.com/1lck/Lithe-IDEA/desktop/internal/term"
	"github.com/vivaui/viva/gfx"
)

// A click on the line being typed moves the shell's cursor there, as Warp, and iTerm2 with
// Option, do (Motty b2357d69, see NOTICE). A terminal cannot place another program's
// cursor, so the view sends cursor keys and lets the shell's line editor act on them;
// term.Terminal.InputMove says when that is sound. A program that asked for the mouse
// already had the click, a link the click opens is not also a move, and a press that drags
// is a selection, not a click.

// inputClick reports whether the release that ends a click asks for the move: the primary
// button, alone or with Option (Alt). Option also starts a block selection, but a click
// that does not move selects no block.
func inputClick(event gfx.PointerEvent) bool {
	return event.Kind == gfx.PointerUp &&
		(event.Button == gfx.PointerButtonPrimary || event.Button == gfx.PointerButtonNone) &&
		(event.Modifiers == 0 || event.Modifiers == gfx.ModifierAlt)
}

// moveInputCursor sends the cursor keys that take the shell's cursor to position. It
// reports whether the click was used, which includes a click on the cursor itself.
func (v *View) moveInputCursor(position term.Position) bool {
	// The shell must have reported its prompt and be waiting at it. PowerShell and cmd mark
	// their prompt but not the start of a command, so without that mark a running program
	// would receive the keys.
	if v.shell == nil || v.ended || !v.screen.CommandReporting() || v.screen.Modes().AltScreen {
		return false
	}
	// Output still on its way can move the cursor the distance is measured from.
	v.Pump()
	if v.shell == nil {
		return false
	}
	moves, ok := v.screen.InputMove(position)
	if !ok {
		return false
	}
	if moves == 0 {
		return true
	}
	key := gfx.KeyRight
	if moves < 0 {
		key, moves = gfx.KeyLeft, -moves
	}
	press := term.EncodeKey(key, 0, "", v.screen.Modes().AppCursorKeys)
	v.sendInput(bytes.Repeat(press, moves))
	return true
}
