//go:build !windows

package localshell

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
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
