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
	// DirectoryToken enables prompt directory reports for supported local shells.
	// Empty leaves the shell's startup and prompt untouched.
	DirectoryToken string
	// WSLScript is the sh program a WSL distribution runs to start its user's
	// login shell with directory reports (Shell "wsl:<distribution>"). Empty
	// starts the distribution's own login shell untouched.
	WSLScript string
	// Env is added to the environment the shell inherits.
	Env []string
	// Unset names variables removed from the inherited environment, before Env is
	// added. A plugin terminal uses it for the overrides that remove a variable.
	Unset []string
	// Notify is called after output arrives and when the shell ends, from any
	// goroutine; it must not block.
	Notify func()
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
	// hangup asks the program to end; kill makes sure it does.
	hangup, kill func()
	// busy reports that a program other than the shell runs in the terminal. It is
	// called from any goroutine, also after the shell ended, and answers false when
	// it cannot tell.
	busy func() bool
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
// buffer is full, which stops reading the pty and so slows the program.
func (shell *Shell) readLoop() {
	defer close(shell.readDone)
	buffer := make([]byte, 32<<10)
	for {
		n, err := shell.b.io.Read(buffer)
		if n > 0 {
			shell.mu.Lock()
			for len(shell.data) >= maxPendingOutput && !shell.finished {
				shell.space.Wait()
			}
			first := len(shell.data) == 0
			shell.data = append(shell.data, buffer[:n]...)
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
	shell.mu.Unlock()
	shell.b.hangup()
	timer := time.AfterFunc(killGrace, shell.b.kill)
	go func() {
		<-shell.done
		timer.Stop()
	}()
	_ = shell.b.io.Close()
	shell.mu.Lock()
	shell.finished = true
	shell.mu.Unlock()
	shell.space.Broadcast()
}

// killGrace is how long a shell gets to leave after a hangup before it is killed.
const killGrace = 500 * time.Millisecond

// readDrainGrace is the longest the end of a shell waits for its last output.
const readDrainGrace = 300 * time.Millisecond
