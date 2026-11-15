package core

import "context"

// GitChange is one normalized index or working-tree change.
type GitChange struct {
	// Path is relative to the repository root with "/" separators. A summarized untracked
	// directory ends with "/".
	Path string `json:"path"`
	// OriginalPath is the previous path of a rename or copy, empty otherwise.
	OriginalPath string `json:"originalPath,omitempty"`
	// Status is the kernel's normalized porcelain status code for the path.
	Status string `json:"status"`
	// Staged reports a change recorded in the index.
	Staged bool `json:"staged"`
	// Worktree reports a change in the working tree that is not in the index.
	Worktree bool `json:"worktree"`
	// Untracked reports a path Git does not track yet.
	Untracked bool `json:"untracked"`
	// CanToggleStaging is false for a parent gitlink whose only change is uncommitted content
	// inside the submodule, which cannot be staged from the parent.
	CanToggleStaging bool `json:"canToggleStaging"`
	// UntrackedFileCount is the number of non-ignored files below a summarized untracked
	// directory, and 0 for every other change.
	UntrackedFileCount int `json:"untrackedFileCount,omitempty"`
}

// GitStatus is the repository identity, branch divergence and file changes of a directory.
type GitStatus struct {
	// RepositoryRoot is the repository's top-level directory, relative to the root that was
	// asked about: "." when they are the same directory, and an absolute path when the
	// repository's top level lies outside it. It is empty when the directory is not inside a
	// Git repository.
	RepositoryRoot string `json:"repositoryRoot"`
	// Branch is the checked-out local branch, "detached" when HEAD is detached, and empty when
	// the directory is not inside a Git repository.
	Branch string `json:"branch"`
	// Ahead is the number of commits the branch has that its upstream lacks.
	Ahead int `json:"ahead"`
	// Behind is the number of commits the upstream has that the branch lacks.
	Behind int `json:"behind"`
	// Changes are the index and working-tree changes in the kernel's deterministic order.
	Changes []GitChange `json:"changes"`
}

// gitStatusRequest is the payload of git.status.
type gitStatusRequest struct {
	Root                          string `json:"root"`
	IncludeIndexOnlyChanges       bool   `json:"includeIndexOnlyChanges"`
	SummarizeUntrackedDirectories bool   `json:"summarizeUntrackedDirectories"`
}

// GitStatus returns the Git status of the directory root.
//
// It asks the kernel to keep additions deleted only from the working tree, as a staging UI
// needs, and to report a large wholly untracked directory as one entry carrying
// UntrackedFileCount instead of one entry per file.
//
// A directory that is not inside a Git repository is not an error: the result has an empty
// RepositoryRoot and Branch, zero Ahead and Behind, and no Changes. A root that does not exist
// or is not a directory fails with CodeWorkspaceNotFound. A missing git executable or a failing
// git process fails with the matching process error code.
//
// GitStatus starts git and blocks; call it from a background goroutine.
func (c *Client) GitStatus(ctx context.Context, root string) (GitStatus, error) {
	request := gitStatusRequest{
		Root:                          root,
		IncludeIndexOnlyChanges:       true,
		SummarizeUntrackedDirectories: true,
	}
	var status GitStatus
	if err := c.Execute(ctx, "git.status", request, &status); err != nil {
		return GitStatus{}, err
	}
	status.Changes = nonNil(status.Changes)
	return status, nil
}
