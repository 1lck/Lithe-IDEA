package termview

import (
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/vivaui/viva/gfx"
)

// launchDeadline bounds every wait in these tests, and also how long a held start waits to
// be released, so a view that waited for its start on the window thread fails the test
// instead of hanging it.
const launchDeadline = 5 * time.Second

// launchedShell is the fake shell a held start opens: it records the sizes it is told and
// ends when it is closed, so a test can wait for the view to let it go.
type launchedShell struct {
	fakeShell
	sizes  [][2]int
	closes int
}

func (s *launchedShell) Resize(cols, rows int) { s.sizes = append(s.sizes, [2]int{cols, rows}) }
func (s *launchedShell) Close() {
	s.closes++
	if s.closes == 1 {
		close(s.done)
	}
}

// heldStart is a shell start the test holds open. entered is closed once the view has
// begun the start, the start returns its shell or error once release is called, and woken
// receives the wake the finished start asks the window for.
type heldStart struct {
	entered chan struct{}
	woken   chan struct{}
	release func()
	start   func(localshell.Config) (shell, error)
}

func newHeldStart(t *testing.T, opened shell, err error, degraded ...error) *heldStart {
	t.Helper()
	entered, released := make(chan struct{}), make(chan struct{})
	var once sync.Once
	h := &heldStart{entered: entered, woken: make(chan struct{}, 1)}
	h.release = func() { once.Do(func() { close(released) }) }
	t.Cleanup(h.release)
	h.start = func(config localshell.Config) (shell, error) {
		close(entered)
		for _, reason := range degraded {
			config.Degraded(reason)
		}
		select {
		case <-released:
		case <-time.After(launchDeadline):
		}
		return opened, err
	}
	return h
}

// view makes a view whose shell starts through h, woken through h, and closed and waited
// for when the test ends.
func (h *heldStart) view(t *testing.T, config Config) *View {
	t.Helper()
	config.start = h.start
	config.Notify = func() {
		select {
		case h.woken <- struct{}{}:
		default:
		}
	}
	view := New(config)
	t.Cleanup(func() {
		ended := view.Close()
		h.release()
		within(t, ended, "the view's shell ending")
	})
	return view
}

func within(t *testing.T, ch <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(launchDeadline):
		t.Fatalf("waited %v for %s", launchDeadline, what)
	}
}

// The shell starts off the window thread: starting returns while the program is still
// being found, the view takes the shell over at the Pump the finished start wakes, and
// what was typed meanwhile reaches it then, in the order it was typed. The log hears
// that the start fell back, from the window thread, once the view has the shell.
func TestAShellStartsOffTheWindowThreadAndGetsWhatWasTypedMeanwhile(t *testing.T) {
	reason := errors.New("conpty: install conpty.dll: access denied")
	fake := &launchedShell{fakeShell: fakeShell{done: make(chan struct{})}}
	held := newHeldStart(t, fake, nil, reason)
	var failures []Failure
	view := held.view(t, Config{Shell: "tool", Args: []string{}, HitID: gfx.Item(1),
		Failed: func(f Failure) { failures = append(failures, f) }})

	view.Start()
	within(t, held.entered, "the start to begin")
	if view.shell != nil {
		t.Fatal("the view waited for its shell to start")
	}
	if view.Pump() || view.shell != nil {
		t.Fatal("a Pump before the start finished took a shell over")
	}
	if _, ok := view.Key(gfx.KeyEvent{Target: gfx.Item(1), Key: gfx.KeyEnter}); !ok {
		t.Fatal("the terminal did not take a key while its shell started")
	}
	if !view.Paste("echo hi") || !view.SendLine("ls") {
		t.Fatal("input for a starting shell was refused")
	}
	if len(failures) != 0 {
		t.Fatalf("the view logged %+v before it had the shell", failures)
	}

	held.release()
	within(t, held.woken, "the finished start to wake the window")
	view.Pump()
	if view.shell != fake {
		t.Fatal("the Pump the start woke did not take the shell over")
	}
	if got, want := string(fake.input), "\recho hils\r"; got != want {
		t.Fatalf("the shell got %q, want %q", got, want)
	}
	want := Failure{Event: eventBackgroundFailed, Operation: operationConPTY, Warn: true, Err: reason}
	if len(failures) != 1 || failures[0] != want {
		t.Fatalf("the view logged %+v, want %+v", failures, want)
	}
}

// A grid laid out anew while the shell starts is told to the shell as soon as the view
// takes it over: the shell started in the old size and has printed no prompt to wait for.
func TestAShellIsToldTheGridLaidOutWhileItStarted(t *testing.T) {
	fake := &launchedShell{fakeShell: fakeShell{done: make(chan struct{})}}
	held := newHeldStart(t, fake, nil)
	view := held.view(t, Config{Shell: "tool", Args: []string{}})

	view.Start()
	within(t, held.entered, "the start to begin")
	cols, rows := view.screen.Size()
	view.fit(geometry{cols: cols + 10, rows: rows + 5})

	held.release()
	within(t, held.woken, "the finished start to wake the window")
	view.Pump()
	if want := [][2]int{{cols + 10, rows + 5}}; len(fake.sizes) != 1 || fake.sizes[0] != want[0] {
		t.Fatalf("the shell was told %v, want %v", fake.sizes, want)
	}
}

// A view closed while its shell starts ends that shell as soon as it has started, drops
// what was typed for it, and never starts another. The channel Close returns waits for
// the start and the shell's end, so the workbench does not lose track of the process.
func TestClosingAViewWhileItsShellStartsEndsTheShellOnceStarted(t *testing.T) {
	fake := &launchedShell{fakeShell: fakeShell{done: make(chan struct{})}}
	held := newHeldStart(t, fake, nil)
	view := held.view(t, Config{Shell: "tool", Args: []string{}})

	view.Start()
	within(t, held.entered, "the start to begin")
	view.SendLine("make clean")
	if view.BusyProbe() != nil {
		t.Fatal("a shell that is still starting was offered as busy with a program")
	}
	ended := view.Close()
	select {
	case <-ended:
		t.Fatal("Close reported the shell ended before its start had finished")
	default:
	}

	held.release()
	within(t, ended, "the abandoned shell to end")
	if fake.closes != 1 {
		t.Fatalf("the abandoned shell was closed %d times, want once", fake.closes)
	}
	if len(fake.input) != 0 {
		t.Fatalf("input typed for a closed view reached its shell: %q", fake.input)
	}
	view.Pump()
	view.ensureStarted()
	if view.shell != nil || view.launching != nil {
		t.Fatal("a closed view took a shell over or started another")
	}
}

// A shell that cannot be started off the window thread ends the view at the Pump the
// failed start wakes: the reason is written into the grid and logged, and the owner hears
// the program ended without a status.
func TestAShellThatFailsToStartOffTheWindowThreadEndsTheView(t *testing.T) {
	held := newHeldStart(t, nil, errors.New("not found"))
	var failures []Failure
	exits := 0
	var status *int
	view := held.view(t, Config{Shell: "missing",
		Messages: Messages{StartFailed: func(reason string) string { return reason }},
		Exited:   func(s *int) { exits, status = exits+1, s },
		Failed:   func(f Failure) { failures = append(failures, f) }})

	view.Start()
	within(t, held.entered, "the start to begin")
	view.SendLine("ls")
	if exits != 0 || view.ended {
		t.Fatal("the view ended before its start had failed")
	}

	held.release()
	within(t, held.woken, "the failed start to wake the window")
	if !view.Pump() {
		t.Fatal("the failed start asked for no paint")
	}
	if !view.ended || view.live() || exits != 1 || status != nil {
		t.Fatalf("ended=%v live=%v exits=%d status=%v, want an ended view and one exit without a status",
			view.ended, view.live(), exits, status)
	}
	if len(failures) != 1 || failures[0].Event != eventStartFailed {
		t.Fatalf("the view logged %+v, want one %s", failures, eventStartFailed)
	}
}

// A command sent to a terminal that was never painted, such as one just made to run the
// editor's selection, starts its shell and reaches it, instead of being dropped.
func TestSendLineStartsAViewThatWasNeverPainted(t *testing.T) {
	var started localshell.Config
	fake := &fakeShell{done: make(chan struct{})}
	view := newFakeView(fake, Config{Shell: "tool", Args: []string{}}, &started)
	t.Cleanup(func() { view.Close() })
	if !view.SendLine("make test") {
		t.Fatal("a line sent to a view that was never painted was refused")
	}
	if got, want := string(fake.input), "make test\r"; got != want {
		t.Fatalf("the shell got %q, want %q", got, want)
	}
}
