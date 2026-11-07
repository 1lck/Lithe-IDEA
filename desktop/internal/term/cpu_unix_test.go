//go:build unix

package term

import (
	"syscall"
	"testing"
	"time"
)

// cpuTimer measures process CPU time, which stays meaningful when the machine
// is busy and wall-clock benchmark numbers are not.
type cpuTimer struct{ start time.Duration }

func cpuNow() time.Duration {
	var usage syscall.Rusage
	if syscall.Getrusage(syscall.RUSAGE_SELF, &usage) != nil {
		return 0
	}
	return time.Duration(usage.Utime.Nano() + usage.Stime.Nano())
}

func startCPU() cpuTimer { return cpuTimer{cpuNow()} }

// report adds cpu-ns/op, and cpu-MB/s when bytes per operation is known.
func (c cpuTimer) report(b *testing.B, bytesPerOp int) {
	used := cpuNow() - c.start
	if used <= 0 || b.N == 0 {
		return
	}
	b.ReportMetric(float64(used)/float64(b.N), "cpu-ns/op")
	if bytesPerOp > 0 {
		b.ReportMetric(float64(bytesPerOp)*float64(b.N)/used.Seconds()/1e6, "cpu-MB/s")
	}
}
