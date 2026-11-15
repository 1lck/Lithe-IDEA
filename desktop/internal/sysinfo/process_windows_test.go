package sysinfo

import (
	"testing"
	"unsafe"
)

func TestWindowsProcessMemoryCounters(t *testing.T) {
	fullSize := uint32(unsafe.Sizeof(processMemoryCountersEx2{}))
	partialSize := uint32(unsafe.Sizeof(processMemoryCounters{}))
	for _, tc := range []struct {
		name       string
		returned   uint32
		private    uintptr
		resident   uint64
		hasOutside bool
		commit     uintptr
		outside    uint64
	}{
		{"private working set available", fullSize, 600, 600, true, 750, 150},
		{"short counter reply", partialSize, 0, 800, false, 750, 0},
		{"successful reply with no private working set", fullSize, 0, 800, false, 750, 0},
		{"private commit below the working set", fullSize, 900, 900, true, 750, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			counters := processMemoryCountersEx2{
				processMemoryCounters: processMemoryCounters{cb: tc.returned, workingSetSize: 800},
				privateUsage:          tc.commit,
				privateWorkingSetSize: tc.private,
			}
			resident, outside := counters.memory()
			if resident != tc.resident || (outside != nil) != tc.hasOutside {
				t.Fatalf("resident = %d, outside reported = %t, want %d and %t",
					resident, outside != nil, tc.resident, tc.hasOutside)
			}
			if outside != nil && *outside != tc.outside {
				t.Fatalf("outside = %d, want %d", *outside, tc.outside)
			}
		})
	}
}
