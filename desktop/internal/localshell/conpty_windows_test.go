//go:build windows

package localshell

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/term"
	"golang.org/x/sys/windows"
)

// testConPTYRoot is where the tests install the bundled ConPTY instead of the user's cache
// directory. It is one fixed folder rather than a temporary one per run: the test process
// loads the DLL and Windows does not delete a loaded DLL, so a folder per run could never be
// removed. Below it the set is named by its digest, so every run reuses the same files and
// writes none.
var testConPTYRoot = filepath.Join(os.TempDir(), "lithe-localshell-test-conpty")

// Every shell the tests start runs on the ConPTY the client uses, installed below
// testConPTYRoot.
func init() { conptyRootOverride = testConPTYRoot }

// resetBundledConPTY forgets the loaded DLL so a test can change where it is installed.
func resetBundledConPTY() {
	bundledOnce = sync.Once{}
	bundled = nil
	bundledErr = nil
}

// useConPTYRoot installs the bundled ConPTY below root for one test.
func useConPTYRoot(t *testing.T, root string) {
	t.Helper()
	previous := conptyRootOverride
	conptyRootOverride = root
	resetBundledConPTY()
	t.Cleanup(func() {
		conptyRootOverride = previous
		resetBundledConPTY()
	})
}

// requireBundledConPTY skips a test on an architecture Lithe carries no ConPTY for, and
// fails it where the ConPTY it carries does not install and load.
func requireBundledConPTY(t *testing.T) {
	t.Helper()
	if runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64" {
		t.Skipf("Lithe carries no ConPTY for %s", runtime.GOARCH)
	}
	if _, err := bundledConPTY(); err != nil {
		t.Fatalf("the bundled ConPTY did not install and load: %v", err)
	}
}

// TestBundledConPTYProbeChild is the program the parent test runs inside the pseudo
// console. It asks for the default colors, then writes a synchronized update and waits for
// the terminal's replies.
func TestBundledConPTYProbeChild(t *testing.T) {
	if os.Getenv("LITHE_CONPTY_PROBE_CHILD") != "1" {
		t.Skip("conpty probe child only")
	}
	input := windows.Handle(os.Stdin.Fd())
	if err := windows.SetConsoleMode(input, windows.ENABLE_VIRTUAL_TERMINAL_INPUT|windows.ENABLE_EXTENDED_FLAGS); err != nil {
		fmt.Printf("LITHE-CONPTY-CHILD-ERROR:set console mode: %v\n", err)
		os.Exit(1)
	}
	sequence := "\x1b]10;?\x1b\\\x1b]11;?\x1b\\\x1b[?2026$p" +
		"\x1b[?2026hlithe-conpty-sync-marker\r\n\x1b[?2026l"
	if _, err := os.Stdout.WriteString(sequence); err != nil {
		fmt.Printf("LITHE-CONPTY-CHILD-ERROR:write: %v\n", err)
		os.Exit(1)
	}

	replies := make(chan []byte)
	go func() {
		buffer := make([]byte, 256)
		for {
			n, err := os.Stdin.Read(buffer)
			if n > 0 {
				replies <- append([]byte(nil), buffer[:n]...)
			}
			if err != nil {
				close(replies)
				return
			}
		}
	}()
	var received []byte
	deadline := time.After(8 * time.Second)
probe:
	for !(bytes.Contains(received, []byte("\x1b]10;")) && bytes.Contains(received, []byte("\x1b]11;"))) {
		select {
		case chunk, ok := <-replies:
			if !ok {
				break probe
			}
			received = append(received, chunk...)
		case <-deadline:
			break probe
		}
	}
	fmt.Printf("LITHE-CONPTY-REPLIES:%s\n", hex.EncodeToString(received))
	// The test framework's process is not the application; ending it here keeps its leak
	// checker out of the parent's measurement.
	os.Exit(0)
}

// TestBundledConPTYDeliversColorQueriesAndKeepsSyncBlocksAtomic runs a program that asks
// for the default colors and writes a synchronized update. The inbox ConPTY answers the
// color queries itself and paints the update's content again after its end marker; the
// bundled one hands the queries to the terminal and forwards the update as it was written.
func TestBundledConPTYDeliversColorQueriesAndKeepsSyncBlocksAtomic(t *testing.T) {
	requireBundledConPTY(t)
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	// Wide enough that the child's reply line is never wrapped.
	shell, wakes := startWindows(t, Config{Cols: 200, Rows: 30, Env: []string{"LITHE_CONPTY_PROBE_CHILD=1"}})
	screen := term.New(200, 30, 0)
	screen.SetDefaultColors([3]uint8{0xaa, 0xbb, 0xcc}, [3]uint8{1, 2, 3})
	replies := 0
	screen.SetReply(func(reply []byte) {
		replies++
		shell.Write(append([]byte(nil), reply...))
	})

	// The shell prints the expanded marker after the child has ended, so everything the
	// console paints for the child, a repaint after the synchronized update included, comes
	// before it in the stream; the typed line only echoes the unexpanded %OS%.
	command := windows.ComposeCommandLine([]string{executable, "-test.run=^TestBundledConPTYProbeChild$"}) +
		" & echo LITHE-CONPTY-%OS%-DONE"
	if !shell.Write([]byte(command + "\r")) {
		t.Fatal("the shell refused the probe command")
	}
	var raw []byte
	deadline := time.After(20 * time.Second)
	for !bytes.Contains(raw, []byte("LITHE-CONPTY-Windows_NT-DONE")) {
		if chunk := shell.Drain(nil); len(chunk) > 0 {
			raw = append(raw, chunk...)
			screen.Write(chunk)
			continue
		}
		select {
		case <-wakes:
		case <-deadline:
			t.Fatalf("the probe did not report back; output so far %q", raw)
		}
	}
	stream := string(raw)

	marker := "LITHE-CONPTY-REPLIES:"
	start := strings.Index(stream, marker)
	if start < 0 {
		t.Fatalf("the child's reply line is missing: %q", stream)
	}
	end := strings.IndexAny(stream[start+len(marker):], "\r\n")
	if end < 0 {
		t.Fatalf("the child's reply line is missing: %q", stream)
	}
	encoded := stream[start+len(marker) : start+len(marker)+end]
	received, err := hex.DecodeString(encoded)
	if err != nil {
		t.Fatalf("the child's reply line is not hex (%q): %v", encoded, err)
	}
	for _, want := range []string{"\x1b]10;rgb:aaaa/bbbb/cccc\x1b\\", "\x1b]11;rgb:0101/0202/0303\x1b\\"} {
		if !bytes.Contains(received, []byte(want)) {
			t.Errorf("the child did not receive %q; got %q", want, received)
		}
	}
	if replies < 2 {
		t.Errorf("the terminal answered %d queries", replies)
	}

	begin := strings.Index(stream, "\x1b[?2026h")
	finish := strings.Index(stream, "\x1b[?2026l")
	block := strings.Index(stream, "lithe-conpty-sync-marker")
	if begin < 0 || finish < 0 || block < 0 {
		t.Fatalf("the synchronized block is incomplete: begin=%d finish=%d marker=%d", begin, finish, block)
	}
	if block < begin || block > finish {
		t.Errorf("the block's content reached the terminal outside DECSET 2026: begin=%d marker=%d finish=%d", begin, block, finish)
	}
	if strings.Contains(stream[finish:], "lithe-conpty-sync-marker") {
		t.Errorf("the content was painted again after the synchronized update ended")
	}
}

// TestBundledConPTYProbeMouseChild asks for mouse reporting the way a full-screen program
// does; the parent test reads the request back.
func TestBundledConPTYProbeMouseChild(t *testing.T) {
	if os.Getenv("LITHE_CONPTY_MOUSE_CHILD") != "1" {
		t.Skip("conpty mouse probe child only")
	}
	if _, err := os.Stdout.WriteString("\x1b[?1000h\x1b[?1002h\x1b[?1006hLITHE-CONPTY-MOUSE\r\n"); err != nil {
		fmt.Printf("LITHE-CONPTY-CHILD-ERROR:write: %v\n", err)
		os.Exit(1)
	}
	os.Exit(0)
}

// TestBundledConPTYForwardsMouseReporting keeps a program's mouse modes reaching the
// terminal: the inbox ConPTY consumes them, so a full-screen program's wheel falls back to
// arrow keys. The bundled one forwards them.
func TestBundledConPTYForwardsMouseReporting(t *testing.T) {
	requireBundledConPTY(t)
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	shell, wakes := startWindows(t, Config{Cols: 100, Rows: 30, Env: []string{"LITHE_CONPTY_MOUSE_CHILD=1"}})
	screen := term.New(100, 30, 0)

	command := windows.ComposeCommandLine([]string{executable, "-test.run=^TestBundledConPTYProbeMouseChild$"})
	if !shell.Write([]byte(command + "\r")) {
		t.Fatal("the shell refused the probe command")
	}
	var raw []byte
	deadline := time.After(20 * time.Second)
	for !bytes.Contains(raw, []byte("LITHE-CONPTY-MOUSE")) {
		if chunk := shell.Drain(nil); len(chunk) > 0 {
			raw = append(raw, chunk...)
			screen.Write(chunk)
			continue
		}
		select {
		case <-wakes:
		case <-deadline:
			t.Fatalf("the probe did not report back; output so far %q", raw)
		}
	}
	for _, sequence := range []string{"\x1b[?1000h", "\x1b[?1002h", "\x1b[?1006h"} {
		if !bytes.Contains(raw, []byte(sequence)) {
			t.Errorf("ConPTY swallowed %q", sequence)
		}
	}
	if modes := screen.Modes(); modes.Mouse != term.MouseDrag || modes.MouseEncoding != term.MouseEncodingSGR {
		t.Errorf("the terminal learned mouse=%v encoding=%v", modes.Mouse, modes.MouseEncoding)
	}
}

// TestAShellStartsOnTheInboxConPTYWhenTheBundledOneCannotBeInstalled keeps the terminal
// usable where the cache directory cannot be written: the inbox ConPTY hosts the shell and
// the caller is told why.
func TestAShellStartsOnTheInboxConPTYWhenTheBundledOneCannotBeInstalled(t *testing.T) {
	if runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64" {
		t.Skipf("Lithe carries no ConPTY for %s", runtime.GOARCH)
	}
	blocker := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(blocker, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	useConPTYRoot(t, filepath.Join(blocker, "conpty"))
	if console, err := bundledConPTY(); console != nil || err == nil {
		t.Fatalf("a root below a file gave a console (%t) and error %v", console != nil, err)
	}

	var reasons []error
	shell, wakes := startWindows(t, Config{Degraded: func(err error) { reasons = append(reasons, err) }})
	if len(reasons) != 1 || reasons[0] == nil {
		t.Fatalf("Degraded was told %v, want the install failure once", reasons)
	}
	if !shell.Write([]byte("echo fallback-%OS%\r\n")) {
		t.Fatal("Write refused")
	}
	untilWindows(t, shell, wakes, "fallback-Windows_NT")
}

// TestAShellOnTheBundledConPTYIsNotDegraded keeps the fallback report to the fallback.
func TestAShellOnTheBundledConPTYIsNotDegraded(t *testing.T) {
	requireBundledConPTY(t)
	var reasons []error
	startWindows(t, Config{Degraded: func(err error) { reasons = append(reasons, err) }})
	if len(reasons) != 0 {
		t.Fatalf("Degraded was told %v for a shell on the bundled ConPTY", reasons)
	}
}
