package sysinfo

/*
#include <mach/mach.h>

static unsigned long long resident_bytes(void) {
	struct mach_task_basic_info info;
	mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
	if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
		return 0;
	}
	return info.resident_size;
}
*/
import "C"

import "golang.org/x/sys/unix"

const osName = "macOS"

// Version is the system's version the way Foundation's operatingSystemVersionString writes
// it, which is what the macOS client records.
func Version() string {
	version, err := unix.Sysctl("kern.osproductversion")
	if err != nil || version == "" {
		return ""
	}
	if build, err := unix.Sysctl("kern.osversion"); err == nil && build != "" {
		return "Version " + version + " (Build " + build + ")"
	}
	return "Version " + version
}

func residentBytes() uint64 { return uint64(C.resident_bytes()) }

func diskFree(volume string) uint64 {
	var stat unix.Statfs_t
	if volume == "" || unix.Statfs(volume, &stat) != nil {
		return 0
	}
	return stat.Bavail * uint64(stat.Bsize)
}
