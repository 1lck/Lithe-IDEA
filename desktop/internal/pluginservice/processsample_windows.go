//go:build windows

package pluginservice

import (
	"context"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Windows reports cumulative CPU seconds and working set per process through PowerShell. The CPU share
// is the change between two samples of the same process, so the last reading of each PID is kept. Only
// the root process is measured; the tree is not summed on this platform yet.
var windowsCPU struct {
	sync.Mutex
	last map[int]windowsReading
}

type windowsReading struct {
	cpuSeconds float64
	at         time.Time
}

func sampleProcessTree(ctx context.Context, pid int) (ProcessSample, bool) {
	command := "Get-Process -Id " + strconv.Itoa(pid) + " | ForEach-Object { \"$($_.CPU) $($_.WorkingSet64)\" }"
	output, err := exec.CommandContext(ctx, "powershell", "-NoProfile", "-NonInteractive", "-Command", command).Output()
	if err != nil {
		return ProcessSample{}, false
	}
	fields := strings.Fields(string(output))
	if len(fields) != 2 {
		return ProcessSample{}, false
	}
	cpuSeconds, err1 := strconv.ParseFloat(fields[0], 64)
	memory, err2 := strconv.ParseUint(fields[1], 10, 64)
	if err1 != nil || err2 != nil {
		return ProcessSample{}, false
	}
	now := time.Now()
	windowsCPU.Lock()
	defer windowsCPU.Unlock()
	if windowsCPU.last == nil {
		windowsCPU.last = map[int]windowsReading{}
	}
	previous, seen := windowsCPU.last[pid]
	windowsCPU.last[pid] = windowsReading{cpuSeconds: cpuSeconds, at: now}
	sample := ProcessSample{MemoryBytes: memory}
	if seen && now.After(previous.at) {
		sample.CPUPercent = (cpuSeconds - previous.cpuSeconds) / now.Sub(previous.at).Seconds() * 100
	}
	return sample, true
}
