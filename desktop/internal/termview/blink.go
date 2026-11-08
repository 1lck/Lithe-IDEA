package termview

import (
	"time"

	"github.com/vivaui/viva/ui"
)

// The cursor is lit for cursorBlinkHalf, dark for as long, and keeps going for
// cursorBlinkSpan after the last thing that happened; then it stays lit, so a
// window left alone asks for no frames.
const (
	cursorBlinkHalf = 530 * time.Millisecond
	cursorBlinkSpan = 20 * time.Second
)

// How thick the thin cursors draw: the bar's width and the underline's height in
// logical pixels. The block cursor fills its cell and does not follow them.
const (
	cursorBarWidth        = float32(3)
	cursorUnderlineHeight = float32(2)
)

// cursorBlink is the phase of the terminal's cursor.
type cursorBlink struct {
	since time.Duration // when the cursor last moved or the pane was entered
	x, y  int
	seen  bool // since is meaningful: the terminal was painted focused
}

// on reports whether the cursor is lit in this frame, and asks for the frame
// that turns it over. It restarts the phase when the cursor has moved or the
// pane has just got the keyboard.
func (blink *cursorBlink) on(canvas *ui.Canvas, x, y int) bool {
	now := canvas.Now()
	if !blink.seen || blink.x != x || blink.y != y {
		blink.since, blink.x, blink.y, blink.seen = now, x, y, true
	}
	elapsed := max(now-blink.since, 0)
	if elapsed >= cursorBlinkSpan || canvas.ReduceMotion() {
		return true
	}
	phase := elapsed % (2 * cursorBlinkHalf)
	if phase < cursorBlinkHalf {
		canvas.RequestFrameIn(cursorBlinkHalf - phase)
		return true
	}
	canvas.RequestFrameIn(2*cursorBlinkHalf - phase)
	return false
}

// rest forgets the phase: the next time the terminal is painted with the
// keyboard, the cursor starts lit.
func (blink *cursorBlink) rest(x, y int) {
	blink.seen, blink.x, blink.y = false, x, y
}
