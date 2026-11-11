package core

import "context"

// This file wraps the Core commands behind the Diff view and the editor's gutter: the
// structured diff of one file, the blocks Core plans for staging and rolling back, and the
// single-change stage of the gutter. Core builds every patch; Go only forwards the identity
// of a block and shows the rows.

// GitDiffRow is one aligned row of a file's diff. Kind is context, changed, addition, removal
// or information; for context and information rows Right is empty and Left is the text of both
// sides.
type GitDiffRow struct {
	OldLine *int   `json:"oldLine"`
	NewLine *int   `json:"newLine"`
	Left    string `json:"left"`
	Right   string `json:"right"`
	Kind    string `json:"kind"`
	HunkID  string `json:"hunkID,omitempty"`
}

// Text is the text the right side of the row shows.
func (r GitDiffRow) Text() string {
	if r.Right == "" && (r.Kind == "context" || r.Kind == "information") {
		return r.Left
	}
	return r.Right
}

// GitDiffLine is one line of a file's unified view. LineType is header, context, added or
// removed.
type GitDiffLine struct {
	LineType string `json:"lineType"`
	Content  string `json:"content"`
	OldLine  *int   `json:"oldLine"`
	NewLine  *int   `json:"newLine"`
}

// GitDiffFile is the diff of one file with its unified lines and aligned rows.
type GitDiffFile struct {
	Path         string        `json:"path"`
	OriginalPath string        `json:"originalPath,omitempty"`
	Status       string        `json:"status"`
	IsBinary     bool          `json:"isBinary"`
	Additions    int           `json:"additions"`
	Deletions    int           `json:"deletions"`
	Lines        []GitDiffLine `json:"lines"`
	Rows         []GitDiffRow  `json:"rows"`
}

// GitDiffRequest selects what GitDiff compares. The comparison is the working tree against
// the index, or with Staged the index against HEAD. Untracked reads a path Git does not track.
type GitDiffRequest struct {
	Root      string
	Path      string
	Staged    bool
	Untracked bool
	// Reference compares the working tree with a revision when it is set.
	Reference string
	// Commit shows one commit against its first parent when it is set.
	Commit string
	// Base compares the file of a reference: with Target when it is set, with the working tree
	// otherwise. A Base without a kind is a revision such as HEAD and takes no Target.
	Base, Target *GitReference
	// WholeFile reads the whole file as context around the changes, as a side-by-side view of
	// the two versions needs; otherwise Core keeps its default context around each change.
	WholeFile bool
}

// gitDiffWholeFileContext is the context Core reads as the whole file: its
// FULL_FILE_CONTEXT_LINES, at which it also pins Git's inter-hunk context to zero.
const gitDiffWholeFileContext = 1_073_741_823

type gitDiffPayload struct {
	Root                string               `json:"root"`
	Pathspecs           []string             `json:"pathspecs"`
	Reference           string               `json:"reference,omitempty"`
	GitReference        *gitReferenceRequest `json:"gitReference,omitempty"`
	TargetGitReference  *gitReferenceRequest `json:"targetGitReference,omitempty"`
	Commit              string               `json:"commit,omitempty"`
	Staged              bool                 `json:"staged,omitempty"`
	Untracked           bool                 `json:"untracked,omitempty"`
	StashReference      string               `json:"stashReference,omitempty"`
	IncludeFileSections bool                 `json:"includeFileSections"`
	OmitFilePatch       bool                 `json:"omitFilePatch"`
	// ContextLines is the context around each change; nil leaves Core's default.
	ContextLines *int `json:"contextLines,omitempty"`
}

type gitDiffResponse struct {
	Files []GitDiffFile `json:"files"`
}

// GitDiff returns the structured diff of one path. A path without changes yields no file.
//
// GitDiff starts git and blocks; call it from a background goroutine.
func (c *Client) GitDiff(ctx context.Context, request GitDiffRequest) ([]GitDiffFile, error) {
	payload := gitDiffPayload{
		Root:                request.Root,
		Pathspecs:           []string{request.Path},
		Reference:           request.Reference,
		Commit:              request.Commit,
		Staged:              request.Staged,
		Untracked:           request.Untracked,
		IncludeFileSections: true,
		OmitFilePatch:       true,
	}
	if request.Base != nil {
		payload.Reference, payload.GitReference, payload.TargetGitReference = comparisonReferences(*request.Base, request.Target)
	}
	if request.WholeFile {
		lines := gitDiffWholeFileContext
		payload.ContextLines = &lines
	}
	return c.gitDiffFiles(ctx, payload)
}

// GitComparisonFile is a file that differs between the two sides of a comparison. Untracked
// marks a file of the working tree Git does not track yet.
type GitComparisonFile struct {
	Path      string `json:"path"`
	Status    string `json:"status"`
	Untracked bool   `json:"isUntracked"`
}

type gitComparisonPayload struct {
	Root               string               `json:"root"`
	Reference          string               `json:"reference,omitempty"`
	GitReference       *gitReferenceRequest `json:"gitReference,omitempty"`
	TargetGitReference *gitReferenceRequest `json:"targetGitReference,omitempty"`
	IncludeUntracked   bool                 `json:"includeUntracked,omitempty"`
}

// GitComparison lists the files that differ between base and target, or between base and the
// working tree, its untracked files among them, when target is nil. A base without a kind is a
// revision such as HEAD and takes no target. GitDiff with the same Base and Target reads a
// listed file's diff.
//
// GitComparison starts git and blocks; call it from a background goroutine.
func (c *Client) GitComparison(ctx context.Context, root string, base GitReference, target *GitReference) ([]GitComparisonFile, error) {
	payload := gitComparisonPayload{Root: root, IncludeUntracked: target == nil}
	payload.Reference, payload.GitReference, payload.TargetGitReference = comparisonReferences(base, target)
	var response struct {
		Files []GitComparisonFile `json:"files"`
	}
	if err := c.Execute(ctx, "git.comparison", payload, &response); err != nil {
		return nil, err
	}
	return nonNil(response.Files), nil
}

// comparisonReferences are base and target as Core's comparisons take them: a reference by its
// identity, which Core checks against the repository, or a revision without a kind by name.
func comparisonReferences(base GitReference, target *GitReference) (string, *gitReferenceRequest, *gitReferenceRequest) {
	var typedTarget *gitReferenceRequest
	if target != nil {
		typedTarget = target.request()
	}
	if base.Kind == "" {
		return base.FullName, nil, typedTarget
	}
	return "", base.request(), typedTarget
}

// GitStashDiff returns the files a stash saved, its untracked files among them, each with its
// structured diff. Core reads the stash by its immutable identity, so a stash pushed or dropped
// meanwhile does not change what is read.
//
// GitStashDiff starts git and blocks; call it from a background goroutine.
func (c *Client) GitStashDiff(ctx context.Context, root string, stash GitStash) ([]GitDiffFile, error) {
	// A stash is read for the whole repository only; Core refuses any other pathspec.
	return c.gitDiffFiles(ctx, gitDiffPayload{
		Root:                root,
		Pathspecs:           []string{"."},
		StashReference:      stash.OID,
		IncludeFileSections: true,
		OmitFilePatch:       true,
	})
}

// gitDiffFiles runs one git.diff read that answers file by file.
func (c *Client) gitDiffFiles(ctx context.Context, payload gitDiffPayload) ([]GitDiffFile, error) {
	var response gitDiffResponse
	if err := c.Execute(ctx, "git.diff", payload, &response); err != nil {
		return nil, err
	}
	for i := range response.Files {
		response.Files[i].Lines = nonNil(response.Files[i].Lines)
		response.Files[i].Rows = nonNil(response.Files[i].Rows)
	}
	return nonNil(response.Files), nil
}

// DiffBlock is one block Core planned for a file: a run of changed lines the user can stage,
// unstage or roll back as a unit. ID is "line-<index>" into the section's unified lines.
type DiffBlock struct {
	ID            string `json:"id"`
	Checked       bool   `json:"checked"`
	Indeterminate bool   `json:"indeterminate"`
	CanToggle     bool   `json:"canToggle"`
	CanRollback   bool   `json:"canRollback"`
	WholeFile     bool   `json:"wholeFile,omitempty"`
}

// DiffSection is the complete-file diff a block plan refers to: HEAD to working tree, or with
// Staged HEAD to index. It has no files when the file has no such change.
type DiffSection struct {
	Files []GitDiffFile `json:"files"`
}

// DiffBlockPlan is Core's plan of blocks for one file. Token identifies the read: a write
// carries it back, and Core refuses it when the repository moved on.
type DiffBlockPlan struct {
	Token    string       `json:"token"`
	Blocks   []DiffBlock  `json:"blocks"`
	Worktree *DiffSection `json:"worktree"`
	Index    *DiffSection `json:"index"`
}

// DiffBlockTarget is the file a block plan reads or writes.
type DiffBlockTarget struct {
	Root         string `json:"root"`
	Path         string `json:"path"`
	OriginalPath string `json:"originalPath,omitempty"`
	Staged       bool   `json:"staged,omitempty"`
}

// DiffBlockAction is what ApplyDiffBlock does with one block.
type DiffBlockAction string

const (
	// DiffBlockInclude stages the block.
	DiffBlockInclude DiffBlockAction = "include"
	// DiffBlockExclude unstages it.
	DiffBlockExclude DiffBlockAction = "exclude"
	// DiffBlockRollback discards it from the working tree.
	DiffBlockRollback DiffBlockAction = "rollback"
)

// PlanDiffBlocks asks Core for the blocks of one file.
//
// PlanDiffBlocks starts git and blocks; call it from a background goroutine.
func (c *Client) PlanDiffBlocks(ctx context.Context, target DiffBlockTarget) (DiffBlockPlan, error) {
	var plan DiffBlockPlan
	if err := c.Execute(ctx, "git.planDiffBlocks", target, &plan); err != nil {
		return DiffBlockPlan{}, err
	}
	plan.Blocks = nonNil(plan.Blocks)
	return plan, nil
}

type applyDiffBlockPayload struct {
	DiffBlockTarget
	BlockID string          `json:"blockId"`
	Action  DiffBlockAction `json:"action"`
	Token   string          `json:"token"`
}

// ApplyDiffBlock includes, excludes or rolls back one planned block. A block whose plan is out
// of date fails with GIT_DIFF_BLOCK_STALE, one that cannot take the action with
// GIT_DIFF_BLOCK_UNAVAILABLE, and a rollback that file attributes make unsafe with
// GIT_HUNK_ROLLBACK_UNSAFE; the caller plans again after the first.
//
// ApplyDiffBlock starts git and blocks; call it from a background goroutine.
func (c *Client) ApplyDiffBlock(ctx context.Context, plan DiffBlockPlan, target DiffBlockTarget, blockID string, action DiffBlockAction) error {
	payload := applyDiffBlockPayload{DiffBlockTarget: target, BlockID: blockID, Action: action, Token: plan.Token}
	return c.Execute(ctx, "git.applyDiffBlock", payload, nil)
}

// GutterChange is one change of the editor's gutter: the original and modified line spans
// (one-based, end-exclusive) and their text.
type GutterChange struct {
	OriginalStart int      `json:"originalStart"`
	OriginalEnd   int      `json:"originalEnd"`
	ModifiedStart int      `json:"modifiedStart"`
	ModifiedEnd   int      `json:"modifiedEnd"`
	OriginalLines []string `json:"originalLines"`
	ModifiedLines []string `json:"modifiedLines"`
}

type stageGutterPayload struct {
	Root string `json:"root"`
	Path string `json:"path"`
	GutterChange
}

// StageGutterChange stages exactly one gutter change from the original bytes. It fails with
// GIT_GUTTER_CHANGE_STALE when the index or the saved file no longer shows the compared lines.
//
// StageGutterChange starts git and blocks; call it from a background goroutine.
func (c *Client) StageGutterChange(ctx context.Context, root, path string, change GutterChange) error {
	change.OriginalLines = nonNil(change.OriginalLines)
	change.ModifiedLines = nonNil(change.ModifiedLines)
	return c.Execute(ctx, "git.stageGutterChange", stageGutterPayload{Root: root, Path: path, GutterChange: change}, nil)
}
