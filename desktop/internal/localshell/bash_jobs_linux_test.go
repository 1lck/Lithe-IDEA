package localshell

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"golang.org/x/sys/unix"
)

// A FIFO lets the test hold a real Bash child before exec, then release it.
// Only the waiter's clock is virtual; both process states are acknowledged.
func TestBashJobWaiterDistinguishesForkFromExec(t *testing.T) {
	gate := filepath.Join(t.TempDir(), "gate")
	if err := unix.Mkfifo(gate, 0o600); err != nil {
		t.Fatal(err)
	}
	writer, err := os.OpenFile(gate, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	s := startHangupShell(t, "bash", []string{"GATE=" + gate})
	s.run(`(read -r < "$GATE"; exec sh -c 'echo exec-"ready"; exec sleep 300') & echo job=$!`+"\r", 1, "\r\njob=")
	job := jobOf(t, s)
	if s.shell.b.waitForJobs == nil {
		t.Fatal("Linux integrated Bash has no job waiter")
	}
	wait := func() time.Duration {
		var elapsed time.Duration
		synctest.Test(t, func(t *testing.T) {
			start := time.Now()
			s.shell.b.waitForJobs()
			elapsed = time.Since(start)
		})
		return elapsed
	}
	if elapsed := wait(); elapsed <= 0 || elapsed > 100*time.Millisecond {
		t.Fatalf("wait for a child blocked before exec took %v", elapsed)
	}
	if _, err := writer.WriteString("\n"); err != nil {
		t.Fatal(err)
	}
	s.await("child's exec", func() bool { return strings.Contains(s.output, "exec-ready\r\n") })
	if elapsed := wait(); elapsed != 0 {
		t.Fatalf("wait for a child after exec took %v", elapsed)
	}
	closeAndAwaitEnd(t, s.shell)
	awaitProcessEnd(t, job)
}
