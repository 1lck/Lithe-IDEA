//go:build windows

package localshell

import (
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/term"
	"github.com/vivaui/viva/gfx"
	"golang.org/x/sys/windows"
)

// Run the test binary inside ConPTY as a raw VT reader, like a Node TTY.
func TestConPTYRawReader(t *testing.T) {
	if os.Getenv("MOTTY_TEST_RAW_READER") != "1" {
		t.Skip("ConPTY child only")
	}
	input := windows.Handle(os.Stdin.Fd())
	var mode uint32
	if err := windows.GetConsoleMode(input, &mode); err != nil {
		t.Fatal(err)
	}
	if err := windows.SetConsoleMode(input, windows.ENABLE_VIRTUAL_TERMINAL_INPUT|windows.ENABLE_EXTENDED_FLAGS); err != nil {
		t.Fatal(err)
	}
	defer windows.SetConsoleMode(input, mode)
	fmt.Println("RAW-READER-READY")
	var received []byte
	for len(received) < 2 {
		var buffer [32]byte
		n, err := os.Stdin.Read(buffer[:])
		if err != nil {
			t.Fatal(err)
		}
		received = append(received, buffer[:n]...)
	}
	fmt.Printf("RAW-READER-BYTES:%x\n", received)
}

func TestConPTYWin32ControlCharactersReachRawReader(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	shell, wakes := startWindows(t, Config{Env: []string{"MOTTY_TEST_RAW_READER=1"}})
	command := windows.ComposeCommandLine([]string{executable, "-test.run=^TestConPTYRawReader$"})
	shell.Write([]byte(command + "\r"))
	untilWindows(t, shell, wakes, "RAW-READER-READY")
	for _, record := range []gfx.Win32Key{
		{VirtualKey: 13, ScanCode: 28, Unicode: 13},
		{VirtualKey: 'D', ScanCode: 32, Unicode: 4, ControlState: 8},
	} {
		for _, release := range []bool{false, true} {
			if !shell.Write(term.EncodeWin32Key(gfx.KeyEvent{Win32: record, Release: release})) {
				t.Fatal("Write refused")
			}
		}
	}
	untilWindows(t, shell, wakes, "RAW-READER-BYTES:0d04")
}

func startWindows(t *testing.T, config Config) (*Shell, chan struct{}) {
	t.Helper()
	wakes := make(chan struct{}, 1)
	config.Notify = func() {
		select {
		case wakes <- struct{}{}:
		default:
		}
	}
	if config.Shell == "" {
		config.Shell = "cmd.exe" // present on every Windows, unlike PowerShell 7
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

func untilWindows(t *testing.T, shell *Shell, wakes chan struct{}, want string) string {
	t.Helper()
	var output []byte
	deadline := time.After(15 * time.Second)
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

func TestConPTYRunsCommandsAndEchoesTheirOutput(t *testing.T) {
	shell, wakes := startWindows(t, Config{})
	if !shell.Write([]byte("echo conpty-%OS%\r\n")) {
		t.Fatal("Write refused")
	}
	untilWindows(t, shell, wakes, "conpty-Windows_NT")
}

func TestConPTYExitEndsTheShellWithItsStatus(t *testing.T) {
	shell, _ := startWindows(t, Config{})
	shell.Write([]byte("exit 3\r\n"))
	select {
	case <-shell.Done():
	case <-time.After(15 * time.Second):
		t.Fatal("the shell did not end")
	}
	if shell.ExitStatus() != 3 {
		t.Fatalf("status = %d (%v), want 3", shell.ExitStatus(), shell.Err())
	}
	if shell.Write([]byte("x")) {
		t.Fatal("Write succeeded after the shell ended")
	}
}

func TestConPTYCloseEndsARunningProgram(t *testing.T) {
	shell, wakes := startWindows(t, Config{})
	shell.Write([]byte("ping -n 60 127.0.0.1\r\n"))
	untilWindows(t, shell, wakes, "TTL=")
	shell.Close()
	select {
	case <-shell.Done():
	case <-time.After(15 * time.Second):
		t.Fatal("closing did not end the shell")
	}
}

func TestConPTYStartsInTheRequestedDirectory(t *testing.T) {
	dir := t.TempDir()
	shell, wakes := startWindows(t, Config{Dir: dir})
	shell.Write([]byte("cd\r\n"))
	untilWindows(t, shell, wakes, dir)
}

// A console has no foreground group: the shell is busy while it has a child.
func TestConPTYShellIsBusyWhileAProgramRuns(t *testing.T) {
	shell, wakes := startWindows(t, Config{})
	shell.Write([]byte("echo ready-%OS%\r\n"))
	untilWindows(t, shell, wakes, "ready-Windows_NT")
	if shell.Busy() {
		t.Fatal("cmd at its prompt reads as busy")
	}
	shell.Write([]byte("ping -n 60 127.0.0.1\r\n"))
	untilWindows(t, shell, wakes, "TTL=")
	if !shell.Busy() {
		t.Fatal("cmd running ping reads as idle")
	}
	shell.Close()
	select {
	case <-shell.Done():
	case <-time.After(15 * time.Second):
		t.Fatal("closing did not end the shell")
	}
	if shell.Busy() {
		t.Fatal("an ended shell reads as busy")
	}
}
