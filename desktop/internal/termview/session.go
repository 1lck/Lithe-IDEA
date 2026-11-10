package termview

import (
	"errors"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/vivaui/viva/app"
)

// errInputBacklog is what the log records when the shell refuses input: its backlog is
// full because the program is not reading, or it has just ended. Either way the keys are
// lost, and the log is the only place that says so.
var errInputBacklog = errors.New("termview: the shell did not accept the input")

// start opens a shell in the size of the grid. A shell that cannot be started is written
// into the grid and logged; the view is then ended, so Enter tries again instead of the
// view retrying on every paint.
func (v *View) start() {
	// The screen's size, not the layout's, is what the pty is given: the screen clamps
	// the layout, and a pty larger than the screen would wrap lines the screen cannot
	// hold.
	cols, rows := v.screen.Size()
	args := v.cfg.Args
	if args == nil {
		args = localshell.ArgsFor(v.cfg.Shell)
	}
	opened, err := v.cfg.start(localshell.Config{
		Cols: cols, Rows: rows,
		Shell: v.cfg.Shell, Args: args,
		Dir: v.cfg.Dir, Env: v.cfg.Env, Unset: v.cfg.Unset, Notify: v.cfg.Notify,
	})
	if err != nil {
		v.ended = true
		v.say(sgrFail, v.cfg.Messages.StartFailed(err.Error()))
		v.say(sgrMuted, v.cfg.Messages.RestartHint)
		v.failed(Failure{Event: eventStartFailed, Warn: true, Err: err})
		v.exited(nil)
		return
	}
	v.shell = opened
	v.ended = false
	// A program that never got to run its teardown leaves its modes armed on the screen
	// (the alternate screen, mouse reports, the kitty keyboard flags). The shell just
	// started is a process that asked for none of them, so the screen is handed over
	// clean; this matters on a restart, where the old screen is kept.
	v.screen.ReclaimApplicationModes()
	// The answers to the program's queries (device attributes, cursor position) go
	// straight to the shell. They are not typing, so they neither return the view to the
	// live screen nor drop the selection, and a refused answer is not worth a log line
	// per query.
	v.screen.SetReply(func(reply []byte) {
		if v.shell != nil && len(reply) > 0 {
			v.shell.Write(reply)
		}
	})
}

// Start runs the program now, at the default grid size, instead of at the first paint. A
// terminal that is created behind another tab is never painted until it is shown, and its
// program must not wait for that. The first paint resizes the pty to the real grid.
func (v *View) Start() { v.ensureStarted() }

// ensureStarted starts the shell on the first paint, once the grid's size is known. A
// shell that ended or failed waits for Enter, and a closed view never starts one again.
func (v *View) ensureStarted() {
	if v.shell == nil && !v.ended && !v.closed {
		v.start()
	}
}

// Pump moves the shell's output into the screen and notices the shell's end. The window
// calls it from its wake handler, and it reports whether the picture changed and needs a
// paint.
//
// It parses output for at most pumpBudget of window-thread time, in slices of pumpSlice
// bytes, and leaves the rest queued for the next frame. Parsing costs from a few hundred
// to a few thousand nanoseconds per hundred bytes depending on what the bytes are, so a
// byte limit is either far under what a frame can afford or far over it; the time a frame
// can spare is what is bounded. A slice is always parsed, so a wake makes progress however
// slow the thread is. The shell ending, and a view without a Notify to ask for the next
// frame, parse everything at once: the first must not lose the end of the output, and the
// second would never see the rest.
func (v *View) Pump() bool {
	if v.shell == nil {
		return false
	}
	version, selected := v.screen.Version(), v.selection.selected
	v.rx = v.shell.Drain(v.rx) // keep what an earlier frame could not parse
	finished := false
	select {
	case <-v.shell.Done():
		finished = true
		v.rx = v.shell.Drain(v.rx) // output that arrived with the end
	default:
	}
	data := v.rx
	sliced := !finished && v.cfg.Notify != nil
	started := time.Now()
	consumed := 0
	for consumed < len(data) {
		chunk := data[consumed:]
		if sliced && len(chunk) > pumpSlice {
			// The capacity is cut too, so nothing that appends to the chunk can write
			// over the output behind it.
			chunk = chunk[:pumpSlice:pumpSlice]
		}
		consumed += len(chunk)
		v.write(chunk)
		if !sliced || time.Since(started) >= pumpBudget {
			break
		}
	}
	if consumed < len(data) {
		// Move the unparsed suffix to the front of the buffer. The next frame appends new
		// output after it, so order is kept. Only a sliced pass leaves a suffix, and it
		// needs the Notify that asks the window for the frame to parse it in.
		copy(v.rx, v.rx[consumed:])
		v.rx = v.rx[:len(v.rx)-consumed]
		v.cfg.Notify()
	} else {
		v.rx = v.rx[:0]
		if cap(v.rx) > rxKeep {
			v.rx = nil // do not keep a flood's buffer
		}
	}
	if finished {
		v.shellEnded()
	}
	// Writing output drops the selection even when the screen looks the same, and that
	// is a change to paint too.
	return v.screen.Version() != version || (selected && !v.selection.selected)
}

// shellEnded tells the screen the session is over and lets the shell go. Enter then
// starts a new one (see restart).
func (v *View) shellEnded() {
	err := v.shell.Err()
	v.shell.Close()
	v.shell = nil
	v.ended = true
	// A composition cannot be committed to a shell that is gone.
	v.preedit = app.TextState{}
	v.write([]byte("\r\n"))
	line := v.cfg.Messages.SessionEnded
	var exit interface{ ExitStatus() int }
	if errors.As(err, &exit) && exit.ExitStatus() != 0 {
		line = v.cfg.Messages.SessionEndedStatus(exit.ExitStatus())
	}
	v.say(sgrMuted, line)
	if v.cfg.Exited == nil {
		v.say(sgrMuted, v.cfg.Messages.RestartHint)
	}
	var status *int
	if errors.As(err, &exit) {
		code := exit.ExitStatus()
		status = &code
	} else if err == nil {
		zero := 0
		status = &zero
	}
	v.exited(status)
}

// exited tells the owner the program is gone, once.
func (v *View) exited(status *int) {
	if v.cfg.Exited != nil && !v.exitSent {
		v.exitSent = true
		v.cfg.Exited(status)
	}
}

// say writes one line of the terminal's own output into the grid, in the given color.
func (v *View) say(style, line string) {
	v.write([]byte(style + line + sgrReset + "\r\n"))
}

// write puts output into the screen. A selection points at rows that the output moves,
// so it is dropped first: a highlight over text that is no longer there would copy the
// wrong thing.
func (v *View) write(p []byte) {
	v.selection.clear()
	v.screen.Write(p)
}

// sendInput writes what the user typed, pasted or reported with the mouse to the shell and
// reports whether it was accepted. Typing returns the view to the live screen and drops the
// selection, as every terminal does, so the user sees what they are typing into.
func (v *View) sendInput(p []byte) bool {
	if v.shell == nil || len(p) == 0 {
		return false
	}
	v.selection.clear()
	v.screen.ScrollToBottom()
	if v.shell.Write(p) {
		return true
	}
	v.failed(Failure{Event: eventInputFailed, Stage: stageSend, Err: errInputBacklog})
	return false
}

// fit gives the screen and the shell the size of the grid that was just laid out. The
// resize drops the selection, since a reflow moves the lines it points at.
func (v *View) fit(layout geometry) {
	v.layout = layout
	cols, rows := v.screen.Size()
	if cols == layout.cols && rows == layout.rows {
		return
	}
	v.screen.Resize(layout.cols, layout.rows)
	v.selection.clear()
	if v.shell != nil {
		// The screen's size, since it clamps the layout and the pty must match it.
		cols, rows = v.screen.Size()
		v.shell.Resize(cols, rows)
	}
}

// restart starts a new shell in a view whose shell ended or never started, and reports
// whether it did. What the old session printed stays in the history above the new one, so
// the user can still read why it ended.
func (v *View) restart() bool {
	if !v.ended || v.closed || v.cfg.Exited != nil {
		return false
	}
	// A blank line sets the new shell's prompt apart from the notes the old session ended
	// with, which would otherwise run straight into it.
	v.write([]byte("\r\n"))
	v.ended = false
	v.start()
	return true
}
