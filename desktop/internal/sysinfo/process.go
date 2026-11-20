package sysinfo

// Process is one row of the system's process table, with what the memory readout of the
// status bar needs to place the process and weigh it.
type Process struct {
	// PID is the process's ID and ParentPID its parent's, as the system reports them.
	PID, ParentPID int
	// ResponsiblePID is the process the system holds responsible for this one, which macOS
	// reports for the XPC services it starts for an app, such as the WebKit processes of a
	// web view. It is zero where the system has no such notion or did not say.
	ResponsiblePID int
	// StartTime is when the process started, in microseconds since 1970; zero when not read.
	// Windows keeps the ID of a parent that exited, which a later process may reuse; a parent
	// that started after its child is such a reused ID.
	StartTime uint64
	// Name is the process's short name.
	Name string
	// MemoryBytes is what the process has in memory: on macOS the physical footprint Activity
	// Monitor shows less its compressed part, on Windows the private working set Task Manager
	// shows (or the whole working set when the private counter is unavailable), on Linux
	// the resident pages less the shared ones. It is zero for a process whose memory this
	// user may not read.
	MemoryBytes uint64
	// CompressedBytes is what the system compressed or wrote out to disk for the process, which
	// MemoryBytes does not include, nil when it was not read. macOS reports the compressed
	// memory and Linux the swapped-out memory exactly. Windows does not say which part of a
	// process's commit charge is compressed, so it is the private commit not in the working
	// set: compressed, written to the page file, or committed but never touched.
	CompressedBytes *uint64
	// GPUMemoryBytes is graphics memory charged to the process that MemoryBytes does not hold:
	// the dedicated video memory Task Manager shows on Windows. It is nil on macOS and Linux,
	// where it is not read, and for a process whose graphics use was not read.
	GPUMemoryBytes *uint64
	// CPUTime is the processor time the process used since it started, user and system, in
	// microseconds; nil when it was not read.
	CPUTime *uint64
	// GPUEngines is the busy time of every graphics engine the process used, empty when it
	// used none or its graphics use was not read.
	GPUEngines []GPUEngine
}

// GPUEngine is the time one graphics engine spent on a process's work since it started.
type GPUEngine struct {
	// Name is the same for one engine in every process and every reading of this run: an
	// accelerator on macOS, an adapter and node on Windows, a device and engine on Linux.
	Name string
	// BusyTime is in microseconds.
	BusyTime uint64
}

// Options says what Processes reads beyond what every row has.
type Options struct {
	// GPU holds the processes whose graphics use is read; reading it for every process of the
	// system costs far more than the rest of the table.
	GPU map[int]bool
}

// Processes reads the process table: every process this user can see. A fact the system does
// not give for one process is zero or nil; the error says the table could not be listed at all.
func Processes(options Options) ([]Process, error) { return processes(options) }

// ProcessTreeIDs returns the root and the descendants visible in a native process snapshot.
// Callers use it to scope native per-process queries before reading details.
func ProcessTreeIDs(rootPID int, table []Process) []int {
	byPID := make(map[int]Process, len(table))
	children := make(map[int][]Process)
	for _, row := range table {
		if _, seen := byPID[row.PID]; row.PID <= 0 || seen {
			continue
		}
		byPID[row.PID] = row
		children[row.ParentPID] = append(children[row.ParentPID], row)
	}
	pids := []int{rootPID}
	seen := map[int]bool{rootPID: true}
	for index := 0; index < len(pids); index++ {
		parentPID := pids[index]
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
		}
	}
	return pids
}
