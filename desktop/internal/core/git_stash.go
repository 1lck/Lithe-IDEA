package core

import "context"

// GitStash is one entry of the stash list. Reference is the positional name (stash@{0}); OID
// is the immutable identity writes should use.
type GitStash struct {
	Reference string `json:"reference"`
	OID       string `json:"oid"`
	Message   string `json:"message"`
	Date      string `json:"date"`
}

// GitStashes lists the stash entries, newest first.
//
// GitStashes starts git and blocks; call it from a background goroutine.
func (c *Client) GitStashes(ctx context.Context, root string) ([]GitStash, error) {
	var response struct {
		Stashes []GitStash `json:"stashes"`
	}
	if err := c.Execute(ctx, "git.stashes", gitRootRequest{Root: root}, &response); err != nil {
		return nil, err
	}
	return nonNil(response.Stashes), nil
}

// GitStashPush stashes the local changes under message, with the untracked files when asked.
func (c *Client) GitStashPush(ctx context.Context, root, message string, includeUntracked bool) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "stashPush", Message: message, IncludeUntracked: includeUntracked})
}

// GitStashApply applies a stash and keeps it.
func (c *Client) GitStashApply(ctx context.Context, root string, stash GitStash) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "stashApply", Reference: stash.OID})
}

// GitStashPop applies a stash and drops it once it applied.
func (c *Client) GitStashPop(ctx context.Context, root string, stash GitStash) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "stashPop", Reference: stash.OID})
}

// GitStashDrop drops a stash.
func (c *Client) GitStashDrop(ctx context.Context, root string, stash GitStash) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "stashDrop", Reference: stash.OID})
}
