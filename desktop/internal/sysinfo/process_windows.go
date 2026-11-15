package sysinfo

import (
	"errors"
	"unsafe"

	"golang.org/x/sys/windows"
)

// processMemoryCountersEx2 is PROCESS_MEMORY_COUNTERS_EX2, available with the
// September 2023 cumulative update for Windows 10/11 22H2 and on later clients.
type processMemoryCountersEx2 struct {
	processMemoryCounters
	privateUsage          uintptr
	privateWorkingSetSize uintptr
	sharedCommitUsage     uint64
}

// processes reads a Toolhelp snapshot, then each process's start time, processor time and
// memory, and the graphics use of the processes options name. A process this user may not
// open keeps a zero start time and memory and no other facts.
func processes(options Options) ([]Process, error) {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return nil, err
	}
	defer windows.CloseHandle(snapshot)
	var adapters []gpuAdapter
	if len(options.GPU) > 0 {
		var close func()
		adapters, close = openGPUAdapters()
		defer close()
	}
	var entry windows.ProcessEntry32
	entry.Size = uint32(unsafe.Sizeof(entry))
	var table []Process
	for err = windows.Process32First(snapshot, &entry); err == nil; err = windows.Process32Next(snapshot, &entry) {
		row := Process{
			PID:       int(entry.ProcessID),
			ParentPID: int(entry.ParentProcessID),
			Name:      windows.UTF16ToString(entry.ExeFile[:]),
		}
		var gpu []gpuAdapter
		if options.GPU[row.PID] {
			gpu = adapters
		}
		readFacts(&row, gpu)
		table = append(table, row)
	}
	if !errors.Is(err, windows.ERROR_NO_MORE_FILES) {
		return nil, err
	}
	return table, nil
}

// readFacts fills what the process of row says about itself: when it started, its processor
// time, its memory, and its use of the adapters given; what cannot be read is left zero or nil.
func readFacts(row *Process, adapters []gpuAdapter) {
	if row.PID == 0 {
		// The System Idle Process cannot be opened.
		return
	}
	// Reading the memory counters needs PROCESS_VM_READ as well; without it the times are
	// still read.
	pid := uint32(row.PID)
	handle, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.PROCESS_VM_READ, false, pid)
	readMemory := err == nil
	if !readMemory {
		if handle, err = windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid); err != nil {
			return
		}
	}
	defer windows.CloseHandle(handle)
	var creation, exit, kernel, user windows.Filetime
	if windows.GetProcessTimes(handle, &creation, &exit, &kernel, &user) == nil {
		row.StartTime = uint64(max(0, creation.Nanoseconds()/1000))
		// Kernel and user times count 100-nanosecond intervals.
		cpu := (filetimeTicks(kernel) + filetimeTicks(user)) / 10
		row.CPUTime = &cpu
	}
	if readMemory {
		row.MemoryBytes, row.CompressedBytes = privateMemory(handle)
	}
	if len(adapters) > 0 {
		dedicated, engines := processGPU(handle, adapters)
		row.GPUMemoryBytes = dedicated
		row.GPUEngines = engines
	}
}

// filetimeTicks is a duration FILETIME as its count of 100-nanosecond intervals.
func filetimeTicks(time windows.Filetime) uint64 {
	return uint64(time.HighDateTime)<<32 | uint64(time.LowDateTime)
}

// privateMemory is what Task Manager's Memory column shows for the process of handle, its
// private working set, and the private commit outside it, which holds what Windows compressed
// or wrote to the page file. Systems without private working set counters
// report the whole working set and leave the private commit outside it unknown.
func privateMemory(handle windows.Handle) (uint64, *uint64) {
	if getProcessMemoryInfo.Find() != nil {
		return 0, nil
	}
	var counters processMemoryCountersEx2
	if ok, _, _ := getProcessMemoryInfo.Call(uintptr(handle), uintptr(unsafe.Pointer(&counters)), unsafe.Sizeof(counters)); ok != 0 {
		return counters.memory()
	}
	var basic processMemoryCounters
	if ok, _, _ := getProcessMemoryInfo.Call(uintptr(handle), uintptr(unsafe.Pointer(&basic)), unsafe.Sizeof(basic)); ok != 0 {
		return uint64(basic.workingSetSize), nil
	}
	return 0, nil
}

func (c *processMemoryCountersEx2) memory() (uint64, *uint64) {
	// Windows Server 2022 can succeed without filling the private working set.
	if uintptr(c.cb) < unsafe.Sizeof(*c) || (c.privateWorkingSetSize == 0 && c.workingSetSize != 0) {
		return uint64(c.workingSetSize), nil
	}
	resident := uint64(c.privateWorkingSetSize)
	outside := uint64(c.privateUsage) - min(uint64(c.privateUsage), resident)
	return resident, &outside
}
