package sysinfo

import (
	"strconv"
	"unsafe"

	"golang.org/x/sys/windows"
)

const osName = "Windows"

// Version is the system's version number and build, such as 10.0.26100.
func Version() string {
	info := windows.RtlGetVersion()
	return strconv.FormatUint(uint64(info.MajorVersion), 10) + "." +
		strconv.FormatUint(uint64(info.MinorVersion), 10) + "." +
		strconv.FormatUint(uint64(info.BuildNumber), 10)
}

// processMemoryCounters is PROCESS_MEMORY_COUNTERS, which x/sys/windows does not declare.
type processMemoryCounters struct {
	cb                         uint32
	pageFaultCount             uint32
	peakWorkingSetSize         uintptr
	workingSetSize             uintptr
	quotaPeakPagedPoolUsage    uintptr
	quotaPagedPoolUsage        uintptr
	quotaPeakNonPagedPoolUsage uintptr
	quotaNonPagedPoolUsage     uintptr
	pagefileUsage              uintptr
	peakPagefileUsage          uintptr
}

var getProcessMemoryInfo = windows.NewLazySystemDLL("psapi.dll").NewProc("GetProcessMemoryInfo")

// residentBytes is the process's working set.
func residentBytes() uint64 {
	if getProcessMemoryInfo.Find() != nil {
		return 0
	}
	var counters processMemoryCounters
	counters.cb = uint32(unsafe.Sizeof(counters))
	ok, _, _ := getProcessMemoryInfo.Call(uintptr(windows.CurrentProcess()), uintptr(unsafe.Pointer(&counters)), uintptr(counters.cb))
	if ok == 0 {
		return 0
	}
	return uint64(counters.workingSetSize)
}

func diskFree(volume string) uint64 {
	if volume == "" {
		return 0
	}
	path, err := windows.UTF16PtrFromString(volume)
	if err != nil {
		return 0
	}
	var available, total, free uint64
	if windows.GetDiskFreeSpaceEx(path, &available, &total, &free) != nil {
		return 0
	}
	return available
}
