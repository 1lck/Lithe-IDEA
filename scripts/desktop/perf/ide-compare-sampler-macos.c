// Samples the memory, processor time, processes and windows of one running IDE instance, for
// scripts/desktop/perf/ide-compare.mjs. macOS only.
//
// The instance is found and summed the way Lithe's status bar memory readout does it
// (desktop/internal/sysinfo/process_darwin.go and processMemory.summarize in Lithe-core-rust), so
// every IDE is measured with the same rule:
//
// - the root is the first process whose executable is --exe and that started after --after;
// - a process belongs to the instance when its parent belongs to it (and did not start later, so
//   a reused parent ID is not followed), or when macOS holds the root responsible for it, as it does
//   for XPC services such as the WebKit processes of a web view;
// - memory is the physical footprint (ri_phys_footprint), the "Memory" column of Activity Monitor.
//   The resident size is printed next to it for reference.
//
// A main window is an on-screen, opaque, layer-0 window of an instance process at least
// --min-width by --min-height points, which leaves out splash screens and tooltips.
//
// Usage:
//   ide-compare-sampler --exe PATH --after MICROSECONDS --interval MS --duration SECONDS
//                       [--fast-interval MS --fast-until SECONDS] [--find-timeout SECONDS]
//                       [--min-width POINTS] [--min-height POINTS]
//
// --fast-interval samples more often until --fast-until seconds after --after, so the time the main
// window appears is read to that resolution.
//
// Prints one JSON object per line: a "root" line once the root is found, then one "sample" line per
// interval with the instance totals and its processes, and an "end" line. Exits 2 when the root does
// not appear within --find-timeout, 0 otherwise (also when the root exits before --duration).
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <libproc.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <unistd.h>

#define MAX_PROCESSES 8192

typedef struct {
    int pid;
    int ppid;
    int responsible;
    unsigned long long start;
    unsigned long long footprint;
    unsigned long long resident;
    unsigned long long cpu;
    int threads;
    int member;
    char name[2 * MAXCOMLEN + 1];
} row_t;

typedef pid_t (*responsible_fn)(pid_t);
static responsible_fn responsible_for;
static mach_timebase_info_data_t timebase;
static row_t rows[MAX_PROCESSES];
static int pids[MAX_PROCESSES];

static unsigned long long now_us(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (unsigned long long)tv.tv_sec * 1000000ULL + (unsigned long long)tv.tv_usec;
}

// read_rows fills rows with every process this user can read and returns how many.
static int read_rows(void) {
    int count = proc_listallpids(pids, (int)sizeof(pids));
    if (count < 0) {
        return 0;
    }
    if (count > MAX_PROCESSES) {
        count = MAX_PROCESSES;
    }
    int written = 0;
    for (int i = 0; i < count; i++) {
        struct proc_bsdinfo info;
        if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != (int)sizeof(info)) {
            continue;
        }
        row_t *row = &rows[written++];
        memset(row, 0, sizeof(*row));
        row->pid = pids[i];
        row->ppid = (int)info.pbi_ppid;
        row->start = (unsigned long long)info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
        strlcpy(row->name, info.pbi_name[0] != '\0' ? info.pbi_name : info.pbi_comm, sizeof(row->name));
        struct rusage_info_v4 usage;
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V4, (rusage_info_t *)&usage) == 0) {
            row->footprint = usage.ri_phys_footprint;
            row->resident = usage.ri_resident_size;
            long double ticks = (long double)usage.ri_user_time + (long double)usage.ri_system_time;
            row->cpu = (unsigned long long)(ticks * timebase.numer / timebase.denom / 1000.0L);
        }
        struct proc_taskinfo task;
        if (proc_pidinfo(pids[i], PROC_PIDTASKINFO, 0, &task, sizeof(task)) == (int)sizeof(task)) {
            row->threads = task.pti_threadnum;
        }
        int responsible = responsible_for != NULL ? (int)responsible_for(pids[i]) : 0;
        row->responsible = responsible > 0 ? responsible : 0;
    }
    return written;
}

static row_t *find_row(int count, int pid) {
    for (int i = 0; i < count; i++) {
        if (rows[i].pid == pid) {
            return &rows[i];
        }
    }
    return NULL;
}

// mark_members marks the root, its process tree, and the processes macOS holds the root responsible
// for together with their trees.
static void mark_members(int count, int root) {
    for (int i = 0; i < count; i++) {
        rows[i].member = rows[i].pid == root;
    }
    int changed = 1;
    while (changed) {
        changed = 0;
        for (int i = 0; i < count; i++) {
            row_t *row = &rows[i];
            if (row->member) {
                continue;
            }
            row_t *parent = find_row(count, row->ppid);
            int by_parent = parent != NULL && parent->member && parent->start <= row->start;
            int by_responsibility = row->responsible == root && row->pid != root;
            if (by_parent || by_responsibility) {
                row->member = 1;
                changed = 1;
            }
        }
    }
}

static int is_member_pid(int count, int pid) {
    row_t *row = find_row(count, pid);
    return row != NULL && row->member;
}

// window_json holds the instance's on-screen layer-0 windows of the last count_main_windows, as
// JSON objects with their title and size, so a launch stuck at a dialog can be recognised.
static char window_json[16384];

static void append(char *buffer, size_t size, const char *text) {
    size_t used = strlen(buffer);
    if (used + 1 < size) {
        strlcpy(buffer + used, text, size - used);
    }
}

static void append_json_string(char *buffer, size_t size, const char *text) {
    char escaped[8];
    append(buffer, size, "\"");
    for (const unsigned char *c = (const unsigned char *)text; *c; c++) {
        if (*c == '"' || *c == '\\') {
            snprintf(escaped, sizeof(escaped), "\\%c", *c);
        } else if (*c < 0x20) {
            snprintf(escaped, sizeof(escaped), "\\u%04x", *c);
        } else {
            escaped[0] = (char)*c;
            escaped[1] = '\0';
        }
        append(buffer, size, escaped);
    }
    append(buffer, size, "\"");
}

// count_main_windows counts the instance's on-screen main windows and fills window_json.
static int count_main_windows(int count, double min_width, double min_height) {
    window_json[0] = '\0';
    CFArrayRef windows = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (windows == NULL) {
        return 0;
    }
    int found = 0, listed = 0;
    CFIndex total = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < total; i++) {
        CFDictionaryRef window = CFArrayGetValueAtIndex(windows, i);
        int pid = 0, layer = -1;
        double alpha = 0;
        CFNumberRef number = CFDictionaryGetValue(window, kCGWindowOwnerPID);
        if (number == NULL || !CFNumberGetValue(number, kCFNumberIntType, &pid) || !is_member_pid(count, pid)) {
            continue;
        }
        number = CFDictionaryGetValue(window, kCGWindowLayer);
        if (number == NULL || !CFNumberGetValue(number, kCFNumberIntType, &layer) || layer != 0) {
            continue;
        }
        number = CFDictionaryGetValue(window, kCGWindowAlpha);
        if (number == NULL || !CFNumberGetValue(number, kCFNumberDoubleType, &alpha) || alpha <= 0) {
            continue;
        }
        CGRect bounds;
        CFDictionaryRef boundsDict = CFDictionaryGetValue(window, kCGWindowBounds);
        if (boundsDict == NULL || !CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds)) {
            continue;
        }
        if (bounds.size.width >= min_width && bounds.size.height >= min_height) {
            found++;
        }
        // Titles need the screen recording permission; without it the title is empty.
        char title[512] = "";
        CFStringRef name = CFDictionaryGetValue(window, kCGWindowName);
        if (name != NULL) {
            CFStringGetCString(name, title, sizeof(title), kCFStringEncodingUTF8);
        }
        char size_text[64];
        snprintf(size_text, sizeof(size_text), ",\"w\":%.0f,\"h\":%.0f}", bounds.size.width, bounds.size.height);
        append(window_json, sizeof(window_json), listed++ ? ",{\"title\":" : "{\"title\":");
        append_json_string(window_json, sizeof(window_json), title);
        append(window_json, sizeof(window_json), size_text);
    }
    CFRelease(windows);
    return found;
}

static void print_json_string(const char *text) {
    putchar('"');
    for (const unsigned char *c = (const unsigned char *)text; *c; c++) {
        if (*c == '"' || *c == '\\') {
            printf("\\%c", *c);
        } else if (*c < 0x20) {
            printf("\\u%04x", *c);
        } else {
            putchar(*c);
        }
    }
    putchar('"');
}

static void usage(void) {
    fprintf(stderr, "usage: ide-compare-sampler --exe PATH --after MICROSECONDS --interval MS --duration SECONDS\n"
                    "                           [--fast-interval MS --fast-until SECONDS] [--find-timeout SECONDS]\n"
                    "                           [--min-width POINTS] [--min-height POINTS]\n");
    exit(64);
}

int main(int argc, char **argv) {
    const char *exe = NULL;
    unsigned long long after = 0;
    long interval_ms = 500, fast_interval_ms = 0, find_timeout_s = 30;
    double duration_s = 60, fast_until_s = 0, min_width = 800, min_height = 500;
    for (int i = 1; i < argc; i++) {
        if (i + 1 >= argc) {
            usage();
        }
        if (strcmp(argv[i], "--exe") == 0) {
            exe = argv[++i];
        } else if (strcmp(argv[i], "--after") == 0) {
            after = strtoull(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--interval") == 0) {
            interval_ms = strtol(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--duration") == 0) {
            duration_s = strtod(argv[++i], NULL);
        } else if (strcmp(argv[i], "--fast-interval") == 0) {
            fast_interval_ms = strtol(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--fast-until") == 0) {
            fast_until_s = strtod(argv[++i], NULL);
        } else if (strcmp(argv[i], "--find-timeout") == 0) {
            find_timeout_s = strtol(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--min-width") == 0) {
            min_width = strtod(argv[++i], NULL);
        } else if (strcmp(argv[i], "--min-height") == 0) {
            min_height = strtod(argv[++i], NULL);
        } else {
            usage();
        }
    }
    if (exe == NULL || after == 0 || interval_ms <= 0) {
        usage();
    }
    char wanted[PATH_MAX];
    if (realpath(exe, wanted) == NULL) {
        strlcpy(wanted, exe, sizeof(wanted));
    }
    responsible_for = (responsible_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) {
        timebase.numer = 0;
        timebase.denom = 1;
    }

    // Find the root: the earliest process of the executable that started after --after.
    int root = 0;
    unsigned long long root_start = 0;
    while (root == 0) {
        int count = read_rows();
        for (int i = 0; i < count; i++) {
            if (rows[i].start < after) {
                continue;
            }
            char path[PROC_PIDPATHINFO_MAXSIZE];
            if (proc_pidpath(rows[i].pid, path, sizeof(path)) <= 0 || strcmp(path, wanted) != 0) {
                continue;
            }
            if (root == 0 || rows[i].start < root_start) {
                root = rows[i].pid;
                root_start = rows[i].start;
            }
        }
        if (root == 0) {
            if (now_us() - after > (unsigned long long)find_timeout_s * 1000000ULL) {
                printf("{\"type\":\"error\",\"message\":\"root process not found\"}\n");
                return 2;
            }
            usleep(20000);
        }
    }
    printf("{\"type\":\"root\",\"pid\":%d,\"startMs\":%.1f}\n", root, (double)(root_start - after) / 1000.0);
    fflush(stdout);

    unsigned long long deadline = after + (unsigned long long)(duration_s * 1000000.0);
    unsigned long long next = now_us();
    int exited = 0;
    while (now_us() < deadline) {
        int count = read_rows();
        unsigned long long t = now_us();
        if (find_row(count, root) == NULL) {
            exited = 1;
            break;
        }
        mark_members(count, root);
        int windows = count_main_windows(count, min_width, min_height);
        unsigned long long footprint = 0, resident = 0, cpu = 0;
        int processes = 0, threads = 0;
        for (int i = 0; i < count; i++) {
            if (!rows[i].member) {
                continue;
            }
            footprint += rows[i].footprint;
            resident += rows[i].resident;
            cpu += rows[i].cpu;
            threads += rows[i].threads;
            processes++;
        }
        printf("{\"type\":\"sample\",\"tMs\":%.1f,\"footprint\":%llu,\"resident\":%llu,\"cpuUs\":%llu,"
               "\"processes\":%d,\"threads\":%d,\"windows\":%d,\"windowList\":[%s],\"list\":[",
               (double)(t - after) / 1000.0, footprint, resident, cpu, processes, threads, windows, window_json);
        int first = 1;
        for (int i = 0; i < count; i++) {
            if (!rows[i].member) {
                continue;
            }
            printf("%s{\"pid\":%d,\"ppid\":%d,\"responsible\":%d,\"name\":", first ? "" : ",", rows[i].pid,
                   rows[i].ppid, rows[i].responsible);
            print_json_string(rows[i].name);
            printf(",\"footprint\":%llu,\"resident\":%llu,\"cpuUs\":%llu,\"threads\":%d}", rows[i].footprint,
                   rows[i].resident, rows[i].cpu, rows[i].threads);
            first = 0;
        }
        printf("]}\n");
        fflush(stdout);
        int fast = fast_interval_ms > 0 && (double)(t - after) < fast_until_s * 1000000.0;
        next += (unsigned long long)(fast ? fast_interval_ms : interval_ms) * 1000ULL;
        unsigned long long current = now_us();
        if (next > current) {
            usleep((useconds_t)(next - current));
        } else {
            next = current;
        }
    }
    printf("{\"type\":\"end\",\"rootExited\":%s}\n", exited ? "true" : "false");
    return 0;
}
