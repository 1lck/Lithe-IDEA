//go:build windows

package localshell

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/processledger"
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

// A terminal's shell is in the process ledger while it runs, so a shell an earlier run of the app
// left behind can be offered for ending at start-up; it leaves the ledger when it ends.
func TestConPTYShellIsRecordedWhileItRuns(t *testing.T) {
	preferences := t.TempDir()
	t.Cleanup(func() { processledger.Activate("") })
	ledger := processledger.Activate(preferences)
	shell, _ := startWindows(t, Config{})
	records, err := ledger.Leftovers()
	if err != nil || len(records) != 1 || records[0].Kind != processledger.KindTerminal ||
		!strings.EqualFold(filepath.Base(records[0].Command), "cmd.exe") {
		t.Fatalf("leftovers = %+v, %v; want the shell as a terminal", records, err)
	}
	shell.Write([]byte("exit 0\r\n"))
	select {
	case <-shell.Done():
	case <-time.After(15 * time.Second):
		t.Fatal("the shell did not end")
	}
	// An ended process is never a leftover, so the file itself shows that the record was removed.
	data, err := os.ReadFile(filepath.Join(preferences, processledger.LedgerFile))
	if err != nil {
		t.Fatal(err)
	}
	var recorded []processledger.Record
	if err := json.Unmarshal(data, &recorded); err != nil || len(recorded) != 0 {
		t.Fatalf("the ended shell is still recorded: %s, %v", data, err)
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

// A process created with CREATE_NEW_PROCESS_GROUP, or by one that ignores
// Ctrl+C, passes that state on to its children. A terminal started that way
// must still let Ctrl+C reach the program on the pseudo console.
func TestConPTYCtrlCInterruptsAProgramInAnInheritedCtrlCDisabledGroup(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command(executable, "-test.run=^TestConPTYCtrlCChild$", "-test.timeout=60s")
	command.Env = append(os.Environ(), "LITHE_TEST_CTRL_C_CHILD=1")
	command.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NEW_PROCESS_GROUP}
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("the child failed: %v\n%s", err, output)
	}
	if !strings.Contains(string(output), "CTRL-C-CHILD-OK") {
		t.Fatalf("the child did not finish its check:\n%s", output)
	}
}

func TestConPTYCtrlCChild(t *testing.T) {
	if os.Getenv("LITHE_TEST_CTRL_C_CHILD") != "1" {
		t.Skip("ConPTY child only")
	}
	shell, wakes := startWindows(t, Config{})
	shell.Write([]byte("ping -n 60 127.0.0.1\r\n"))
	untilWindows(t, shell, wakes, "TTL=")
	// The child test only proves the point if the program keeps running until
	// the interrupt arrives; 60 pings outlast the waits below.
	shell.Write([]byte{3})
	shell.Write([]byte("echo ctrlc-%OS%\r\n"))
	untilWindows(t, shell, wakes, "ctrlc-Windows_NT")
	fmt.Println("CTRL-C-CHILD-OK")
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
