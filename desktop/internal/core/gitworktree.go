package core

import "context"

// GitWorktree is one working tree registered with a repository, as git.worktrees reports it.
type GitWorktree struct {
	// Path is the checkout's absolute, canonical path. A linked worktree may live outside the
	// opened project.
	Path string `json:"path"`
	// Head is the commit the worktree has checked out.
	Head string `json:"head"`
	// Branch is the fully qualified local branch the worktree has checked out, empty for a
	// detached or bare worktree.
	Branch string `json:"branch"`
	// IsCurrent says this is the worktree the request was made from.
	IsCurrent bool `json:"isCurrent"`
	// IsPrimary says this is the repository's main worktree.
	IsPrimary  bool `json:"isPrimary"`
	IsBare     bool `json:"isBare"`
	IsDetached bool `json:"isDetached"`
	IsLocked   bool `json:"isLocked"`
	// LockReason is the reason the worktree was locked with, when one was given.
	LockReason string `json:"lockReason"`
	// IsPrunable says the registration's checkout is gone, so pruning removes it.
	IsPrunable bool `json:"isPrunable"`
	// PruneReason is Git's explanation of why the registration can be pruned.
	PruneReason string `json:"pruneReason"`
	// Status is the one state the worktree's row shows, one of the GitWorktreeStatus values.
	// It is GitWorktreeModified only in a listing that counted the changes.
	Status string `json:"status"`
	// Changes is the number of local changes of the checkout, nil when they were not counted
	// or could not be read.
	Changes *int `json:"changes"`
	// Actions says which writes Core accepts for the worktree.
	Actions GitWorktreeActions `json:"actions"`
}

// The states of GitWorktree.Status, the first that holds of a worktree.
const (
	// GitWorktreeMissing is a registration whose checkout is gone.
	GitWorktreeMissing = "missing"
	// GitWorktreeLocked is a locked worktree.
	GitWorktreeLocked = "locked"
	// GitWorktreeModified is a checkout with counted local changes.
	GitWorktreeModified = "modified"
	// GitWorktreeCurrent is the worktree the listing was made from.
	GitWorktreeCurrent = "current"
	// GitWorktreeAvailable is any other worktree.
	GitWorktreeAvailable = "available"
)

// GitWorktreeActions are the writes a worktree's menu and details offer.
type GitWorktreeActions struct {
	// Remove is GitRemoveWorktree's.
	Remove GitWorktreeAction `json:"remove"`
	// Lock is GitLockWorktree's and GitUnlockWorktree's.
	Lock GitWorktreeAction `json:"lock"`
}

// GitWorktreeAction says whether Core accepts one write to a worktree.
type GitWorktreeAction struct {
	Allowed bool `json:"allowed"`
	// Reason names the refusal, empty when the write is allowed: CodeGitWorktreePrimary,
	// CodeGitWorktreeCurrent and CodeGitWorktreeLocked are the codes the write itself returns,
	// and GitWorktreeBlockedMissing is a checkout that is gone, which is pruned instead.
	Reason ErrorCode `json:"reason"`
}

// GitWorktreeBlockedMissing is the GitWorktreeAction.Reason of a checkout that is gone. It is
// not an error code: Core leaves such a write to Git.
const GitWorktreeBlockedMissing ErrorCode = "git_worktree_missing"

// GitWorktrees returns the worktrees registered with the repository at root, in Git's order,
// without reading their checkouts.
//
// GitWorktrees starts git and blocks; call it from a background goroutine.
func (c *Client) GitWorktrees(ctx context.Context, root string) ([]GitWorktree, error) {
	return c.gitWorktrees(ctx, root, false)
}

// GitWorktreesWithChanges is GitWorktrees with the local changes of every checkout counted,
// which sets each worktree's Changes and lets its Status be GitWorktreeModified.
//
// GitWorktreesWithChanges starts git once per checkout and blocks; call it from a background
// goroutine.
func (c *Client) GitWorktreesWithChanges(ctx context.Context, root string) ([]GitWorktree, error) {
	return c.gitWorktrees(ctx, root, true)
}

func (c *Client) gitWorktrees(ctx context.Context, root string, countChanges bool) ([]GitWorktree, error) {
	var response struct {
		Worktrees []GitWorktree `json:"worktrees"`
	}
	if err := c.Execute(ctx, "git.worktrees", struct {
		Root         string `json:"root"`
		CountChanges bool   `json:"countChanges,omitempty"`
	}{root, countChanges}, &response); err != nil {
		return nil, err
	}
	return response.Worktrees, nil
}

// GitWorktreeCreationInput is what the dialog that creates a worktree holds, for
// GitWorktreeCreationPreview.
type GitWorktreeCreationInput struct {
	// Root is the repository the worktree is created from.
	Root string `json:"root"`
	// Mode is one of GitWorktreeNewBranch, GitWorktreeExistingBranch and GitWorktreeDetached.
	Mode string `json:"mode"`
	// Kind is the kind of reference listed, "local", "remote" or "tag"; an existing-branch
	// worktree lists local branches whatever it is.
	Kind string `json:"kind"`
	// Reference is the FullName of the held reference, empty for none.
	Reference string `json:"reference"`
	// Name is the new branch as typed; RequireName makes an empty one an error, as a submit
	// does.
	Name        string `json:"name"`
	RequireName bool   `json:"requireName"`
	// Revision is the revision as typed.
	Revision string `json:"revision"`
	// Destination is the destination as typed, and LastSuggestion the suggestion it last
	// followed, empty at first.
	Destination    string `json:"destination"`
	LastSuggestion string `json:"lastSuggestion"`
	// References are the repository's references, as GitReferences reads them.
	References []GitReference `json:"references"`
	// CheckedOutBranches are the Branch of every registered worktree.
	CheckedOutBranches []string `json:"checkedOutBranches"`
}

// GitWorktreeCreationPreview is what the dialog shows for a GitWorktreeCreationInput.
type GitWorktreeCreationPreview struct {
	// Choices are indices into the input's References the dialog lists, in their order.
	Choices []int `json:"choices"`
	// Reference is the FullName of the reference the dialog holds now, nil without choices.
	Reference *string `json:"reference"`
	// Branch is the cleaned and checked new branch name, nil outside GitWorktreeNewBranch.
	Branch *BranchNamePreview `json:"branch"`
	// SuggestedDestination is the next input's LastSuggestion.
	SuggestedDestination string `json:"suggestedDestination"`
	// Destination is what the destination field holds: the suggestion until the user edited
	// it, then what they typed.
	Destination           string `json:"destination"`
	DestinationIsAbsolute bool   `json:"destinationIsAbsolute"`
	// Ready says the dialog can create the worktree.
	Ready bool `json:"ready"`
}

// GitWorktreeCreationPreview derives the choices, the branch name, the destination and the
// readiness of the dialog that creates a worktree. It does not start git.
func (c *Client) GitWorktreeCreationPreview(ctx context.Context, input GitWorktreeCreationInput) (GitWorktreeCreationPreview, error) {
	input.References = nonNil(input.References)
	input.CheckedOutBranches = nonNil(input.CheckedOutBranches)
	var preview GitWorktreeCreationPreview
	if err := c.Execute(ctx, "git.worktreeCreationPreview", input, &preview); err != nil {
		return GitWorktreeCreationPreview{}, err
	}
	return preview, nil
}

// How a created worktree gets its checkout, for GitWorktreeCreation.Mode.
const (
	// GitWorktreeNewBranch creates a branch for the worktree.
	GitWorktreeNewBranch = "newBranch"
	// GitWorktreeExistingBranch checks out a local branch no other worktree has checked out.
	GitWorktreeExistingBranch = "existingBranch"
	// GitWorktreeDetached checks out a commit without a branch.
	GitWorktreeDetached = "detached"
)

// GitWorktreeCreation is what a new worktree checks out and where.
type GitWorktreeCreation struct {
	// Mode is one of GitWorktreeNewBranch, GitWorktreeExistingBranch and GitWorktreeDetached.
	Mode string
	// Name is the branch a GitWorktreeNewBranch worktree creates; the other modes take none.
	Name string
	// Reference is where the worktree starts: the start of a new branch, which tracks it when
	// it is a remote branch and no Revision is given; the local branch of a
	// GitWorktreeExistingBranch worktree; or the commit of a detached one. A detached worktree
	// may give a Revision instead.
	Reference *GitReference
	// Revision is the commit a new branch or a detached worktree starts at instead of
	// Reference's; an existing-branch worktree takes none.
	Revision string
	// Destination is the absolute path of the new checkout. Git refuses a directory that is
	// not empty.
	Destination string
	// NoCheckout registers the worktree and prepares its HEAD without filling its directory.
	NoCheckout bool
}

// GitCreateWorktree adds a worktree to the repository at root.
//
// GitCreateWorktree starts git and blocks; call it from a background goroutine.
func (c *Client) GitCreateWorktree(ctx context.Context, root string, creation GitWorktreeCreation) error {
	request := gitWriteRequest{
		Root:         root,
		Operation:    "createWorktree",
		WorktreeMode: creation.Mode,
		Name:         creation.Name,
		Revision:     creation.Revision,
		Destination:  creation.Destination,
		NoCheckout:   creation.NoCheckout,
	}
	if creation.Reference != nil {
		request.GitReference = creation.Reference.request()
	}
	return c.gitWrite(ctx, request)
}

// GitRemoveWorktree removes the worktree registered at path, and its checkout, from the
// repository at root. The worktree's branch is kept. A refusal is an *Error whose code names
// its reason: CodeGitWorktreeNotRegistered, CodeGitWorktreePrimary, CodeGitWorktreeCurrent
// (path is the worktree root belongs to) or CodeGitWorktreeLocked from Core, and
// CodeGitWorktreeHasChanges when Git refuses a checkout with changes; force removes it anyway
// and deletes those changes.
//
// GitRemoveWorktree starts git and blocks; call it from a background goroutine.
func (c *Client) GitRemoveWorktree(ctx context.Context, root, path string, force bool) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "removeWorktree", Destination: path, Force: force})
}

// GitLockWorktree locks the worktree registered at path, so it is not pruned or removed.
// Core refuses a path that is not registered (CodeGitWorktreeNotRegistered) and the
// primary worktree (CodeGitWorktreePrimary).
//
// GitLockWorktree starts git and blocks; call it from a background goroutine.
func (c *Client) GitLockWorktree(ctx context.Context, root, path string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "lockWorktree", Destination: path})
}

// GitUnlockWorktree unlocks the worktree registered at path.
// Core refuses a path that is not registered (CodeGitWorktreeNotRegistered) and the
// primary worktree (CodeGitWorktreePrimary).
//
// GitUnlockWorktree starts git and blocks; call it from a background goroutine.
func (c *Client) GitUnlockWorktree(ctx context.Context, root, path string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "unlockWorktree", Destination: path})
}

// GitPruneWorktrees removes the registrations of the repository at root whose checkouts are
// gone. It deletes no branch and no checkout.
//
// GitPruneWorktrees starts git and blocks; call it from a background goroutine.
func (c *Client) GitPruneWorktrees(ctx context.Context, root string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "pruneWorktrees"})
}

// GitRepairWorktrees repairs the links between the repository at root and its worktrees,
// after a checkout or the repository was moved.
//
// GitRepairWorktrees starts git and blocks; call it from a background goroutine.
func (c *Client) GitRepairWorktrees(ctx context.Context, root string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "repairWorktrees"})
}
