package sysinfo

import (
	"errors"
	"unsafe"

	"golang.org/x/sys/windows"
)

// processMemoryCountersEx2 is PROCESS_MEMORY_COUNTERS_EX2, which Windows 10 1809 and later fill.
type processMemoryCountersEx2 struct {
	processMemoryCounters
	privateUsage          uintptr
	privateWorkingSetSize uintptr
	sharedCommitUsage     uint64
}

// processes reads a Toolhelp snapshot, then each process's start time and memory. A process
// this user may not open keeps a zero start time and memory.
func processes() ([]Process, error) {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return nil, err
	}
	defer windows.CloseHandle(snapshot)
	var entry windows.ProcessEntry32
	entry.Size = uint32(unsafe.Sizeof(entry))
	var table []Process
	for err = windows.Process32First(snapshot, &entry); err == nil; err = windows.Process32Next(snapshot, &entry) {
		row := Process{
			PID:       int(entry.ProcessID),
			ParentPID: int(entry.ParentProcessID),
			Name:      windows.UTF16ToString(entry.ExeFile[:]),
		}
		row.StartTime, row.MemoryBytes = processFacts(entry.ProcessID)
		table = append(table, row)
	}
	if !errors.Is(err, windows.ERROR_NO_MORE_FILES) {
		return nil, err
	}
	return table, nil
}

// processFacts is when the process of pid started, in microseconds since 1970, and its private
// working set; zero for what cannot be read.
func processFacts(pid uint32) (start, memory uint64) {
	if pid == 0 {
		// The System Idle Process cannot be opened.
		return 0, 0
	}
	// Reading the memory counters needs PROCESS_VM_READ as well; without it the start time
	// is still read.
	handle, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.PROCESS_VM_READ, false, pid)
	readMemory := err == nil
	if !readMemory {
		if handle, err = windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid); err != nil {
			return 0, 0
		}
	}
	defer windows.CloseHandle(handle)
	var creation, exit, kernel, user windows.Filetime
	if windows.GetProcessTimes(handle, &creation, &exit, &kernel, &user) == nil {
		start = uint64(max(0, creation.Nanoseconds()/1000))
	}
	if readMemory {
		memory = privateWorkingSet(handle)
	}
	return start, memory
}

// privateWorkingSet is what Task Manager's Memory column shows for the process of handle. On
// a system older than Windows 10 1809 it is the whole working set.
func privateWorkingSet(handle windows.Handle) uint64 {
	if getProcessMemoryInfo.Find() != nil {
		return 0
	}
	var counters processMemoryCountersEx2
	counters.cb = uint32(unsafe.Sizeof(counters))
	if ok, _, _ := getProcessMemoryInfo.Call(uintptr(handle), uintptr(unsafe.Pointer(&counters)), uintptr(counters.cb)); ok != 0 {
		return uint64(counters.privateWorkingSetSize)
	}
	counters.cb = uint32(unsafe.Sizeof(counters.processMemoryCounters))
	if ok, _, _ := getProcessMemoryInfo.Call(uintptr(handle), uintptr(unsafe.Pointer(&counters)), uintptr(counters.cb)); ok != 0 {
		return uint64(counters.workingSetSize)
	}
	return 0
}
