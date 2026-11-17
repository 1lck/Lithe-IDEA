//go:build windows

package pluginservice

import (
	"context"
	"os"
	"testing"
	"time"
)

// The sampler reads the process table in this process, so the run window starts no PowerShell, and
// with it no console window, every sampling interval.
func TestSampleProcessTreeReadsTheCurrentProcessFromTheWin32Table(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	first, ok := SampleProcessTree(ctx, os.Getpid())
	if !ok || first.MemoryBytes == 0 {
		t.Fatalf("first sample = %+v, %t; want the test process with its memory", first, ok)
	}
	second, ok := SampleProcessTree(ctx, os.Getpid())
	if !ok || second.MemoryBytes == 0 || second.CPUPercent < 0 {
		t.Fatalf("second sample = %+v, %t; want memory and a CPU share that is not negative", second, ok)
	}
}
