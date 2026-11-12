//go:build !windows

package pluginservice

import "context"

// sampleProcessTree reads the process table once with ps, which reports the CPU share and resident
// memory of every process, so the tree under pid can be summed from it.
func sampleProcessTree(ctx context.Context, pid int) (ProcessSample, bool) {
	output, err := psCommand(ctx)
	if err != nil {
		return ProcessSample{}, false
	}
	return parsePSTable(output, pid)
}

func processTable(ctx context.Context) ([]byte, error) { return psCommand(ctx) }

func treeMemory(output []byte, pid int) (uint64, bool) {
	sample, ok := parsePSTable(output, pid)
	return sample.MemoryBytes, ok
}
