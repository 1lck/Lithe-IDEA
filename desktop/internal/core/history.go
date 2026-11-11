package core

import "context"

// Local history: Core stores versioned snapshots of workspace files under a
// host-chosen storage root and decides, per editing event, which snapshots are
// taken (shared/contracts/rust-core-api.md, history.*).

// HistoryEntry is one stored snapshot of a file.
type HistoryEntry struct {
	ID           string `json:"id"`
	Timestamp    int64  `json:"timestamp"`
	RelativePath string `json:"relativePath"`
	Reason       string `json:"reason"`
	ContentPath  string `json:"contentPath"`
	ByteCount    int    `json:"byteCount"`
	Label        string `json:"label,omitempty"`
}

// HistorySnapshotPlan is one snapshot an event records: whose text (Source is
// beforeChange, afterChange or editorBuffer) under which reason.
type HistorySnapshotPlan struct {
	Source string `json:"source"`
	Reason string `json:"reason"`
}

// PlanHistoryEvent asks which snapshots an editing event records (history.planEvent).
func (c *Client) PlanHistoryEvent(ctx context.Context, event string) ([]HistorySnapshotPlan, error) {
	var response struct {
		Snapshots []HistorySnapshotPlan `json:"snapshots"`
	}
	err := c.Execute(ctx, "history.planEvent", struct {
		Event string `json:"event"`
	}{event}, &response)
	return response.Snapshots, err
}

// RecordHistory stores one snapshot (history.record). Core skips a file that is
// hidden, ignored, unchanged since its last snapshot or too large; it then
// returns nil.
func (c *Client) RecordHistory(ctx context.Context, workspaceRoot, storageRoot, path, reason, content string) (*HistoryEntry, error) {
	var entry *HistoryEntry
	err := c.Execute(ctx, "history.record", struct {
		WorkspaceRoot string `json:"workspaceRoot"`
		StorageRoot   string `json:"storageRoot"`
		Path          string `json:"path"`
		Reason        string `json:"reason"`
		Content       string `json:"content"`
	}{workspaceRoot, storageRoot, path, reason, content}, &entry)
	return entry, err
}

// HistoryEntries lists one file's snapshots, newest first (history.entries).
func (c *Client) HistoryEntries(ctx context.Context, workspaceRoot, storageRoot, path string) ([]HistoryEntry, error) {
	var response struct {
		Entries []HistoryEntry `json:"entries"`
	}
	err := c.Execute(ctx, "history.entries", struct {
		WorkspaceRoot string `json:"workspaceRoot"`
		StorageRoot   string `json:"storageRoot"`
		Path          string `json:"path,omitempty"`
	}{workspaceRoot, storageRoot, path}, &response)
	return response.Entries, err
}

// HistoryContent reads one snapshot's text (history.content).
func (c *Client) HistoryContent(ctx context.Context, storageRoot, contentPath string) (string, error) {
	var response struct {
		Text string `json:"text"`
	}
	err := c.Execute(ctx, "history.content", struct {
		StorageRoot string `json:"storageRoot"`
		ContentPath string `json:"contentPath"`
	}{storageRoot, contentPath}, &response)
	return response.Text, err
}

// RenameHistory sets or, with an empty label, clears a snapshot's label (history.rename).
func (c *Client) RenameHistory(ctx context.Context, storageRoot, path, id, label string) error {
	var labelValue *string
	if label != "" {
		labelValue = &label
	}
	return c.Execute(ctx, "history.rename", struct {
		StorageRoot string  `json:"storageRoot"`
		Path        string  `json:"path"`
		ID          string  `json:"id"`
		Label       *string `json:"label"`
	}{storageRoot, path, id, labelValue}, nil)
}

// DeleteHistory deletes one snapshot (history.delete).
func (c *Client) DeleteHistory(ctx context.Context, storageRoot, path, id string) error {
	return c.Execute(ctx, "history.delete", struct {
		StorageRoot string `json:"storageRoot"`
		Path        string `json:"path"`
		ID          string `json:"id"`
	}{storageRoot, path, id}, nil)
}

// RelocateHistory moves retained history after a rename or move (history.relocate).
func (c *Client) RelocateHistory(ctx context.Context, storageRoot, source, destination string) error {
	return c.Execute(ctx, "history.relocate", struct {
		StorageRoot     string `json:"storageRoot"`
		SourcePath      string `json:"sourcePath"`
		DestinationPath string `json:"destinationPath"`
	}{storageRoot, source, destination}, nil)
}
