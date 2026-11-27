// Package localshell runs the user's login shell on a pseudo-terminal of this
// machine. It has the shape of a remote shell (see sshconn.Shell): output is
// drained by the window thread, input is queued without blocking it, and the
// owner is woken when something arrives. The pseudo-terminal itself is a small
// per-platform backend: a pty on Unix, ConPTY on Windows.
package localshell

import (
	"errors"
	"fmt"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shellkind"
	"github.com/vivaui/viva/leaks"
	"io"
	"strings"
	"sync"
	"time"
)

const (
	// maxPendingOutput is how much output may wait for the window thread before
	// the reader pauses, which in turn pauses the program through the pty.
	maxPendingOutput = 1 << 20
	// maxPendingInput is how much typed or pasted input may wait to be written.
	maxPendingInput = 4 << 20
	// resizeInterval bounds PTY redraws during a window drag while keeping the
	// program up to date even when the window never pauses at one size.
	resizeInterval = time.Second / 60
)

// ArgsFor is how an interactive session starts the chosen program: Git Bash
// needs its login startup files, or /etc/profile and the bundled tools that
// live beside the binary are missing from the session.
func ArgsFor(program string) []string {
	name := program
	if cut := strings.LastIndexAny(name, `\/`); cut >= 0 {
		name = name[cut+1:]
	}
	if strings.EqualFold(name, "bash.exe") {
		return []string{"--login", "-i"}
	}
	return nil
}

// Config describes the shell to start.
type Config struct {
	// Cols and Rows are the terminal size in cells.
	Cols, Rows int
	// Shell is the program to run. Empty means the platform's default shell.
	Shell string
	// Args starts a specific local executable without interpreting a shell
	// command. Nil preserves the platform's normal interactive shell behavior.
	Args []string
	// Dir is the working directory. Empty means the user's home directory.
	Dir string
	// PromptToken enables prompt and command reports (OSC 133), bound to the
	// token, for the shells that support them: Bash and Zsh on Unix and in a WSL
	// distribution, and the prompts alone of PowerShell and cmd.exe on Windows.
	// It applies only when Args is nil. Empty leaves the shell's startup and
	// prompt untouched.
	PromptToken string
	// Env is added to the environment the shell inherits.
	Env []string
	// Unset names variables removed from the inherited environment, before Env is
	// added. A plugin terminal uses it for the overrides that remove a variable.
	Unset []string
	// Notify is called after output arrives and when the shell ends, from any
	// goroutine; it must not block.
	Notify func()
	// Degraded, when not nil, is told why the shell runs on a fallback, during
	// Start and on its goroutine. On Windows it is the bundled ConPTY that could
	// not be installed, loaded or create the console; the inbox ConPTY then hosts
	// the shell, which re-renders the program's output.
	Degraded func(error)
}

// backend is one platform's pseudo-terminal and the process on it.
type backend struct {
	// io is the terminal's master side: read what the program prints, write what
	// the user types.
	io io.ReadWriteCloser
	// resize tells the program the terminal size in cells.
	resize func(cols, rows int)
	// wait blocks until the program has ended and returns its exit status.
	wait func() (status int, err error)
	// hangup asks the program to end; kill makes sure it does. inputReady
	// reports that the terminal is in the shell line editor's input mode.
	// interruptInput abandons that input, and closeAtInput invokes the shell's
	// close key sequence once a fresh prompt has replaced it.
	hangup, kill   func()
	inputReady     func() bool
	interruptInput func()
	closeAtInput   func()
	// busy reports that a program other than the shell runs in the terminal. It is
	// called from any goroutine, also after the shell ended, and answers false when
	// it cannot tell.
	busy func() bool
	// promptToken is the token of the prompt marks the shell prints when it was
	// started with integration (see integration_scripts.go), else empty.
	promptToken string
}

// ExitError is why a shell ended with a nonzero status. It has the same
// ExitStatus method as an SSH exit error, so both are reported alike.
type ExitError struct{ Code int }

func (err *ExitError) Error() string   { return fmt.Sprintf("shell exited with status %d", err.Code) }
func (err *ExitError) ExitStatus() int { return err.Code }

// Shell is a running local shell.
type Shell struct {
	b      backend
	notify func()
	done   chan struct{}
	// readDone is closed when the reader has seen the end of the terminal.
	readDone chan struct{}

	mu       sync.Mutex
	space    *sync.Cond
	data     []byte
	finished bool
	exitErr  error

	input   chan []byte
	pending int
	closed  bool

	resizeWake         chan struct{}
	resizeMu           sync.Mutex
	wantCols, wantRows int
	curCols, curRows   int

	kind shellkind.Kind

	// marks follows the prompt marks of an integrated shell; nil without
	// integration. Only the reader uses it.
	marks *promptMarks
	// lastMark is the letter of the latest prompt mark, zero before the first, and
	// prompted says the shell has shown a prompt. promptShown, made by a Close that
	// waits for the prompt, is closed when the shell shows it. All are guarded by mu.
	lastMark    byte
	prompted    bool
	promptShown chan struct{}

	// promptCount counts finished primary prompts. closeThroughInput waits for
	// the one produced by interrupting the input that was active at close.
	promptCount int
}

// Kind is the family of the shell this session runs, Unknown when the program is
// not a shell Start recognizes.
func (shell *Shell) Kind() shellkind.Kind { return shell.kind }

// liveShells counts shells that were started and not yet closed: each holds a
// pty and four goroutines until Close.
var liveShells = leaks.New("local shells")

// Start launches the shell. It returns once the process is running.
func Start(config Config) (*Shell, error) {
	b, err := startBackend(config)
	if err != nil {
		return nil, err
	}
	liveShells.Acquire()
	cols, rows := max(config.Cols, 1), max(config.Rows, 1)
	shell := &Shell{
		b: b, notify: config.Notify, done: make(chan struct{}), readDone: make(chan struct{}),
		input: make(chan []byte, 256), kind: kindOf(config),
		resizeWake: make(chan struct{}, 1),
		wantCols:   cols, wantRows: rows, curCols: cols, curRows: rows,
		marks: newPromptMarks(b.promptToken),
	}
	shell.space = sync.NewCond(&shell.mu)
	go shell.readLoop()
	go shell.writeLoop()
	go shell.resizeLoop()
	go shell.wait()
	return shell, nil
}

func (shell *Shell) wake() {
	if shell.notify != nil {
		shell.notify()
	}
}

// kindOf names the shell Start runs, from the program alone: the arguments only
// shape how it starts, and the integration shim on Unix starts Bash or Zsh
// through sh.
func kindOf(config Config) shellkind.Kind {
	program := config.Shell
	if program == "" {
		program = defaultShell()
	}
	return shellkind.FromProgram(program)
}

// readLoop moves the program's output into the buffer. It blocks while the
// buffer is full, which stops reading the pty and so slows the program. Once the
// shell is closed nobody drains it: the reader keeps reading, so that a shell
// that settles before its hangup (see Close) can print its prompt, and drops
// what it reads.
func (shell *Shell) readLoop() {
	defer close(shell.readDone)
	buffer := make([]byte, 32<<10)
	for {
		n, err := shell.b.io.Read(buffer)
		if n > 0 {
			if shell.marks != nil {
				shell.marks.feed(buffer[:n], shell.sawMark)
			}
			shell.mu.Lock()
			for len(shell.data) >= maxPendingOutput && !shell.finished && !shell.closed {
				shell.space.Wait()
			}
			first := false
			if !shell.closed {
				first = len(shell.data) == 0
				shell.data = append(shell.data, buffer[:n]...)
			}
			shell.mu.Unlock()
			if first {
				shell.wake() // only the first chunk after a drain needs to wake the owner
			}
		}
		if err != nil {
			return
		}
	}
}

func (shell *Shell) writeLoop() {
	for data := range shell.input {
		shell.mu.Lock()
		shell.pending -= len(data)
		ended := shell.closed || shell.finished
		shell.mu.Unlock()
		if ended {
			return
		}
		// Input starts at the latest size. The actual write holds no resize
		// lock: a program that stops reading input can still be resized.
		shell.flushResize()
		if _, err := shell.b.io.Write(data); err != nil {
			return
		}
	}
}

func (shell *Shell) resizeLoop() {
	var timer *time.Timer
	var resizeReady <-chan time.Time
	defer func() {
		if timer != nil {
			timer.Stop()
		}
	}()
	for {
		select {
		case _, ok := <-shell.resizeWake:
			if !ok {
				return
			}
			// Keep the first deadline. Resetting it for every motion would
			// leave full-screen programs frozen until the drag ends.
			if resizeReady == nil {
				if timer == nil {
					timer = time.NewTimer(resizeInterval)
				} else {
					timer.Reset(resizeInterval)
				}
				resizeReady = timer.C
			}
		case <-resizeReady:
			resizeReady = nil
			shell.flushResize()
		case <-shell.done:
			return
		}
	}
}

func (shell *Shell) wait() {
	status, err := shell.b.wait()
	if err == nil && status != 0 {
		err = &ExitError{Code: status}
	}
	// The reader sees the end of the terminal once the last holder is gone; give
	// it time to deliver what the shell printed on its way out. A program that
	// left a child behind still holding the terminal does not keep us waiting.
	select {
	case <-shell.readDone:
	case <-time.After(readDrainGrace):
	}
	// Closing a Unix PTY early can make Bash read EOF before it handles SIGHUP.
	// By now the shell has had its chance to forward SIGHUP to its jobs.
	_ = shell.b.io.Close()
	shell.mu.Lock()
	shell.exitErr = err
	shell.finished = true
	shell.mu.Unlock()
	shell.space.Broadcast()
	close(shell.done)
	shell.wake()
}

// Busy reports that the shell is running a program: a command in the foreground on
// Unix, any child process of the shell on Windows. An ended shell, and a shell whose
// state cannot be read, is not busy. It may be called from any goroutine.
func (shell *Shell) Busy() bool {
	shell.mu.Lock()
	finished := shell.finished
	shell.mu.Unlock()
	return !finished && shell.b.busy != nil && shell.b.busy()
}

// Drain appends the output received since the last call to dst. It never blocks.
func (shell *Shell) Drain(dst []byte) []byte {
	shell.mu.Lock()
	dst = append(dst, shell.data...)
	if cap(shell.data) > 4*maxPendingOutput {
		shell.data = nil
	} else {
		shell.data = shell.data[:0]
	}
	shell.mu.Unlock()
	shell.space.Broadcast()
	return dst
}

// Write queues input for the program. It reports false when the shell has ended
// or the backlog is full; it never blocks the caller.
func (shell *Shell) Write(p []byte) bool {
	if len(p) == 0 {
		return true
	}
	shell.mu.Lock()
	defer shell.mu.Unlock()
	if shell.closed || shell.finished || shell.pending+len(p) > maxPendingInput {
		return false
	}
	select {
	case shell.input <- append([]byte(nil), p...):
		shell.pending += len(p)
		return true
	default:
		return false
	}
}

// Resize queues the terminal size in cells without blocking the caller.
// Updates within one frame interval collapse into the latest size.
func (shell *Shell) Resize(cols, rows int) {
	if cols < 1 || rows < 1 {
		return
	}
	shell.mu.Lock()
	defer shell.mu.Unlock()
	if shell.closed || shell.finished {
		return
	}
	if cols == shell.wantCols && rows == shell.wantRows {
		return
	}
	shell.wantCols, shell.wantRows = cols, rows
	select {
	case shell.resizeWake <- struct{}{}:
	default:
	}
}

// flushResize serializes the timer and input writer's size updates. Backend
// calls hold no shell-state lock, so a slow resize never blocks the window.
func (shell *Shell) flushResize() {
	shell.resizeMu.Lock()
	defer shell.resizeMu.Unlock()
	shell.mu.Lock()
	if shell.closed || shell.finished || (shell.wantCols == shell.curCols && shell.wantRows == shell.curRows) {
		shell.mu.Unlock()
		return
	}
	cols, rows := shell.wantCols, shell.wantRows
	shell.curCols, shell.curRows = cols, rows
	shell.mu.Unlock()
	if shell.b.resize != nil {
		shell.b.resize(cols, rows)
	}
}

// Done is closed once the shell has ended and its output is complete.
func (shell *Shell) Done() <-chan struct{} { return shell.done }

// Err is why the shell ended: nil for a clean exit or a hangup, an *ExitError for
// a nonzero status. Only meaningful after Done is closed.
func (shell *Shell) Err() error {
	shell.mu.Lock()
	defer shell.mu.Unlock()
	return shell.exitErr
}

// ExitStatus is the exit code of a shell that ended with one.
func (shell *Shell) ExitStatus() int {
	var exit *ExitError
	if errors.As(shell.Err(), &exit) {
		return exit.Code
	}
	return 0
}

// Close hangs the shell up and releases its goroutines. It does not wait.
//
// The shell passes the hangup on to the jobs it would end, and leaves those the user
// disowned. Bash does so only while it is interactive, and running PROMPT_COMMAND,
// which the integration uses, it is not; a job Zsh is still starting misses it too.
// A foreground program can also be part of PROMPT_COMMAND. Wait for the next
// prompt of an integrated shell that has already shown one, bounded by
// promptGrace. A shell without prompt information is hung up at once.
func (shell *Shell) Close() {
	shell.mu.Lock()
	if shell.closed {
		shell.mu.Unlock()
		return
	}
	shell.closed = true
	liveShells.Release()
	close(shell.input)
	if shell.resizeWake != nil {
		close(shell.resizeWake)
	}
	var shown chan struct{}
	if shell.prompted && shell.lastMark != 'B' && !shell.finished {
		shown = make(chan struct{})
		shell.promptShown = shown
	}
	shell.finished = true
	shell.mu.Unlock()
	// A reader waiting for room drops what it holds and reads on.
	shell.space.Broadcast()
	if shown != nil {
		go shell.hangUpAtPrompt(shown)
	} else {
		shell.hangUp()
	}
}

// hangUpAtPrompt hangs up a closed shell once it shows its prompt, ends, or has had
// promptGrace to get there.
func (shell *Shell) hangUpAtPrompt(shown <-chan struct{}) {
	timer := time.NewTimer(promptGrace)
	defer timer.Stop()
	select {
	case <-shown:
	case <-shell.done:
		return
	case <-timer.C:
	}
	shell.hangUp()
}

// hangUp asks the shell to end and kills it if it outlives killGrace. The
// waiter releases the terminal after the process exits and output is drained.
func (shell *Shell) hangUp() {
	select {
	case <-shell.done:
		return
	default:
	}
	shell.mu.Lock()
	atPrompt := shell.lastMark == 'B'
	shell.mu.Unlock()
	controlled := atPrompt && shell.b.inputReady != nil
	if controlled {
		go shell.hangupWhenInputReady()
	} else {
		shell.b.hangup()
	}
	grace := killGrace
	if controlled {
		// The controlled close first waits for the input mode. Give
		// that wait the same promptGrace a shell between commands already
		// gets before the forced-exit deadline starts.
		grace += 2 * promptGrace
	}
	kill := time.AfterFunc(grace, shell.b.kill)
	go func() {
		<-shell.done
		kill.Stop()
	}()
}

// hangupWhenInputReady waits the short input-mode transition after Bash draws
// its prompt. Readline puts the terminal into noncanonical no-echo mode only
// once it owns input, which is when the controlled close can safely discard the
// input line. Without the transition the plain hangup remains the fallback.
func (shell *Shell) hangupWhenInputReady() {
	deadline := time.NewTimer(promptGrace)
	defer deadline.Stop()
	poll := time.NewTicker(5 * time.Millisecond)
	defer poll.Stop()
	for {
		if shell.b.inputReady() {
			shell.closeThroughInput()
			return
		}
		select {
		case <-shell.done:
			return
		case <-deadline.C:
			shell.b.hangup()
			return
		case <-poll.C:
		}
	}
}

// closeThroughInput abandons whatever input Readline holds, including the
// continuation of a multiline command, then waits for the fresh prompt before
// invoking the close key sequence. The wait is ordered by inputReady: once the
// shell is reading this input, no newer primary prompt can already be on its
// way. If the interrupt is lost, the plain-hangup fallback remains.
func (shell *Shell) closeThroughInput() {
	shell.mu.Lock()
	target := shell.promptCount + 1
	shell.mu.Unlock()
	shell.b.interruptInput()
	deadline := time.NewTimer(promptGrace)
	defer deadline.Stop()
	poll := time.NewTicker(5 * time.Millisecond)
	defer poll.Stop()
	for {
		shell.mu.Lock()
		ready := shell.promptCount >= target
		shell.mu.Unlock()
		if ready {
			shell.b.closeAtInput()
			go shell.hangupAfterControlledClose()
			return
		}
		select {
		case <-shell.done:
			return
		case <-deadline.C:
			shell.b.hangup()
			return
		case <-poll.C:
		}
	}
}

// hangupAfterControlledClose covers shells whose Readline cannot bind the
// controlled close, or whose user startup replaced the binding. The close
// command normally leaves long before this; when it did not, the shell is in
// the same input state in which a plain hangup is the best remaining shutdown.
func (shell *Shell) hangupAfterControlledClose() {
	delay := time.NewTimer(controlledCloseFallbackDelay)
	defer delay.Stop()
	select {
	case <-shell.done:
	case <-delay.C:
		shell.b.hangup()
	}
}

// sawMark records a prompt mark the reader found in the output.
func (shell *Shell) sawMark(kind byte) {
	shell.mu.Lock()
	defer shell.mu.Unlock()
	shell.lastMark = kind
	if kind != 'B' {
		return
	}
	shell.promptCount++
	shell.prompted = true
	if shell.promptShown != nil {
		close(shell.promptShown)
		shell.promptShown = nil
	}
}

// controlledCloseFallbackDelay lets a working close key binding finish before
// the plain-hangup fallback is tried.
const controlledCloseFallbackDelay = 100 * time.Millisecond

// killGrace is how long a shell gets to leave after a hangup before it is killed.
const killGrace = 500 * time.Millisecond

// promptGrace is how long a closed shell between a command and its next prompt may
// take to show the prompt before it is hung up.
const promptGrace = time.Second

// readDrainGrace is the longest the end of a shell waits for its last output.
const readDrainGrace = 300 * time.Millisecond
