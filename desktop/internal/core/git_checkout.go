package core

import "context"

// GitCheckoutBranch asks Core to interpret bounded Git HEAD text. Empty means
// no branch or detached revision could be displayed.
func (c *Client) GitCheckoutBranch(ctx context.Context, text string) (string, error) {
	var result struct {
		Branch *string `json:"branch"`
	}
	if err := c.Execute(ctx, "git.parseCheckoutMetadata", struct {
		Text string `json:"text"`
	}{text}, &result); err != nil {
		return "", err
	}
	if result.Branch == nil {
		return "", nil
	}
	return *result.Branch, nil
}

// GitDirectoryPointer asks Core to interpret a bounded .git pointer. Empty
// means that it does not identify a Git directory; path resolution is native IO.
func (c *Client) GitDirectoryPointer(ctx context.Context, text string) (string, error) {
	var result struct {
		Path *string `json:"path"`
	}
	if err := c.Execute(ctx, "git.parseGitdirPointer", struct {
		Text string `json:"text"`
	}{text}, &result); err != nil {
		return "", err
	}
	if result.Path == nil {
		return "", nil
	}
	return *result.Path, nil
}
