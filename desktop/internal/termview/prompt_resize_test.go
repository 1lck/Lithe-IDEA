package termview

import (
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
)

// The user's shell reports its prompts under a token new to each start, and only the
// markers of the shell now running count.
func TestTheUsersShellReportsItsPromptsUnderATokenNewToEachStart(t *testing.T) {
	var started localshell.Config
	shell := &fakeShell{done: make(chan struct{})}
	view := newFakeView(shell, Config{Shell: "/bin/zsh"}, &started)
	t.Cleanup(func() { view.Close() })
	view.ensureStarted()
	first := started.PromptToken
	// The shell integration takes letters, digits, '-' and '_', at most 128 of them.
	valid := func(token string) bool {
		return token != "" && len(token) <= 128 && strings.Trim(token, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_") == ""
	}
	if !valid(first) || started.Args != nil {
		t.Fatalf("the user's shell started with token %q and arguments %q", first, started.Args)
	}
	output(view, shell, "\x1b]133;C;motty="+first+"\a")
	if !view.screen.CommandReporting() {
		t.Fatal("the shell's own command mark did not count")
	}

	close(shell.done)
	view.Pump()
	shell.done = make(chan struct{})
	if !view.restart() {
		t.Fatal("the ended shell did not restart")
	}
	second := started.PromptToken
	if !valid(second) || second == first {
		t.Fatalf("the restarted shell has token %q after %q", second, first)
	}
	if view.screen.CommandReporting() {
		t.Fatal("the restarted shell inherited the command marks of the one before")
	}
	output(view, shell, "\x1b]133;C;motty="+first+"\a")
	if view.screen.CommandReporting() {
		t.Fatal("the token of the shell before the restart still counts")
	}
}

// A program started with arguments of its own, which includes a shell the platform starts
// with some, is left as it is: it gets no token, so nothing it prints is taken for a prompt.
func TestAProgramWithArgumentsOfItsOwnGetsNoToken(t *testing.T) {
	for _, config := range []Config{
		{Shell: "tool", Args: []string{}},
		{Shell: "/bin/bash", Args: []string{"-c", "true"}},
		{Shell: `C:\Program Files\Git\bin\bash.exe`},
	} {
		var started localshell.Config
		view := newFakeView(&fakeShell{done: make(chan struct{})}, config, &started)
		view.ensureStarted()
		view.Close()
		if started.PromptToken != "" {
			t.Errorf("%s %q started with token %q", config.Shell, started.Args, started.PromptToken)
		}
	}
}

// promptMarks is a shell that ran a command and is back at its prompt, "$ ", reported
// under the token "t".
const promptMarks = "\x1b]133;C;motty=t\a\x1b]133;D;0;motty=t\a\x1b]133;A;motty=t\a$ \x1b]133;B;motty=t\a"

// clockRig is a font rig painted on a canvas with a clock the test sets, its shell
// reporting under the token "t" and having printed marks.
type clockRig struct {
	*fontRig
	now time.Duration
}

func newClockRig(t *testing.T, marks string) *clockRig {
	t.Helper()
	rig := &clockRig{fontRig: newFontRig(t)}
	rig.canvas.SetClock(func() time.Duration { return rig.now })
	rig.view.screen.SetPromptToken("t")
	output(rig.view, &rig.shell.fakeShell, marks)
	return rig
}

// paintCols paints one frame into an area cols columns wide and 30 rows tall, at the rig's
// time, and returns when that frame asked to be painted again.
func (r *clockRig) paintCols(cols int) (time.Duration, bool) {
	r.canvas.Reset()
	r.canvas.BeginFrame()
	area := fontTestArea
	area.Width += float32(cols-80) * 6.5
	r.view.Paint(r.canvas, area, fontTestLook)
	r.canvas.EndFrame()
	return r.canvas.NextFrame()
}

// A shell at its prompt is told its size once the size holds, so a drag cannot leave it
// redrawing its prompt for widths the screen has already left. The screen follows every
// step.
func TestAShellAtItsPromptIsToldItsSizeOnceItHolds(t *testing.T) {
	rig := newClockRig(t, promptMarks)
	if !rig.view.screen.AtPrompt() {
		t.Fatal("the shell is not at the prompt its marks reported")
	}
	rig.paintCols(90)
	rig.now += 40 * time.Millisecond
	delay, asked := rig.paintCols(100)
	if len(rig.shell.sizes) != 0 {
		t.Fatalf("the shell was told %v while the size was still changing", rig.shell.sizes)
	}
	if cols, _ := rig.view.screen.Size(); cols != 100 {
		t.Fatalf("the screen is %d columns wide, not the 100 of the grid", cols)
	}
	if !asked || delay > shellResizeDelay {
		t.Fatalf("the paint asked for a frame in %v (%v), not within %v", delay, asked, shellResizeDelay)
	}
	rig.now += shellResizeDelay - time.Millisecond
	rig.paintCols(100)
	if len(rig.shell.sizes) != 0 {
		t.Fatalf("the shell was told %v before the size had held", rig.shell.sizes)
	}
	rig.now += time.Millisecond
	rig.paintCols(100)
	rig.now += time.Second
	rig.paintCols(100)
	if want := [][2]int{{100, 30}}; !slices.Equal(rig.shell.sizes, want) {
		t.Fatalf("the shell was told %v, want the size that held, once: %v", rig.shell.sizes, want)
	}
}

// A size that comes back to the one the shell has before it held is not sent at all.
func TestASizeThatComesBackIsNotSentToAShellAtItsPrompt(t *testing.T) {
	rig := newClockRig(t, promptMarks)
	rig.paintCols(90)
	rig.now += 40 * time.Millisecond
	rig.paintCols(80)
	rig.now += time.Second
	if _, asked := rig.paintCols(80); asked {
		t.Fatal("the view still waits for a size it has no need to send")
	}
	if len(rig.shell.sizes) != 0 {
		t.Fatalf("the shell was told %v, the size it already had", rig.shell.sizes)
	}
}

// A program draws its own screen and is told the size at once, and so is a shell that
// marks its prompts but not its commands (PowerShell, cmd): nothing ends its prompt before
// a command writes, so it is never taken to be at one.
func TestAProgramIsToldItsSizeAtOnce(t *testing.T) {
	for name, marks := range map[string]string{
		"a running command": promptMarks + "\x1b]133;C;motty=t\a",
		"no command marks":  "\x1b]133;A;motty=t\aPS> \x1b]133;B;motty=t\a",
		"no marks":          "$ ",
	} {
		t.Run(name, func(t *testing.T) {
			rig := newClockRig(t, marks)
			rig.paintCols(90)
			if want := [][2]int{{90, 30}}; !slices.Equal(rig.shell.sizes, want) {
				t.Fatalf("the shell was told %v, want %v at once", rig.shell.sizes, want)
			}
		})
	}
}
