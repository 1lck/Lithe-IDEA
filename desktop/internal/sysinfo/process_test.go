package sysinfo

import (
	"io"
	"os"
	"os/exec"
	"runtime"
	"testing"
	"time"
)

// helperEnvironment marks the copy of the test binary that TestProcessesListsThisProcessAndItsChild
// starts as its child.
const helperEnvironment = "LITHE_SYSINFO_PROCESS_HELPER"

// TestProcessHelper is the child: it waits until its parent closes its standard input.
func TestProcessHelper(t *testing.T) {
	if os.Getenv(helperEnvironment) != "1" {
		t.Skip("only runs as the child of TestProcessesListsThisProcessAndItsChild")
	}
	_, _ = io.Copy(io.Discard, os.Stdin)
}

// TestProcessesListsThisProcessAndItsChild checks that the table has this process under its
// parent, with a name and memory, and a child it started under it.
func TestProcessesListsThisProcessAndItsChild(t *testing.T) {
	switch runtime.GOOS {
	case "darwin", "linux", "windows":
	default:
		t.Skip("the process table is not read on " + runtime.GOOS)
	}
	child := exec.Command(os.Args[0], "-test.run=^TestProcessHelper$")
	child.Env = append(os.Environ(), helperEnvironment+"=1")
	stdin, err := child.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = stdin.Close()
		done := make(chan error, 1)
		go func() { done <- child.Wait() }()
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			_ = child.Process.Kill()
			<-done
			t.Error("the helper process did not exit within 10s of its input closing")
		}
	})

	table, err := Processes()
	if err != nil {
		t.Fatal(err)
	}
	rows := map[int]Process{}
	for _, row := range table {
		if _, seen := rows[row.PID]; seen {
			t.Fatalf("process %d is listed twice", row.PID)
		}
		rows[row.PID] = row
	}
	self, ok := rows[os.Getpid()]
	if !ok {
		t.Fatalf("this process %d is not in a table of %d processes", os.Getpid(), len(table))
	}
	if self.ParentPID != os.Getppid() || self.Name == "" || self.MemoryBytes == 0 {
		t.Fatalf("this process = %+v, want parent %d, a name and memory", self, os.Getppid())
	}
	started, ok := rows[child.Process.Pid]
	if !ok {
		t.Fatalf("the child %d is not in the table", child.Process.Pid)
	}
	if started.ParentPID != os.Getpid() {
		t.Fatalf("the child = %+v, want parent %d", started, os.Getpid())
	}
	if self.StartTime != 0 && started.StartTime != 0 && started.StartTime < self.StartTime {
		t.Fatalf("the child started at %d, before this process at %d", started.StartTime, self.StartTime)
	}
	if runtime.GOOS == "darwin" && self.ResponsiblePID == 0 {
		t.Fatalf("this process = %+v, want a responsible process", self)
	}
}
