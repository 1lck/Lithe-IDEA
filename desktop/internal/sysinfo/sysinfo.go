// Package sysinfo reads the facts about the machine a diagnostic bundle's manifest records:
// the operating system, the processor count, how much memory the process holds and how much
// room is left on the disk of the log directory. A fact the system does not give is zero or
// empty rather than an error, so a bundle can always be made.
package sysinfo

import "runtime"

// Snapshot is what the system said at one moment.
type Snapshot struct {
	// OSName is the operating system's name, such as macOS.
	OSName string
	// OSVersion is its version as the system writes it, such as "Version 27.3 (Build 25D125)".
	OSVersion string
	// CPUCores is how many logical processors the process may use.
	CPUCores uint32
	// ResidentBytes is the memory the process holds in RAM.
	ResidentBytes uint64
	// DiskFreeBytes is the room left on the volume of the path the snapshot was taken for,
	// available to this user.
	DiskFreeBytes uint64
}

// Name is the operating system's name, as Snapshot.OSName holds it.
func Name() string {
	return osName
}

// Current is a snapshot of the system now, with the room left on volume's disk.
func Current(volume string) Snapshot {
	return Snapshot{
		OSName:        osName,
		OSVersion:     Version(),
		CPUCores:      uint32(max(0, runtime.NumCPU())),
		ResidentBytes: residentBytes(),
		DiskFreeBytes: diskFree(volume),
	}
}
