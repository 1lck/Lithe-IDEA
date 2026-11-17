//go:build windows

package pluginservice

import (
	"context"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
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
	command := exec.CommandContext(ctx, "powershell", "-NoProfile", "-NonInteractive", "-Command", windowsTableCommand)
	// The client is a GUI program with no console, so Windows would give each sample's console
	// program a console of its own: with Windows Terminal as the default terminal that is a new
	// terminal window every sampling interval while a run is shown. The query needs no window.
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}
	output, err := command.Output()
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
