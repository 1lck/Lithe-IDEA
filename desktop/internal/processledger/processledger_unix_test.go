//go:build !windows

package processledger

import (
	"bufio"
	"context"
	"errors"
	"os"
	"os/exec"
	ossignal "os/signal"
	"syscall"
	"testing"
	"time"
)

// helperMode names, in the environment, what TestLedgerHelper does when the tests start this
// test binary as a leftover process.
const helperMode = "LITHE_TEST_PROCESS_LEDGER"

// TestLedgerHelper is the leftover process the tests end. "trap-term" exits as soon as it is
// asked to stop; "ignore-term" ignores the request and runs until it is killed. Each prints a
// line once it handles the request as it should, so the test knows when to send it.
func TestLedgerHelper(t *testing.T) {
	mode := os.Getenv(helperMode)
	if mode == "" {
		t.Skip("only runs as a leftover process")
	}
	switch mode {
	case "trap-term":
		stop := make(chan os.Signal, 1)
		ossignal.Notify(stop, syscall.SIGTERM)
		os.Stdout.WriteString("ready\n")
		select {
		case <-stop:
			os.Exit(0)
		case <-time.After(30 * time.Second):
			os.Exit(2)
		}
	case "ignore-term":
		ossignal.Ignore(syscall.SIGTERM)
		os.Stdout.WriteString("ready\n")
		time.Sleep(30 * time.Second)
		os.Exit(2)
	}
}

// leftover is a running helper process recorded in a ledger of its own.
type leftover struct {
	ledger *Ledger
	cmd    *exec.Cmd
	// done closes once the process has exited and was reaped, so ps no longer finds it.
	done chan struct{}
}

// startLeftover starts the helper in mode, waits until it is ready and records it. The process
// is killed when the test ends, whatever the test did with it.
func startLeftover(t *testing.T, mode string) *leftover {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^TestLedgerHelper$")
	cmd.Env = append(os.Environ(), helperMode+"="+mode)
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
		ready <- line == "ready\n"
		_ = cmd.Wait()
		close(l.done)
	}()
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		select {
		case <-l.done:
		case <-time.After(5 * time.Second):
			t.Error("the leftover process was not reaped")
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

func TestSettleEndsALeftoverThatStopsWithinItsGrace(t *testing.T) {
	l := startLeftover(t, "trap-term")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	started := time.Now()
	count, err := l.ledger.Settle(ctx, l.recorded(t), true, 20*time.Second)
	if err != nil || count != 1 {
		t.Fatalf("settled %d, %v", count, err)
	}
	if elapsed := time.Since(started); elapsed >= 10*time.Second {
		t.Fatalf("a process that stopped when asked was waited for %v", elapsed)
	}
	if !l.exited(5*time.Second) || !l.cmd.ProcessState.Success() {
		t.Fatalf("the process did not exit on its own: %v", l.cmd.ProcessState)
	}
	if records, err := l.ledger.Leftovers(); err != nil || len(records) != 0 {
		t.Fatalf("the settled process is still recorded: %+v, %v", records, err)
	}
}

func TestSettleKillsALeftoverThatOutlivesItsGrace(t *testing.T) {
	l := startLeftover(t, "ignore-term")
	grace := 300 * time.Millisecond
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	started := time.Now()
	count, err := l.ledger.Settle(ctx, l.recorded(t), true, grace)
	if err != nil || count != 1 {
		t.Fatalf("settled %d, %v", count, err)
	}
	if elapsed := time.Since(started); elapsed < grace {
		t.Fatalf("the process was killed after %v, before its grace of %v", elapsed, grace)
	}
	if !l.exited(5 * time.Second) {
		t.Fatal("the process outlived the kill")
	}
	status, ok := l.cmd.ProcessState.Sys().(syscall.WaitStatus)
	if !ok || !status.Signaled() || status.Signal() != syscall.SIGKILL {
		t.Fatalf("the process ended with %v, want SIGKILL", l.cmd.ProcessState)
	}
}

func TestSettleWithoutEndingForgetsTheLeftover(t *testing.T) {
	l := startLeftover(t, "ignore-term")
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

// TestSettleLeavesAProcessThatIsNotTheRecordedOne checks the guard against a reused PID: a
// record whose start time is not the running process's is not signalled.
func TestSettleLeavesAProcessThatIsNotTheRecordedOne(t *testing.T) {
	l := startLeftover(t, "trap-term")
	record := l.recorded(t)[0]
	record.Started = "Mon Jan  1 00:00:00 2001"
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if count, err := endProcesses(ctx, []Record{record}, time.Minute); err != nil || count != 0 {
		t.Fatalf("ended %d, %v", count, err)
	}
	if l.exited(200 * time.Millisecond) {
		t.Fatal("a process that is not the recorded one was ended")
	}
}

// TestSettleStopsWaitingWhenItsContextEnds checks that a cancelled settlement returns at once
// instead of waiting out the grace.
func TestSettleStopsWaitingWhenItsContextEnds(t *testing.T) {
	l := startLeftover(t, "ignore-term")
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	started := time.Now()
	_, err := l.ledger.Settle(ctx, l.recorded(t), true, time.Minute)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v, want the context's", err)
	}
	if elapsed := time.Since(started); elapsed >= 10*time.Second {
		t.Fatalf("a cancelled settlement waited %v", elapsed)
	}
}
