package termview

import (
	"crypto/rand"
	"errors"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// errInputBacklog is what the log records when the shell refuses input: its backlog is
// full because the program is not reading, or it has just ended. Either way the keys are
// lost, and the log is the only place that says so.
var errInputBacklog = errors.New("termview: the shell did not accept the input")

// maxQueuedInput is how much typed or pasted input may wait for a shell that is still
// starting: as much as the shell itself lets wait to be written (localshell's
// maxPendingInput), so a paste the shell would take is not refused for arriving early.
const maxQueuedInput = 4 << 20

// launch is a shell being started off the window thread. The goroutine that starts it
// sets shell, err and degraded and then closes done; the window thread reads them only
// after done is closed.
type launch struct {
	done  chan struct{}
	shell shell
	err   error
	// degraded is what Config.Degraded was told during the start, reported to the log
	// from the window thread.
	degraded []error
	// cols and rows are the size the shell is started in.
	cols, rows int
}

// start opens a shell in the size of the grid. Finding and starting the program is file
// and process work the window thread must not wait on (on Windows it searches the PATH
// for PowerShell and creates a console), so it runs on a goroutine of its own, and the
// view takes the shell over at the next Pump once Config.Notify has woken the window.
// Until then the grid shows what it holds and what is typed waits (see sendInput). A
// view without a Notify could never be woken for it, so it starts the shell in place.
//
// A shell that cannot be started is written into the grid and logged; the view is then
// ended, so Enter tries again instead of the view retrying on every paint.
func (v *View) start() {
	// The screen's size, not the layout's, is what the pty is given: the screen clamps
	// the layout, and a pty larger than the screen would wrap lines the screen cannot
	// hold.
	cols, rows := v.screen.Size()
	args := v.cfg.Args
	if args == nil && v.cfg.Open == nil {
		args = localshell.ArgsFor(v.cfg.Shell)
	}
	// The user's own shell, started without arguments of its own, reports its prompts and its
	// commands, bound to a token new to this start (see
	// localshell.Config.PromptToken). The screen trusts only the markers that carry it:
	// a program that prints the same sequences, a shell nested in this one, or what the
	// shell before a restart left half written cannot pass for this shell's prompt. A
	// program started with arguments is left as it is, and so is the user's shell when the
	// settings turned the integration off: without a token it starts plain. A program that
	// Config.Open starts elsewhere is not one localshell can integrate, so it starts plain.
	token := ""
	if args == nil && !v.options.PlainShell && v.cfg.Open == nil {
		token = rand.Text()
	}
	v.screen.SetPromptToken(token)
	// A program that never got to run its teardown leaves its modes armed on the screen
	// (the alternate screen, mouse reports, the kitty keyboard flags). The shell about to
	// start is a process that asked for none of them, so the screen is handed over clean
	// before anything is typed for it; this matters on a restart, where the old screen is
	// kept.
	v.screen.ReclaimApplicationModes()
	// Leaving the alternate screen the old program left behind moves the buffer under a
	// selection made on it.
	v.reconcileSelection()
	l := &launch{done: make(chan struct{}), cols: cols, rows: rows}
	config := localshell.Config{
		Cols: cols, Rows: rows,
		Shell: v.cfg.Shell, Args: args,
		Dir: v.cfg.Dir, Env: v.cfg.Env, Unset: v.cfg.Unset, Notify: v.cfg.Notify,
		PromptToken: token,
		// Called during the start, on the goroutine that starts the shell.
		Degraded: func(err error) { l.degraded = append(l.degraded, err) },
	}
	open, notify := v.cfg.start, v.cfg.Notify
	run := func() {
		l.shell, l.err = open(config)
		close(l.done)
	}
	v.launching = l
	if notify == nil {
		run()
		v.launched()
		return
	}
	go func() {
		run()
		notify()
	}()
}

// launched takes over the shell the last start opened, or reports why it could not.
// It runs on the window thread once the start has finished.
func (v *View) launched() {
	l := v.launching
	v.launching = nil
	// The shell still runs; the log is the only place that says it runs degraded.
	for _, err := range l.degraded {
		v.failed(Failure{Event: eventBackgroundFailed, Operation: operationConPTY, Warn: true, Err: err})
	}
	queued := v.queued
	v.queued = nil
	if l.err != nil {
		v.ended = true
		v.say(sgrFail, v.cfg.Messages.StartFailed(l.err.Error()))
		v.say(sgrMuted, v.cfg.Messages.RestartHint)
		v.failed(Failure{Event: eventStartFailed, Stage: stageSpawn, Warn: true, Err: l.err})
		v.exited(nil)
		return
	}
	v.shell = l.shell
	v.ended = false
	// The shell starts in the size the screen had then, so that is the size it has been
	// told. The grid may have been laid out anew while it started; the shell is then told
	// the screen's size at once, as it has not printed a prompt to hold the size for.
	v.shellCols, v.shellRows, v.shellWaiting = l.cols, l.rows, false
	if cols, rows := v.screen.Size(); cols != l.cols || rows != l.rows {
		v.tellShellSize(cols, rows)
	}
	// The answers to the program's queries (device attributes, cursor position) go
	// straight to the shell. They are not typing, so they neither return the view to the
	// live screen nor drop the selection, and a refused answer is not worth a log line
	// per query.
	v.screen.SetReply(func(reply []byte) {
		if v.shell != nil && len(reply) > 0 {
			v.shell.Write(reply)
		}
	})
	// What was typed while the shell started reaches it now, in the order it was typed,
	// as a pty holds what is typed before the shell gets to read it.
	if len(queued) > 0 && !v.shell.Write(queued) {
		v.failed(Failure{Event: eventInputFailed, Stage: stageSend, Err: errInputBacklog})
	}
}

// settleLaunch takes over a shell whose start has finished, and reports whether the view
// is past its start: false while the shell is still starting.
func (v *View) settleLaunch() bool {
	if v.launching == nil {
		return true
	}
	select {
	case <-v.launching.done:
		v.launched()
		return true
	default:
		return false
	}
}

// Start runs the program now, at the default grid size, instead of at the first paint. A
// terminal that is created behind another tab is never painted until it is shown, and its
// program must not wait for that. The first paint resizes the pty to the real grid.
func (v *View) Start() { v.ensureStarted() }

// ensureStarted starts the shell on the first paint, once the grid's size is known. A
// shell that is starting is not started again, a shell that ended or failed waits for
// Enter, and a closed view never starts one again.
func (v *View) ensureStarted() {
	if v.shell == nil && v.launching == nil && !v.ended && !v.closed {
		v.start()
	}
}

// live reports that the view has a shell to type into: one that runs, or one that is
// starting and takes what is typed once it runs.
func (v *View) live() bool { return v.shell != nil || v.launching != nil }

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
	version, selected := v.screen.Version(), v.selection.selected
	// A shell whose start has finished is taken over first, so the output it has already
	// printed is parsed in this pass.
	if !v.settleLaunch() || v.shell == nil {
		return v.screen.Version() != version
	}
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
	// Output that drops the selection is a change to paint even if the screen's version
	// were to hold.
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

// write puts output into the screen. Output is text arriving, not an edit, so the
// selection stays on the text it was made on and scrolls up with it, as terminals keep
// it; it is only dropped or cut where the buffer stops holding the lines it points at.
func (v *View) write(p []byte) {
	v.screen.Write(p)
	v.reconcileSelection()
}

// reconcileSelection follows the buffer under the selection after the screen changed. A
// new buffer generation (a reset, the alternate screen, a cleared screen) means its line
// numbers name other text, so it is dropped; otherwise it is trimmed to the lines the
// scrollback still keeps. Every change to the screen outside write calls it too, so a
// generation is never left for a later write to mistake for its own.
func (v *View) reconcileSelection() {
	if generation := v.screen.BufferGeneration(); generation != v.generation {
		v.generation = generation
		v.selection.clear()
		return
	}
	v.selection.trim(v.screen)
}

// sendInput writes what the user typed, pasted or reported with the mouse to the shell and
// reports whether it was accepted. Typing returns the view to the live screen and drops the
// selection, as every terminal does, so the user sees what they are typing into. Input for
// a shell that is still starting waits for it, up to maxQueuedInput (see launched).
func (v *View) sendInput(p []byte) bool {
	if !v.live() || len(p) == 0 {
		return false
	}
	v.selection.clear()
	v.screen.ScrollToBottom()
	if v.shell == nil {
		if len(v.queued)+len(p) <= maxQueuedInput {
			v.queued = append(v.queued, p...)
			return true
		}
	} else if v.shell.Write(p) {
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
		v.resizeShell(cols, rows)
	}
}

// shellResizeDelay is how long a size has to hold before a shell at its prompt is told
// it. That shell redraws its prompt after every resize, from the rows it last drew it on,
// and dragging the window or a splitter changes the width faster than it redraws: each
// redraw then answers a width the screen has already left and lands beside the prompt it
// was going to replace. The screen follows every step; the shell is told the size the
// steps settle on.
//
// Motty also holds the size for as long as the pointer is down; the view does not see
// the drags of the window and the splitters around it, so here the size only has to
// hold.
const shellResizeDelay = 100 * time.Millisecond

// resizeShell gives the shell the size of the grid. A program that draws its own screen,
// and a shell that has not reported a prompt of its own (see term.Terminal.AtPrompt), is
// told at once; a shell at its prompt is told once the size holds (see
// settleShellResize). A canvas without a clock has no time that could pass, so it never
// waits.
func (v *View) resizeShell(cols, rows int) {
	v.shellWaiting = false
	if !v.paced || !v.screen.AtPrompt() {
		v.tellShellSize(cols, rows)
		return
	}
	if v.shellCols == cols && v.shellRows == rows {
		return
	}
	v.wantCols, v.wantRows, v.shellWaiting, v.shellWaitAt = cols, rows, true, v.clock
}

// settleShellResize tells a shell waiting at its prompt the size it waits for, once that
// size has held for shellResizeDelay, and until then asks for the frame that will.
func (v *View) settleShellResize(canvas *gfx.Canvas) {
	if !v.shellWaiting || v.shell == nil {
		return
	}
	if wait := shellResizeDelay - (v.clock - v.shellWaitAt); wait > 0 {
		canvas.RequestFrameIn(wait)
		return
	}
	v.shellWaiting = false
	if v.shellCols != v.wantCols || v.shellRows != v.wantRows {
		v.tellShellSize(v.wantCols, v.wantRows)
	}
}

// tellShellSize resizes the shell's terminal and remembers the size it was told.
func (v *View) tellShellSize(cols, rows int) {
	v.shellCols, v.shellRows = cols, rows
	v.shell.Resize(cols, rows)
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
