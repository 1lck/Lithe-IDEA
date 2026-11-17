package pluginservice

import (
	"context"
	"os/exec"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/sysinfo"
)

// ProcessSample is what a process tree used at one moment: its CPU share in percent of one core, and
// the memory of every process in it, in bytes: the resident set ps reports on macOS and Linux, the
// private working set Task Manager shows on Windows.
type ProcessSample struct {
	CPUPercent  float64
	MemoryBytes uint64
}

// SampleProcessTree reads the CPU and memory of a process and its descendants. ok is false when the
// process is gone or the platform cannot tell. The sample reads the whole process table (one short-lived
// ps on macOS and Linux, the Win32 API on Windows), so the caller samples on its own schedule and never
// from the window thread.
func SampleProcessTree(ctx context.Context, pid int) (ProcessSample, bool) {
	if pid <= 0 {
		return ProcessSample{}, false
	}
	return sampleProcessTree(ctx, pid)
}

// parsePSTable reads the table `ps -axo pid=,ppid=,pcpu=,rss=` prints and sums the tree under root.
func parsePSTable(output []byte, root int) (ProcessSample, bool) {
	children := map[int][]int{}
	type row struct {
		cpu float64
		rss uint64
	}
	rows := map[int]row{}
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) != 4 {
			continue
		}
		pid, err1 := strconv.Atoi(fields[0])
		ppid, err2 := strconv.Atoi(fields[1])
		cpu, err3 := strconv.ParseFloat(fields[2], 64)
		rss, err4 := strconv.ParseUint(fields[3], 10, 64)
		if err1 != nil || err2 != nil || err3 != nil || err4 != nil {
			continue
		}
		rows[pid] = row{cpu: cpu, rss: rss}
		children[ppid] = append(children[ppid], pid)
	}
	if _, ok := rows[root]; !ok {
		return ProcessSample{}, false
	}
	var sample ProcessSample
	stack := []int{root}
	seen := map[int]bool{}
	for len(stack) > 0 {
		pid := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if seen[pid] {
			continue
		}
		seen[pid] = true
		current := rows[pid]
		sample.CPUPercent += current.cpu
		sample.MemoryBytes += current.rss * 1024
		stack = append(stack, children[pid]...)
	}
	return sample, true
}

// psCommand runs ps for the whole table; the command line is fixed, the PID never reaches a shell.
func psCommand(ctx context.Context) ([]byte, error) {
	return exec.CommandContext(ctx, "ps", "-axo", "pid=,ppid=,pcpu=,rss=").Output()
}

// sumProcessTree sums what root and its descendants in table hold in memory and the CPU time they
// used, in seconds; ok is false when root is not in the table. Windows keeps the ID of a parent that
// exited, which a later process may reuse, so a row that started before the process its parent ID
// names is not that process's child. A start time or CPU time the system did not give counts as
// unknown, not as zero.
func sumProcessTree(table []sysinfo.Process, root int) (memoryBytes uint64, cpuSeconds float64, ok bool) {
	rows := make(map[int]sysinfo.Process, len(table))
	children := map[int][]int{}
	for _, row := range table {
		rows[row.PID] = row
		children[row.ParentPID] = append(children[row.ParentPID], row.PID)
	}
	if _, found := rows[root]; !found {
		return 0, 0, false
	}
	var micros uint64
	stack, seen := []int{root}, map[int]bool{}
	for len(stack) > 0 {
		pid := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if seen[pid] {
			continue
		}
		seen[pid] = true
		current := rows[pid]
		memoryBytes += current.MemoryBytes
		if current.CPUTime != nil {
			micros += *current.CPUTime
		}
		for _, child := range children[pid] {
			if started := rows[child].StartTime; started != 0 && current.StartTime != 0 && started < current.StartTime {
				continue
			}
			stack = append(stack, child)
		}
	}
	return memoryBytes, float64(micros) / 1e6, true
}
