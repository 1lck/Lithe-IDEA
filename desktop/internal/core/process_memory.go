package core

import "context"

// MemoryProcess is one row of the process table the client read for processMemory.summarize.
type MemoryProcess struct {
	ProcessID       int64 `json:"processId"`
	ParentProcessID int64 `json:"parentProcessId"`
	// ResponsibleProcessID is the process the system holds responsible for this one, nil
	// where the system has no such notion.
	ResponsibleProcessID *int64 `json:"responsibleProcessId,omitempty"`
	// StartTime is when the process started, in microseconds since 1970, nil when it was not
	// read. Core ignores a parent link to a process that started later.
	StartTime *uint64 `json:"startTime,omitempty"`
	Name      string  `json:"name"`
	// Bytes is what the process has in memory.
	Bytes uint64 `json:"bytes"`
	// CompressedBytes is what the system compressed or wrote out to disk, which Bytes does not
	// include, nil when it was not read.
	CompressedBytes *uint64 `json:"compressedBytes,omitempty"`
	// GPUMemoryBytes is graphics memory charged to the process that Bytes does not hold, such as
	// dedicated video memory on Windows, nil where it was not read or Bytes holds it.
	GPUMemoryBytes *uint64 `json:"gpuMemoryBytes,omitempty"`
	// CPUTime is the processor time the process used since it started, user and system, in
	// microseconds, nil when it was not read.
	CPUTime *uint64 `json:"cpuTime,omitempty"`
	// GPUEngines is the busy time of every graphics engine the process used, empty when it used
	// none or they were not read.
	GPUEngines []GPUEngineTime `json:"gpuEngines,omitempty"`
}

// GPUEngineTime is the time one graphics engine was busy with a process's work. Engine names the
// same engine in every process and every table; times of one name add up.
type GPUEngineTime struct {
	Engine string `json:"engine"`
	// BusyTime is in microseconds.
	BusyTime uint64 `json:"busyTime"`
}

// MemoryRole kinds: what the client started a process for.
const (
	MemoryRoleLanguageServer = "languageServer"
	MemoryRolePluginService  = "pluginService"
)

// MemoryRole names a process the client started for a role. An empty Name shows the
// process name.
type MemoryRole struct {
	ProcessID int64  `json:"processId"`
	Kind      string `json:"kind"`
	Name      string `json:"name"`
}

// MemoryRequest is the process table of one moment and the roles of the processes the
// client started. HostProcessID must be one of Processes. A nil EntryLimit takes Core's
// default; it is capped at 200.
type MemoryRequest struct {
	HostProcessID int64           `json:"hostProcessId"`
	Processes     []MemoryProcess `json:"processes"`
	Roles         []MemoryRole    `json:"roles,omitempty"`
	EntryLimit    *int            `json:"entryLimit,omitempty"`
	// SampledAt is when the table was read, in microseconds of a clock that only moves forward.
	// Without it the summary has no percentages and no baseline.
	SampledAt *uint64 `json:"sampledAt,omitempty"`
	// Previous is the Baseline of the previous summary.
	Previous *MemoryBaseline `json:"previous,omitempty"`
	// LogicalProcessors, when set, makes a processor percentage a share of that many processors,
	// as the Windows Task Manager shows it; otherwise 100 is one processor busy. It must be at
	// least 1.
	LogicalProcessors *int `json:"logicalProcessors,omitempty"`
}

// MemoryBaseline holds the use counters of the instance's processes at one moment, which the
// next request sends back so Core can measure the use in between.
type MemoryBaseline struct {
	SampledAt uint64            `json:"sampledAt"`
	Processes []BaselineProcess `json:"processes"`
}

// BaselineProcess is the use counters of one process in a baseline.
type BaselineProcess struct {
	ProcessID  int64           `json:"processId"`
	StartTime  *uint64         `json:"startTime,omitempty"`
	CPUTime    *uint64         `json:"cpuTime,omitempty"`
	GPUEngines []GPUEngineTime `json:"gpuEngines,omitempty"`
}

// Memory kinds: the part of the instance a process counts in, in the order the summary
// lists its categories.
const (
	MemoryHost           = "host"
	MemoryLanguageServer = "languageServer"
	MemoryPluginService  = "pluginService"
	MemorySystemHelper   = "systemHelper"
	MemoryChildProcess   = "childProcess"
)

// MemoryUsage is what a group of processes has beyond its memory in memory. Each figure is on
// the summary, every category and every entry, or on none of them: the byte sums when a process
// of the instance reported them, the percentages once a process can be compared with the
// previous baseline.
type MemoryUsage struct {
	// CompressedBytes is what the system compressed or wrote out to disk.
	CompressedBytes *uint64 `json:"compressedBytes,omitempty"`
	// GPUMemoryBytes is graphics memory the bytes in memory do not hold.
	GPUMemoryBytes *uint64 `json:"gpuMemoryBytes,omitempty"`
	// CPUPercent is the processor use since the previous table, rounded to a tenth.
	CPUPercent *float64 `json:"cpuPercent,omitempty"`
	// GPUPercent is the use of the busiest graphics engine since the previous table, rounded to
	// a tenth and at most 100.
	GPUPercent *float64 `json:"gpuPercent,omitempty"`
}

// MemoryCategory is the sum of one part.
type MemoryCategory struct {
	Kind         string `json:"kind"`
	Bytes        uint64 `json:"bytes"`
	ProcessCount int    `json:"processCount"`
	MemoryUsage
}

// MemoryEntry is one process of the instance other than the host, with the processes Core
// counts under it.
type MemoryEntry struct {
	Kind         string `json:"kind"`
	Name         string `json:"name"`
	ProcessID    int64  `json:"processId"`
	Bytes        uint64 `json:"bytes"`
	ProcessCount int    `json:"processCount"`
	MemoryUsage
}

// MemoryOmitted is the count and sum of the entries past the limit.
type MemoryOmitted struct {
	Count int    `json:"count"`
	Bytes uint64 `json:"bytes"`
}

// MemorySummary is Core's account of what the instance holds: the total, every part in a
// fixed order with the empty ones included, and the largest entries.
type MemorySummary struct {
	TotalBytes uint64 `json:"totalBytes"`
	MemoryUsage
	Categories []MemoryCategory `json:"categories"`
	Entries    []MemoryEntry    `json:"entries"`
	Omitted    MemoryOmitted    `json:"omitted"`
	// Baseline is what to send as Previous with the next table, nil when the request had no
	// SampledAt.
	Baseline *MemoryBaseline `json:"baseline,omitempty"`
}

// SummarizeProcessMemory has Core attribute every process of the table to the instance or
// leave it out, and sum what each part holds.
func (c *Client) SummarizeProcessMemory(ctx context.Context, request MemoryRequest) (MemorySummary, error) {
	request.Processes = nonNil(request.Processes)
	var summary MemorySummary
	if err := c.Execute(ctx, "processMemory.summarize", request, &summary); err != nil {
		return MemorySummary{}, err
	}
	summary.Categories = nonNil(summary.Categories)
	summary.Entries = nonNil(summary.Entries)
	return summary, nil
}
