package core

import "context"

// gitReferenceRequest is the complete identity of a reference the kernel acts on. The kernel
// checks all three fields against the repository before it runs Git.
type gitReferenceRequest struct {
	FullName  string `json:"fullName"`
	ShortName string `json:"shortName"`
	Kind      string `json:"kind"`
}

// request is the identity of r as the kernel takes it.
func (r GitReference) request() *gitReferenceRequest {
	return &gitReferenceRequest{FullName: r.FullName, ShortName: r.ShortName, Kind: r.Kind}
}

// gitCheckoutPreflightRequest is the payload of git.checkoutPreflight.
type gitCheckoutPreflightRequest struct {
	Root         string               `json:"root"`
	GitReference *gitReferenceRequest `json:"gitReference"`
}

// gitCheckoutPreflightResponse is git.checkoutPreflight's answer.
type gitCheckoutPreflightResponse struct {
	BlockingPaths []string `json:"blockingPaths"`
}

// GitCheckoutPreflight returns the paths that would stop a checkout of reference in the
// repository at root: files with uncommitted changes whose content also differs between HEAD
// and reference, and untracked files reference tracks. An empty result means Git can switch
// without touching a local change.
//
// GitCheckoutPreflight starts git and blocks; call it from a background goroutine.
func (c *Client) GitCheckoutPreflight(ctx context.Context, root string, reference GitReference) ([]string, error) {
	var response gitCheckoutPreflightResponse
	request := gitCheckoutPreflightRequest{Root: root, GitReference: reference.request()}
	if err := c.Execute(ctx, "git.checkoutPreflight", request, &response); err != nil {
		return nil, err
	}
	return nonNil(response.BlockingPaths), nil
}

// CheckoutMode is what a checkout does with the local changes that would block it.
type CheckoutMode int

const (
	// CheckoutPlain lets Git refuse a checkout that would overwrite a local change.
	CheckoutPlain CheckoutMode = iota
	// CheckoutSmart stashes the local changes, switches, and restores them on the new branch.
	CheckoutSmart
	// CheckoutForce switches and discards the local changes that are in the way.
	CheckoutForce
)

// GitCheckout switches the repository at root to reference. A remote branch is checked out
// as the local branch of the same name tracking it: created when it does not exist yet,
// brought up to the remote branch when it does, and refused with CodeInvalidRequest when it
// tracks something else. A tag leaves HEAD detached. The current local branch is refused with
// CodeInvalidRequest. A smart checkout whose restore conflicts fails and leaves the stash in
// place.
//
// GitCheckout starts git and blocks; call it from a background goroutine.
func (c *Client) GitCheckout(ctx context.Context, root string, reference GitReference, mode CheckoutMode) error {
	return c.gitWrite(ctx, gitWriteRequest{
		Root:         root,
		Operation:    "checkout",
		GitReference: reference.request(),
		Force:        mode == CheckoutForce,
		AutoStash:    mode == CheckoutSmart,
	})
}

// GitCheckoutRevision detaches HEAD of the repository at root at revision, which is anything
// Git resolves to a commit: a hash, a tag, a branch or an expression such as HEAD~2.
//
// GitCheckoutRevision starts git and blocks; call it from a background goroutine.
func (c *Client) GitCheckoutRevision(ctx context.Context, root, revision string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "checkoutRevision", Revision: revision})
}

// GitCreateBranch creates the local branch name at from in the repository at root, and
// switches to it when checkout is set. The new branch tracks nothing, whatever from is, so
// its first push cannot land on the branch it started from.
//
// GitCreateBranch starts git and blocks; call it from a background goroutine.
func (c *Client) GitCreateBranch(ctx context.Context, root, name string, from GitReference, checkout bool) error {
	return c.gitWrite(ctx, gitWriteRequest{
		Root:         root,
		Operation:    "createBranch",
		GitReference: from.request(),
		Name:         name,
		Checkout:     checkout,
	})
}

// GitRenameBranch renames the local branch to name in the repository at root.
//
// GitRenameBranch starts git and blocks; call it from a background goroutine.
func (c *Client) GitRenameBranch(ctx context.Context, root string, branch GitReference, name string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "renameBranch", GitReference: branch.request(), Name: name})
}

// GitMerge merges reference into the branch checked out in the repository at root. Core refuses
// the checked-out branch itself. A merge Git stops at conflicts stays active; git.operationState
// reports it.
//
// GitMerge starts git and blocks; call it from a background goroutine.
func (c *Client) GitMerge(ctx context.Context, root string, reference GitReference) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "merge", GitReference: reference.request()})
}

// GitRebaseOnto replays the branch checked out in the repository at root onto reference. Core
// refuses the checked-out branch itself. A rebase Git stops at conflicts stays active.
//
// GitRebaseOnto starts git and blocks; call it from a background goroutine.
func (c *Client) GitRebaseOnto(ctx context.Context, root string, reference GitReference) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "rebase", GitReference: reference.request()})
}

// GitCheckoutAndRebase checks out the local or remote branch reference in the repository at root
// and replays it onto the branch that was checked out before. Core refuses it while the working
// tree has changes.
//
// GitCheckoutAndRebase starts git and blocks; call it from a background goroutine.
func (c *Client) GitCheckoutAndRebase(ctx context.Context, root string, reference GitReference) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "checkoutAndRebase", GitReference: reference.request()})
}

// GitSetUpstream makes the local branch track the remote branch upstream in the repository at root.
//
// GitSetUpstream starts git and blocks; call it from a background goroutine.
func (c *Client) GitSetUpstream(ctx context.Context, root string, branch, upstream GitReference) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "setUpstream", Name: branch.ShortName, GitReference: upstream.request()})
}

// GitUnsetUpstream makes the local branch track no remote branch in the repository at root.
//
// GitUnsetUpstream starts git and blocks; call it from a background goroutine.
func (c *Client) GitUnsetUpstream(ctx context.Context, root string, branch GitReference) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "unsetUpstream", Name: branch.ShortName})
}

// GitBranchDeletion is what a deleted branch was, enough to create it again.
type GitBranchDeletion struct {
	// Name is the branch's short name.
	Name string `json:"name"`
	// DeletedTarget is the commit the branch pointed at.
	DeletedTarget string `json:"deletedTarget"`
}

// GitDeleteBranch deletes the local branch from the repository at root, even when its commits
// are not merged anywhere, and returns what it was. The current branch is refused with
// CodeInvalidRequest.
//
// GitDeleteBranch starts git and blocks; call it from a background goroutine.
func (c *Client) GitDeleteBranch(ctx context.Context, root string, branch GitReference) (GitBranchDeletion, error) {
	response, err := c.gitWriteAnswer(ctx, gitWriteRequest{Root: root, Operation: "deleteBranch", GitReference: branch.request()})
	if err != nil {
		return GitBranchDeletion{}, err
	}
	if response.BranchDeletion == nil {
		return GitBranchDeletion{Name: branch.ShortName}, nil
	}
	return *response.BranchDeletion, nil
}

// BranchNameRequest asks how a typed branch name is cleaned and whether it can be created.
type BranchNameRequest struct {
	// RawName is the text exactly as the user typed it.
	RawName string
	// RequireName makes an empty name an error, as a submit does; typing leaves it unset.
	RequireName bool
	// References are the repository's loaded references the name must not clash with.
	References []GitReference
	// From is the reference the dialog was opened on, which proposes InitialName; nil has
	// none.
	From *GitReference
}

// gitBranchNameReference is one loaded reference as git.branchNamePreview takes it.
type gitBranchNameReference struct {
	Kind      string `json:"kind"`
	ShortName string `json:"shortName"`
}

// gitBranchNamePreviewRequest is the payload of git.branchNamePreview.
type gitBranchNamePreviewRequest struct {
	RawName     string                   `json:"rawName"`
	RequireName bool                     `json:"requireName"`
	References  []gitBranchNameReference `json:"references"`
	Reference   *gitBranchNameReference  `json:"reference,omitempty"`
}

// BranchNameErrorCode is why a cleaned branch name cannot be created.
type BranchNameErrorCode string

const (
	// BranchNameEmpty is an empty name on submit.
	BranchNameEmpty BranchNameErrorCode = "empty"
	// BranchNameHead is the name HEAD, which Git reserves.
	BranchNameHead BranchNameErrorCode = "head"
	// BranchNameClashesWithRemote is a name a remote branch already uses.
	BranchNameClashesWithRemote BranchNameErrorCode = "clashesWithRemote"
	// BranchNameClashesWithDirectory is a name local branches are stored below.
	BranchNameClashesWithDirectory BranchNameErrorCode = "clashesWithDirectory"
	// BranchNameAlreadyExists is the name of an existing local branch.
	BranchNameAlreadyExists BranchNameErrorCode = "alreadyExists"
	// BranchNameClashesWithBranchPrefix is a name below an existing local branch, as a/b is
	// below a.
	BranchNameClashesWithBranchPrefix BranchNameErrorCode = "clashesWithBranchPrefix"
)

// BranchNameError is a reason a name cannot be created, with the names a message shows.
type BranchNameError struct {
	Code BranchNameErrorCode `json:"code"`
	// Name is the candidate name, or the directory it clashes with.
	Name string `json:"name,omitempty"`
	// Branch is the existing local branch below which the name would be stored.
	Branch string `json:"branch,omitempty"`
}

// BranchNamePreview is how the kernel cleans one typed branch name.
type BranchNamePreview struct {
	// TypingCleanedName is the text the field shows while the user types: characters Git
	// refuses are dropped and spaces become "-".
	TypingCleanedName string `json:"typingCleanedName"`
	// CleanedName is the name a submit creates: TypingCleanedName without a trailing dot,
	// slash or ".lock", trimmed.
	CleanedName string `json:"cleanedName"`
	// InitialName is the name proposed for the reference the dialog was opened on.
	InitialName string `json:"initialName"`
	// Error is why CleanedName cannot be created, nil when it can.
	Error *BranchNameError `json:"error"`
}

// branchNameReference is r as git.branchNamePreview takes it.
func branchNameReference(r GitReference) gitBranchNameReference {
	return gitBranchNameReference{Kind: r.Kind, ShortName: r.ShortName}
}

// GitBranchNamePreview cleans and checks a typed branch name against the references the
// request carries. It does not read the repository, so it can run on the window thread; Git
// still decides whether the name is valid when the branch is created. A name longer than the
// kernel accepts fails with CodeInvalidRequest.
func (c *Client) GitBranchNamePreview(ctx context.Context, request BranchNameRequest) (BranchNamePreview, error) {
	payload := gitBranchNamePreviewRequest{
		RawName:     request.RawName,
		RequireName: request.RequireName,
		References:  make([]gitBranchNameReference, 0, len(request.References)),
	}
	for _, reference := range request.References {
		payload.References = append(payload.References, branchNameReference(reference))
	}
	if request.From != nil {
		from := branchNameReference(*request.From)
		payload.Reference = &from
	}
	var preview BranchNamePreview
	if err := c.Execute(ctx, "git.branchNamePreview", payload, &preview); err != nil {
		return BranchNamePreview{}, err
	}
	return preview, nil
}
