package sysinfo

import (
	"fmt"
	"unsafe"

	"golang.org/x/sys/windows"
)

// The graphics kernel's statistics, which Task Manager's GPU columns show, are read through
// the D3DKMT functions of gdi32. x/sys/windows declares none of them, so their structures are
// laid out here as d3dkmthk.h declares them.
var (
	gdi32                  = windows.NewLazySystemDLL("gdi32.dll")
	d3dkmtEnumAdapters2    = gdi32.NewProc("D3DKMTEnumAdapters2")
	d3dkmtCloseAdapter     = gdi32.NewProc("D3DKMTCloseAdapter")
	d3dkmtQueryAdapterInfo = gdi32.NewProc("D3DKMTQueryAdapterInfo")
	d3dkmtQueryStatistics  = gdi32.NewProc("D3DKMTQueryStatistics")
)

// D3DKMT_QUERYSTATISTICS_TYPE values.
const (
	statisticsAdapter        = 0
	statisticsSegment        = 3
	statisticsProcessSegment = 4
	statisticsProcessNode    = 6
)

// adapterTypeQuery is KMTQAITYPE_ADAPTERTYPE, and softwareDevice its bit for an adapter that
// renders on the processor, as the Microsoft Basic Render Driver.
const (
	adapterTypeQuery = 15
	softwareDevice   = 1 << 2
)

// d3dkmtAdapterInfo is D3DKMT_ADAPTERINFO.
type d3dkmtAdapterInfo struct {
	handle  uint32
	luid    windows.LUID
	sources uint32
	precise int32
}

// d3dkmtEnumAdapters is D3DKMT_ENUMADAPTERS2.
type d3dkmtEnumAdapters struct {
	count    uint32
	adapters *d3dkmtAdapterInfo
}

// d3dkmtQueryAdapter is D3DKMT_QUERYADAPTERINFO.
type d3dkmtQueryAdapter struct {
	handle uint32
	kind   uint32
	data   unsafe.Pointer
	size   uint32
}

// d3dkmtStatistics is D3DKMT_QUERYSTATISTICS: the query, its result, then the segment or node
// the query is about.
type d3dkmtStatistics struct {
	kind    uint32
	luid    windows.LUID
	process windows.Handle
	result  [776]byte
	id      uint32
	_       uint32
}

// gpuAdapter is a hardware adapter with the facts the process queries need: which of its
// segments are dedicated memory and how many engines it has.
type gpuAdapter struct {
	luid      windows.LUID
	dedicated []uint32
	nodes     uint32
}

// openGPUAdapters lists the hardware adapters and returns a function that closes them. An
// adapter whose statistics cannot be read is left out; none are listed on a system without
// the functions.
func openGPUAdapters() ([]gpuAdapter, func()) {
	if d3dkmtEnumAdapters2.Find() != nil || d3dkmtQueryStatistics.Find() != nil {
		return nil, func() {}
	}
	var enum d3dkmtEnumAdapters
	if status, _, _ := d3dkmtEnumAdapters2.Call(uintptr(unsafe.Pointer(&enum))); status != 0 || enum.count == 0 {
		return nil, func() {}
	}
	infos := make([]d3dkmtAdapterInfo, enum.count)
	enum.adapters = &infos[0]
	if status, _, _ := d3dkmtEnumAdapters2.Call(uintptr(unsafe.Pointer(&enum))); status != 0 {
		return nil, func() {}
	}
	infos = infos[:min(int(enum.count), len(infos))]
	close := func() {
		for _, info := range infos {
			handle := info.handle
			_, _, _ = d3dkmtCloseAdapter.Call(uintptr(unsafe.Pointer(&handle)))
		}
	}
	adapters := make([]gpuAdapter, 0, len(infos))
	for _, info := range infos {
		if softwareAdapter(info.handle) {
			continue
		}
		if adapter, ok := readGPUAdapter(info.luid); ok {
			adapters = append(adapters, adapter)
		}
	}
	return adapters, close
}

// softwareAdapter says whether the adapter renders on the processor; an adapter whose type
// cannot be read is taken as hardware.
func softwareAdapter(handle uint32) bool {
	if d3dkmtQueryAdapterInfo.Find() != nil {
		return false
	}
	var flags uint32
	query := d3dkmtQueryAdapter{handle: handle, kind: adapterTypeQuery, data: unsafe.Pointer(&flags), size: uint32(unsafe.Sizeof(flags))}
	status, _, _ := d3dkmtQueryAdapterInfo.Call(uintptr(unsafe.Pointer(&query)))
	return status == 0 && flags&softwareDevice != 0
}

// readGPUAdapter reads an adapter's segments and engine count. A segment that is an aperture
// maps system memory, which the working set already counts, so only the others are kept.
func readGPUAdapter(luid windows.LUID) (gpuAdapter, bool) {
	adapter := gpuAdapter{luid: luid}
	query := d3dkmtStatistics{kind: statisticsAdapter, luid: luid}
	if !queryStatistics(&query) {
		return adapter, false
	}
	// D3DKMT_QUERYSTATISTICS_ADAPTER_INFORMATION starts with NbSegments and NodeCount.
	segments := resultUint32(&query, 0)
	adapter.nodes = resultUint32(&query, 4)
	for segment := range segments {
		query = d3dkmtStatistics{kind: statisticsSegment, luid: luid, id: segment}
		// D3DKMT_QUERYSTATISTICS_SEGMENT_INFORMATION has Aperture after three counters and the
		// memory statistics.
		if queryStatistics(&query) && resultUint32(&query, 40) == 0 {
			adapter.dedicated = append(adapter.dedicated, segment)
		}
	}
	return adapter, true
}

// processGPU reads what the process of handle holds in the adapters' dedicated memory and
// how long each of their engines ran its work, in microseconds. The memory is nil when no
// adapter answered for the process.
func processGPU(handle windows.Handle, adapters []gpuAdapter) (*uint64, []GPUEngine) {
	var dedicated uint64
	answered := false
	var engines []GPUEngine
	for _, adapter := range adapters {
		for _, segment := range adapter.dedicated {
			query := d3dkmtStatistics{kind: statisticsProcessSegment, luid: adapter.luid, process: handle, id: segment}
			if queryStatistics(&query) {
				// D3DKMT_QUERYSTATISTICS_PROCESS_SEGMENT_INFORMATION starts with BytesCommitted.
				dedicated += resultUint64(&query, 0)
				answered = true
			}
		}
		for node := range adapter.nodes {
			query := d3dkmtStatistics{kind: statisticsProcessNode, luid: adapter.luid, process: handle, id: node}
			if !queryStatistics(&query) {
				continue
			}
			answered = true
			// D3DKMT_QUERYSTATISTICS_PROCESS_NODE_INFORMATION starts with RunningTime, in
			// 100-nanosecond intervals.
			if running := resultUint64(&query, 0); running > 0 {
				name := fmt.Sprintf("%08x%08x/%d", uint32(adapter.luid.HighPart), adapter.luid.LowPart, node)
				engines = append(engines, GPUEngine{Name: name, BusyTime: running / 10})
			}
		}
	}
	if !answered {
		return nil, nil
	}
	return &dedicated, engines
}

func queryStatistics(query *d3dkmtStatistics) bool {
	status, _, _ := d3dkmtQueryStatistics.Call(uintptr(unsafe.Pointer(query)))
	return status == 0
}

func resultUint32(query *d3dkmtStatistics, offset int) uint32 {
	return *(*uint32)(unsafe.Pointer(&query.result[offset]))
}

func resultUint64(query *d3dkmtStatistics, offset int) uint64 {
	return *(*uint64)(unsafe.Pointer(&query.result[offset]))
}
