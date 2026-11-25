//go:build !windows

package processledger

import (
	"os/exec"
	"strconv"
	"strings"
)

// identity reads the start time and command name of a live process. ok is false when the process
// is gone or the platform cannot tell.
func identity(pid int) (started, command string, ok bool) {
	output, err := exec.Command("ps", "-o", "lstart=", "-o", "comm=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return "", "", false
	}
	line := strings.TrimSpace(string(output))
	if line == "" {
		return "", "", false
	}
	// lstart has a fixed width of 24 characters on the systems this runs on; the command follows it.
	if len(line) < 25 {
		return "", "", false
	}
	return strings.TrimSpace(line[:24]), strings.TrimSpace(line[24:]), true
}

// signal sends pid the signal called name: TERM asks it to stop, KILL ends it.
func signal(pid int, name string) error {
	return exec.Command("kill", "-"+name, strconv.Itoa(pid)).Run()
}
