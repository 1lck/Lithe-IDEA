package sysinfo

/*
#include <dlfcn.h>
#include <libproc.h>
#include <pthread.h>
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
	char name[2 * MAXCOMLEN + 1];
} lithe_process;

// responsibility_get_pid_responsible_for_pid is the libsystem function Activity Monitor uses
// to put XPC services under the app they work for. It is not declared in the SDK, so it is
// looked up once; without it no process has a responsible process.
typedef pid_t (*lithe_responsible_fn)(pid_t);
static lithe_responsible_fn lithe_responsible;
static pthread_once_t lithe_responsible_once = PTHREAD_ONCE_INIT;

static void lithe_find_responsible(void) {
	lithe_responsible = (lithe_responsible_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
}

static int lithe_process_count(void) {
	return proc_listallpids(NULL, 0);
}

// lithe_read_processes writes up to capacity rows and returns how many it wrote, or -1 when the
// process IDs cannot be listed. A process that exits while it is read is left out.
static int lithe_read_processes(lithe_process *rows, int capacity) {
	pthread_once(&lithe_responsible_once, lithe_find_responsible);
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
		row->pid = pids[i];
		row->ppid = (int)info.pbi_ppid;
		row->start = (unsigned long long)info.pbi_start_tvsec * 1000000ULL + (unsigned long long)info.pbi_start_tvusec;
		const char *name = info.pbi_name[0] != '\0' ? info.pbi_name : info.pbi_comm;
		strlcpy(row->name, name, sizeof(row->name));
		struct rusage_info_v4 usage;
		row->footprint = proc_pid_rusage(pids[i], RUSAGE_INFO_V4, (rusage_info_t *)&usage) == 0 ? usage.ri_phys_footprint : 0;
		int responsible = lithe_responsible != NULL ? (int)lithe_responsible(pids[i]) : 0;
		row->responsible = responsible > 0 ? responsible : 0;
	}
	free(pids);
	return written;
}
*/
import "C"

import (
	"errors"
	"unsafe"
)

// processSlack is how many more rows than the system listed a moment before are made room
// for, for the processes that start between the two calls.
const processSlack = 64

func processes() ([]Process, error) {
	listed := int(C.lithe_process_count())
	if listed <= 0 {
		return nil, errors.New("sysinfo: the process IDs cannot be listed")
	}
	rows := make([]C.lithe_process, listed+processSlack)
	written := int(C.lithe_read_processes((*C.lithe_process)(unsafe.Pointer(&rows[0])), C.int(len(rows))))
	if written < 0 {
		return nil, errors.New("sysinfo: the process IDs cannot be listed")
	}
	table := make([]Process, written)
	for i, row := range rows[:written] {
		table[i] = Process{
			PID:            int(row.pid),
			ParentPID:      int(row.ppid),
			ResponsiblePID: int(row.responsible),
			StartTime:      uint64(row.start),
			Name:           C.GoString(&row.name[0]),
			MemoryBytes:    uint64(row.footprint),
		}
	}
	return table, nil
}
