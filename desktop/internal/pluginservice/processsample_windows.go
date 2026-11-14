//go:build windows

package pluginservice

import (
	"context"
	"os/exec"
	"sync"
	"time"
)

// Windows has no ps. One PowerShell query reads the whole Win32_Process table, from which the tree under
// the root is summed the same way the unix table is. The CPU share is the change in the tree's CPU time
// between two samples of the same root, over the wall time between them.
var windowsCPU struct {
	sync.Mutex
	last map[int]windowsReading
}

type windowsReading struct {
	cpuSeconds float64
	at         time.Time
}

const windowsTableCommand = "Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,WorkingSetSize,KernelModeTime,UserModeTime | ConvertTo-Csv -NoTypeInformation"

func sampleProcessTree(ctx context.Context, pid int) (ProcessSample, bool) {
	output, err := exec.CommandContext(ctx, "powershell", "-NoProfile", "-NonInteractive", "-Command", windowsTableCommand).Output()
	if err != nil {
		return ProcessSample{}, false
	}
	memory, cpuSeconds, ok := parseWindowsTable(output, pid)
	if !ok {
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
		// A tree that lost a child can read less CPU than before; a share is never negative.
		sample.CPUPercent = max(0, (cpuSeconds-previous.cpuSeconds)/now.Sub(previous.at).Seconds()*100)
	}
	return sample, true
}
