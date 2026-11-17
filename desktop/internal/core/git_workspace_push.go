package core

import (
	"context"
	"encoding/json"
)

// WorkspacePushState is whether a repository of a workspace push can push, and why not.
type WorkspacePushState string

const (
	// WorkspacePushReady has commits to send, or a remote branch to create.
	WorkspacePushReady WorkspacePushState = "ready"
	// WorkspacePushUpToDate is a branch its remote already has.
	WorkspacePushUpToDate WorkspacePushState = "upToDate"
	// WorkspacePushNoRemote is a repository without a remote.
	WorkspacePushNoRemote WorkspacePushState = "noRemote"
	// WorkspacePushEmpty is a branch without a commit yet.
	WorkspacePushEmpty WorkspacePushState = "emptyRepository"
	// WorkspacePushDetached is a repository whose HEAD names a commit instead of a branch.
	WorkspacePushDetached WorkspacePushState = "detachedHead"
	// WorkspacePushFailed is a repository Git could not read or resolve; Detail says why.
	WorkspacePushFailed WorkspacePushState = "failed"
)

// WorkspacePushRepository is Core's push review of one repository of a workspace push.
type WorkspacePushRepository struct {
	ID    string             `json:"id"`
	State WorkspacePushState `json:"state"`
	// Branch is the checked-out branch, empty when HEAD is detached or the repository could
	// not be read.
	Branch string `json:"branch"`
	// Preview is the push review of a ready or up-to-date repository, nil otherwise.
	Preview *GitPushPreview `json:"preview"`
	// NeedsTarget reports a divergent upstream no destination was picked for.
	NeedsTarget bool `json:"needsTarget"`
	// Records are the listed repositories this one records as submodules. They come earlier
	// in the list, and this one should not push after one of them failed to.
	Records []string `json:"records"`
	Detail  string   `json:"detail"`
}

type workspacePushPreviewRequest struct {
	Repositories []WorkspaceCommitRepository `json:"repositories"`
	Limit        int                         `json:"limit,omitempty"`
	PushTags     GitPushTags                 `json:"pushTags,omitempty"`
	PushTargets  map[string]PushTargetChoice `json:"pushTargets,omitempty"`
}

// WorkspacePushPreview reviews pushing the checked-out branch of every repository, as IDEA's
// Push dialog lists them. The answer is in push order: a submodule before every listed
// repository that records it. targets answers divergent upstreams by repository ID.
//
// WorkspacePushPreview starts git and blocks; call it from a background goroutine.
func (c *Client) WorkspacePushPreview(ctx context.Context, repositories []WorkspaceCommitRepository, tags GitPushTags, targets map[string]PushTargetChoice) ([]WorkspacePushRepository, error) {
	request := workspacePushPreviewRequest{Repositories: nonNil(repositories), Limit: 100, PushTags: tags, PushTargets: targets}
	var response struct {
		Repositories []WorkspacePushRepository `json:"repositories"`
	}
	if err := c.Execute(ctx, "git.workspacePushPreview", request, &response); err != nil {
		return nil, err
	}
	for i := range response.Repositories {
		r := &response.Repositories[i]
		r.Records = nonNil(r.Records)
		if r.Preview != nil {
			r.Preview.Tags = nonNil(r.Preview.Tags)
			r.Preview.Commits = nonNil(r.Preview.Commits)
		}
	}
	return nonNil(response.Repositories), nil
}

// GitPushInWorkspace is GitPush for one repository of a workspace push: Git also refuses the
// push while a submodule commit it records is on no remote (--recurse-submodules=check).
//
// GitPushInWorkspace starts git and blocks; call it from a background goroutine.
func (c *Client) GitPushInWorkspace(ctx context.Context, root string, preview GitPushPreview, tags GitPushTags, target PushTargetChoice) error {
	request, err := pushRequest(root, preview, tags, target, false)
	if err != nil {
		return err
	}
	request.CheckSubmodules = true
	return c.gitWrite(ctx, request)
}

// pushRequest is the git.write request of a push validated against preview.
func pushRequest(root string, preview GitPushPreview, tags GitPushTags, target PushTargetChoice, force bool) (gitWriteRequest, error) {
	reviewed := expectedPush{
		LocalBranch: preview.LocalBranch, LocalHead: preview.LocalHead, Remote: preview.Remote,
		RemoteBranch: preview.RemoteBranch, TargetKind: preview.TargetKind,
		RemoteTrackingOID: preview.RemoteTrackingOID, Tags: nonNil(preview.Tags),
	}
	raw, err := json.Marshal(reviewed)
	if err != nil {
		return gitWriteRequest{}, err
	}
	return gitWriteRequest{
		Root: root, Operation: "push", Force: force, PushTags: string(tags), PushTarget: string(target),
		ExpectedPush: raw,
		GitReference: &gitReferenceRequest{FullName: "refs/heads/" + preview.LocalBranch, ShortName: preview.LocalBranch, Kind: "local"},
	}, nil
}
