//go:build !windows

package localshell

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"
)

func start(t *testing.T, config Config) (*Shell, chan struct{}) {
	t.Helper()
	wakes := make(chan struct{}, 1)
	config.Notify = func() {
		select {
		case wakes <- struct{}{}:
		default:
		}
	}
	if config.Shell == "" {
		config.Shell = "/bin/sh"
	}
	if config.Cols == 0 {
		config.Cols, config.Rows = 80, 24
	}
	shell, err := Start(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(shell.Close)
	return shell, wakes
}

func until(t *testing.T, shell *Shell, wakes chan struct{}, want string) string {
	t.Helper()
	var output []byte
	deadline := time.After(5 * time.Second)
	for {
		output = shell.Drain(output)
		if strings.Contains(string(output), want) {
			return string(output)
		}
		select {
		case <-wakes:
		case <-deadline:
			t.Fatalf("waiting for %q; output so far %q", want, output)
		}
	}
}

func TestShellEchoesInputAndRunsCommands(t *testing.T) {
	shell, wakes := start(t, Config{})
	if !shell.Write([]byte("echo hello-$((6*7))\n")) {
		t.Fatal("Write refused")
	}
	until(t, shell, wakes, "hello-42")
}

func TestShellStartsInTheRequestedDirectoryWithTheTerminalType(t *testing.T) {
	dir := t.TempDir()
	shell, wakes := start(t, Config{Dir: dir})
	shell.Write([]byte("pwd; echo term=$TERM\n"))
	output := until(t, shell, wakes, "term=xterm-256color")
	if !strings.Contains(output, dir) && !strings.Contains(output, strings.TrimPrefix(dir, "/private")) {
		t.Fatalf("shell started somewhere else: %q (want %s)", output, dir)
	}
}

// A project opened through a symbolic link is the directory the user named: the
// shell's pwd keeps the link instead of the kernel's spelling of the target.
func TestShellSeesItsDirectoryAsTheHostSpelledIt(t *testing.T) {
	link := filepath.Join(t.TempDir(), "project")
	if err := os.Symlink(t.TempDir(), link); err != nil {
		t.Fatal(err)
	}
	shell, wakes := start(t, Config{Dir: link})
	shell.Write([]byte("echo dir=$(pwd)\n"))
	output := until(t, shell, wakes, "dir=/")
	if !strings.Contains(output, "dir="+link+"\r\n") {
		t.Fatalf("pwd = %q, want %s", output, link)
	}
}

// A plugin terminal's own PWD replaces the directory's, and one it unsets is not
// passed at all. env prints what the program received, which a shell would rewrite.
func TestPluginTerminalKeepsItsOwnPWD(t *testing.T) {
	for _, test := range []struct {
		name   string
		config Config
		want   []string
	}{
		{"set", Config{Env: []string{"PWD=/chosen"}}, []string{"PWD=/chosen"}},
		{"unset", Config{Unset: []string{"PWD"}}, nil},
	} {
		t.Run(test.name, func(t *testing.T) {
			config := test.config
			config.Shell, config.Args, config.Dir, config.Cols, config.Rows = "/usr/bin/env", []string{}, t.TempDir(), 80, 24
			shell, err := Start(config)
			if err != nil {
				t.Fatal(err)
			}
			defer shell.Close()
			var got []string
			for _, line := range strings.Split(waitForExit(t, shell, 5*time.Second), "\n") {
				if line = strings.TrimSpace(line); strings.HasPrefix(line, "PWD=") {
					got = append(got, line)
				}
			}
			if !slices.Equal(got, test.want) {
				t.Fatalf("PWD entries = %q, want %q", got, test.want)
			}
		})
	}
}

// An application opened from Finder inherits no locale, and the C locale it
// would otherwise see makes macOS ls print "?" for every character of a
// non-ASCII file name.
func TestShellSeesChineseFileNamesWhenNoLocaleIsInherited(t *testing.T) {
	for _, name := range []string{"LANG", "LC_ALL", "LC_CTYPE"} {
		t.Setenv(name, "")
	}
	dir := t.TempDir()
	const name = "产品分类映射.xlsx"
	if err := os.WriteFile(filepath.Join(dir, name), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	shell, wakes := start(t, Config{Dir: dir})
	shell.Write([]byte("ls\n"))
	until(t, shell, wakes, name)
}

func TestResizeReachesTheProgram(t *testing.T) {
	shell, wakes := start(t, Config{Cols: 80, Rows: 24})
	shell.Resize(132, 43)
	shell.Write([]byte("stty size\n"))
	until(t, shell, wakes, "43 132")
}

func TestAnInFlightResizeCanOverlapClosingThePTY(t *testing.T) {
	shell, _ := start(t, Config{})
	started, resized := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(resized)
		close(started)
		// Call the backend directly to exercise a resize that has already
		// passed Shell's closed check when Close destroys the descriptor.
		for i := range 1000 {
			shell.b.resize(80+i%2, 24)
		}
	}()
	<-started
	shell.Close()
	<-resized
	select {
	case <-shell.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("concurrent resize kept the closed shell alive")
	}
}

func TestExitEndsTheShellCleanlyAndRefusesFurtherInput(t *testing.T) {
	shell, _ := start(t, Config{})
	shell.Write([]byte("exit 0\n"))
	select {
	case <-shell.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("the shell did not end")
	}
	if err := shell.Err(); err != nil {
		t.Fatalf("clean exit reported %v", err)
	}
	if shell.Write([]byte("x")) {
		t.Fatal("Write succeeded after the shell ended")
	}
}

func TestNonzeroExitIsReportedWithItsStatus(t *testing.T) {
	shell, _ := start(t, Config{})
	shell.Write([]byte("exit 3\n"))
	<-shell.Done()
	if shell.Err() == nil || shell.ExitStatus() != 3 {
		t.Fatalf("err=%v status=%d, want status 3", shell.Err(), shell.ExitStatus())
	}
}

func TestCloseHangsUpARunningProgramAndReleasesIt(t *testing.T) {
	shell, wakes := start(t, Config{})
	shell.Write([]byte("sleep 60\n"))
	until(t, shell, wakes, "sleep")
	shell.Close()
	select {
	case <-shell.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("closing did not end the shell")
	}
	shell.Close() // idempotent
}

type hangupTestPTY struct {
	resizeTestIO
	onClose func()
}

func (pty hangupTestPTY) Close() error {
	pty.onClose()
	return nil
}

func TestCloseLetsTheShellHandleHangupBeforeReleasingThePTY(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		exited := make(chan struct{})
		var calls []string
		shell := resizeTestShell(backend{
			io: hangupTestPTY{onClose: func() { calls = append(calls, "close PTY") }},
			wait: func() (int, error) {
				<-exited
				return 0, nil
			},
			hangup:              func() { calls = append(calls, "hangup") },
			kill:                func() { calls = append(calls, "kill") },
			busy:                func() bool { return true },
			retryHangupAtPrompt: true,
		})
		shell.space = sync.NewCond(&shell.mu)
		shell.readDone = make(chan struct{})
		shell.prompted, shell.lastMark = true, 'C'
		liveShells.Acquire()
		go shell.wait()

		// A foreground process can belong to a slow PROMPT_COMMAND. Its
		// presence doesn't mean the shell can already propagate a hangup.
		shell.Close()
		synctest.Wait()
		if len(calls) != 0 {
			t.Errorf("while the prompt hook runs: %v, want no backend calls", calls)
		}
		shell.sawMark('B')
		synctest.Wait()
		if !slices.Equal(calls, []string{"hangup"}) {
			t.Errorf("before the shell handles hangup: %v, want only hangup", calls)
		}

		close(exited)
		close(shell.readDone)
		select {
		case <-shell.Done():
		case <-time.After(time.Second):
			t.Fatal("the shell never released its terminal")
		}
		synctest.Wait()
		if !slices.Equal(calls, []string{"hangup", "close PTY"}) {
			t.Fatalf("shutdown order = %v, want hangup followed by PTY close", calls)
		}
	})
}

func TestHangupRetriesAtTheBashPromptBeforeForcingExit(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		signals := make(chan string, 3)
		shell := resizeTestShell(backend{
			hangup:              func() { signals <- "hangup" },
			retryHangupAtPrompt: true,
		})
		shell.b.kill = func() {
			signals <- "kill"
			close(shell.done)
		}
		shell.lastMark = 'B'
		shell.hangUp()
		synctest.Wait()
		if len(signals) != 1 {
			t.Errorf("initial signal count = %d, want one hangup", len(signals))
		}

		select {
		case <-shell.done:
		case <-time.After(killGrace + time.Millisecond):
			t.Fatal("the fallback did not end the shell within its original grace period")
		}
		for _, want := range []string{"hangup", "hangup", "kill"} {
			select {
			case got := <-signals:
				if got != want {
					t.Fatalf("signal = %q, want %q", got, want)
				}
			default:
				t.Fatalf("missing signal %q", want)
			}
		}
	})
}

func TestOutputIsBoundedAndNothingIsLost(t *testing.T) {
	shell, wakes := start(t, Config{})
	// 3 MiB of output against a 1 MiB buffer: the program is held back, not
	// dropped. The marker is assembled by the shell so the echo of the command
	// line does not contain it.
	const size = 3 << 20
	shell.Write([]byte("head -c 3145728 /dev/zero | tr '\\0' 'q'; echo don''e-$((1+1))\n"))
	total := 0
	var buffer []byte
	deadline := time.After(20 * time.Second)
	for {
		buffer = shell.Drain(buffer[:0])
		text := string(buffer)
		total += strings.Count(text, "q")
		if strings.Contains(text, "done-2") {
			break
		}
		select {
		case <-wakes:
		case <-deadline:
			t.Fatalf("stalled after %d bytes", total)
		}
	}
	if total < size {
		t.Fatalf("received %d bytes of output, want at least %d", total, size)
	}
}

// A shell holds a pty and goroutines until it is closed; the leak counter must see
// it as held while it runs and give it back on Close, once however often it is closed.
func TestAStartedShellIsCountedUntilItIsClosed(t *testing.T) {
	before := liveShells.Live()
	shell, _ := start(t, Config{})
	if got := liveShells.Live(); got != before+1 {
		t.Fatalf("live shells = %d after Start, want %d", got, before+1)
	}
	shell.Close()
	shell.Close()
	if got := liveShells.Live(); got != before {
		t.Fatalf("live shells = %d after Close, want %d", got, before)
	}
}

// busyWithin waits for shell.Busy to report want. The foreground process group
// changes without any output, so there is no event to wait on: the state is
// polled, bounded by a deadline, and the failure says which state never came.
func busyWithin(t *testing.T, shell *Shell, want bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for shell.Busy() != want {
		if time.Now().After(deadline) {
			t.Fatalf("Busy() stayed %v for 5s, want %v", !want, want)
		}
		// test-stability: allow(go-real-sleep) reason: the pty's foreground group changes without output or any other event a test could wait on.
		time.Sleep(10 * time.Millisecond)
	}
}

// A shell at its prompt is idle; a command it runs in the foreground makes it busy
// until the command ends, and an ended shell is never busy.
func TestShellIsBusyWhileAForegroundCommandRuns(t *testing.T) {
	shell, wakes := start(t, Config{})
	shell.Write([]byte("echo ready-$((1+1))\n"))
	until(t, shell, wakes, "ready-2")
	busyWithin(t, shell, false)

	shell.Write([]byte("sleep 30\n"))
	busyWithin(t, shell, true)
	shell.Write([]byte{0x03}) // Ctrl+C ends the command, not the shell
	busyWithin(t, shell, false)

	shell.Write([]byte("sleep 30\n"))
	busyWithin(t, shell, true)
	shell.Close()
	select {
	case <-shell.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("closing did not end the shell")
	}
	if shell.Busy() {
		t.Fatal("an ended shell reads as busy")
	}
}
