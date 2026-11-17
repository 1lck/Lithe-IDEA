package core

import (
	"context"
	"encoding/json"
)

// RunConfigGenerated is Core's generated run configuration layer: the runs the
// build provider plugins declare. The entries stay raw: their fields differ by
// type and the host only lists and forwards them, so Core remains the one place
// that knows their shape.
type RunConfigGenerated struct {
	Version        int               `json:"version"`
	Configurations []json.RawMessage `json:"configurations"`
}

// RunConfigGeneration is the outcome of generating the provider runs.
type RunConfigGeneration struct {
	Generated  RunConfigGenerated `json:"generated"`
	EntryCount int                `json:"entryCount"`
}

// GenerateRunConfigurations turns providerRuns, the complete run selector list
// of the build providers, into root's generated layer, replacing the previous
// one. Core detects no entries itself, and the layer lives only in Core's
// memory: nothing is written into the workspace or a cache.
func (c *Client) GenerateRunConfigurations(ctx context.Context, root string, providerRuns json.RawMessage) (RunConfigGeneration, error) {
	var result RunConfigGeneration
	request := struct {
		Root         string          `json:"root"`
		ProviderRuns json.RawMessage `json:"providerRuns,omitempty"`
	}{root, providerRuns}
	if err := c.Execute(ctx, "runConfig.generate", request, &result); err != nil {
		return RunConfigGeneration{}, err
	}
	return result, nil
}

// ExecutionEnvironmentRequest is the input of the launch environment merge.
// Overrides values are either a string or a {toolchain, property} binding; a
// binding the host could not resolve to text contributes nothing. A runtime
// home such as JAVA_HOME is not chosen here: it comes from the toolchain
// installation the step selected (applyToolchainSelection in the workbench).
type ExecutionEnvironmentRequest struct {
	Inherited       map[string]string `json:"inherited"`
	Overrides       map[string]any    `json:"overrides"`
	CaseInsensitive bool              `json:"caseInsensitive"`
}

// ResolveExecutionEnvironment merges inherited values and the explicit
// overrides into the environment a launch uses; overrides win.
func (c *Client) ResolveExecutionEnvironment(ctx context.Context, request ExecutionEnvironmentRequest) (map[string]string, error) {
	if request.Inherited == nil {
		request.Inherited = map[string]string{}
	}
	if request.Overrides == nil {
		request.Overrides = map[string]any{}
	}
	var result struct {
		Environment map[string]string `json:"environment"`
	}
	if err := c.Execute(ctx, "execution.resolveEnvironment", request, &result); err != nil {
		return nil, err
	}
	return result.Environment, nil
}

// SearchPathCandidate is one directory a platform wants on the search path.
type SearchPathCandidate struct {
	Priority int    `json:"priority"`
	ID       string `json:"id"`
	Path     string `json:"path"`
}

// ResolveSearchPath keeps the existing entries' precedence, adds the candidates
// sorted by priority then identity and drops duplicates under the case policy.
func (c *Client) ResolveSearchPath(ctx context.Context, existing []string, candidates []SearchPathCandidate, caseInsensitive bool) ([]string, error) {
	if existing == nil {
		existing = []string{}
	}
	if candidates == nil {
		candidates = []SearchPathCandidate{}
	}
	var result []string
	if err := c.Execute(ctx, "execution.resolveSearchPath", struct {
		Existing        []string              `json:"existing"`
		Candidates      []SearchPathCandidate `json:"candidates"`
		CaseInsensitive bool                  `json:"caseInsensitive"`
	}{existing, candidates, caseInsensitive}, &result); err != nil {
		return nil, err
	}
	return result, nil
}
