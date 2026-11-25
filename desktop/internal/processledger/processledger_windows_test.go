//go:build windows

package processledger

import (
	"bufio"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

// helperMode names, in the environment, that the test binary runs as TestLedgerHelper.
const helperMode = "LITHE_TEST_PROCESS_LEDGER"

// TestLedgerHelper is the leftover process the tests end. It prints a line once it runs and waits
// to be ended, for 30 seconds at most.
func TestLedgerHelper(t *testing.T) {
	if os.Getenv(helperMode) == "" {
		t.Skip("only runs as a leftover process")
	}
	os.Stdout.WriteString("ready\n")
	time.Sleep(30 * time.Second)
	os.Exit(2)
}

// withRecordingProcessTools puts a ps and a kill that record their calls first on PATH, as Git for
// Windows or MSYS2 can put theirs. The client is a GUI program with no console, so each console
// program the ledger ran would open a console window of its own at every start it records; the
// test fails if anything called them.
func withRecordingProcessTools(t *testing.T) {
	t.Helper()
	tools := t.TempDir()
	calls := filepath.Join(tools, "calls.txt")
	for _, name := range []string{"ps", "kill"} {
		script := "@echo off\r\necho " + name + " %*>>\"%~dp0calls.txt\"\r\n"
		if err := os.WriteFile(filepath.Join(tools, name+".bat"), []byte(script), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", tools+string(os.PathListSeparator)+os.Getenv("PATH"))
	if found, err := exec.LookPath("ps"); err != nil || !strings.EqualFold(filepath.Dir(found), tools) {
		t.Fatalf("the recording ps is not the one on PATH: %q, %v", found, err)
	}
	t.Cleanup(func() {
		if data, err := os.ReadFile(calls); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("the ledger ran process tools: %q, %v", data, err)
		}
	})
}

// leftover is a running helper process recorded in a ledger of its own.
type leftover struct {
	ledger *Ledger
	cmd    *exec.Cmd
	// done closes once the process has exited and Wait returned.
	done chan struct{}
}

// startLeftover starts the helper, waits until it runs and records it. The process is killed when
// the test ends, whatever the test did with it.
func startLeftover(t *testing.T) *leftover {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^TestLedgerHelper$")
	cmd.Env = append(os.Environ(), helperMode+"=1")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	l := &leftover{ledger: Open(t.TempDir()), cmd: cmd, done: make(chan struct{})}
	ready := make(chan bool, 1)
	go func() {
		line, _ := bufio.NewReader(stdout).ReadString('\n')
		ready <- strings.TrimSpace(line) == "ready"
		_ = cmd.Wait()
		close(l.done)
	}()
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		select {
		case <-l.done:
		case <-time.After(5 * time.Second):
			t.Error("the leftover process did not end")
		}
	})
	select {
	case ok := <-ready:
		if !ok {
			t.Fatal("the leftover process did not get ready")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the leftover process did not get ready within 10s")
	}
	if err := l.ledger.AddKind(KindRun, cmd.Process.Pid); err != nil {
		t.Fatal(err)
	}
	return l
}

// recorded returns the ledger's leftovers, which must be exactly the helper.
func (l *leftover) recorded(t *testing.T) []Record {
	t.Helper()
	records, err := l.ledger.Leftovers()
	if err != nil || len(records) != 1 || records[0].PID != l.cmd.Process.Pid || records[0].Kind != KindRun {
		t.Fatalf("leftovers = %+v, %v", records, err)
	}
	return records
}

// exited reports that the helper ended within limit.
func (l *leftover) exited(limit time.Duration) bool {
	select {
	case <-l.done:
		return true
	case <-time.After(limit):
		return false
	}
}

// TestWindowsLedgerIdentifiesALeftoverByItsCreationAndPath: the record holds the process's creation
// time and executable, read from the system without running ps.
func TestWindowsLedgerIdentifiesALeftoverByItsCreationAndPath(t *testing.T) {
	withRecordingProcessTools(t)
	l := startLeftover(t)
	record := l.recorded(t)[0]
	if _, err := strconv.ParseUint(record.Started, 10, 64); err != nil {
		t.Fatalf("Started = %q, want the creation time", record.Started)
	}
	// The executable's directory can be spelt in short (8.3) form in os.Args, so only its name is compared.
	if want := filepath.Base(os.Args[0]); !strings.EqualFold(filepath.Base(record.Command), want) &&
		!strings.EqualFold(filepath.Base(record.Command), want+".exe") {
		t.Fatalf("Command = %q, want the test binary %q", record.Command, want)
	}
}

func TestWindowsTrackRecordsAProcessUntilItIsUntracked(t *testing.T) {
	withRecordingProcessTools(t)
	t.Cleanup(func() { Activate("") })
	ledger := Activate(t.TempDir())
	if ledger == nil {
		t.Fatal("Activate returned no ledger")
	}
	untrack := Track(KindBuild, os.Getpid())
	if records, err := ledger.Leftovers(); err != nil || len(records) != 1 || records[0].PID != os.Getpid() || records[0].Kind != KindBuild {
		t.Fatalf("leftovers = %+v, %v; want this process as a build", records, err)
	}
	untrack()
	if records, err := ledger.Leftovers(); err != nil || len(records) != 0 {
		t.Fatalf("an untracked process is still recorded: %+v, %v", records, err)
	}
}

// TestWindowsSettleEndsALeftoverAtOnce: a process has no stop request here, so the one asked to
// stop is ended at once, without waiting out its grace and without running kill.
func TestWindowsSettleEndsALeftoverAtOnce(t *testing.T) {
	withRecordingProcessTools(t)
	l := startLeftover(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	started := time.Now()
	count, err := l.ledger.Settle(ctx, l.recorded(t), true, 20*time.Second)
	if err != nil || count != 1 {
		t.Fatalf("settled %d, %v", count, err)
	}
	if elapsed := time.Since(started); elapsed >= 10*time.Second {
		t.Fatalf("an ended process was waited for %v", elapsed)
	}
	if !l.exited(5*time.Second) || l.cmd.ProcessState.ExitCode() != 1 {
		t.Fatalf("the process was not ended by the ledger: %v", l.cmd.ProcessState)
	}
	if records, err := l.ledger.Leftovers(); err != nil || len(records) != 0 {
		t.Fatalf("the settled process is still recorded: %+v, %v", records, err)
	}
}

func TestWindowsSettleWithoutEndingForgetsTheLeftover(t *testing.T) {
	withRecordingProcessTools(t)
	l := startLeftover(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if count, err := l.ledger.Settle(ctx, l.recorded(t), false, time.Minute); err != nil || count != 0 {
		t.Fatalf("settled %d, %v", count, err)
	}
	if records, err := l.ledger.Leftovers(); err != nil || len(records) != 0 {
		t.Fatalf("the kept process is still recorded: %+v, %v", records, err)
	}
	if l.exited(200 * time.Millisecond) {
		t.Fatal("a kept process was ended")
	}
}

// TestWindowsSettleLeavesAProcessThatIsNotTheRecordedOne checks the guard against a reused PID: a
// record whose creation time is not the running process's is not ended.
func TestWindowsSettleLeavesAProcessThatIsNotTheRecordedOne(t *testing.T) {
	withRecordingProcessTools(t)
	l := startLeftover(t)
	record := l.recorded(t)[0]
	record.Started = "1"
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if count, err := endProcesses(ctx, []Record{record}, time.Minute); err != nil || count != 0 {
		t.Fatalf("ended %d, %v", count, err)
	}
	if l.exited(200 * time.Millisecond) {
		t.Fatal("a process that is not the recorded one was ended")
	}
}

// TestWindowsLeftoversSkipAProcessThatExited: a process that has exited can still be opened while a
// handle to it is held, and keeps its creation time and path; it is not a leftover all the same.
func TestWindowsLeftoversSkipAProcessThatExited(t *testing.T) {
	withRecordingProcessTools(t)
	l := startLeftover(t)
	l.recorded(t)
	held, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.SYNCHRONIZE, false, uint32(l.cmd.Process.Pid))
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(held)
	if err := l.cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	if !l.exited(5 * time.Second) {
		t.Fatal("the killed process did not end")
	}
	if records, err := l.ledger.Leftovers(); err != nil || len(records) != 0 {
		t.Fatalf("an exited process is a leftover: %+v, %v", records, err)
	}
}
