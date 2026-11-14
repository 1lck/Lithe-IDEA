package sysinfo

import (
	"os"
	"strconv"
	"strings"
)

// processes reads /proc. Linux gives an orphan to init or a subreaper, so the parent IDs are
// never stale and the start time is not read.
func processes() ([]Process, error) {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	page := uint64(os.Getpagesize())
	table := make([]Process, 0, len(entries))
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid <= 0 {
			continue
		}
		if row, ok := readProcess(pid, page); ok {
			table = append(table, row)
		}
	}
	return table, nil
}

// readProcess reads the parent and name from /proc/pid/stat and the memory from
// /proc/pid/statm; false when the process exited while it was read.
func readProcess(pid int, page uint64) (Process, bool) {
	dir := "/proc/" + strconv.Itoa(pid) + "/"
	stat, err := os.ReadFile(dir + "stat")
	if err != nil {
		return Process{}, false
	}
	// The name is in parentheses and may itself hold spaces and parentheses, so the fields
	// after it start at the last closing one: the state, then the parent ID.
	text := string(stat)
	open, close := strings.IndexByte(text, '('), strings.LastIndexByte(text, ')')
	if open < 0 || close < open {
		return Process{}, false
	}
	fields := strings.Fields(text[close+1:])
	if len(fields) < 2 {
		return Process{}, false
	}
	parent, err := strconv.Atoi(fields[1])
	if err != nil {
		return Process{}, false
	}
	row := Process{PID: pid, ParentPID: parent, Name: text[open+1 : close]}
	if statm, err := os.ReadFile(dir + "statm"); err == nil {
		row.MemoryBytes = privatePages(string(statm)) * page
	}
	return row, true
}

// privatePages is the resident pages of a statm line less its shared ones.
func privatePages(statm string) uint64 {
	fields := strings.Fields(statm)
	if len(fields) < 3 {
		return 0
	}
	resident, err := strconv.ParseUint(fields[1], 10, 64)
	if err != nil {
		return 0
	}
	shared, err := strconv.ParseUint(fields[2], 10, 64)
	if err != nil || shared > resident {
		return 0
	}
	return resident - shared
}
