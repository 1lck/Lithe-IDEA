package core

import (
	"context"
	"strings"
)

// GitBlameLine is the blame of one line of a file: the commit that last changed it. Line is
// one-based and AuthorTime is Unix seconds.
type GitBlameLine struct {
	Line       int    `json:"line"`
	Hash       string `json:"commitHash"`
	AuthorName string `json:"authorName"`
	AuthorTime int64  `json:"authorTime"`
}

// Uncommitted reports a line Git attributes to no commit yet, which has the all-zero hash.
func (l GitBlameLine) Uncommitted() bool { return strings.Trim(l.Hash, "0") == "" }

type gitBlamePayload struct {
	Root string `json:"root"`
	Path string `json:"path"`
}

// GitBlame returns the blame of every line of a tracked file in line order.
//
// GitBlame starts git and blocks; call it from a background goroutine.
func (c *Client) GitBlame(ctx context.Context, root, path string) ([]GitBlameLine, error) {
	var response struct {
		Lines []GitBlameLine `json:"lines"`
	}
	if err := c.Execute(ctx, "git.blame", gitBlamePayload{Root: root, Path: path}, &response); err != nil {
		return nil, err
	}
	return nonNil(response.Lines), nil
}

// LineHistoryRange is one hunk of a commit that intersects the traced lines.
type LineHistoryRange struct {
	OldStart int `json:"oldStart"`
	OldEnd   int `json:"oldEnd"`
	NewStart int `json:"newStart"`
	NewEnd   int `json:"newEnd"`
}

// LineHistoryCommit is one commit that touched the traced lines.
type LineHistoryCommit struct {
	Hash           string             `json:"hash"`
	Kind           string             `json:"kind"`
	AuthorName     string             `json:"authorName"`
	AuthorTime     int64              `json:"authorTime"`
	Subject        string             `json:"subject"`
	PathAtCommit   string             `json:"pathAtCommit"`
	PreviousPath   string             `json:"previousPath,omitempty"`
	CompareBase    string             `json:"compareBase"`
	RelevantRanges []LineHistoryRange `json:"relevantRanges"`
}

// LineHistoryUnmapped is a traced line Core could not map onto the base commit: Kind is
// "new" for an inserted line and "unreliable" for a rewritten one.
type LineHistoryUnmapped struct {
	Line int    `json:"line"`
	Kind string `json:"kind"`
}

// LineHistory is the commits that touched a line range, newest first.
type LineHistory struct {
	BaseCommit    string                `json:"baseCommit"`
	UnmappedLines []LineHistoryUnmapped `json:"unmappedLines"`
	Commits       []LineHistoryCommit   `json:"commits"`
	Truncated     bool                  `json:"truncated"`
}

// LineHistoryRequest traces lines StartLine..EndLine (one-based, inclusive) of Content, the
// editor's snapshot of Path, so unsaved edits stay answerable. Limit 0 takes Core's default.
type LineHistoryRequest struct {
	Root      string `json:"root"`
	Path      string `json:"path"`
	Content   string `json:"content"`
	StartLine int    `json:"startLine"`
	EndLine   int    `json:"endLine"`
	Limit     int    `json:"limit,omitempty"`
}

// GitLineHistory returns the first-parent commits that touched the requested lines.
//
// GitLineHistory starts git and blocks; call it from a background goroutine.
func (c *Client) GitLineHistory(ctx context.Context, request LineHistoryRequest) (LineHistory, error) {
	var history LineHistory
	if err := c.Execute(ctx, "git.lineHistory", request, &history); err != nil {
		return LineHistory{}, err
	}
	history.UnmappedLines = nonNil(history.UnmappedLines)
	history.Commits = nonNil(history.Commits)
	return history, nil
}
