package core

import "context"

// PortProcess describes one process table entry for process.listeningPorts.
type PortProcess struct {
	ProcessID       int64   `json:"processId"`
	ParentProcessID int64   `json:"parentProcessId"`
	StartTime       *uint64 `json:"startTime,omitempty"`
}

// ListeningSocket describes one raw listening TCP socket observed by the host.
type ListeningSocket struct {
	ProcessID int64  `json:"processId"`
	Address   string `json:"address"`
	Port      uint16 `json:"port"`
}

// ListeningPortsRequest asks Core to filter, deduplicate, and format TCP listeners
// owned by the process tree rooted at RootProcessID.
type ListeningPortsRequest struct {
	RootProcessID int64             `json:"rootProcessId"`
	Processes     []PortProcess     `json:"processes"`
	Sockets       []ListeningSocket `json:"sockets"`
	ExcludePorts  []uint16          `json:"excludePorts,omitempty"`
	Limit         *int              `json:"limit,omitempty"`
}

// ListeningPort describes one normalized, browser-ready listening TCP endpoint.
type ListeningPort struct {
	Port      uint16 `json:"port"`
	Address   string `json:"address"`
	Label     string `json:"label"`
	URL       string `json:"url"`
	ProcessID int64  `json:"processId"`
}

// ListeningPortsResponse holds Core's deduplicated listening ports for one run.
type ListeningPortsResponse struct {
	SchemaVersion uint32          `json:"schemaVersion"`
	Ports         []ListeningPort `json:"ports"`
	Truncated     bool            `json:"truncated"`
}

// ProcessListeningPorts filters candidate sockets to RootProcessID's live process tree,
// omits excluded ports, deduplicates dual-stack bindings, and formats labels and URLs.
func (c *Client) ProcessListeningPorts(ctx context.Context, request ListeningPortsRequest) (ListeningPortsResponse, error) {
	request.Processes = nonNil(request.Processes)
	request.Sockets = nonNil(request.Sockets)
	var response ListeningPortsResponse
	if err := c.Execute(ctx, "process.listeningPorts", request, &response); err != nil {
		return ListeningPortsResponse{}, err
	}
	response.Ports = nonNil(response.Ports)
	return response, nil
}
