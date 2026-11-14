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
	Bytes     uint64  `json:"bytes"`
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

// MemoryCategory is the sum of one part.
type MemoryCategory struct {
	Kind         string `json:"kind"`
	Bytes        uint64 `json:"bytes"`
	ProcessCount int    `json:"processCount"`
}

// MemoryEntry is one process of the instance other than the host, with the processes Core
// counts under it.
type MemoryEntry struct {
	Kind         string `json:"kind"`
	Name         string `json:"name"`
	ProcessID    int64  `json:"processId"`
	Bytes        uint64 `json:"bytes"`
	ProcessCount int    `json:"processCount"`
}

// MemoryOmitted is the count and sum of the entries past the limit.
type MemoryOmitted struct {
	Count int    `json:"count"`
	Bytes uint64 `json:"bytes"`
}

// MemorySummary is Core's account of what the instance holds: the total, every part in a
// fixed order with the empty ones included, and the largest entries.
type MemorySummary struct {
	TotalBytes uint64           `json:"totalBytes"`
	Categories []MemoryCategory `json:"categories"`
	Entries    []MemoryEntry    `json:"entries"`
	Omitted    MemoryOmitted    `json:"omitted"`
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
