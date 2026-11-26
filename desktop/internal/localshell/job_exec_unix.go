//go:build !windows

package localshell

import (
	"os"
	"runtime"
	"strconv"
	"strings"
	"time"
)

func jobExecWaiter(pid int, promptToken string) func() {
	if runtime.GOOS != "linux" || promptToken == "" {
		return nil
	}
	return func() { waitForJobExec(pid) }
}

// On Linux, the shell can show its prompt while a background child still handles
// SIGHUP as the shell. A hangup forwarded in that window can be consumed before
// the child execs its program. Inspect only this shell's direct children;
// the shell still decides which process groups to signal, respecting disown.
func waitForJobExec(pid int) {
	parent := strconv.Itoa(pid)
	children, err := os.ReadFile("/proc/" + parent + "/task/" + parent + "/children")
	if err != nil {
		return // procfs may be unavailable or the shell already gone
	}
	// A subshell running builtins need never exec. All jobs share one grace
	// period so they cannot hold terminal closure open indefinitely.
	deadline := time.Now().Add(100 * time.Millisecond)
	for child := range strings.FieldsSeq(string(children)) {
		for {
			if !time.Now().Before(deadline) {
				return
			}
			if !jobBeforeExec(parent, child) {
				break
			}
			time.Sleep(time.Millisecond)
		}
	}
}

func jobBeforeExec(parent, child string) bool {
	stat, err := os.ReadFile("/proc/" + child + "/stat")
	if err != nil {
		return false // a job can exit between the children and stat reads
	}
	// The command name in parentheses can contain spaces and ')'. Starting
	// after it, state, ppid and flags are fields 3, 4 and 9 of proc_pid_stat(5).
	text := string(stat)
	fields := strings.Fields(text[strings.LastIndexByte(text, ')')+1:])
	if len(fields) < 7 || fields[1] != parent || fields[0] == "Z" || fields[0] == "T" || fields[0] == "t" {
		return false
	}
	const forkNoExec = 0x40 // PF_FORKNOEXEC in linux/sched.h
	flags, err := strconv.ParseUint(fields[6], 10, 64)
	return err == nil && flags&forkNoExec != 0
}
