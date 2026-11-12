package core

import "context"

type untrackedDirectoryPayload struct {
	Root           string   `json:"root"`
	Directory      string   `json:"directory"`
	RepositoryRoot []string `json:"repositoryRoots,omitempty"`
}

// GitUntrackedDirectory lists one level of a summarized untracked directory: its untracked
// files, and each subdirectory as one more summary whose Path ends with "/". directory is the
// summary's own path, which ends with "/".
//
// GitUntrackedDirectory starts git and blocks; call it from a background goroutine.
func (c *Client) GitUntrackedDirectory(ctx context.Context, root, directory string) ([]GitChange, error) {
	var response struct {
		Changes []GitChange `json:"changes"`
	}
	if err := c.Execute(ctx, "git.untrackedDirectory", untrackedDirectoryPayload{Root: root, Directory: directory}, &response); err != nil {
		return nil, err
	}
	return nonNil(response.Changes), nil
}

// GitRollbackStep is one Git write of a rollback: operation is the git.write operation and
// Paths are the literal paths it acts on.
type GitRollbackStep struct {
	Operation string   `json:"operation"`
	Paths     []string `json:"paths"`
}

type rollbackChange struct {
	Path         string `json:"path"`
	OriginalPath string `json:"originalPath,omitempty"`
	Status       string `json:"status"`
}

type rollbackPayload struct {
	Root             string           `json:"root,omitempty"`
	Changes          []rollbackChange `json:"changes"`
	DeleteAddedFiles bool             `json:"deleteAddedFiles,omitempty"`
}

// GitRollbackPrepare asks Core for the ordered Git writes that restore changes to HEAD. It
// rechecks each selected identity against the repository and fails with
// GIT_ROLLBACK_STALE_SELECTION when one changed. deleteAdded also deletes added files from disk.
// Run the steps in order with GitRunRollbackStep, stop at the first failure, and read the status
// again whatever the outcome.
//
// GitRollbackPrepare starts git and blocks; call it from a background goroutine.
func (c *Client) GitRollbackPrepare(ctx context.Context, root string, changes []GitChange, deleteAdded bool) ([]GitRollbackStep, error) {
	payload := rollbackPayload{Root: root, DeleteAddedFiles: deleteAdded}
	for _, change := range changes {
		payload.Changes = append(payload.Changes, rollbackChange{Path: change.Path, OriginalPath: change.OriginalPath, Status: change.Status})
	}
	payload.Changes = nonNil(payload.Changes)
	var response struct {
		Steps []GitRollbackStep `json:"steps"`
	}
	if err := c.Execute(ctx, "git.rollbackPrepare", payload, &response); err != nil {
		return nil, err
	}
	return nonNil(response.Steps), nil
}

// GitRunRollbackStep executes one step Core planned.
func (c *Client) GitRunRollbackStep(ctx context.Context, root string, step GitRollbackStep) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: step.Operation, Paths: nonNil(step.Paths)})
}
