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

// HistoryIgnoreRules are the user's rules for files whose changes local history does not
// record. PathPatterns are globs in the hidden-path syntax; a "!**/name/" or "!name" entry turns
// one of Core's built-in folders off. PathRegexes are case-insensitive regular expressions
// matched anywhere in the project-relative path; an invalid one never matches.
type HistoryIgnoreRules struct {
	PathPatterns []string `json:"pathPatterns,omitempty"`
	PathRegexes  []string `json:"pathRegexes,omitempty"`
}

// HistoryPolicy is the user's local history settings a record follows: what is not recorded
// and how many bytes one project's history may take, zero keeping Core's default. Core keeps a
// configured limit within its own bounds.
type HistoryPolicy struct {
	IgnoreRules       HistoryIgnoreRules
	StorageLimitBytes uint64
}

// storageLimit is the limit as Core reads it: absent for its default.
func (p HistoryPolicy) storageLimit() *uint64 {
	if p.StorageLimitBytes == 0 {
		return nil
	}
	limit := p.StorageLimitBytes
	return &limit
}

// RecordHistory stores one snapshot (history.record) under policy. Core skips a file that is
// hidden, ignored, unchanged since its last snapshot or too large; it then returns nil.
func (c *Client) RecordHistory(ctx context.Context, workspaceRoot, storageRoot, path, reason, content string, policy HistoryPolicy) (*HistoryEntry, error) {
	var entry *HistoryEntry
	err := c.Execute(ctx, "history.record", struct {
		WorkspaceRoot     string             `json:"workspaceRoot"`
		StorageRoot       string             `json:"storageRoot"`
		Path              string             `json:"path"`
		Reason            string             `json:"reason"`
		Content           string             `json:"content"`
		IgnoreRules       HistoryIgnoreRules `json:"ignoreRules"`
		StorageLimitBytes *uint64            `json:"storageLimitBytes,omitempty"`
	}{workspaceRoot, storageRoot, path, reason, content, policy.IgnoreRules, policy.storageLimit()}, &entry)
	return entry, err
}

// HistoryIgnoreMatch is the rule that keeps a path out of local history. Kind is "hidden" (the
// path is hidden from the project tree), "pattern" (Pattern is the wildcard rule as written,
// built-in or the user's) or "regex" (Index is the rule's position in PathRegexes).
type HistoryIgnoreMatch struct {
	Kind    string `json:"kind"`
	Pattern string `json:"pattern,omitempty"`
	Index   int    `json:"index,omitempty"`
}

// HistoryRegexError is a regular expression rule Core cannot compile, by its position in
// PathRegexes, and the compiler's reason.
type HistoryRegexError struct {
	Index   int    `json:"index"`
	Message string `json:"message"`
}

// HistoryIgnorePreview is Core's reading of ignore rules (history.ignorePreview): the rules it
// cannot compile, its built-in wildcard rules, the rule a sample path matches (nil when the
// path is recorded or none was given), and whether Git ignores the path, which local history
// does not follow (nil without a path, a project or a repository).
type HistoryIgnorePreview struct {
	RegexErrors           []HistoryRegexError `json:"regexErrors"`
	BuiltInIgnorePatterns []string            `json:"builtInIgnorePatterns"`
	Matched               *HistoryIgnoreMatch `json:"matched"`
	GitIgnored            *bool               `json:"gitIgnored"`
}

// PreviewHistoryIgnore checks rules and, when path is not empty, which of them keeps the
// project-relative path out of local history; with workspaceRoot it also asks Git about the
// path. A path that is absolute or leaves the project is an invalid request.
func (c *Client) PreviewHistoryIgnore(ctx context.Context, rules HistoryIgnoreRules, workspaceRoot, path string) (HistoryIgnorePreview, error) {
	var preview HistoryIgnorePreview
	err := c.Execute(ctx, "history.ignorePreview", struct {
		Path          string             `json:"path,omitempty"`
		IgnoreRules   HistoryIgnoreRules `json:"ignoreRules"`
		WorkspaceRoot string             `json:"workspaceRoot,omitempty"`
	}{path, rules, workspaceRoot}, &preview)
	return preview, err
}

// HistoryUsage is the disk space one project's history takes, in allocated bytes, and the
// limit Core keeps it under.
type HistoryUsage struct {
	UsedBytes  uint64 `json:"usedBytes"`
	LimitBytes uint64 `json:"limitBytes"`
}

// LocalHistoryUsage measures the history under storageRoot (history.usage) and reports the
// limit Core applies for limitBytes, zero being its default.
func (c *Client) LocalHistoryUsage(ctx context.Context, storageRoot string, limitBytes uint64) (HistoryUsage, error) {
	var usage HistoryUsage
	err := c.Execute(ctx, "history.usage", struct {
		StorageRoot       string  `json:"storageRoot"`
		StorageLimitBytes *uint64 `json:"storageLimitBytes,omitempty"`
	}{storageRoot, HistoryPolicy{StorageLimitBytes: limitBytes}.storageLimit()}, &usage)
	return usage, err
}

// ClearHistory deletes every snapshot under storageRoot (history.clear); the folder stays.
func (c *Client) ClearHistory(ctx context.Context, storageRoot string) error {
	return c.Execute(ctx, "history.clear", struct {
		StorageRoot string `json:"storageRoot"`
	}{storageRoot}, nil)
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
