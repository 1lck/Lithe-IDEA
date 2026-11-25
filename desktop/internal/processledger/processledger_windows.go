//go:build windows

package processledger

import (
	"fmt"
	"math"
	"strconv"

	"golang.org/x/sys/windows"
)

// identity reads the creation time and executable path of a live process. ok is false when the
// process is gone or cannot be opened, as a process of another user or a higher integrity level
// cannot. It asks the system through the process's handle and starts no program: the client is a
// GUI program with no console, so a console program it started without hiding the console, such
// as the ps that Git for Windows or MSYS2 can put on PATH, would open a console window of its own,
// one that flashed up at every build, run, test, debug and terminal start.
func identity(pid int) (started, command string, ok bool) {
	id, valid := processID(pid)
	if !valid {
		return "", "", false
	}
	handle, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.SYNCHRONIZE, false, id)
	if err != nil {
		return "", "", false
	}
	defer windows.CloseHandle(handle)
	// A process that has exited can still be opened while any handle to it is held, and it keeps
	// its creation time and path; it is not running all the same.
	if event, err := windows.WaitForSingleObject(handle, 0); err != nil || event != uint32(windows.WAIT_TIMEOUT) {
		return "", "", false
	}
	var creation, exit, kernel, user windows.Filetime
	if err := windows.GetProcessTimes(handle, &creation, &exit, &kernel, &user); err != nil {
		return "", "", false
	}
	path := make([]uint16, windows.MAX_LONG_PATH)
	size := uint32(len(path))
	if err := windows.QueryFullProcessImageName(handle, 0, &path[0], &size); err != nil {
		return "", "", false
	}
	// The creation time is kept exact, in 100-nanosecond intervals: a process that reuses the PID
	// was created later.
	created := uint64(creation.HighDateTime)<<32 | uint64(creation.LowDateTime)
	return strconv.FormatUint(created, 10), windows.UTF16ToString(path[:size]), true
}

// signal ends pid through its handle, for TERM as for KILL: there is no stop request to send it
// here (see buildprocess.StopsGracefully), so a leftover asked to stop ends at once. Like identity,
// it starts no program.
func signal(pid int, name string) error {
	id, valid := processID(pid)
	if !valid {
		return fmt.Errorf("processledger: %s %d: not a process ID", name, pid)
	}
	handle, err := windows.OpenProcess(windows.PROCESS_TERMINATE, false, id)
	if err != nil {
		return fmt.Errorf("processledger: %s %d: %w", name, pid, err)
	}
	defer windows.CloseHandle(handle)
	if err := windows.TerminateProcess(handle, 1); err != nil {
		return fmt.Errorf("processledger: %s %d: %w", name, pid, err)
	}
	return nil
}

// processID is pid as the system's process ID; a record read from the ledger can hold any number.
func processID(pid int) (uint32, bool) {
	if pid <= 0 || uint64(pid) > math.MaxUint32 {
		return 0, false
	}
	return uint32(pid), true
}
