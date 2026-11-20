package workbench

import (
	"context"
	"slices"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/sysinfo"
	"github.com/vivaui/viva/app"
)

// processPortsKernel is the Core command that attributes, deduplicates, and formats
// TCP listening ports owned by a run session's process tree.
type processPortsKernel interface {
	ProcessListeningPorts(context.Context, core.ListeningPortsRequest) (core.ListeningPortsResponse, error)
}

const runPortProbeTimeout = 2 * time.Second

// Fast initial probes pick up web frameworks quickly at startup before settling to a
// steady 2-second polling cadence; the last interval repeats until the run exits.
var (
	runPortSampleSchedule = []time.Duration{
		250 * time.Millisecond,
		500 * time.Millisecond,
		time.Second,
		2 * time.Second,
	}
	readRunProcesses = func() ([]sysinfo.Process, error) {
		return sysinfo.Processes(sysinfo.Options{})
	}
	readListeningSockets = sysinfo.ListeningSockets
)

// startRunPortSampling begins polling TCP listening sockets of rootPID's process tree
// and posts changes to entry.ports on the window thread until stopRunPortSampling runs.
func (a *App) startRunPortSampling(p *project, entry *runEntry, rootPID, debugPort int) {
	if a == nil || p == nil || entry == nil || rootPID <= 0 || a.kernel == nil {
		return
	}
	stopRunPortSampling(entry)

	ctx, cancel := context.WithCancel(context.Background())
	entry.stopPorts = cancel

	kernel := a.kernel
	schedule := slices.Clone(runPortSampleSchedule)
	if len(schedule) == 0 {
		schedule = []time.Duration{2 * time.Second}
	}
	readProcs := readRunProcesses
	readSockets := readListeningSockets

	go func() {
		step := 0
		timer := time.NewTimer(schedule[step])
		defer timer.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-timer.C:
				probeCtx, probeCancel := context.WithTimeout(ctx, runPortProbeTimeout)
				resp, ok := readRunPortsSnapshot(probeCtx, kernel, readProcs, readSockets, rootPID, debugPort)
				probeCancel()
				if ok && ctx.Err() == nil {
					a.post(func(a *App) {
						if a.project != p || !entry.running || ctx.Err() != nil {
							return
						}
						if slices.Equal(entry.ports, resp.Ports) && entry.portsTruncated == resp.Truncated {
							return
						}
						entry.ports = resp.Ports
						entry.portsTruncated = resp.Truncated
					})
				}
				if step+1 < len(schedule) {
					step++
				}
				timer.Reset(schedule[step])
			}
		}
	}()
}

// stopRunPortSampling ends active port polling for entry and clears live ports.
func stopRunPortSampling(entry *runEntry) {
	if entry == nil {
		return
	}
	if entry.stopPorts != nil {
		entry.stopPorts()
		entry.stopPorts = nil
	}
	entry.ports = nil
	entry.portsTruncated = false
}

func readRunPortsSnapshot(
	ctx context.Context,
	kernel processPortsKernel,
	readProcs func() ([]sysinfo.Process, error),
	readSockets func([]int) ([]sysinfo.ListeningSocket, error),
	rootPID int,
	debugPort int,
) (core.ListeningPortsResponse, bool) {
	if rootPID <= 0 || ctx.Err() != nil {
		return core.ListeningPortsResponse{}, false
	}
	table, _ := readProcs()
	candidatePIDs, coreProcesses := candidateRunTree(rootPID, table)
	rawSockets, err := readSockets(candidatePIDs)
	if err != nil {
		return core.ListeningPortsResponse{}, false
	}
	sockets := make([]core.ListeningSocket, 0, len(rawSockets))
	for _, s := range rawSockets {
		sockets = append(sockets, core.ListeningSocket{
			ProcessID: int64(s.PID),
			Address:   s.Address,
			Port:      s.Port,
		})
	}
	var exclude []uint16
	if debugPort > 0 && debugPort <= 65535 {
		exclude = []uint16{uint16(debugPort)}
	}
	resp, err := kernel.ProcessListeningPorts(ctx, core.ListeningPortsRequest{
		RootProcessID: int64(rootPID),
		Processes:     coreProcesses,
		Sockets:       sockets,
		ExcludePorts:  exclude,
	})
	if err != nil {
		return core.ListeningPortsResponse{}, false
	}
	return resp, true
}

// candidateRunTree collects rootPID and its valid descendants so socket enumeration only
// inspects the run's processes rather than unrelated processes on the host.
func candidateRunTree(rootPID int, table []sysinfo.Process) ([]int, []core.PortProcess) {
	byPID := make(map[int]sysinfo.Process, len(table))
	children := make(map[int][]sysinfo.Process)
	coreProcesses := make([]core.PortProcess, 0, len(table))
	for _, proc := range table {
		if proc.PID <= 0 {
			continue
		}
		if _, dup := byPID[proc.PID]; dup {
			continue
		}
		byPID[proc.PID] = proc
		children[proc.ParentPID] = append(children[proc.ParentPID], proc)
		var started *uint64
		if proc.StartTime > 0 {
			v := proc.StartTime
			started = &v
		}
		coreProcesses = append(coreProcesses, core.PortProcess{
			ProcessID:       int64(proc.PID),
			ParentProcessID: int64(proc.ParentPID),
			StartTime:       started,
		})
	}

	pids := []int{rootPID}
	seen := map[int]bool{rootPID: true}
	queue := []int{rootPID}
	for len(queue) > 0 {
		parentPID := queue[0]
		queue = queue[1:]
		parent, hasParent := byPID[parentPID]
		for _, child := range children[parentPID] {
			if seen[child.PID] {
				continue
			}
			// Guard against OS PID reuse where a child appears older than its recycled parent.
			if hasParent && parent.StartTime > 0 && child.StartTime > 0 && parent.StartTime > child.StartTime {
				continue
			}
			seen[child.PID] = true
			pids = append(pids, child.PID)
			queue = append(queue, child.PID)
		}
	}
	return pids, coreProcesses
}

// openRunPort opens the listening endpoint's URL in the system browser.
func (a *App) openRunPort(port core.ListeningPort, surface actionSurface) {
	a.performed("run.port.open", surface)
	if err := openURL(port.URL); err != nil {
		a.operationFailed("run_port_open", err)
		a.notifyError(a.text.Run.Ports.OpenFailed(port.URL))
	}
}

// copyRunPortURL copies the listening endpoint's URL to the clipboard.
func (a *App) copyRunPortURL(port core.ListeningPort) {
	a.performed("run.port.copy", surfaceContextMenu)
	_ = app.SetClipboardText(port.URL)
}
