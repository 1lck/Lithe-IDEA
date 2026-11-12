//go:build !darwin && !linux && !windows

package sysinfo

import "runtime"

var osName = runtime.GOOS

// Version is empty: this system's version is not read.
func Version() string { return "" }

func residentBytes() uint64 { return 0 }

func diskFree(string) uint64 { return 0 }
