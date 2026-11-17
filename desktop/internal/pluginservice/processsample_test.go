package pluginservice

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/sysinfo"
)

func TestSumProcessTreeAddsDescendantsAndSkipsReusedParentIDs(t *testing.T) {
	cpu := func(micros uint64) *uint64 { return &micros }
	table := []sysinfo.Process{
		{PID: 10, ParentPID: 1, StartTime: 100, MemoryBytes: 1000, CPUTime: cpu(2_000_000)},
		{PID: 11, ParentPID: 10, StartTime: 110, MemoryBytes: 200, CPUTime: cpu(500_000)},
		// A grandchild whose CPU time was not read still counts its memory.
		{PID: 12, ParentPID: 11, StartTime: 120, MemoryBytes: 30},
		// It started before 10, so 10 is the reused ID of its exited parent, not its parent.
		{PID: 13, ParentPID: 10, StartTime: 50, MemoryBytes: 4000, CPUTime: cpu(9_000_000)},
		// A process this user may not open has no start time; its parent link is kept.
		{PID: 14, ParentPID: 10, MemoryBytes: 5, CPUTime: cpu(0)},
		{PID: 20, ParentPID: 1, StartTime: 90, MemoryBytes: 70000, CPUTime: cpu(1_000_000)},
	}
	memory, cpuSeconds, ok := sumProcessTree(table, 10)
	if !ok || memory != 1235 || cpuSeconds != 2.5 {
		t.Fatalf("sumProcessTree(10) = %d, %v, %t; want 1235, 2.5, true", memory, cpuSeconds, ok)
	}
}

func TestSumProcessTreeEndsOnACycleAndMissesAnAbsentRoot(t *testing.T) {
	// The System Idle Process names itself as its parent.
	table := []sysinfo.Process{
		{PID: 0, ParentPID: 0, MemoryBytes: 1},
		{PID: 4, ParentPID: 0, MemoryBytes: 2},
	}
	if memory, _, ok := sumProcessTree(table, 0); !ok || memory != 3 {
		t.Fatalf("sumProcessTree(0) = %d, %t; want 3, true", memory, ok)
	}
	if _, _, ok := sumProcessTree(table, 99); ok {
		t.Fatal("sumProcessTree found a root that is not in the table")
	}
}
