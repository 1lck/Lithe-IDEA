package sysinfo

/*
#cgo LDFLAGS: -framework IOKit -framework CoreFoundation

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/param.h>
#include <sys/resource.h>

typedef struct {
	int pid;
	int ppid;
	int responsible;
	unsigned long long start;
	unsigned long long footprint;
	// compressed is the compressed part of footprint; has_compressed is zero when the task's
	// memory could not be read, as for a process of another user.
	unsigned long long compressed;
	int has_compressed;
	// cpu is the user and system time in microseconds; has_cpu is zero when it was not read.
	unsigned long long cpu;
	int has_cpu;
	char name[2 * MAXCOMLEN + 1];
} lithe_process;

// responsibility_get_pid_responsible_for_pid is the libsystem function Activity Monitor uses
// to put XPC services under the app they work for. It is not declared in the SDK, so it is
// looked up once; without it no process has a responsible process. The mach time base the
// processor times are counted in is read at the same time.
typedef pid_t (*lithe_responsible_fn)(pid_t);
static lithe_responsible_fn lithe_responsible;
static mach_timebase_info_data_t lithe_timebase;
static pthread_once_t lithe_setup_once = PTHREAD_ONCE_INIT;

static void lithe_setup(void) {
	lithe_responsible = (lithe_responsible_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
	if (mach_timebase_info(&lithe_timebase) != KERN_SUCCESS || lithe_timebase.denom == 0) {
		lithe_timebase.numer = 0;
		lithe_timebase.denom = 1;
	}
}

static int lithe_process_count(void) {
	return proc_listallpids(NULL, 0);
}

// lithe_compressed reads the compressed memory of a task, which the physical footprint
// includes. It returns zero when the task cannot be read.
static int lithe_compressed(int pid, unsigned long long *compressed) {
	mach_port_t task;
	if (task_name_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) {
		return 0;
	}
	task_vm_info_data_t info;
	mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
	kern_return_t result = task_info(task, TASK_VM_INFO, (task_info_t)&info, &count);
	mach_port_deallocate(mach_task_self(), task);
	if (result != KERN_SUCCESS) {
		return 0;
	}
	*compressed = info.compressed;
	return 1;
}

// lithe_read_processes writes up to capacity rows and returns how many it wrote, or -1 when the
// process IDs cannot be listed. A process that exits while it is read is left out.
static int lithe_read_processes(lithe_process *rows, int capacity) {
	pthread_once(&lithe_setup_once, lithe_setup);
	int *pids = calloc((size_t)capacity, sizeof(int));
	if (pids == NULL) {
		return -1;
	}
	int count = proc_listallpids(pids, capacity * (int)sizeof(int));
	if (count < 0) {
		free(pids);
		return -1;
	}
	if (count > capacity) {
		count = capacity;
	}
	int written = 0;
	for (int i = 0; i < count; i++) {
		struct proc_bsdinfo info;
		if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != (int)sizeof(info)) {
			continue;
		}
		lithe_process *row = &rows[written++];
		memset(row, 0, sizeof(*row));
		row->pid = pids[i];
		row->ppid = (int)info.pbi_ppid;
		row->start = (unsigned long long)info.pbi_start_tvsec * 1000000ULL + (unsigned long long)info.pbi_start_tvusec;
		const char *name = info.pbi_name[0] != '\0' ? info.pbi_name : info.pbi_comm;
		strlcpy(row->name, name, sizeof(row->name));
		struct rusage_info_v4 usage;
		if (proc_pid_rusage(pids[i], RUSAGE_INFO_V4, (rusage_info_t *)&usage) == 0) {
			row->footprint = usage.ri_phys_footprint;
			if (lithe_timebase.numer != 0) {
				// Mach time units times numer over denom are nanoseconds. A long double keeps the
				// product of a long-running process from overflowing.
				long double ticks = (long double)usage.ri_user_time + (long double)usage.ri_system_time;
				row->cpu = (unsigned long long)(ticks * lithe_timebase.numer / lithe_timebase.denom / 1000.0L);
				row->has_cpu = 1;
			}
			row->has_compressed = lithe_compressed(pids[i], &row->compressed);
		}
		int responsible = lithe_responsible != NULL ? (int)lithe_responsible(pids[i]) : 0;
		row->responsible = responsible > 0 ? responsible : 0;
	}
	free(pids);
	return written;
}

typedef struct {
	int pid;
	unsigned long long accelerator;
	// busy is the GPU time of one client of the accelerator, in nanoseconds.
	unsigned long long busy;
} lithe_gpu_client;

// lithe_pid_wanted says whether pid is one of the count IDs in wanted.
static int lithe_pid_wanted(int pid, const int *wanted, int count) {
	for (int i = 0; i < count; i++) {
		if (wanted[i] == pid) {
			return 1;
		}
	}
	return 0;
}

// lithe_creator_pid reads the process that opened an accelerator client from its creator
// property, which reads "pid 123, name"; it returns -1 when there is none.
static int lithe_creator_pid(io_registry_entry_t client) {
	CFTypeRef creator = IORegistryEntryCreateCFProperty(client, CFSTR("IOUserClientCreator"), kCFAllocatorDefault, 0);
	int pid = -1;
	if (creator != NULL) {
		char text[128];
		if (CFGetTypeID(creator) == CFStringGetTypeID() &&
			CFStringGetCString((CFStringRef)creator, text, sizeof(text), kCFStringEncodingUTF8) &&
			sscanf(text, "pid %d", &pid) != 1) {
			pid = -1;
		}
		CFRelease(creator);
	}
	return pid;
}

// lithe_client_busy sums the GPU time an accelerator client reports in its AppUsage property,
// the counters Activity Monitor reads for its GPU column.
static unsigned long long lithe_client_busy(io_registry_entry_t client) {
	CFTypeRef usage = IORegistryEntryCreateCFProperty(client, CFSTR("AppUsage"), kCFAllocatorDefault, 0);
	unsigned long long busy = 0;
	if (usage != NULL) {
		if (CFGetTypeID(usage) == CFArrayGetTypeID()) {
			CFIndex count = CFArrayGetCount((CFArrayRef)usage);
			for (CFIndex i = 0; i < count; i++) {
				CFTypeRef item = CFArrayGetValueAtIndex((CFArrayRef)usage, i);
				if (CFGetTypeID(item) != CFDictionaryGetTypeID()) {
					continue;
				}
				CFTypeRef time = CFDictionaryGetValue((CFDictionaryRef)item, CFSTR("accumulatedGPUTime"));
				long long value = 0;
				if (time != NULL && CFGetTypeID(time) == CFNumberGetTypeID() &&
					CFNumberGetValue((CFNumberRef)time, kCFNumberSInt64Type, &value) && value > 0) {
					busy += (unsigned long long)value;
				}
			}
		}
		CFRelease(usage);
	}
	return busy;
}

// lithe_read_gpu writes the accelerator clients of the wanted processes, up to capacity rows,
// and returns how many there are, which may exceed capacity; -1 means no accelerator could be
// listed.
static int lithe_read_gpu(const int *wanted, int wanted_count, lithe_gpu_client *rows, int capacity) {
	io_iterator_t accelerators;
	if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) != KERN_SUCCESS) {
		return -1;
	}
	int found = 0;
	io_registry_entry_t accelerator;
	while ((accelerator = IOIteratorNext(accelerators)) != 0) {
		uint64_t id = 0;
		io_iterator_t clients;
		if (IORegistryEntryGetRegistryEntryID(accelerator, &id) == KERN_SUCCESS &&
			IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients) == KERN_SUCCESS) {
			io_registry_entry_t client;
			while ((client = IOIteratorNext(clients)) != 0) {
				int pid = lithe_creator_pid(client);
				if (pid > 0 && lithe_pid_wanted(pid, wanted, wanted_count)) {
					if (found < capacity) {
						rows[found].pid = pid;
						rows[found].accelerator = id;
						rows[found].busy = lithe_client_busy(client);
					}
					found++;
				}
				IOObjectRelease(client);
			}
			IOObjectRelease(clients);
		}
		IOObjectRelease(accelerator);
	}
	IOObjectRelease(accelerators);
	return found;
}
*/
import "C"

import (
	"errors"
	"fmt"
	"sort"
	"unsafe"
)

// processSlack is how many more rows than the system listed a moment before are made room
// for, for the processes that start between the two calls.
const processSlack = 64

func processes(options Options) ([]Process, error) {
	listed := int(C.lithe_process_count())
	if listed <= 0 {
		return nil, errors.New("sysinfo: the process IDs cannot be listed")
	}
	rows := make([]C.lithe_process, listed+processSlack)
	written := int(C.lithe_read_processes((*C.lithe_process)(unsafe.Pointer(&rows[0])), C.int(len(rows))))
	if written < 0 {
		return nil, errors.New("sysinfo: the process IDs cannot be listed")
	}
	engines := gpuEngines(options.GPU)
	table := make([]Process, written)
	for i, row := range rows[:written] {
		process := Process{
			PID:            int(row.pid),
			ParentPID:      int(row.ppid),
			ResponsiblePID: int(row.responsible),
			StartTime:      uint64(row.start),
			Name:           C.GoString(&row.name[0]),
			MemoryBytes:    uint64(row.footprint),
			GPUEngines:     engines[int(row.pid)],
		}
		if row.has_compressed != 0 {
			// The footprint holds the compressed memory; what is in memory is the rest.
			compressed := min(uint64(row.compressed), process.MemoryBytes)
			process.MemoryBytes -= compressed
			process.CompressedBytes = &compressed
		}
		if row.has_cpu != 0 {
			cpu := uint64(row.cpu)
			process.CPUTime = &cpu
		}
		table[i] = process
	}
	return table, nil
}

// gpuClientCapacity is how many accelerator clients the first read makes room for; a process
// holds one for every device it opened, so a few dozen processes rarely hold more.
const gpuClientCapacity = 256

// gpuEngines reads the GPU time of the wanted processes, one engine per accelerator, in
// microseconds. A process with no accelerator client, or every process when the accelerators
// cannot be listed, has none.
func gpuEngines(wanted map[int]bool) map[int][]GPUEngine {
	if len(wanted) == 0 {
		return nil
	}
	pids := make([]C.int, 0, len(wanted))
	for pid := range wanted {
		pids = append(pids, C.int(pid))
	}
	clients := make([]C.lithe_gpu_client, gpuClientCapacity)
	found := int(C.lithe_read_gpu(&pids[0], C.int(len(pids)), &clients[0], C.int(len(clients))))
	if found > len(clients) {
		// Clients opened between two reads are left out of the second.
		clients = make([]C.lithe_gpu_client, found+gpuClientCapacity)
		found = min(int(C.lithe_read_gpu(&pids[0], C.int(len(pids)), &clients[0], C.int(len(clients)))), len(clients))
	}
	if found <= 0 {
		return nil
	}
	busy := map[int]map[uint64]uint64{}
	for _, client := range clients[:found] {
		pid := int(client.pid)
		if busy[pid] == nil {
			busy[pid] = map[uint64]uint64{}
		}
		busy[pid][uint64(client.accelerator)] += uint64(client.busy)
	}
	engines := make(map[int][]GPUEngine, len(busy))
	for pid, accelerators := range busy {
		list := make([]GPUEngine, 0, len(accelerators))
		for id, nanoseconds := range accelerators {
			list = append(list, GPUEngine{Name: fmt.Sprintf("accelerator-%x", id), BusyTime: nanoseconds / 1000})
		}
		sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
		engines[pid] = list
	}
	return engines
}
