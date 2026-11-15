//go:build !unix

package term

import "testing"

type cpuTimer struct{}

func startCPU() cpuTimer                { return cpuTimer{} }
func (cpuTimer) report(*testing.B, int) {}
