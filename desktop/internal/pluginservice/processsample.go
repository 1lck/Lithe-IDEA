package pluginservice

import (
	"context"
	"os/exec"
	"strconv"
	"strings"
)

// ProcessSample is what a process tree used at one moment: its CPU share in percent of one core, and
// the resident memory of every process in it, in bytes.
type ProcessSample struct {
	CPUPercent  float64
	MemoryBytes uint64
}

// SampleProcessTree reads the CPU and memory of a process and its descendants. ok is false when the
// process is gone or the platform cannot tell. The sample is taken by one short-lived command, so the
// caller samples on its own schedule and never from the window thread.
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

// windowsProcess is one row of the Win32_Process table: its tree links, its working set and the CPU
// time it has used in 100-nanosecond units.
type windowsProcess struct {
	pid, parent int
	workingSet  uint64
	cpuTicks    uint64
}

// parseWindowsTable reads the CSV the Win32_Process query prints (ProcessId, ParentProcessId,
// WorkingSetSize, KernelModeTime, UserModeTime) and sums the tree under root. cpuSeconds is the CPU
// time the tree has used so far; the caller turns two readings into a share.
func parseWindowsTable(output []byte, root int) (memoryBytes uint64, cpuSeconds float64, ok bool) {
	children := map[int][]int{}
	rows := map[int]windowsProcess{}
	for index, line := range strings.Split(string(output), "\n") {
		line = strings.TrimSpace(line)
		if index == 0 || line == "" {
			continue
		}
		fields := strings.Split(strings.Trim(line, `"`), `","`)
		if len(fields) != 5 {
			continue
		}
		pid, err1 := strconv.Atoi(fields[0])
		parent, err2 := strconv.Atoi(fields[1])
		workingSet, err3 := strconv.ParseUint(fields[2], 10, 64)
		kernel, err4 := strconv.ParseUint(fields[3], 10, 64)
		user, err5 := strconv.ParseUint(fields[4], 10, 64)
		if err1 != nil || err2 != nil || err3 != nil || err4 != nil || err5 != nil {
			continue
		}
		rows[pid] = windowsProcess{pid: pid, parent: parent, workingSet: workingSet, cpuTicks: kernel + user}
		children[parent] = append(children[parent], pid)
	}
	if _, found := rows[root]; !found {
		return 0, 0, false
	}
	var ticks uint64
	stack, seen := []int{root}, map[int]bool{}
	for len(stack) > 0 {
		pid := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if seen[pid] {
			continue
		}
		seen[pid] = true
		current := rows[pid]
		memoryBytes += current.workingSet
		ticks += current.cpuTicks
		stack = append(stack, children[pid]...)
	}
	return memoryBytes, float64(ticks) / 1e7, true
}

// SampleProcessMemory reads the process table once and sums the resident memory of the tree under
// each pid, in bytes. A pid that is gone is left out. Like SampleProcessTree it runs a short-lived
// command, so it is called off the window thread.
func SampleProcessMemory(ctx context.Context, pids []int) map[int]uint64 {
	if len(pids) == 0 {
		return nil
	}
	output, err := processTable(ctx)
	if err != nil {
		return nil
	}
	memory := make(map[int]uint64, len(pids))
	for _, pid := range pids {
		if pid <= 0 {
			continue
		}
		if bytes, ok := treeMemory(output, pid); ok {
			memory[pid] = bytes
		}
	}
	return memory
}
