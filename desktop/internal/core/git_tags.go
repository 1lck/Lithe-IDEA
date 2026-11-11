package core

import "context"

// GitCreateTag creates the tag name at revision in the repository at root. An empty message
// makes a lightweight tag; a non-empty one makes an annotated tag with that message. Core
// refuses a duplicate name or a revision that is not a commit with an invalid_request error.
//
// GitCreateTag starts git and blocks; call it from a background goroutine.
func (c *Client) GitCreateTag(ctx context.Context, root, name, revision, message string) error {
	return c.gitWrite(ctx, gitWriteRequest{
		Root:        root,
		Operation:   "createTag",
		Name:        name,
		Revision:    revision,
		Message:     message,
		Lightweight: message == "",
	})
}

// GitDeleteTag removes the tag name from the repository at root.
//
// GitDeleteTag starts git and blocks; call it from a background goroutine.
func (c *Client) GitDeleteTag(ctx context.Context, root, name string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "deleteTag", Name: name})
}
