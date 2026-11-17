//go:build windows

package pluginservice

import (
	"context"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/sysinfo"
)

// Windows has no ps. The process table is read in this process through the Win32 API (sysinfo, the
// same table the status bar's memory readout uses), so a sample starts no PowerShell: the client is a
// GUI program with no console, and every console program it started would get a console window of its
// own, a new terminal window per sampling interval with Windows Terminal as the default terminal. The
// CPU share is the change in the tree's CPU time between two samples of the same root, over the wall
// time between them.
var windowsCPU struct {
	sync.Mutex
	last map[int]windowsReading
}

type windowsReading struct {
	cpuSeconds float64
	at         time.Time
}

func sampleProcessTree(ctx context.Context, pid int) (ProcessSample, bool) {
	if ctx.Err() != nil {
		return ProcessSample{}, false
	}
	table, err := sysinfo.Processes(sysinfo.Options{})
	if err != nil {
		return ProcessSample{}, false
	}
	memory, cpuSeconds, ok := sumProcessTree(table, pid)
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
