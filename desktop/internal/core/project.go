package core

import "context"

// ProjectNameProblem is Core's validation result for a new project directory name.
// An empty value means the name is valid.
type ProjectNameProblem string

// CheckProjectName asks Core to validate the name without touching the filesystem.
func (c *Client) CheckProjectName(ctx context.Context, name string) (ProjectNameProblem, error) {
	var result struct {
		Status string `json:"status"`
		Name   *struct {
			Problem ProjectNameProblem `json:"problem"`
		} `json:"name"`
	}
	if err := c.Execute(ctx, "project.checkName", struct {
		ProjectName string `json:"projectName"`
	}{name}, &result); err != nil {
		return "", err
	}
	if result.Status != "ok" || result.Name == nil {
		return "", newParseError("project.checkName", "invalid project name response", "")
	}
	return result.Name.Problem, nil
}

// InitializeGit creates a Git repository in an existing directory using Core's
// repository setup contract. Core refuses a directory inside a repository.
func (c *Client) InitializeGit(ctx context.Context, root string) error {
	return c.Execute(ctx, "git.initialize", struct {
		Root  string `json:"root"`
		Scope string `json:"scope"`
	}{root, "local"}, nil)
}
