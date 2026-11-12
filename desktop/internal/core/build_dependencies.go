package core

import (
	"context"
	"encoding/json"
)

// BuildDependency is one node of a project's dependency tree, as Core decoded it.
type BuildDependency struct {
	Name       string            `json:"name"`
	Group      string            `json:"group,omitempty"`
	Version    string            `json:"version,omitempty"`
	Scope      string            `json:"scope,omitempty"`
	Properties map[string]string `json:"properties,omitempty"`
	Children   []BuildDependency `json:"children"`
}

// BuildDependencyTree is the bounded dependency tree of one project, or of the workspace
// when Project is empty; Truncated says Core cut it at its bounds.
type BuildDependencyTree struct {
	Project      json.RawMessage   `json:"project"`
	Dependencies []BuildDependency `json:"dependencies"`
	Truncated    bool              `json:"truncated"`
}

// BuildDecodeDependenciesRequest decodes the output of a dependency command, or the result a
// provider answered for lithe/build/dependencies.
type BuildDecodeDependenciesRequest struct {
	WorkspaceRoot string `json:"workspaceRoot"`
	Root          string `json:"root"`
	// Project is the workspace-relative directory of the project the plan selected; empty
	// decodes for the instance root.
	Project    string          `json:"project,omitempty"`
	Output     string          `json:"output,omitempty"`
	OutputFile string          `json:"outputFile,omitempty"`
	Result     json.RawMessage `json:"result,omitempty"`
}

// PlanBuildDependencies plans the command that prints a project's dependency tree, or the
// request its build provider answers (build.dependencyPlan).
func (c *Client) PlanBuildDependencies(ctx context.Context, manifest json.RawMessage, buildSystemID string, request BuildPlanRequest) (BuildPlan, error) {
	return c.planBuild(ctx, "build.dependencyPlan", manifest, buildSystemID, request)
}

// DecodeBuildDependencies turns dependency output or a provider result into one project's
// bounded tree (build.decodeDependencies).
func (c *Client) DecodeBuildDependencies(ctx context.Context, manifest json.RawMessage, buildSystemID string, request BuildDecodeDependenciesRequest) (BuildDependencyTree, error) {
	const command = "build.decodeDependencies"
	var result buildOutcome
	if err := c.Execute(ctx, command, struct {
		Manifest      json.RawMessage                `json:"manifest"`
		BuildSystemID string                         `json:"buildSystemID"`
		Request       BuildDecodeDependenciesRequest `json:"request"`
	}{manifest, buildSystemID, request}, &result); err != nil {
		return BuildDependencyTree{}, err
	}
	if err := result.failure(command); err != nil {
		return BuildDependencyTree{}, err
	}
	if result.Dependencies == nil {
		return BuildDependencyTree{}, newParseError(command, "build dependencies returned no tree", "")
	}
	return *result.Dependencies, nil
}
