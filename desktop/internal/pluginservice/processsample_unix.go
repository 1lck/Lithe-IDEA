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
