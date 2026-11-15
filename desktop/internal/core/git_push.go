package core

import (
	"context"
	"encoding/json"
)

// GitPushTags says which tags a push sends along with the branch.
type GitPushTags string

const (
	// GitPushTagsNone sends no tags.
	GitPushTagsNone GitPushTags = "none"
	// GitPushTagsAll sends every tag.
	GitPushTagsAll GitPushTags = "all"
	// GitPushTagsReachable sends the annotated tags reachable from the pushed commits.
	GitPushTagsReachable GitPushTags = "reachable"
)

// GitPushTag is a tag identity a reviewed push would send.
type GitPushTag struct {
	FullName string `json:"fullName"`
	ObjectID string `json:"objectId"`
}

// GitPushPreview is where a push of a local branch would go and the commits it would send.
// It is also the review a push is validated against: GitPush sends it back unchanged.
type GitPushPreview struct {
	LocalBranch  string `json:"localBranch"`
	LocalHead    string `json:"localHead"`
	Remote       string `json:"remote"`
	RemoteBranch string `json:"remoteBranch"`
	// TargetKind is tracking, publish or divergent. A divergent destination is only pushed
	// once the user chose a PushTargetChoice.
	TargetKind          string       `json:"targetKind"`
	CreatesRemoteBranch bool         `json:"createsRemoteBranch"`
	RemoteTrackingOID   *string      `json:"remoteTrackingOid"`
	Upstream            *string      `json:"upstream"`
	Tags                []GitPushTag `json:"tags"`
	Commits             []GitCommit  `json:"commits"`
	HasMore             bool         `json:"hasMore"`
}

type gitPushPreviewPayload struct {
	Root         string               `json:"root"`
	GitReference *gitReferenceRequest `json:"gitReference,omitempty"`
	Limit        int                  `json:"limit,omitempty"`
	PushTags     GitPushTags          `json:"pushTags,omitempty"`
	PushTarget   PushTargetChoice     `json:"pushTarget,omitempty"`
}

// GitPushPreviewOf resolves the destination of pushing branch (the checked-out branch when
// branch is the zero reference) and the bounded commits the remote lacks. target answers a
// divergent destination and is ignored otherwise. A repository with no remote fails with Core's
// invalid_request error.
//
// GitPushPreviewOf starts git and blocks; call it from a background goroutine.
func (c *Client) GitPushPreviewOf(ctx context.Context, root string, branch GitReference, tags GitPushTags, target PushTargetChoice) (GitPushPreview, error) {
	payload := gitPushPreviewPayload{Root: root, Limit: 100, PushTags: tags, PushTarget: target}
	if branch.FullName != "" {
		payload.GitReference = branch.request()
	}
	var preview GitPushPreview
	if err := c.Execute(ctx, "git.pushPreview", payload, &preview); err != nil {
		return GitPushPreview{}, err
	}
	preview.Tags = nonNil(preview.Tags)
	preview.Commits = nonNil(preview.Commits)
	return preview, nil
}

// expectedPush is the part of a preview Core checks a push against.
type expectedPush struct {
	LocalBranch       string       `json:"localBranch"`
	LocalHead         string       `json:"localHead"`
	Remote            string       `json:"remote"`
	RemoteBranch      string       `json:"remoteBranch"`
	TargetKind        string       `json:"targetKind"`
	RemoteTrackingOID *string      `json:"remoteTrackingOid"`
	Tags              []GitPushTag `json:"tags"`
}

// GitPush sends the commits the user reviewed in preview. Core rejects the push as stale when
// the local tip, the destination or the remote-tracking commit moved since the preview. force
// pushes with a lease bound to the reviewed remote commit; it never overwrites a commit the
// user did not see.
//
// GitPush starts git and blocks; call it from a background goroutine and observe its progress
// with WithGitProgress.
func (c *Client) GitPush(ctx context.Context, root string, preview GitPushPreview, tags GitPushTags, target PushTargetChoice, force bool) error {
	reviewed := expectedPush{
		LocalBranch: preview.LocalBranch, LocalHead: preview.LocalHead, Remote: preview.Remote,
		RemoteBranch: preview.RemoteBranch, TargetKind: preview.TargetKind,
		RemoteTrackingOID: preview.RemoteTrackingOID, Tags: nonNil(preview.Tags),
	}
	raw, err := json.Marshal(reviewed)
	if err != nil {
		return err
	}
	return c.gitWrite(ctx, gitWriteRequest{
		Root: root, Operation: "push", Force: force, PushTags: string(tags), PushTarget: string(target),
		ExpectedPush: raw,
		GitReference: &gitReferenceRequest{FullName: "refs/heads/" + preview.LocalBranch, ShortName: preview.LocalBranch, Kind: "local"},
	})
}
