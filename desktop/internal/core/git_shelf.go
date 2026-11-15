package core

import "context"

// This file wraps Core's Shelf steps (git.shelf) and its patch reader (git.parsePatch). Core
// captures the local changes as patches, cleans them from the checkout and applies them
// back, each step guarded against a repository that changed meanwhile; the host keeps the
// captured snapshot between the steps and after them, until the shelf is restored or dropped.

// GitShelfSnapshot is what a shelf saves: the staged changes and the working tree's changes,
// untracked files among them, as patches, and every path either patch touches.
type GitShelfSnapshot struct {
	StagedPatch  string   `json:"stagedPatch"`
	WorkingPatch string   `json:"workingPatch"`
	Paths        []string `json:"paths"`
}

// Empty says the snapshot saved no change.
func (s GitShelfSnapshot) Empty() bool { return s.StagedPatch == "" && s.WorkingPatch == "" }

// The phases Core plans the layers of, and the layers a step cleans or restores.
const (
	GitShelfClean   = "clean"
	GitShelfRestore = "restore"
	GitShelfStaged  = "staged"
	GitShelfWorking = "working"
)

// The messages Core fails a Shelf step with: the repository changed under the step, which
// left the shelf as it was, or it has unmerged files, which a shelf cannot capture.
const (
	GitShelfChanged   = "SHELF_CHANGED"
	GitShelfConflicts = "SHELF_CONFLICTS"
)

type gitShelfRequest struct {
	Root     string            `json:"root"`
	Action   string            `json:"action"`
	Layer    string            `json:"layer,omitempty"`
	Snapshot *GitShelfSnapshot `json:"snapshot,omitempty"`
	Phase    string            `json:"phase,omitempty"`
}

// GitShelfCapture reads the local changes of the repository at root as a snapshot, without
// changing them. It fails with GitShelfConflicts while the repository has unmerged files.
//
// GitShelfCapture starts git and blocks; call it from a background goroutine.
func (c *Client) GitShelfCapture(ctx context.Context, root string) (GitShelfSnapshot, error) {
	var snapshot GitShelfSnapshot
	if err := c.Execute(ctx, "git.shelf", gitShelfRequest{Root: root, Action: "capture"}, &snapshot); err != nil {
		return GitShelfSnapshot{}, err
	}
	snapshot.Paths = nonNil(snapshot.Paths)
	return snapshot, nil
}

// GitShelfPlan returns the layers phase cleans or restores, in the order Core steps through
// them.
func (c *Client) GitShelfPlan(ctx context.Context, root, phase string) ([]string, error) {
	var response struct {
		Layers []string `json:"layers"`
	}
	if err := c.Execute(ctx, "git.shelf", gitShelfRequest{Root: root, Action: "plan", Phase: phase}, &response); err != nil {
		return nil, err
	}
	return nonNil(response.Layers), nil
}

// GitShelfClean removes one layer of snapshot from the checkout. It fails with GitShelfChanged,
// and changes nothing, when the layer is no longer what the snapshot captured.
//
// GitShelfClean starts git and blocks; call it from a background goroutine.
func (c *Client) GitShelfClean(ctx context.Context, root, layer string, snapshot GitShelfSnapshot) error {
	return c.gitShelfStep(ctx, root, "clean", layer, snapshot)
}

// GitShelfRestore applies one layer of snapshot to the checkout again. A layer already applied
// by an earlier attempt succeeds, so a restore that stopped halfway can be repeated.
//
// GitShelfRestore starts git and blocks; call it from a background goroutine.
func (c *Client) GitShelfRestore(ctx context.Context, root, layer string, snapshot GitShelfSnapshot) error {
	return c.gitShelfStep(ctx, root, "restore", layer, snapshot)
}

func (c *Client) gitShelfStep(ctx context.Context, root, action, layer string, snapshot GitShelfSnapshot) error {
	snapshot.Paths = nonNil(snapshot.Paths)
	var response struct{}
	return c.Execute(ctx, "git.shelf", gitShelfRequest{Root: root, Action: action, Layer: layer, Snapshot: &snapshot}, &response)
}

// GitParsePatch reads a saved patch of the repository at root as structured files, one per
// file the patch changes, as GitDiff answers them.
//
// GitParsePatch starts git and blocks; call it from a background goroutine.
func (c *Client) GitParsePatch(ctx context.Context, root, patch string) ([]GitDiffFile, error) {
	var response gitDiffResponse
	payload := struct {
		Root  string `json:"root"`
		Patch string `json:"patch"`
	}{root, patch}
	if err := c.Execute(ctx, "git.parsePatch", payload, &response); err != nil {
		return nil, err
	}
	for i := range response.Files {
		response.Files[i].Lines = nonNil(response.Files[i].Lines)
		response.Files[i].Rows = nonNil(response.Files[i].Rows)
	}
	return nonNil(response.Files), nil
}
