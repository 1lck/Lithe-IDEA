package core

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"time"
)

// RecentProject is one entry of the recently opened project list.
type RecentProject struct {
	// Path is the project root exactly as the host normalizes it. The kernel compares paths
	// byte for byte, never touches the file system and rejects an empty path.
	Path string `json:"path"`
	// LastOpenedAt is the time the project was last opened, in Unix milliseconds. It must not
	// be negative.
	LastOpenedAt int64 `json:"lastOpenedAt"`
	// Pinned entries are listed first and do not count against the capacity.
	Pinned bool `json:"pinned"`
}

// recentKind names the variants of a RecentAction. The values are the "kind" tags of the Rust
// RecentProjectsAction enum.
type recentKind string

const (
	recentRecord       recentKind = "record"
	recentRemove       recentKind = "remove"
	recentTogglePinned recentKind = "togglePinned"
	recentImport       recentKind = "import"
	recentNormalize    recentKind = "normalize"
)

// RecentAction is one change to the recent project list. Build it with RecordRecent,
// RemoveRecent, TogglePinnedRecent, ImportRecent or NormalizeRecent; the zero value is not a
// valid action and cannot be encoded.
type RecentAction struct {
	kind     recentKind
	path     string
	paths    []string
	openedAt int64
}

// RecordRecent records that the project at path was opened at openedAt. The project moves to
// the front and keeps its pin.
func RecordRecent(path string, openedAt time.Time) RecentAction {
	return RecentAction{kind: recentRecord, path: path, openedAt: openedAt.UnixMilli()}
}

// RemoveRecent removes the projects at paths, for example because the user removed them or the
// host found them unavailable.
func RemoveRecent(paths ...string) RecentAction {
	return RecentAction{kind: recentRemove, paths: slices.Clone(paths)}
}

// TogglePinnedRecent flips the pin of the project at path. An unknown path is ignored.
func TogglePinnedRecent(path string) RecentAction {
	return RecentAction{kind: recentTogglePinned, path: path}
}

// ImportRecent adds projects discovered elsewhere, for example by another IDE, that are not
// listed yet. The first new path is stamped openedAt and each later one a millisecond older, so
// the source order is kept.
func ImportRecent(paths []string, openedAt time.Time) RecentAction {
	return RecentAction{kind: recentImport, paths: slices.Clone(paths), openedAt: openedAt.UnixMilli()}
}

// NormalizeRecent re-applies ordering, deduplication and the capacity to a loaded list without
// any other change.
func NormalizeRecent() RecentAction {
	return RecentAction{kind: recentNormalize}
}

// recentKindWire, recentPathWire, recentPathsWire, recentRecordWire and recentImportWire are the
// exact JSON shapes of the action variants. The kernel rejects unknown fields, so each variant
// encodes only its own fields.
type recentKindWire struct {
	Kind recentKind `json:"kind"`
}

type recentPathWire struct {
	Kind recentKind `json:"kind"`
	Path string     `json:"path"`
}

type recentPathsWire struct {
	Kind  recentKind `json:"kind"`
	Paths []string   `json:"paths"`
}

type recentRecordWire struct {
	Kind     recentKind `json:"kind"`
	Path     string     `json:"path"`
	OpenedAt int64      `json:"openedAt"`
}

type recentImportWire struct {
	Kind     recentKind `json:"kind"`
	Paths    []string   `json:"paths"`
	OpenedAt int64      `json:"openedAt"`
}

// MarshalJSON encodes the action as the exact object of its variant.
func (a RecentAction) MarshalJSON() ([]byte, error) {
	switch a.kind {
	case recentRecord:
		return json.Marshal(recentRecordWire{Kind: a.kind, Path: a.path, OpenedAt: a.openedAt})
	case recentRemove:
		return json.Marshal(recentPathsWire{Kind: a.kind, Paths: nonNil(a.paths)})
	case recentTogglePinned:
		return json.Marshal(recentPathWire{Kind: a.kind, Path: a.path})
	case recentImport:
		return json.Marshal(recentImportWire{Kind: a.kind, Paths: nonNil(a.paths), OpenedAt: a.openedAt})
	case recentNormalize:
		return json.Marshal(recentKindWire{Kind: a.kind})
	}
	return nil, errors.New("core: zero RecentAction; build one with RecordRecent, RemoveRecent, TogglePinnedRecent, ImportRecent or NormalizeRecent")
}

// RecentProjectsResult is the outcome of reducing the recent project list.
type RecentProjectsResult struct {
	// Entries is the retained list: pinned projects first, then by most recent LastOpenedAt;
	// entries with equal times keep their input order.
	Entries []RecentProject `json:"entries"`
	// Added lists the paths that are in Entries but were not in the input.
	Added []string `json:"added"`
	// Removed lists the paths that were in the input but are no longer in Entries, whether the
	// action removed them or the capacity dropped them. The host discards its per-project
	// metadata for them.
	Removed []string `json:"removed"`
}

// recentProjectsRequest is the payload of workspace.recentProjects.reduce. The kernel rejects
// unknown fields.
type recentProjectsRequest struct {
	Entries  []RecentProject `json:"entries"`
	Action   RecentAction    `json:"action"`
	Capacity int             `json:"capacity,omitempty"`
}

// ReduceRecentProjects applies action to the stored list entries and returns the retained list
// together with the paths the reduction added and dropped. The host owns persistence: it loads
// entries, calls this, and stores Entries.
//
// capacity bounds the number of unpinned entries kept; 0 leaves it to the kernel's default
// (20). The kernel rejects a negative capacity, a capacity above 200, more than 1024 entries,
// an empty path and a negative time with CodeInvalidRequest.
//
// The call only computes over its arguments and is fast enough for an event handler.
func (c *Client) ReduceRecentProjects(ctx context.Context, entries []RecentProject, action RecentAction, capacity int) (RecentProjectsResult, error) {
	request := recentProjectsRequest{
		Entries:  nonNil(entries),
		Action:   action,
		Capacity: capacity,
	}
	var result RecentProjectsResult
	if err := c.Execute(ctx, "workspace.recentProjects.reduce", request, &result); err != nil {
		return RecentProjectsResult{}, err
	}
	return result, nil
}
