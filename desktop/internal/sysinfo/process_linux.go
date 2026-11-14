package sysinfo

import (
	"bufio"
	"os"
	"sort"
	"strconv"
	"strings"
)

// userHz is the unit of the processor times in /proc/pid/stat. The kernel reports them in
// USER_HZ, which is 100 on every architecture Lithe is built for.
const userHz = 100

// processes reads /proc. Linux gives an orphan to init or a subreaper, so the parent IDs are
// never stale and the start time is not read.
func processes(options Options) ([]Process, error) {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	page := uint64(os.Getpagesize())
	table := make([]Process, 0, len(entries))
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid <= 0 {
			continue
		}
		if row, ok := readProcess(pid, page); ok {
			if options.GPU[pid] {
				row.GPUEngines = drmEngines(pid)
			}
			table = append(table, row)
		}
	}
	return table, nil
}

// readProcess reads the parent, name and processor time from /proc/pid/stat, the memory
// from /proc/pid/statm and the swapped-out memory from /proc/pid/status; false when the
// process exited while it was read.
func readProcess(pid int, page uint64) (Process, bool) {
	dir := "/proc/" + strconv.Itoa(pid) + "/"
	stat, err := os.ReadFile(dir + "stat")
	if err != nil {
		return Process{}, false
	}
	// The name is in parentheses and may itself hold spaces and parentheses, so the fields
	// after it start at the last closing one: the state, then the parent ID.
	text := string(stat)
	open, close := strings.IndexByte(text, '('), strings.LastIndexByte(text, ')')
	if open < 0 || close < open {
		return Process{}, false
	}
	fields := strings.Fields(text[close+1:])
	if len(fields) < 2 {
		return Process{}, false
	}
	parent, err := strconv.Atoi(fields[1])
	if err != nil {
		return Process{}, false
	}
	row := Process{PID: pid, ParentPID: parent, Name: text[open+1 : close], CPUTime: processorTime(fields)}
	if statm, err := os.ReadFile(dir + "statm"); err == nil {
		row.MemoryBytes = privatePages(string(statm)) * page
	}
	if status, err := os.ReadFile(dir + "status"); err == nil {
		row.CompressedBytes = swappedOut(string(status))
	}
	return row, true
}

// processorTime is the user and system time of the stat fields after the name, in
// microseconds; nil when the fields do not hold them.
func processorTime(fields []string) *uint64 {
	// utime and stime are fields 14 and 15 of the line; the fields here start at the third.
	if len(fields) < 13 {
		return nil
	}
	user, err := strconv.ParseUint(fields[11], 10, 64)
	if err != nil {
		return nil
	}
	system, err := strconv.ParseUint(fields[12], 10, 64)
	if err != nil {
		return nil
	}
	total := (user + system) * (1_000_000 / userHz)
	return &total
}

// swappedOut is the VmSwap line of a status file in bytes, nil when there is none, as for a
// kernel thread.
func swappedOut(status string) *uint64 {
	for line := range strings.SplitSeq(status, "\n") {
		value, ok := strings.CutPrefix(line, "VmSwap:")
		if !ok {
			continue
		}
		fields := strings.Fields(value)
		if len(fields) != 2 || fields[1] != "kB" {
			return nil
		}
		kilobytes, err := strconv.ParseUint(fields[0], 10, 64)
		if err != nil {
			return nil
		}
		bytes := kilobytes * 1024
		return &bytes
	}
	return nil
}

// privatePages is the resident pages of a statm line less its shared ones.
func privatePages(statm string) uint64 {
	fields := strings.Fields(statm)
	if len(fields) < 3 {
		return 0
	}
	resident, err := strconv.ParseUint(fields[1], 10, 64)
	if err != nil {
		return 0
	}
	shared, err := strconv.ParseUint(fields[2], 10, 64)
	if err != nil || shared > resident {
		return 0
	}
	return resident - shared
}

// drmEngines reads the GPU time of a process from the fdinfo of its open DRM files, which
// the kernel's drm-usage-stats give per engine, and names each engine by its device. Files
// of one DRM client, as a duplicated descriptor, count once.
func drmEngines(pid int) []GPUEngine {
	dir := "/proc/" + strconv.Itoa(pid) + "/"
	descriptors, err := os.ReadDir(dir + "fd")
	if err != nil {
		return nil
	}
	clients := map[string]bool{}
	busy := map[string]uint64{}
	for _, descriptor := range descriptors {
		target, err := os.Readlink(dir + "fd/" + descriptor.Name())
		if err != nil || !strings.HasPrefix(target, "/dev/dri/") {
			continue
		}
		info, err := os.ReadFile(dir + "fdinfo/" + descriptor.Name())
		if err != nil {
			continue
		}
		client, engines := drmUsage(string(info))
		if client == "" || clients[client] {
			continue
		}
		clients[client] = true
		for name, nanoseconds := range engines {
			busy[name] += nanoseconds
		}
	}
	if len(busy) == 0 {
		return nil
	}
	engines := make([]GPUEngine, 0, len(busy))
	for name, nanoseconds := range busy {
		engines = append(engines, GPUEngine{Name: name, BusyTime: nanoseconds / 1000})
	}
	sort.Slice(engines, func(i, j int) bool { return engines[i].Name < engines[j].Name })
	return engines
}

// drmUsage parses one DRM fdinfo: the client, as its device and ID, and the nanoseconds of
// every engine named by device and engine. The client is empty when the file reports no
// client ID.
func drmUsage(info string) (string, map[string]uint64) {
	var driver, device, id string
	times := map[string]uint64{}
	scanner := bufio.NewScanner(strings.NewReader(info))
	for scanner.Scan() {
		key, value, ok := strings.Cut(scanner.Text(), ":")
		if !ok {
			continue
		}
		value = strings.TrimSpace(value)
		switch {
		case key == "drm-driver":
			driver = value
		case key == "drm-pdev":
			device = value
		case key == "drm-client-id":
			id = value
		case strings.HasPrefix(key, "drm-engine-") && !strings.HasPrefix(key, "drm-engine-capacity-"):
			number, ok := strings.CutSuffix(value, " ns")
			if !ok {
				continue
			}
			nanoseconds, err := strconv.ParseUint(strings.TrimSpace(number), 10, 64)
			if err != nil {
				continue
			}
			times[strings.TrimPrefix(key, "drm-engine-")] = nanoseconds
		}
	}
	if id == "" {
		return "", nil
	}
	if device == "" {
		device = driver
	}
	engines := make(map[string]uint64, len(times))
	for name, nanoseconds := range times {
		engines[device+"/"+name] = nanoseconds
	}
	return device + "#" + id, engines
}
