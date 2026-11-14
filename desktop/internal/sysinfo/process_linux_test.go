package sysinfo

import (
	"reflect"
	"strings"
	"testing"
)

// TestProcessorTimeReadsUserAndSystemTicks checks that utime and stime, fields 14 and 15 of
// a stat line, are added and turned from USER_HZ ticks into microseconds.
func TestProcessorTimeReadsUserAndSystemTicks(t *testing.T) {
	line := "S 1 100 100 0 -1 4194560 2000 0 3 0 150 25 0 0 20 0 4 0 9000 1000000 300"
	cpu := processorTime(strings.Fields(line))
	if cpu == nil || *cpu != 1_750_000 {
		t.Fatalf("processorTime = %v, want 1750000", cpu)
	}
	if processorTime(strings.Fields("S 1 100")) != nil {
		t.Fatal("a short stat line has a processor time")
	}
}

// TestSwappedOutReadsVmSwap checks that the VmSwap line of a status file is read in bytes and
// that a status without one, as a kernel thread's, has none.
func TestSwappedOutReadsVmSwap(t *testing.T) {
	status := "Name:\tnode\nVmRSS:\t  51200 kB\nVmSwap:\t    1536 kB\nThreads:\t11\n"
	swapped := swappedOut(status)
	if swapped == nil || *swapped != 1536*1024 {
		t.Fatalf("swappedOut = %v, want %d", swapped, 1536*1024)
	}
	if swappedOut("Name:\tkthreadd\nThreads:\t1\n") != nil {
		t.Fatal("a status without VmSwap has swapped-out memory")
	}
}

// TestDRMUsageNamesEnginesByDevice checks that the engine times of a DRM fdinfo are named by
// device and engine, that the capacity lines and lines without nanoseconds are skipped, and
// that a file without a client ID reports no client.
func TestDRMUsageNamesEnginesByDevice(t *testing.T) {
	info := strings.Join([]string{
		"pos:\t0",
		"drm-driver:\tamdgpu",
		"drm-pdev:\t0000:03:00.0",
		"drm-client-id:\t42",
		"drm-engine-gfx:\t1500000 ns",
		"drm-engine-capacity-gfx:\t2",
		"drm-engine-compute:\t250000 ns",
		"drm-memory-vram:\t1024 KiB",
	}, "\n")
	client, engines := drmUsage(info)
	want := map[string]uint64{"0000:03:00.0/gfx": 1500000, "0000:03:00.0/compute": 250000}
	if client != "0000:03:00.0#42" || !reflect.DeepEqual(engines, want) {
		t.Fatalf("drmUsage = %q %v, want client 0000:03:00.0#42 and %v", client, engines, want)
	}
	client, engines = drmUsage("drm-driver:\ti915\ndrm-client-id:\t7\ndrm-engine-render:\t30 ns\n")
	if client != "i915#7" || !reflect.DeepEqual(engines, map[string]uint64{"i915/render": 30}) {
		t.Fatalf("drmUsage without a device = %q %v, want the driver as the device", client, engines)
	}
	if client, _ := drmUsage("pos:\t0\nflags:\t02\n"); client != "" {
		t.Fatalf("a file that is not a DRM client reports client %q", client)
	}
}
