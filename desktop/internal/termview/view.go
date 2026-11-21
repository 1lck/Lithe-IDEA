// Package termview is the terminal of the Terminal tool window: a local shell, the screen
// its output builds (package term) and the grid that paints that screen.
//
// It is ported from motty's workbench terminal (Apache-2.0, see NOTICE in this directory)
// and keeps its design: the screen keeps lines with stable IDs and versions; a row cache
// prepares each line's text, colored runs and backgrounds once and reuses them while the
// line, the cursor on it and the palette stay the same; and Viva caches the shaped text and
// the surfaces. Output is parsed on the window thread within a time budget per frame, in
// slices, so a flood of output never stalls the window, and the shell's own backlog limit
// pushes back on a program that writes faster than the screen takes it in.
//
// Every method runs on the window thread. The shell is started on a goroutine of its own
// (see start), which then calls Config.Notify; Config.Notify is also called from the
// shell's reader. No other call is made from another goroutine.
package termview

import (
	"cmp"
	"strings"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shellkind"
	"github.com/1lck/Lithe-IDEA/desktop/internal/term"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// The margins around the terminal's grid.
const (
	padX      = float32(14)
	padTop    = float32(8)
	padBottom = float32(8)
)

// The smallest grid a pane is laid out at, however small the panel is dragged.
const (
	minCols = 20
	minRows = 5
)

// scrollbackLines is how much history the terminal keeps above its screen.
const scrollbackLines = 5000

// The parsing budget. pumpBudget is how long one frame may spend feeding output into the
// screen while more is waiting: a quarter of a 60 Hz frame. pumpSlice is how much is fed
// between two looks at the clock, small enough that one slice never overruns the budget by
// much.
const (
	pumpBudget = time.Second / 240
	pumpSlice  = 32 << 10
	// rxKeep is the drain buffer size kept between floods; a larger one is let go once
	// it is empty so a burst does not hold its memory for the life of the session.
	rxKeep = 1 << 22
)

// The escape sequences the terminal writes for its own notes in the grid.
const (
	sgrMuted = "\x1b[90m"
	sgrFail  = "\x1b[31m"
	sgrReset = "\x1b[0m"
)

// barLinger is how long the scrollbar stays after the view last moved.
const barLinger = time.Second

// Messages are the words the terminal shows. The workbench fills them from its catalog.
type Messages struct {
	// Label is the accessible name of the grid.
	Label string
	// ScrollbarLabel is the accessible name of the scrollbar.
	ScrollbarLabel string
	// SessionEnded is written into the grid when the shell exits cleanly.
	SessionEnded string
	// SessionEndedStatus is written when the shell exits with a status other than 0.
	SessionEndedStatus func(status int) string
	// RestartHint follows the end of a session: Enter starts a new shell.
	RestartHint string
	// StartFailed is written when the shell cannot be started.
	StartFailed func(reason string) string
}

// Look is the terminal's colors, taken from the workbench theme each frame. A change starts
// a new palette epoch, so every cached row is prepared again in the new colors.
type Look struct {
	Dark bool
	// Background is what the grid is painted on. It may be translucent or clear, so the
	// window behind the terminal shows through, such as the workbench background image.
	Background gfx.Color
	// Solid is the terminal's own opaque color: the ink of inverse cells and of the text
	// under the cursor, the clear under an input method's composition, and what native ANSI
	// colors are measured against. The zero value takes Background.
	Solid      gfx.Color
	Foreground gfx.Color
	Cursor     gfx.Color
	Selection  gfx.Color
	// Native is the system terminal's ANSI colors, nil for none: an entry it sets replaces the
	// built-in one when it stands out enough from Solid (see nativeContrast).
	Native *[16]NativeColor
}

// NativeColor is one ANSI color of the system terminal's profile; Set is false where the
// profile keeps the system's own default.
type NativeColor struct {
	RGB [3]uint8
	Set bool
}

// Failure is a failure the terminal reports to the client's log.
type Failure struct {
	// Event is the catalog event ID.
	Event string
	// Stage is the event's stage field; empty when the event has none.
	Stage string
	// Operation is the event's operation field; empty when the event has none.
	Operation string
	// Warn records the event at warn level; otherwise it is recorded at debug level.
	Warn bool
	Err  error
}

// The catalog events the terminal reports.
const (
	eventStartFailed = "terminal.session.start_failed"
	eventInputFailed = "terminal.input.failed"
	stageSpawn       = "spawn"
	stageSend        = "send"
	// eventBackgroundFailed with operationConPTY is a shell that started on a fallback: the
	// ConPTY the Windows client carries could not host it, so the inbox one does and
	// re-renders the program's output.
	eventBackgroundFailed = "app.background.operation_failed"
	operationConPTY       = "terminal_conpty"
)

// Config sets up a terminal view.
type Config struct {
	// Dir is the working directory of each shell the view starts.
	Dir string
	// Scrollback is how many lines of history the view keeps above its screen; zero
	// keeps scrollbackLines.
	Scrollback int
	// Shell is the program to run; empty runs the user's default shell.
	Shell string
	// HitID is the grid's hit; keyboard focus rests on it. BarID is the scrollbar's.
	HitID, BarID gfx.ID
	// Messages are the words the view shows.
	Messages Messages
	// Notify asks the window for a wake (its OnWake then calls Pump). It is called from the
	// shell's reader goroutine and must be safe to call from any goroutine.
	Notify func()
	// Failed records a failure in the client's log. It may be nil.
	Failed func(Failure)
	// Args are the program's arguments. Nil runs the program the way the shell
	// menu does (see localshell.ArgsFor); an empty slice runs it with none.
	Args []string
	// Env adds variables to the program's environment and Unset removes inherited
	// ones.
	Env, Unset []string
	// Prefill is plain text written into the screen before the program starts, for
	// a reopened terminal. It never reaches the program's input.
	Prefill string
	// Exited is called once when the program ends or cannot start, with its exit
	// status when it has one. A view with Exited set does not restart on Enter: the
	// owner decides what happens next.
	Exited func(status *int)
	// Clipboard reads the system clipboard for a paste. Nil uses app.ClipboardText.
	Clipboard func() (string, error)
	// PasteImage is asked first when a paste into a live shell finds no text on the
	// clipboard, and reports whether it took the paste over, as the workbench does
	// for a picture it saves and types the path of. Nil, or a false answer, sends the
	// empty paste a program that reads the clipboard itself waits for. It runs on the
	// window thread and must not block.
	PasteImage func() bool
	// OpenLink opens a link the user Command- (Control- off macOS) clicked. Nil leaves
	// links inert.
	OpenLink func(target string)
	// Open starts the program somewhere other than this machine, such as on the host of a
	// remote workspace, in a grid of cols by rows cells. The view then gives it Args as they
	// are, leaves Shell, Dir, Env and Unset to Open, and starts it plain, without the prompt
	// integration of localshell.Config.PromptToken. Open runs off the window thread when
	// Notify is set and may block until the program runs; the Shell it returns must keep
	// every promise of Shell. Nil starts a local shell.
	Open func(cols, rows int) (Shell, error)
	// start opens a shell; nil uses localshell.Start, or Open when it is set. It runs off the
	// window thread when Notify is set (see View.start). Tests replace it.
	start func(localshell.Config) (shell, error)
}

// shell is the name the view uses for Shell.
type shell = Shell

// Shell is the part of *localshell.Shell the view uses, so tests and Config.Open can stand
// in for it.
type Shell interface {
	// Drain appends the output received since the last call to dst. It never blocks.
	Drain(dst []byte) []byte
	// Write queues input for the shell and reports whether it was accepted: false once the
	// shell has ended or its backlog is full.
	Write(p []byte) bool
	// Resize tells the pty the terminal size in cells.
	Resize(cols, rows int)
	// Done is closed once the shell has ended and all its output is drainable.
	Done() <-chan struct{}
	// Err says why the shell ended; nil for a clean exit.
	Err() error
	// Busy reports that the shell runs a program; it may be called from any goroutine.
	Busy() bool
	// Kind names the family of the program the shell runs, from its name alone.
	Kind() shellkind.Kind
	// Close ends the shell. It may be called from any goroutine: a view closed while its
	// shell was starting closes the shell from the goroutine that waits for the start.
	Close()
}

// geometry is where the grid of the last paint was: the area the view was given, the
// top-left corner of its first cell and its size in cells.
type geometry struct {
	area      gfx.Rect
	left, top float32
	cols      int
	rows      int
}

// palette is the terminal's resolved colors. epoch changes with every new Look, so a row
// prepared in older colors is never reused.
type palette struct {
	dark      bool
	terminal  gfx.Color // the terminal's own opaque color, see Look.Solid
	ground    gfx.Color // the ground the grid is painted on, see Look.Background
	termFG    gfx.Color // the default ink
	cursor    gfx.Color
	selection gfx.Color
	ansi      [16][3]uint8 // the 16 ANSI colors; term.Resolve derives the 240 others
	epoch     uint32
}

// barState is the scrollbar's interaction and fade.
type barState struct {
	dragging bool          // the thumb is held
	grab     float32       // where on the thumb it was taken
	offset   int           // view offset the bar last saw, to notice the view moving
	since    time.Duration // when the bar was last lit
	lit      bool          // the bar is lit or still lingering
}

// View is one terminal: its shell, its screen and the state of painting and input.
type View struct {
	cfg Config

	screen *term.Terminal
	// owner is the view's number in the text identities its rows are painted with (see
	// paintGrid). Line IDs are only unique within one screen, so two terminals painted
	// in one frame need different owners.
	owner uint32
	shell shell
	// launching is the shell being started, nil when none is; queued is what was typed
	// for it meanwhile. See start.
	launching *launch
	queued    []byte
	rx        []byte // scratch the shell's output is drained into
	// shellCols and shellRows are the size the shell was last told; wantCols and wantRows
	// are the size a shell at its prompt is waiting to be told, once it has held since
	// shellWaitAt. See resizeShell.
	shellCols, shellRows int
	wantCols, wantRows   int
	shellWaiting         bool
	shellWaitAt          time.Duration
	// ended is true once a shell finished or failed to start. Enter starts a new one.
	ended bool
	// closed is true after Close: the view starts no shell again.
	closed bool
	// exitSent is true once Exited was called.
	exitSent bool

	// font is the fixed-pitch font the grid is drawn with. SetFont changes it, and it always
	// holds a normalized font, so two fonts that draw alike are equal.
	font Font
	// cellW and glyphH are the character cell of the font, and rowH the pitch of a row: glyphH
	// times the font's line spacing, rounded to a whole pixel. All three are measured on the
	// window's canvas at each paint and are zero before the first. Everything that turns a
	// distance into rows (placing rows, the grid's size, the pointer, the wheel, the
	// scrollbar) uses rowH; only the text itself is drawn glyphH tall.
	cellW, glyphH, rowH float32
	layout              geometry // the grid of the last paint
	// cursorThickness is how thick a bar or an underline cursor draws; SetCursor sets it.
	cursorThickness CursorThickness
	// options are the Terminal settings page's switches; SetOptions sets them.
	options Options

	look    Look
	hasLook bool
	pal     palette
	cache   rowCache

	selection terminalSelection
	// generation is the screen's buffer generation the selection was last reconciled
	// with (see reconcileSelection).
	generation uint64
	find       findState
	blink      cursorBlink
	bar        barState

	// preedit is the input method's composition, drawn over the cursor's cells.
	preedit app.TextState
	// input is reused so resolving the text input allocates nothing.
	input app.TextInput

	wheelY float32 // vertical wheel travel not yet worth a whole line
	wheelX float32 // horizontal wheel travel not yet worth a whole cell

	// The mouse report a program asked for: the encoding scratch, the button held and the
	// last cell reported, so a motion inside one cell is not sent again.
	mouseReport        [64]byte
	mouseButton        term.MouseEventButton
	mousePosition      term.Position
	mousePositionValid bool

	// clock is the time the selection's edge scroll steps by; it is the canvas time of the
	// last paint or event. paced is whether that canvas has a clock at all: without one the
	// time stands still, and nothing may wait for it to pass.
	clock time.Duration
	paced bool
}

// owners numbers the views for their text identities.
var owners atomic.Uint32

// nextOwner is a new view's owner number. Zero means no identity to Viva, so it is never
// handed out, even after the count wraps.
func nextOwner() uint32 {
	for {
		if owner := owners.Add(1); owner != 0 {
			return owner
		}
	}
}

// New makes a terminal view. Its shell starts at the first paint, once the grid's size is
// known.
func New(cfg Config) *View {
	if cfg.start == nil && cfg.Open != nil {
		openElsewhere := cfg.Open
		cfg.start = func(config localshell.Config) (shell, error) { return openElsewhere(config.Cols, config.Rows) }
	}
	if cfg.start == nil {
		cfg.start = func(config localshell.Config) (shell, error) {
			opened, err := localshell.Start(config)
			if err != nil {
				return nil, err
			}
			return opened, nil
		}
	}
	if cfg.Clipboard == nil {
		cfg.Clipboard = app.ClipboardText
	}
	v := &View{
		cfg:    cfg,
		screen: term.New(80, 24, cmp.Or(cfg.Scrollback, scrollbackLines)),
		owner:  nextOwner(),
		layout: geometry{cols: 80, rows: 24},
		font:   DefaultFont(),
	}
	if cfg.Prefill != "" {
		v.screen.Write([]byte(strings.ReplaceAll(strings.ReplaceAll(cfg.Prefill, "\r\n", "\n"), "\n", "\r\n") + "\r\n"))
		v.generation = v.screen.BufferGeneration()
	}
	return v
}

// RetainedText is the plain text of the screen and its history, cut to the last
// budget bytes without splitting a character. It reads no input and keeps no
// escape sequence, so it is a rendering snapshot, not a replayable record.
func (v *View) RetainedText(budget int) string {
	if budget <= 0 {
		return ""
	}
	text := v.screen.AppendRetainedText(nil)
	if len(text) > budget {
		text = text[len(text)-budget:]
		for len(text) > 0 && !utf8.RuneStart(text[0]) {
			text = text[1:]
		}
	}
	return string(text)
}

// Bind gives the view the identities a page's Control declared for it: hit is the Control's own,
// which takes the keyboard focus, and parts is its Handlers.Parts scope, whose part 0 is the
// scrollbar. The host calls it from the Control's draw callback, before Paint.
func (v *View) Bind(hit gfx.ID, parts gfx.Scope) {
	v.cfg.HitID, v.cfg.BarID = hit, parts.At(0)
}

// Owns reports whether a hit belongs to the view: its grid or its scrollbar.
func (v *View) Owns(id gfx.ID) bool {
	return !id.IsZero() && (id == v.cfg.HitID || id == v.cfg.BarID)
}

// SetMessages replaces the words the view shows, for a change of the window's language.
// What is already written into the grid stays in the language it was written in.
func (v *View) SetMessages(messages Messages) { v.cfg.Messages = messages }

// BusyProbe returns what tells whether the running shell is busy with a program, nil
// when no shell runs, including one that is still starting: it runs nothing yet, and
// closing it ends the start (see Close). The probe may be called from any goroutine and
// answers false once that shell has ended, so it can be taken now and asked off the
// window thread.
func (v *View) BusyProbe() func() bool {
	if v.shell == nil {
		return nil
	}
	return v.shell.Busy
}

// SendLine types text into the shell as one command line, followed by the Enter key. It reports
// whether the shell accepted it. A view that has not started its shell yet, such as a terminal
// just made to run a command before it was ever painted, starts it, and the line waits for it.
func (v *View) SendLine(text string) bool {
	v.ensureStarted()
	return v.sendInput([]byte(text + "\r"))
}

// Close ends the shell and keeps the view from starting another. It returns a channel that
// is closed once the shell's process has ended and the shell has let go of what it holds;
// the shell is killed when it outlives its grace period, so the channel is closed soon. A
// shell that is still starting is ended as soon as it has started, and what was typed for
// it is dropped; the channel then waits for both. A view with no shell returns a closed
// one.
func (v *View) Close() <-chan struct{} {
	v.closed = true
	if l := v.launching; l != nil {
		v.launching, v.queued = nil, nil
		ended := make(chan struct{})
		go func() {
			defer close(ended)
			<-l.done
			if l.shell != nil {
				l.shell.Close()
				<-l.shell.Done()
			}
		}()
		return ended
	}
	if v.shell == nil {
		return closedChannel
	}
	done := v.shell.Done()
	v.shell.Close()
	v.shell = nil
	return done
}

// closedChannel is the end of a shell that is already gone.
var closedChannel = func() chan struct{} {
	c := make(chan struct{})
	close(c)
	return c
}()

// failed reports a failure to the client's log.
func (v *View) failed(failure Failure) {
	if v.cfg.Failed != nil {
		v.cfg.Failed(failure)
	}
}
