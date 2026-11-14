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
	// MemoryBytes is the memory the system charges to the process: the physical footprint
	// Activity Monitor shows on macOS, the private working set Task Manager shows on Windows
	// and the resident pages less the shared ones on Linux. It is zero for a process whose
	// memory this user may not read.
	MemoryBytes uint64
}

// Processes reads the process table: every process this user can see. A fact the system does
// not give for one process is zero; the error says the table could not be listed at all.
func Processes() ([]Process, error) { return processes() }
